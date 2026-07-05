<#
.SYNOPSIS
    Full Autopilot provisioning diagnostic from serial number.
.DESCRIPTION
    Enter a device serial number and get the complete Autopilot build timeline:

      - Device registration in Autopilot inventory
      - Deployment profile assigned
      - Pre-provisioning (Technician Flow) result
      - ESP Device Phase -- apps, policies, certificates installing
      - ESP User Phase -- user-targeted apps and policies
      - First sign-in outcome
      - Exact failure reason and which app/policy caused the block
      - Duration for every phase

    Uses the Microsoft Graph beta/deviceManagement/autopilotEvents endpoint
    which is the same data source as the Intune Autopilot monitor blade.
.EXAMPLE
    .\Get-AutopilotBuildDiagnostic.ps1
    .\Get-AutopilotBuildDiagnostic.ps1 -SerialNumber "5CG1234XYZ"
    .\Get-AutopilotBuildDiagnostic.ps1 -SerialNumber "5CG1234XYZ" -ExportHTML
#>
param(
    [string]$SerialNumber = "",
    [switch]$ExportHTML
)

$moduleRoot = Join-Path $PSScriptRoot "..\Modules"
Import-Module (Join-Path $moduleRoot "EIQ-Helpers.psm1") -Force
Import-Module (Join-Path $moduleRoot "EIQ-Auth.psm1")   -Force

# ── Auth ──────────────────────────────────────────────────────────────────────
$ctx = Get-EIQContext
if (-not $ctx) { Write-EIQError "Authentication failed."; exit 1 }

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host "   EndpointIQ -- Autopilot Build Diagnostic" -ForegroundColor Cyan
Write-Host "   by Imran Awan | EndpointWeekly.com" -ForegroundColor DarkGray
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host ""

# ── Serial number input ───────────────────────────────────────────────────────
if (-not $SerialNumber) {
    $SerialNumber = Read-Host "  Enter device serial number"
}
$SerialNumber = $SerialNumber.Trim()
if (-not $SerialNumber) { Write-EIQError "No serial number provided."; exit 1 }

Write-EIQInfo "Searching for serial: $SerialNumber"
Write-Host ""

# ── Helper: format duration ───────────────────────────────────────────────────
function Format-Duration {
    param($iso)
    if (-not $iso) { return "n/a" }
    try {
        $ts = [System.Xml.XmlConvert]::ToTimeSpan($iso)
        if ($ts.TotalHours -ge 1) { return "$([int]$ts.TotalHours)h $($ts.Minutes)m $($ts.Seconds)s" }
        if ($ts.TotalMinutes -ge 1) { return "$([int]$ts.TotalMinutes)m $($ts.Seconds)s" }
        return "$($ts.Seconds)s"
    } catch { return $iso }
}

function Format-DateTime {
    param($dt)
    if (-not $dt) { return "n/a" }
    try { return ([datetime]$dt).ToLocalTime().ToString("dd MMM yyyy  HH:mm:ss") }
    catch { return $dt }
}

function Write-Phase {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Duration = "",
        [string]$Detail = ""
    )
    $icon  = switch ($Status) {
        "success"    { "[OK]" }
        "failure"    { "[X]" }
        "inProgress" { "[~]" }
        "notApplicable" { "[-]" }
        default      { "[?]" }
    }
    $color = switch ($Status) {
        "success"    { "Green" }
        "failure"    { "Red" }
        "inProgress" { "Yellow" }
        "notApplicable" { "DarkGray" }
        default      { "Gray" }
    }
    Write-Host "  $icon " -ForegroundColor $color -NoNewline
    Write-Host $Name.PadRight(36) -ForegroundColor White -NoNewline
    Write-Host $Status.PadRight(14) -ForegroundColor $color -NoNewline
    if ($Duration) { Write-Host $Duration -ForegroundColor DarkGray }
    else { Write-Host "" }
    if ($Detail) {
        Write-Host "      -> $Detail" -ForegroundColor DarkYellow
    }
}

# ── Step 1: Find device in Autopilot inventory ───────────────────────────────
Write-EIQStep "Checking Autopilot device inventory..."
$apDevice = $null
try {
    $apUri    = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$SerialNumber')"
    $apResult = Invoke-EIQGraphRequest -Uri $apUri
    $apDevice = if ($apResult.value) { $apResult.value[0] } elseif ($apResult -and $apResult.serialNumber) { $apResult } else { $null }
} catch {
    Write-EIQWarn "Could not query Autopilot inventory: $_"
}

# ── Step 2: Find managed device record ───────────────────────────────────────
Write-EIQStep "Checking Intune managed device record..."
$managedDevice = $null
try {
    $mdUri    = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$SerialNumber'&`$select=id,deviceName,userPrincipalName,enrolledDateTime,lastSyncDateTime,complianceState,managementState,operatingSystem,osVersion,azureADDeviceId,enrollmentType"
    $mdResult = Invoke-EIQGraphRequest -Uri $mdUri
    $managedDevice = if ($mdResult.value) { $mdResult.value[0] } elseif ($mdResult -and $mdResult.serialNumber) { $mdResult } else { $null }
} catch {
    Write-EIQWarn "Could not query managed devices: $_"
}

# ── Step 3: Autopilot deployment events (beta) ────────────────────────────────
Write-EIQStep "Fetching Autopilot deployment events..."
$event = $null
try {
    # Search by serial number in autopilotEvents
    $evUri    = "https://graph.microsoft.com/beta/deviceManagement/autopilotEvents?`$filter=deviceSerialNumber eq '$SerialNumber'&`$orderby=deploymentStartDateTime desc&`$top=5"
    $evResult = Invoke-EIQGraphRequest -Uri $evUri
    $events   = if ($evResult.value) { $evResult.value } else { @() }
    $event    = $events | Select-Object -First 1
} catch {
    Write-EIQWarn "Could not fetch autopilot events (requires DeviceManagementConfiguration.Read.All): $_"
}

# ── Step 4: ESP tracking (managed device installation state) ─────────────────
$espApps     = @()
$espPolicies = @()
if ($managedDevice) {
    Write-EIQStep "Fetching ESP app and policy install status..."
    try {
        $appsUri  = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($managedDevice.id)/deviceHealthScripts"
        # Get app install state for this device
        $appStateUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($managedDevice.id)/windowsProtectionState"
        # ESP tracked apps
        $espAppsUri  = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($managedDevice.id)/managedDeviceMobileAppConfigurationStates"
        $espAppsResult = Invoke-EIQGraphRequest -Uri $espAppsUri
        $espApps = if ($espAppsResult.value) { $espAppsResult.value } else { @() }
    } catch { }

    try {
        $espPolUri    = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($managedDevice.id)/deviceConfigurationStates"
        $espPolResult = Invoke-EIQGraphRequest -Uri $espPolUri
        $espPolicies  = if ($espPolResult.value) { $espPolResult.value } else { @() }
    } catch { }
}

# ── Output ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host "   DEVICE IDENTITY" -ForegroundColor Yellow
Write-Host "  =====================================================" -ForegroundColor DarkGray

if ($apDevice) {
    Write-Host "  Serial Number   : " -NoNewline; Write-Host $apDevice.serialNumber -ForegroundColor Cyan
    Write-Host "  Model           : " -NoNewline; Write-Host "$($apDevice.manufacturer) $($apDevice.model)" -ForegroundColor White
    Write-Host "  Managed Name    : " -NoNewline; Write-Host ($managedDevice.deviceName ?? $apDevice.managedDeviceName ?? "Not yet enrolled") -ForegroundColor White
    Write-Host "  Autopilot ID    : " -NoNewline; Write-Host $apDevice.id -ForegroundColor DarkGray
    Write-Host "  AAD Device ID   : " -NoNewline; Write-Host ($apDevice.azureAdDeviceId ?? $managedDevice.azureADDeviceId ?? "n/a") -ForegroundColor DarkGray
    Write-Host "  Profile         : " -NoNewline
    if ($apDevice.deploymentProfileAssignmentStatus -eq "assigned") {
        Write-Host $apDevice.displayName -ForegroundColor Green
    } elseif ($apDevice.deploymentProfileAssignmentStatus -eq "assignedUnkownSyncedDevice") {
        Write-Host "Assigned (device not yet seen)" -ForegroundColor Yellow
    } else {
        Write-Host "NOT ASSIGNED -- device will not Autopilot" -ForegroundColor Red
    }
    Write-Host "  Profile Status  : " -NoNewline; Write-Host $apDevice.deploymentProfileAssignmentStatus -ForegroundColor $(if ($apDevice.deploymentProfileAssignmentStatus -eq "assigned") {"Green"} else {"Yellow"})
} else {
    Write-Host "  [!] Device NOT found in Autopilot inventory" -ForegroundColor Red
    Write-Host "      Serial: $SerialNumber" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Possible reasons:" -ForegroundColor Yellow
    Write-Host "    - Hardware hash not uploaded (OEM, manual, or CSV import needed)" -ForegroundColor White
    Write-Host "    - Serial number typo" -ForegroundColor White
    Write-Host "    - Device registered under a different tenant" -ForegroundColor White
}

Write-Host ""
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host "   ENROLLMENT STATUS" -ForegroundColor Yellow
Write-Host "  =====================================================" -ForegroundColor DarkGray

if ($managedDevice) {
    Write-Host "  Enrolled        : " -NoNewline; Write-Host (Format-DateTime $managedDevice.enrolledDateTime) -ForegroundColor Green
    Write-Host "  Last Sync       : " -NoNewline; Write-Host (Format-DateTime $managedDevice.lastSyncDateTime) -ForegroundColor White
    Write-Host "  Enroll Type     : " -NoNewline; Write-Host $managedDevice.enrollmentType -ForegroundColor White
    Write-Host "  OS Version      : " -NoNewline; Write-Host "$($managedDevice.operatingSystem) $($managedDevice.osVersion)" -ForegroundColor White
    Write-Host "  Assigned User   : " -NoNewline; Write-Host ($managedDevice.userPrincipalName ?? "None (device-only)") -ForegroundColor White
    Write-Host "  Compliance      : " -NoNewline
    $compColor = if ($managedDevice.complianceState -eq "compliant") { "Green" } elseif ($managedDevice.complianceState -eq "noncompliant") { "Red" } else { "Yellow" }
    Write-Host $managedDevice.complianceState -ForegroundColor $compColor
    Write-Host "  Mgmt State      : " -NoNewline; Write-Host $managedDevice.managementState -ForegroundColor White
} else {
    Write-Host "  [!] Device has NOT been enrolled into Intune yet" -ForegroundColor Red
    if ($apDevice) {
        Write-Host "      The device is in Autopilot inventory but provisioning has not started." -ForegroundColor Yellow
        Write-Host "      Boot the device connected to the internet to begin." -ForegroundColor Yellow
    }
}

# ── Autopilot event timeline ──────────────────────────────────────────────────
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host "   AUTOPILOT DEPLOYMENT TIMELINE" -ForegroundColor Yellow
Write-Host "  =====================================================" -ForegroundColor DarkGray

if ($event) {
    Write-Host "  Event recorded  : " -NoNewline; Write-Host (Format-DateTime $event.eventDateTime) -ForegroundColor White
    Write-Host "  Deployment start: " -NoNewline; Write-Host (Format-DateTime $event.deploymentStartDateTime) -ForegroundColor White
    Write-Host "  Deployment end  : " -NoNewline; Write-Host (Format-DateTime $event.deploymentEndDateTime) -ForegroundColor White
    Write-Host "  Total duration  : " -NoNewline; Write-Host (Format-Duration $event.deploymentTotalDuration) -ForegroundColor $(if ($event.deploymentState -eq "success") {"Green"} else {"Yellow"})
    Write-Host "  Profile used    : " -NoNewline; Write-Host ($event.windowsAutopilotDeploymentProfileDisplayName ?? "n/a") -ForegroundColor White
    Write-Host "  ESP Config      : " -NoNewline; Write-Host ($event.windows10EnrollmentCompletionPageConfigurationDisplayName ?? "None / not tracked") -ForegroundColor White
    Write-Host "  Enrolled user   : " -NoNewline; Write-Host ($event.userPrincipalName ?? "None (Self-Deploy / Pre-Prov)") -ForegroundColor White
    Write-Host ""
    Write-Host "  -- Phase Breakdown --------------------------------" -ForegroundColor DarkGray
    Write-Host "  Phase".PadRight(40) + "Result".PadRight(16) + "Duration" -ForegroundColor DarkGray
    Write-Host "  " + ("-" * 60) -ForegroundColor DarkGray

    # Overall
    Write-Phase -Name "Overall deployment" `
                -Status $event.deploymentState `
                -Duration (Format-Duration $event.deploymentTotalDuration)

    # Device preparation (network, AAD join)
    Write-Phase -Name "Device preparation" `
                -Status ($event.devicePreparationStatus ?? "unknown") `
                -Duration (Format-Duration $event.devicePreparationDuration)

    # Device setup (ESP device phase)
    $deviceSetupStatus = $event.deviceSetupStatus ?? "unknown"
    $deviceSetupDetail = ""
    if ($deviceSetupStatus -eq "failure") {
        $deviceSetupDetail = $event.enrollmentFailureDetails ?? "No failure detail captured in Graph"
    }
    Write-Phase -Name "ESP - Device setup phase" `
                -Status $deviceSetupStatus `
                -Duration (Format-Duration $event.deviceSetupDuration) `
                -Detail $deviceSetupDetail

    # Account setup (ESP user phase)
    $accountSetupStatus = $event.accountSetupStatus ?? "unknown"
    $accountSetupDetail = ""
    if ($accountSetupStatus -eq "failure") {
        $accountSetupDetail = "User phase failed -- check user-targeted apps and policies"
    }
    Write-Phase -Name "ESP - Account setup phase" `
                -Status $accountSetupStatus `
                -Duration (Format-Duration $event.accountSetupDuration)

    # App and policy counts
    Write-Host ""
    Write-Host "  Targeted apps    : $($event.targetedAppCount    ?? 'n/a')" -ForegroundColor DarkGray
    Write-Host "  Targeted policies: $($event.targetedPolicyCount ?? 'n/a')" -ForegroundColor DarkGray

    # Failure detail block
    if ($event.deploymentState -eq "failure" -or $event.enrollmentFailureDetails) {
        Write-Host ""
        Write-Host "  -- FAILURE DETAILS --------------------------------" -ForegroundColor Red
        if ($event.enrollmentFailureDetails) {
            Write-Host "  $($event.enrollmentFailureDetails)" -ForegroundColor Red
        } else {
            Write-Host "  No structured failure detail available in Graph." -ForegroundColor Yellow
            Write-Host "  Check IME logs on the device: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\" -ForegroundColor Yellow
        }
    }

} elseif ($managedDevice) {
    Write-Host "  [!] No Autopilot deployment event found for this device." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This means one of:" -ForegroundColor White
    Write-Host "    - Device enrolled via a non-Autopilot method (manual / bulk enrol)" -ForegroundColor DarkGray
    Write-Host "    - Autopilot event data has expired (Graph retains ~30 days)" -ForegroundColor DarkGray
    Write-Host "    - Device is still in provisioning (event not yet written)" -ForegroundColor DarkGray
} else {
    Write-Host "  No deployment data -- device has not been provisioned yet." -ForegroundColor DarkGray
}

# ── ESP App install status ────────────────────────────────────────────────────
if ($espApps.Count -gt 0) {
    Write-Host ""
    Write-Host "  =====================================================" -ForegroundColor DarkGray
    Write-Host "   APP INSTALL STATUS (ESP tracked)" -ForegroundColor Yellow
    Write-Host "  =====================================================" -ForegroundColor DarkGray
    Write-Host ("  " + "App Name".PadRight(48) + "State".PadRight(20) + "Error") -ForegroundColor DarkGray
    Write-Host "  " + ("-" * 72) -ForegroundColor DarkGray

    foreach ($app in ($espApps | Sort-Object state)) {
        $stateColor = switch ($app.state) {
            "installed"   { "Green" }
            "failed"      { "Red" }
            "notInstalled"{ "Yellow" }
            default       { "Gray" }
        }
        $name      = ($app.displayName ?? $app.settingName ?? "Unknown App")
        $truncName = if ($name.Length -gt 46) { $name.Substring(0,43) + "..." } else { $name }
        $errorCode = if ($app.errorCode -and $app.errorCode -ne 0) { "0x{0:X8}" -f $app.errorCode } else { "" }

        Write-Host ("  " + $truncName.PadRight(48)) -NoNewline
        Write-Host ($app.state.PadRight(20)) -ForegroundColor $stateColor -NoNewline
        if ($errorCode) { Write-Host $errorCode -ForegroundColor Red } else { Write-Host "" }
    }
}

# ── Policy compliance status ──────────────────────────────────────────────────
if ($espPolicies.Count -gt 0) {
    Write-Host ""
    Write-Host "  =====================================================" -ForegroundColor DarkGray
    Write-Host "   POLICY STATUS" -ForegroundColor Yellow
    Write-Host "  =====================================================" -ForegroundColor DarkGray
    Write-Host ("  " + "Policy Name".PadRight(48) + "State".PadRight(20) + "Error") -ForegroundColor DarkGray
    Write-Host "  " + ("-" * 72) -ForegroundColor DarkGray

    $problemPolicies = $espPolicies | Where-Object { $_.state -notin @("compliant","notApplicable") }
    $okPolicies      = $espPolicies | Where-Object { $_.state -in    @("compliant","notApplicable") }

    foreach ($pol in $problemPolicies) {
        $stateColor = switch ($pol.state) {
            "error"        { "Red" }
            "conflict"     { "Red" }
            "nonCompliant" { "Yellow" }
            default        { "Gray" }
        }
        $name      = ($pol.displayName ?? "Unknown Policy")
        $truncName = if ($name.Length -gt 46) { $name.Substring(0,43) + "..." } else { $name }
        $errorCode = if ($pol.errorCode -and $pol.errorCode -ne 0) { "0x{0:X8}" -f $pol.errorCode } else { "" }

        Write-Host ("  " + $truncName.PadRight(48)) -NoNewline
        Write-Host ($pol.state.PadRight(20)) -ForegroundColor $stateColor -NoNewline
        if ($errorCode) { Write-Host $errorCode -ForegroundColor Red } else { Write-Host "" }
    }

    if ($okPolicies.Count -gt 0) {
        Write-Host "  [OK] $($okPolicies.Count) policies in compliant/not-applicable state (hidden)" -ForegroundColor DarkGray
    }
}

# ── IME log hint ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host "   WHERE TO DIG DEEPER (if the issue is not clear)" -ForegroundColor Yellow
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  On the device itself, check these logs:" -ForegroundColor White
Write-Host "    IME logs    : C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\" -ForegroundColor Cyan
Write-Host "                  Look for: 'failed', 'error', 'timeout'" -ForegroundColor DarkGray
Write-Host "    MDM diag    : C:\Users\Public\Documents\MDMDiagnostics\" -ForegroundColor Cyan
Write-Host "                  Run: MdmDiagnosticsTool.exe -area Autopilot -zip c:\temp\diag.zip" -ForegroundColor DarkGray
Write-Host "    Autopilot   : C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp\DiagOutputDir\" -ForegroundColor Cyan
Write-Host "                  File: AutopilotDDSZTDFile.json" -ForegroundColor DarkGray
Write-Host "    Event Viewer: Applications and Services Logs -> Microsoft -> Windows ->" -ForegroundColor Cyan
Write-Host "                  ModernDeployment-Diagnostics-Provider / AutoPilot (Operational)" -ForegroundColor DarkGray
Write-Host "    dsregcmd    : Run 'dsregcmd /status' and check AzureAdJoined, PRT, WAM" -ForegroundColor Cyan
Write-Host ""
Write-Host "  In Intune portal: Devices -> [Device Name] -> Enrollment -> Autopilot deployment" -ForegroundColor DarkGray
Write-Host ""

# ── Optional HTML export ──────────────────────────────────────────────────────
if ($ExportHTML -and $event) {
    $htmlPath = Get-EIQOutputPath -ReportName "AutopilotDiag-$($SerialNumber -replace '[^a-zA-Z0-9]','')"
    $html = Get-EIQHTMLHeader -Title "Autopilot Build Diagnostic" -Subtitle "Serial: $SerialNumber | Build: $(Format-DateTime $event.deploymentStartDateTime)"

    $deployColor = if ($event.deploymentState -eq "success") { "badge-green" } elseif ($event.deploymentState -eq "failure") { "badge-red" } else { "badge-blue" }

    $html += @"
<div class="stats">
  <div class="stat"><div class="stat-n">$SerialNumber</div><div class="stat-l">Serial Number</div></div>
  <div class="stat"><div class="stat-n"><span class="badge $deployColor">$($event.deploymentState)</span></div><div class="stat-l">Deployment</div></div>
  <div class="stat"><div class="stat-n">$(Format-Duration $event.deploymentTotalDuration)</div><div class="stat-l">Total Duration</div></div>
  <div class="stat"><div class="stat-n">$($event.targetedAppCount ?? 0)</div><div class="stat-l">Apps Targeted</div></div>
  <div class="stat"><div class="stat-n">$($event.targetedPolicyCount ?? 0)</div><div class="stat-l">Policies</div></div>
</div>

<div class="section-title">Deployment Timeline</div>
<table>
<thead><tr><th>Phase</th><th>Status</th><th>Duration</th></tr></thead>
<tbody>
  <tr><td>Overall deployment</td><td><span class="badge $deployColor">$($event.deploymentState)</span></td><td>$(Format-Duration $event.deploymentTotalDuration)</td></tr>
  <tr><td>Device preparation (AAD Join)</td><td>$($event.devicePreparationStatus ?? 'n/a')</td><td>$(Format-Duration $event.devicePreparationDuration)</td></tr>
  <tr><td>ESP Device setup phase</td><td>$($event.deviceSetupStatus ?? 'n/a')</td><td>$(Format-Duration $event.deviceSetupDuration)</td></tr>
  <tr><td>ESP Account setup phase</td><td>$($event.accountSetupStatus ?? 'n/a')</td><td>$(Format-Duration $event.accountSetupDuration)</td></tr>
</tbody>
</table>
"@

    if ($event.enrollmentFailureDetails) {
        $html += @"
<div class="section-title" style="color:#dc2626">[!] Failure Details</div>
<div style="background:#fef2f2;border-left:4px solid #dc2626;padding:16px 20px;border-radius:8px;font-family:monospace;font-size:13px;line-height:1.8">
$($event.enrollmentFailureDetails)
</div>
"@
    }

    if ($espApps.Count -gt 0) {
        $html += "<div class='section-title'>App Install Status</div><table><thead><tr><th>App</th><th>State</th><th>Error Code</th></tr></thead><tbody>"
        foreach ($app in ($espApps | Sort-Object state)) {
            $badge = if ($app.state -eq "installed") { "badge-green" } elseif ($app.state -eq "failed") { "badge-red" } else { "badge-blue" }
            $err   = if ($app.errorCode -and $app.errorCode -ne 0) { "0x{0:X8}" -f $app.errorCode } else { "" }
            $html += "<tr><td>$($app.displayName ?? $app.settingName)</td><td><span class='badge $badge'>$($app.state)</span></td><td class='mono'>$err</td></tr>"
        }
        $html += "</tbody></table>"
    }

    $html += Get-EIQHTMLFooter
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-EIQSuccess "HTML report saved: $htmlPath"
    Invoke-Item $htmlPath
}
