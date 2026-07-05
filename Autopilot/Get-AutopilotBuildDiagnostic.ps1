<#
.SYNOPSIS
    Full Autopilot provisioning diagnostic from serial number.
.DESCRIPTION
    Enter a device serial number. The script pulls everything Graph has:

      Quick Diagnosis -- one-line root cause before any phases
      Phase 1 -- Autopilot inventory check (is the device registered?)
      Phase 2 -- Deployment profiles in the tenant (with group assignments)
      Phase 3 -- Enrollment restrictions (could a policy block this device?)
      Phase 4 -- Enrollment status (is it enrolled, when, who)
      Phase 5 -- Autopilot deployment event timeline (if a build was attempted)
      Phase 6 -- App and policy install failures
      Phase 7 -- Audit log (last enrollment-related events)
      Phase 8 -- Generates a script to run ON the device collecting:
                 MDM diagnostic zip, Event Viewer logs, IME logs, registry keys

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

$ctx = Get-EIQContext
if (-not $ctx) { Write-EIQError "Authentication failed."; exit 1 }

Write-Host ""
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host "   EndpointIQ -- Autopilot Build Diagnostic" -ForegroundColor Cyan
Write-Host "   by Imran Awan | EndpointWeekly.com" -ForegroundColor DarkGray
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host ""

if (-not $SerialNumber) { $SerialNumber = Read-Host "  Enter device serial number" }
$SerialNumber = $SerialNumber.Trim()
if (-not $SerialNumber) { Write-EIQError "No serial number provided."; exit 1 }

Write-EIQInfo "Searching for serial: $SerialNumber"
Write-Host ""

# ── Helpers ───────────────────────────────────────────────────────────────────
function Coalesce {
    param([object[]]$Values)
    foreach ($v in $Values) { if ($v -ne $null -and $v -ne '') { return $v } }
    return $null
}

function Format-Dur {
    param([string]$iso)
    if (-not $iso) { return "n/a" }
    try {
        $ts = [System.Xml.XmlConvert]::ToTimeSpan($iso)
        if ($ts.TotalHours -ge 1)   { return "$([int]$ts.TotalHours)h $($ts.Minutes)m $($ts.Seconds)s" }
        if ($ts.TotalMinutes -ge 1) { return "$([int]$ts.TotalMinutes)m $($ts.Seconds)s" }
        return "$($ts.Seconds)s"
    } catch { return $iso }
}

function Format-DT {
    param([string]$dt)
    if (-not $dt) { return "n/a" }
    try { return ([datetime]$dt).ToLocalTime().ToString("dd MMM yyyy  HH:mm:ss") }
    catch { return $dt }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  =====================================================" -ForegroundColor DarkGray
    Write-Host "   $Title" -ForegroundColor Yellow
    Write-Host "  =====================================================" -ForegroundColor DarkGray
}

function Write-Row {
    param([string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("  " + $Label.PadRight(18) + ": ") -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Write-Phase {
    param([string]$Name, [string]$Status, [string]$Duration = "", [string]$Detail = "")
    $icon = "[?]"
    switch ($Status) {
        "success"        { $icon = "[OK]" }
        "failure"        { $icon = "[X]"  }
        "inProgress"     { $icon = "[~]"  }
        "notApplicable"  { $icon = "[-]"  }
    }
    $color = "Gray"
    switch ($Status) {
        "success"        { $color = "Green"   }
        "failure"        { $color = "Red"     }
        "inProgress"     { $color = "Yellow"  }
        "notApplicable"  { $color = "DarkGray"}
    }
    Write-Host "  $icon " -ForegroundColor $color -NoNewline
    Write-Host $Name.PadRight(36) -ForegroundColor White -NoNewline
    Write-Host $Status.PadRight(16) -ForegroundColor $color -NoNewline
    Write-Host $Duration -ForegroundColor DarkGray
    if ($Detail) { Write-Host "      -> $Detail" -ForegroundColor Red }
}

function Safe-Get {
    param([string]$Uri, [string]$Label)
    try   { return Invoke-EIQGraphRequest -Uri $Uri }
    catch { Write-Host "  [!] $Label : $_" -ForegroundColor DarkGray; return $null }
}

# ── Data collection ───────────────────────────────────────────────────────────
Write-EIQStep "Checking Autopilot device inventory..."
$apUri     = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$SerialNumber')&`$select=id,serialNumber,manufacturer,model,groupTag,managedDeviceName,azureAdDeviceId,deploymentProfileAssignmentStatus,deploymentProfileAssignmentDetailedStatus,deploymentProfileAssignedDateTime,profileErrorCode,profileErrorMessage,deploymentProfileDisplayName"
$apResult  = Safe-Get $apUri "Autopilot inventory"
$apDevice  = $null
if ($apResult -and $apResult.value)            { $apDevice = $apResult.value[0] }
elseif ($apResult -and $apResult.serialNumber) { $apDevice = $apResult }

Write-EIQStep "Checking Intune managed device record..."
$mdUri         = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$SerialNumber'&`$select=id,deviceName,userPrincipalName,enrolledDateTime,lastSyncDateTime,complianceState,managementState,operatingSystem,osVersion,azureADDeviceId,enrollmentType,managedDeviceOwnerType,deviceEnrollmentType"
$mdResult      = Safe-Get $mdUri "Managed devices"
$managedDevice = $null
if ($mdResult -and $mdResult.value)  { $managedDevice = $mdResult.value[0] }
elseif ($mdResult -and $mdResult.id) { $managedDevice = $mdResult }

Write-EIQStep "Fetching Autopilot deployment events..."
$evResult = Safe-Get "https://graph.microsoft.com/beta/deviceManagement/autopilotEvents?`$filter=deviceSerialNumber eq '$SerialNumber'&`$orderby=deploymentStartDateTime desc&`$top=5" "Autopilot events"
$event    = $null
if ($evResult -and $evResult.value) { $event = $evResult.value[0] }

Write-EIQStep "Fetching deployment profiles..."
$profilesResult = Safe-Get "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?`$select=id,displayName,description,deviceType,outOfBoxExperienceSettings" "Deployment profiles"
$profiles = @()
if ($profilesResult -and $profilesResult.value) { $profiles = $profilesResult.value }

# Fetch assignments for each profile
$profileAssignments = @{}
foreach ($p in $profiles) {
    $pid = $p.id
    $asgUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$pid/assignments"
    $asgResult = Safe-Get $asgUri "Profile assignments ($($p.displayName))"
    $assignedGroups = @()
    if ($asgResult -and $asgResult.value) {
        foreach ($asg in $asgResult.value) {
            $targetType = ""
            if ($asg.target) {
                $targetType = $asg.target.'@odata.type'
            }
            $groupId = ""
            if ($asg.target -and $asg.target.groupId) {
                $groupId = $asg.target.groupId
            }
            if ($groupId) {
                $grpInfo = Safe-Get "https://graph.microsoft.com/v1.0/groups/$groupId`?`$select=id,displayName" "Group lookup"
                if ($grpInfo -and $grpInfo.displayName) {
                    $assignedGroups += $grpInfo.displayName
                } else {
                    $assignedGroups += $groupId
                }
            } elseif ($targetType -like "*allDevices*") {
                $assignedGroups += "All Devices"
            } elseif ($targetType -like "*allLicensed*") {
                $assignedGroups += "All Users"
            }
        }
    }
    $profileAssignments[$pid] = $assignedGroups
}

Write-EIQStep "Fetching enrollment restrictions..."
$restrictResult = Safe-Get "https://graph.microsoft.com/v1.0/deviceManagement/deviceEnrollmentConfigurations" "Enrollment restrictions"
$restrictions = @()
if ($restrictResult -and $restrictResult.value) { $restrictions = $restrictResult.value }

$espApps     = @()
$espPolicies = @()
if ($managedDevice) {
    Write-EIQStep "Fetching app and policy status..."
    $appR = Safe-Get "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($managedDevice.id)/managedDeviceMobileAppConfigurationStates" "App states"
    if ($appR -and $appR.value) { $espApps = $appR.value }
    $polR = Safe-Get "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($managedDevice.id)/deviceConfigurationStates" "Policy states"
    if ($polR -and $polR.value) { $espPolicies = $polR.value }
}

$auditEvents = @()
Write-EIQStep "Fetching audit log..."
$auditR = Safe-Get "https://graph.microsoft.com/v1.0/deviceManagement/auditEvents?`$filter=contains(displayName,'$SerialNumber')&`$top=10&`$orderby=activityDateTime desc" "Audit log"
if ($auditR -and $auditR.value) { $auditEvents = $auditR.value }
if ($auditEvents.Count -eq 0 -and $managedDevice -and $managedDevice.deviceName) {
    $dn      = $managedDevice.deviceName
    $auditR2 = Safe-Get "https://graph.microsoft.com/v1.0/deviceManagement/auditEvents?`$filter=contains(displayName,'$dn')&`$top=10&`$orderby=activityDateTime desc" "Audit log (by name)"
    if ($auditR2 -and $auditR2.value) { $auditEvents = $auditR2.value }
}

# ── AAD Dynamic Group lookup for Group Tag ─────────────────────────────────────
$matchingGroups = @()
$groupTag = ""
if ($apDevice) {
    $groupTag = Coalesce @($apDevice.groupTag, "")
}
if ($groupTag -ne "") {
    Write-EIQStep "Searching AAD dynamic groups for Group Tag '$groupTag'..."
    $dynGrpUri    = "https://graph.microsoft.com/v1.0/groups?`$filter=groupTypes/any(c:c eq 'DynamicMembership')&`$select=id,displayName,membershipRule,membershipRuleProcessingState"
    $dynGrpResult = Safe-Get $dynGrpUri "Dynamic AAD groups"
    if ($dynGrpResult -and $dynGrpResult.value) {
        foreach ($g in $dynGrpResult.value) {
            if ($g.membershipRule -like "*$groupTag*") {
                $matchingGroups += $g
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  QUICK DIAGNOSIS (before Phase 1)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host "   QUICK DIAGNOSIS" -ForegroundColor Cyan
Write-Host "  =====================================================" -ForegroundColor DarkGray
Write-Host ""

$qdInInventory = if ($apDevice) { "YES" } else { "NO" }
$qdGroupTag    = if ($groupTag -ne "") { $groupTag } else { "(none)" }

$qdProfileAssigned = "NO"
$qdProfileName     = ""
if ($apDevice) {
    $qdProfStatus = Coalesce @($apDevice.deploymentProfileAssignmentStatus, "unknown")
    if ($qdProfStatus -eq "assigned") {
        $qdProfileAssigned = "YES"
        $qdProfileName     = Coalesce @($apDevice.deploymentProfileDisplayName, "")
    }
}

$qdProfileStr = $qdProfileAssigned
if ($qdProfileAssigned -eq "YES" -and $qdProfileName -ne "") {
    $qdProfileStr = "YES ($qdProfileName)"
}

$qdErrorStr = ""
if ($apDevice -and $apDevice.profileErrorCode -and $apDevice.profileErrorCode -ne 0) {
    $qdErrMsg   = Coalesce @($apDevice.profileErrorMessage, "No message")
    $qdErrorStr = "0x{0:X8} -- $qdErrMsg" -f $apDevice.profileErrorCode
}

$qdEnrolled = if ($managedDevice) { "YES" } else { "NO" }

$qdGroupFoundStr = "NOT FOUND"
$qdGroupFoundName = ""
if ($matchingGroups.Count -gt 0) {
    $qdGroupFoundName = $matchingGroups[0].displayName
    $qdGroupFoundStr  = "FOUND ($qdGroupFoundName)"
}

# LIKELY CAUSE logic
$qdLikelyCause = ""
if (-not $apDevice) {
    $qdLikelyCause = "Device not in Autopilot inventory -- hardware hash not uploaded, serial typo, or wrong tenant."
} elseif ($qdProfileAssigned -eq "NO" -and $matchingGroups.Count -eq 0) {
    $qdGtDisplay = if ($groupTag -ne "") { $groupTag } else { "(empty)" }
    $qdLikelyCause = "No dynamic AAD group found with membershipRule matching group tag '$qdGtDisplay'. Create group with rule: (device.devicePhysicalIds -any _ -eq ""[OrderID]:$qdGtDisplay"") and assign a profile."
} elseif ($qdProfileAssigned -eq "NO" -and $matchingGroups.Count -gt 0) {
    $qdLikelyCause = "Dynamic group '$qdGroupFoundName' exists for tag '$groupTag' but no Autopilot profile is assigned to that group."
} elseif ($qdProfileAssigned -eq "YES" -and -not $managedDevice) {
    $qdLikelyCause = "Profile is assigned. Boot the device on internet to start provisioning."
} elseif ($managedDevice -and $event -and $event.deploymentState -eq "failure") {
    $qdLikelyCause = "Build attempted -- see Phase 5 for failure details."
} elseif ($managedDevice) {
    $qdLikelyCause = "Device successfully provisioned."
} else {
    $qdLikelyCause = "Unable to determine -- review phases below."
}

Write-Host ("  " + "In Autopilot inventory".PadRight(32) + ": ") -NoNewline
if ($qdInInventory -eq "YES") { Write-Host $qdInInventory -ForegroundColor Green } else { Write-Host $qdInInventory -ForegroundColor Red }

Write-Host ("  " + "Group Tag".PadRight(32) + ": ") -NoNewline
Write-Host $qdGroupTag -ForegroundColor Cyan

Write-Host ("  " + "Profile assigned".PadRight(32) + ": ") -NoNewline
if ($qdProfileAssigned -eq "YES") { Write-Host $qdProfileStr -ForegroundColor Green } else { Write-Host $qdProfileStr -ForegroundColor Red }

if ($qdErrorStr -ne "") {
    Write-Host ("  " + "Profile error".PadRight(32) + ": ") -NoNewline
    Write-Host $qdErrorStr -ForegroundColor Red
}

Write-Host ("  " + "Enrolled in Intune".PadRight(32) + ": ") -NoNewline
if ($qdEnrolled -eq "YES") { Write-Host $qdEnrolled -ForegroundColor Green } else { Write-Host $qdEnrolled -ForegroundColor Yellow }

Write-Host ("  " + "Dynamic AAD group for tag".PadRight(32) + ": ") -NoNewline
if ($matchingGroups.Count -gt 0) { Write-Host $qdGroupFoundStr -ForegroundColor Green } else { Write-Host $qdGroupFoundStr -ForegroundColor Red }

Write-Host ""
Write-Host "  LIKELY CAUSE:" -ForegroundColor Yellow
Write-Host "  $qdLikelyCause" -ForegroundColor White
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
#  OUTPUT
# ═══════════════════════════════════════════════════════════════════════════════

# Phase 1 ─────────────────────────────────────────────────────────────────────
Write-Section "PHASE 1 -- DEVICE IDENTITY"
if ($apDevice) {
    $devName    = Coalesce @($managedDevice.deviceName, $apDevice.managedDeviceName, "Not yet enrolled")
    $aadId      = Coalesce @($apDevice.azureAdDeviceId, $managedDevice.azureADDeviceId, "n/a")
    $groupTagD  = Coalesce @($apDevice.groupTag, "(none)")
    $profStatus = Coalesce @($apDevice.deploymentProfileAssignmentStatus, "unknown")
    $model      = "$($apDevice.manufacturer) $($apDevice.model)"

    Write-Row "Serial Number"  $apDevice.serialNumber "Cyan"
    Write-Row "Model"          $model    "White"
    Write-Row "Device Name"    $devName  "White"
    Write-Row "Autopilot ID"   $apDevice.id "DarkGray"
    Write-Row "AAD Device ID"  $aadId    "DarkGray"
    Write-Row "Group Tag"      $groupTagD "White"

    Write-Host ("  Profile Status    : ") -NoNewline
    if ($profStatus -eq "assigned") {
        Write-Host $profStatus -ForegroundColor Green
    } elseif ($profStatus -like "*notAssigned*" -or $profStatus -eq "unknown") {
        Write-Host "$profStatus  <-- NO PROFILE ASSIGNED -- BUILD WILL NOT AUTO-START" -ForegroundColor Red
    } else {
        Write-Host $profStatus -ForegroundColor Yellow
    }

    if ($apDevice.deploymentProfileAssignmentDetailedStatus -and $apDevice.deploymentProfileAssignmentDetailedStatus -ne 'none') {
        $detailStatus = $apDevice.deploymentProfileAssignmentDetailedStatus
        Write-Row "Profile Detail" $detailStatus "Yellow"
    }
    if ($apDevice.profileErrorCode -and $apDevice.profileErrorCode -ne 0) {
        $errMsg = Coalesce @($apDevice.profileErrorMessage, "No message")
        $errStr = "0x{0:X8} -- $errMsg" -f $apDevice.profileErrorCode
        Write-Row "Profile Error" $errStr "Red"
    }
    if ($apDevice.deploymentProfileAssignedDateTime -and $apDevice.deploymentProfileAssignedDateTime -ne '') {
        Write-Row "Profile Assigned" (Format-DT $apDevice.deploymentProfileAssignedDateTime) "White"
    }

    if ($apDevice.deploymentProfileDisplayName) {
        Write-Row "Profile Name" $apDevice.deploymentProfileDisplayName "Green"
    }
} else {
    Write-Host "  [X] Device NOT found in Autopilot inventory for serial: $SerialNumber" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Possible reasons:" -ForegroundColor Yellow
    Write-Host "    - Hardware hash not uploaded (OEM, manual upload, or CSV import needed)" -ForegroundColor White
    Write-Host "    - Serial number typo" -ForegroundColor White
    Write-Host "    - Device registered under a different tenant" -ForegroundColor White
    Write-Host "    - Hash uploaded but not yet synced (can take up to 24 hours)" -ForegroundColor White
}

# Phase 2 ─────────────────────────────────────────────────────────────────────
Write-Section "PHASE 2 -- DEPLOYMENT PROFILES (all in tenant)"
if ($profiles.Count -gt 0) {
    Write-Host ("  " + "Profile Name".PadRight(36) + "Mode".PadRight(18) + "Join Type".PadRight(18) + "Assigned Groups") -ForegroundColor DarkGray
    Write-Host ("  " + "-" * 88) -ForegroundColor DarkGray
    foreach ($p in $profiles) {
        $mode     = Coalesce @($p.outOfBoxExperienceSettings.userType, "standard")
        $joinType = if ($p.'@odata.type' -like "*hybrid*") { "Hybrid AAD Join" } else { "AAD Join" }
        $pname    = Coalesce @($p.displayName, "Unnamed")
        $trunc    = if ($pname.Length -gt 34) { $pname.Substring(0,31) + "..." } else { $pname }

        $asgList  = $profileAssignments[$p.id]
        if ($asgList -and $asgList.Count -gt 0) {
            $asgStr = $asgList -join ", "
        } else {
            $asgStr = "(no groups)"
        }

        Write-Host ("  " + $trunc.PadRight(36) + $mode.PadRight(18) + $joinType.PadRight(18)) -NoNewline
        if ($asgStr -eq "(no groups)") {
            Write-Host $asgStr -ForegroundColor Red
        } else {
            Write-Host $asgStr -ForegroundColor White
        }
    }

    # Check if any profile is assigned to a group matching the device's group tag
    Write-Host ""
    if ($groupTag -ne "") {
        $matchedProfile = $false
        foreach ($p in $profiles) {
            $asgList = $profileAssignments[$p.id]
            if ($asgList -and $asgList.Count -gt 0) {
                foreach ($grpName in $asgList) {
                    foreach ($mg in $matchingGroups) {
                        if ($grpName -eq $mg.displayName) {
                            $matchedProfile = $true
                            $matchedProfileName = $p.displayName
                            $matchedGroupName   = $grpName
                        }
                    }
                }
            }
        }
        if ($matchedProfile) {
            Write-Host "  [OK] Profile '$matchedProfileName' is assigned to group '$matchedGroupName' which matches Group Tag '$groupTag'." -ForegroundColor Green
        } else {
            $profileNames = ($profiles | ForEach-Object { Coalesce @($_.displayName, "Unnamed") }) -join ", "
            Write-Host "  [X] WARNING: None of the profiles' assigned groups match Group Tag '$groupTag'." -ForegroundColor Red
            Write-Host "      Profiles in tenant: $profileNames" -ForegroundColor Yellow
            Write-Host "      Ensure a profile is assigned to the dynamic group for this group tag." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [!] No Group Tag on this device -- profile must be assigned to All Devices or a static group." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [!] No deployment profiles found in this tenant." -ForegroundColor Red
    Write-Host "      A device CANNOT auto-provision without a profile." -ForegroundColor Yellow
}

# Phase 3 ─────────────────────────────────────────────────────────────────────
Write-Section "PHASE 3 -- ENROLLMENT RESTRICTIONS"
$blockFound = $false
foreach ($r in $restrictions) {
    if ($r.'@odata.type' -notlike "*Limit*" -and $r.'@odata.type' -notlike "*Platform*") { continue }
    $rName = Coalesce @($r.displayName, "Unnamed restriction")
    $rType = $r.'@odata.type' -replace '#microsoft.graph.', ''
    Write-Host ("  " + $rName.PadRight(44)) -NoNewline
    Write-Host $rType -ForegroundColor DarkGray

    if ($r.deviceEnrollmentConfigurationType -eq "limit") {
        Write-Host "    Limit: $($r.limit) devices per user" -ForegroundColor DarkGray
    }
    if ($r.platformRestrictions) {
        $pr = $r.platformRestrictions
        if ($pr.windowsRestriction -and $pr.windowsRestriction.platformBlocked) {
            Write-Host "    [X] Windows enrollment BLOCKED by this restriction" -ForegroundColor Red
            $blockFound = $true
        }
        if ($pr.windowsRestriction -and $pr.windowsRestriction.personalDeviceEnrollmentBlocked) {
            Write-Host "    [!] Personal/BYOD Windows devices blocked (corporate only)" -ForegroundColor Yellow
        }
    }
}
if (-not $blockFound) {
    Write-Host "  [OK] No blocking enrollment restrictions detected." -ForegroundColor Green
}

# Phase 4 ─────────────────────────────────────────────────────────────────────
Write-Section "PHASE 4 -- ENROLLMENT STATUS"
if ($managedDevice) {
    $enrollType  = Coalesce @($managedDevice.deviceEnrollmentType, $managedDevice.enrollmentType, "unknown")
    $assignedUPN = Coalesce @($managedDevice.userPrincipalName, "None (device-only)")
    $compColor   = "Yellow"
    if ($managedDevice.complianceState -eq "compliant")    { $compColor = "Green" }
    if ($managedDevice.complianceState -eq "noncompliant") { $compColor = "Red"   }

    Write-Row "Enrolled"      (Format-DT $managedDevice.enrolledDateTime) "Green"
    Write-Row "Last Sync"     (Format-DT $managedDevice.lastSyncDateTime) "White"
    Write-Row "Enroll Type"   $enrollType  "White"
    Write-Row "OS"            "$($managedDevice.operatingSystem) $($managedDevice.osVersion)" "White"
    Write-Row "Assigned User" $assignedUPN "White"
    Write-Row "Compliance"    $managedDevice.complianceState $compColor
    Write-Row "Mgmt State"    $managedDevice.managementState "White"
    Write-Row "Ownership"     $managedDevice.managedDeviceOwnerType "White"
} else {
    Write-Host "  [X] Device has NOT been enrolled into Intune." -ForegroundColor Red
    if ($apDevice) {
        $profStatus2 = Coalesce @($apDevice.deploymentProfileAssignmentStatus, "unknown")
        $groupTag2   = Coalesce @($apDevice.groupTag, "(none)")
        if ($profStatus2 -notlike "*assigned*") {
            Write-Host ""
            Write-Host "  ROOT CAUSE: No deployment profile is assigned to this device." -ForegroundColor Red
            Write-Host ""
            Write-Host "  To fix:" -ForegroundColor White
            Write-Host "    1. Check the Group Tag on this device: '$groupTag2'" -ForegroundColor Cyan
            Write-Host "    2. Ensure a dynamic AAD group exists that targets this Group Tag:" -ForegroundColor Cyan
            Write-Host "       Rule: (device.devicePhysicalIds -any _ -eq ""[OrderID]:$groupTag2"")" -ForegroundColor DarkGray
            Write-Host "    3. Assign the Autopilot deployment profile to that group" -ForegroundColor Cyan
            Write-Host "    4. Allow up to 24 hours for group membership to sync" -ForegroundColor DarkGray
        } else {
            Write-Host "  Profile IS assigned -- boot the device on internet to begin provisioning." -ForegroundColor Yellow
        }
    }
}

# Phase 5 ─────────────────────────────────────────────────────────────────────
Write-Section "PHASE 5 -- AUTOPILOT DEPLOYMENT TIMELINE"
if ($event) {
    $profName   = Coalesce @($event.windowsAutopilotDeploymentProfileDisplayName, "n/a")
    $espName    = Coalesce @($event.windows10EnrollmentCompletionPageConfigurationDisplayName, "None / not tracked")
    $evtUPN     = Coalesce @($event.userPrincipalName, "None (Self-Deploy / Pre-Prov)")
    $failDetail = Coalesce @($event.enrollmentFailureDetails, "")

    Write-Row "Event recorded" (Format-DT $event.eventDateTime) "White"
    Write-Row "Build started"  (Format-DT $event.deploymentStartDateTime) "White"
    Write-Row "Build ended"    (Format-DT $event.deploymentEndDateTime) "White"

    $durColor = "Yellow"
    if ($event.deploymentState -eq "success") { $durColor = "Green" }
    Write-Row "Total duration" (Format-Dur $event.deploymentTotalDuration) $durColor
    Write-Row "Profile used"   $profName  "White"
    Write-Row "ESP config"     $espName   "White"
    Write-Row "Enrolled user"  $evtUPN    "White"

    Write-Host ""
    Write-Host ("  " + "Phase".PadRight(38) + "Result".PadRight(18) + "Duration") -ForegroundColor DarkGray
    Write-Host ("  " + "-" * 70) -ForegroundColor DarkGray

    $devPrepStatus  = Coalesce @($event.devicePreparationStatus, "unknown")
    $devSetupStatus = Coalesce @($event.deviceSetupStatus,       "unknown")
    $accSetupStatus = Coalesce @($event.accountSetupStatus,      "unknown")

    Write-Phase -Name "Overall deployment"   -Status $event.deploymentState -Duration (Format-Dur $event.deploymentTotalDuration)
    Write-Phase -Name "Device preparation"   -Status $devPrepStatus          -Duration (Format-Dur $event.devicePreparationDuration)

    $devSetupDetail = ""
    if ($devSetupStatus -eq "failure" -and $failDetail) { $devSetupDetail = $failDetail }
    Write-Phase -Name "ESP -- Device setup"  -Status $devSetupStatus          -Duration (Format-Dur $event.deviceSetupDuration)  -Detail $devSetupDetail

    $accSetupDetail = ""
    if ($accSetupStatus -eq "failure") { $accSetupDetail = "User-phase failure -- check user-targeted apps below" }
    Write-Phase -Name "ESP -- Account setup" -Status $accSetupStatus          -Duration (Format-Dur $event.accountSetupDuration) -Detail $accSetupDetail

    Write-Host ""
    $appCount = if ($event.targetedAppCount    -ne $null) { $event.targetedAppCount    } else { "n/a" }
    $polCount = if ($event.targetedPolicyCount -ne $null) { $event.targetedPolicyCount } else { "n/a" }
    Write-Host "  Targeted apps    : $appCount" -ForegroundColor DarkGray
    Write-Host "  Targeted policies: $polCount" -ForegroundColor DarkGray

    if ($event.deploymentState -eq "failure" -or $failDetail) {
        Write-Host ""
        Write-Host "  [X] FAILURE DETAIL:" -ForegroundColor Red
        if ($failDetail) {
            Write-Host "  $failDetail" -ForegroundColor Red
        } else {
            Write-Host "  No structured failure string in Graph -- use on-device script (Phase 8)" -ForegroundColor Yellow
        }
    }
} elseif ($managedDevice) {
    Write-Host "  [!] No Autopilot deployment event found in Graph." -ForegroundColor Yellow
    Write-Host "  Possible reasons:" -ForegroundColor White
    Write-Host "    - Device enrolled via non-Autopilot method" -ForegroundColor DarkGray
    Write-Host "    - Event data expired (Graph keeps approx 30 days)" -ForegroundColor DarkGray
    Write-Host "    - Build is still in progress" -ForegroundColor DarkGray
} else {
    Write-Host "  No build has been attempted -- device not yet enrolled." -ForegroundColor DarkGray
}

# Phase 6 ─────────────────────────────────────────────────────────────────────
if ($espApps.Count -gt 0) {
    Write-Section "PHASE 6 -- APP INSTALL STATUS"
    Write-Host ("  " + "App / Config".PadRight(46) + "State".PadRight(18) + "Error Code") -ForegroundColor DarkGray
    Write-Host ("  " + "-" * 72) -ForegroundColor DarkGray

    $failedApps = @($espApps | Where-Object { $_.state -notin @("installed","notApplicable","unknown") })
    $okApps     = @($espApps | Where-Object { $_.state -in    @("installed","notApplicable") })

    foreach ($app in ($failedApps | Sort-Object state)) {
        $sc = "Gray"
        switch ($app.state) {
            "failed"       { $sc = "Red"    }
            "notInstalled" { $sc = "Yellow" }
        }
        $nm = Coalesce @($app.displayName, $app.settingName, "Unknown")
        $nm = if ($nm.Length -gt 44) { $nm.Substring(0,41) + "..." } else { $nm }
        $ec = if ($app.errorCode -and $app.errorCode -ne 0) { "0x{0:X8}" -f $app.errorCode } else { "" }
        Write-Host ("  " + $nm.PadRight(46)) -NoNewline
        Write-Host ($app.state.PadRight(18)) -ForegroundColor $sc -NoNewline
        if ($ec) { Write-Host $ec -ForegroundColor Red } else { Write-Host "" }
    }
    if ($okApps.Count -gt 0) {
        Write-Host "  [OK] $($okApps.Count) apps installed/not-applicable (hidden)" -ForegroundColor DarkGray
    }
}

if ($espPolicies.Count -gt 0) {
    Write-Host ""
    Write-Host "  POLICY STATE" -ForegroundColor Yellow
    Write-Host ("  " + "-" * 72) -ForegroundColor DarkGray

    $failPol = @($espPolicies | Where-Object { $_.state -notin @("compliant","notApplicable","unknown") })
    $okPol   = @($espPolicies | Where-Object { $_.state -in    @("compliant","notApplicable") })

    foreach ($pol in ($failPol | Sort-Object state)) {
        $sc = "Gray"
        switch ($pol.state) {
            "error"       { $sc = "Red"    }
            "conflict"    { $sc = "Red"    }
            "nonCompliant"{ $sc = "Yellow" }
        }
        $nm = Coalesce @($pol.displayName, "Unknown Policy")
        $nm = if ($nm.Length -gt 44) { $nm.Substring(0,41) + "..." } else { $nm }
        $ec = if ($pol.errorCode -and $pol.errorCode -ne 0) { "0x{0:X8}" -f $pol.errorCode } else { "" }
        Write-Host ("  " + $nm.PadRight(46)) -NoNewline
        Write-Host ($pol.state.PadRight(18)) -ForegroundColor $sc -NoNewline
        if ($ec) { Write-Host $ec -ForegroundColor Red } else { Write-Host "" }
    }
    if ($okPol.Count -gt 0) {
        Write-Host "  [OK] $($okPol.Count) policies compliant/not-applicable (hidden)" -ForegroundColor DarkGray
    }
}

# Phase 7 ─────────────────────────────────────────────────────────────────────
Write-Section "PHASE 7 -- AUDIT LOG (recent enrollment events)"
if ($auditEvents.Count -gt 0) {
    Write-Host ("  " + "Date/Time".PadRight(24) + "Action".PadRight(34) + "Result") -ForegroundColor DarkGray
    Write-Host ("  " + "-" * 70) -ForegroundColor DarkGray
    foreach ($ae in $auditEvents) {
        $dt  = Format-DT $ae.activityDateTime
        $act = if ($ae.activityDisplayName.Length -gt 32) { $ae.activityDisplayName.Substring(0,29) + "..." } else { $ae.activityDisplayName }
        $res = Coalesce @($ae.activityResult, "unknown")
        $rc  = "Yellow"
        if ($res -eq "success")  { $rc = "Green" }
        if ($res -like "*fail*") { $rc = "Red"   }
        Write-Host ("  " + $dt.PadRight(24) + $act.PadRight(34)) -NoNewline
        Write-Host $res -ForegroundColor $rc
    }
} else {
    Write-Host "  No audit events found for this device." -ForegroundColor DarkGray
    Write-Host "  (Requires AuditLog.Read.All permission)" -ForegroundColor DarkGray
}

# Phase 8 ─────────────────────────────────────────────────────────────────────
Write-Section "PHASE 8 -- ON-DEVICE DIAGNOSTIC COLLECTOR"
Write-Host "  Generating a script to run ON the device itself..." -ForegroundColor Cyan
Write-Host ""

$deviceScriptName = "AP-Diag-$($SerialNumber -replace '[^a-zA-Z0-9]','').ps1"
$outputFolder     = Split-Path (Get-EIQOutputPath -ReportName "placeholder") -Parent
$deviceScriptPath = Join-Path $outputFolder $deviceScriptName

$diagScript = @'
# ============================================================
#  Autopilot On-Device Diagnostic Collector
#  Run AS ADMINISTRATOR on the affected device
#  Output goes to C:\AP-Diag\
# ============================================================
$out = "C:\AP-Diag"
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

function Log { param([string]$m) Write-Host "  $m" }

Log "Starting on-device diagnostic collection -> $out"
Log ""

# 1. dsregcmd
Log "[1] dsregcmd /status ..."
dsregcmd /status 2>&1 | Out-File "$out\dsregcmd-status.txt" -Encoding UTF8

# 2. MDM Diagnostic Tool
Log "[2] MDM diagnostics zip ..."
try {
    $mdmTool = "$env:windir\System32\MdmDiagnosticsTool.exe"
    if (Test-Path $mdmTool) {
        & $mdmTool -area Autopilot -zip "$out\MDMDiag-Autopilot.zip" 2>&1 | Out-Null
        Log "    Saved: $out\MDMDiag-Autopilot.zip"
    } else { Log "    MdmDiagnosticsTool.exe not found" }
} catch { Log "    Error: $_" }

# 3. IME logs
Log "[3] IntuneManagementExtension logs ..."
$imeLogs = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (Test-Path $imeLogs) {
    Get-ChildItem $imeLogs -Filter "*.log" | Copy-Item -Destination $out -ErrorAction SilentlyContinue
    Log "    Copied IME logs to $out"
} else { Log "    IME logs folder not found (IME may not have run yet)" }

# 4. Autopilot ZTD JSON
Log "[4] Autopilot ZTD file ..."
$ztd = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp\DiagOutputDir\AutopilotDDSZTDFile.json"
if (Test-Path $ztd) {
    Copy-Item $ztd "$out\AutopilotZTD.json"
    Log "    Saved: AutopilotZTD.json"
} else { Log "    ZTD file not found (device has not contacted Autopilot service)" }

# 5. Event Viewer -- Autopilot Operational
Log "[5] Autopilot event log ..."
try {
    $ev = Get-WinEvent -LogName "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/AutoPilot" -MaxEvents 100 -ErrorAction Stop
    $ev | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-File "$out\Events-Autopilot.txt" -Encoding UTF8
    Log "    $($ev.Count) events saved"
} catch { Log "    $_" }

# 6. Event Viewer -- AAD Operational
Log "[6] Azure AD event log ..."
try {
    $ev = Get-WinEvent -LogName "Microsoft-Windows-AAD/Operational" -MaxEvents 50 -ErrorAction Stop
    $ev | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-File "$out\Events-AAD.txt" -Encoding UTF8
    Log "    $($ev.Count) events saved"
} catch { Log "    $_" }

# 7. Event Viewer -- User Device Registration
Log "[7] User Device Registration events ..."
try {
    $ev = Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 50 -ErrorAction Stop
    $ev | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-File "$out\Events-UserDeviceReg.txt" -Encoding UTF8
    Log "    $($ev.Count) events saved"
} catch { Log "    $_" }

# 8. Event Viewer -- DeviceManagement Enterprise Diagnostics
Log "[8] DeviceManagement diagnostic events ..."
try {
    $ev = Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin" -MaxEvents 50 -ErrorAction Stop
    $ev | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List | Out-File "$out\Events-DeviceMgmt.txt" -Encoding UTF8
    Log "    $($ev.Count) events saved"
} catch { Log "    $_" }

# 9. Registry keys
Log "[9] Registry keys ..."
$regKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Enrollments",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM",
    "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin",
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\UnattendSettings\SysprepStatus"
)
$regOut = @()
foreach ($key in $regKeys) {
    $regOut += ("=" * 60)
    $regOut += "KEY: $key"
    $regOut += ("=" * 60)
    try {
        $props = Get-ItemProperty -Path $key -ErrorAction Stop
        $props.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
            $regOut += ("  " + $_.Name.PadRight(40) + " = " + $_.Value)
        }
    } catch { $regOut += "  (not found or access denied)" }
    $regOut += ""
}
$regOut | Out-File "$out\Registry-Keys.txt" -Encoding UTF8
Log "    Registry dump saved"

# 10. Instant summary
Log ""
Log "[SUMMARY] Checking key state ..."
Log ""
$dsreg = (Get-Content "$out\dsregcmd-status.txt" -Raw -ErrorAction SilentlyContinue)
if ($dsreg) {
    if ($dsreg -match "AzureAdJoined\s*:\s*YES")          { Log "  [OK] Azure AD Joined" }
    elseif ($dsreg -match "WorkplaceJoined\s*:\s*YES")    { Log "  [~] Workplace Joined only (not AAD joined)" }
    else                                                  { Log "  [X] NOT Azure AD Joined" }

    if ($dsreg -match "AzureAdPrt\s*:\s*YES")             { Log "  [OK] PRT present" }
    else                                                  { Log "  [X] PRT MISSING -- SSO and further provisioning will fail" }

    if ($dsreg -match "MdmEnrolled\s*:\s*YES")            { Log "  [OK] MDM enrolled (Intune)" }
    else                                                  { Log "  [X] NOT MDM enrolled" }

    if ($dsreg -match "WamDefaultSet\s*:\s*YES")          { Log "  [OK] WAM token broker healthy" }
    else                                                  { Log "  [!] WAM token broker not set" }

    if ($dsreg -match "KeySignTest\s*:\s*PASSED")         { Log "  [OK] Device certificate (KeySignTest) passed" }
    else                                                  { Log "  [X] Device certificate FAILED -- WHfB and cert auth will not work" }
}

if (Test-Path $imeLogs) {
    $latestLog = Get-ChildItem $out -Filter "IntuneManagementExtension*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) {
        $errLines = Select-String -Path $latestLog.FullName -Pattern "(Error|Failed|failed|exception|timeout)" | Select-Object -Last 15
        if ($errLines.Count -gt 0) {
            Log ""
            Log "  Last $($errLines.Count) error lines from IME log ($($latestLog.Name)):"
            $errLines | ForEach-Object { Log "    $($_.Line.Trim())" }
        }
    }
}

Log ""
Log "  All files saved to: $out"
Log "  Zip the folder and send to your IT engineer."
Log ""
'@

[System.IO.File]::WriteAllText($deviceScriptPath, $diagScript, (New-Object System.Text.UTF8Encoding($true)))

Write-Host "  [OK] Script saved to: $deviceScriptPath" -ForegroundColor Green
Write-Host ""
Write-Host "  HOW TO USE:" -ForegroundColor Yellow
Write-Host "    1. Copy this script to the affected device (USB, Teams, network share)" -ForegroundColor White
Write-Host "    2. On the device: right-click -> Run as Administrator" -ForegroundColor White
Write-Host "    3. All output goes to C:\AP-Diag\" -ForegroundColor Cyan
Write-Host "    4. Zip C:\AP-Diag\ and send back to review" -ForegroundColor White
Write-Host ""
Write-Host "  WHAT IT COLLECTS:" -ForegroundColor Yellow
Write-Host "    dsregcmd /status               AAD join, PRT, WAM, certificate state" -ForegroundColor DarkGray
Write-Host "    MdmDiagnosticsTool.exe         Full MDM + Autopilot diagnostic zip" -ForegroundColor DarkGray
Write-Host "    IME logs                       IntuneManagementExtension runtime logs" -ForegroundColor DarkGray
Write-Host "    AutopilotDDSZTDFile.json       Autopilot provisioning package" -ForegroundColor DarkGray
Write-Host "    Event: Autopilot/Operational   100 Autopilot provisioning events" -ForegroundColor DarkGray
Write-Host "    Event: AAD/Operational         Azure AD join events" -ForegroundColor DarkGray
Write-Host "    Event: UserDeviceRegistration  Device registration failures" -ForegroundColor DarkGray
Write-Host "    Event: DeviceManagement/Admin  MDM enrollment errors" -ForegroundColor DarkGray
Write-Host "    Registry: Enrollments, MDM     Raw enrollment and join registry keys" -ForegroundColor DarkGray
Write-Host "    Summary: instant pass/fail     PRT, AAD join, MDM, WAM, cert" -ForegroundColor DarkGray
Write-Host ""

# ── Optional HTML export ──────────────────────────────────────────────────────
if ($ExportHTML) {
    $htmlPath = Get-EIQOutputPath -ReportName "AutopilotDiag-$($SerialNumber -replace '[^a-zA-Z0-9]','')"
    $html = Get-EIQHTMLHeader -Title "Autopilot Build Diagnostic" -Subtitle "Serial: $SerialNumber"

    $overallState = "Not enrolled"
    $overallColor = "badge-red"
    if ($event) {
        $overallState = $event.deploymentState
        if ($event.deploymentState -eq "success") {
            $overallColor = "badge-green"
        } else {
            $overallColor = "badge-red"
        }
    } elseif ($managedDevice) {
        $overallState = "Enrolled (no event)"
        $overallColor = "badge-blue"
    }

    $apStatus = if ($apDevice) { Coalesce @($apDevice.deploymentProfileAssignmentStatus, "unknown") } else { "Not in inventory" }

    $modelStr = if ($apDevice) { "$($apDevice.manufacturer) $($apDevice.model)" } else { "Not found" }

    $html += @"
<div class="stats">
  <div class="stat"><div class="stat-n">$SerialNumber</div><div class="stat-l">Serial Number</div></div>
  <div class="stat"><div class="stat-n"><span class="badge $overallColor">$overallState</span></div><div class="stat-l">Build Status</div></div>
  <div class="stat"><div class="stat-n">$modelStr</div><div class="stat-l">Model</div></div>
  <div class="stat"><div class="stat-n">$apStatus</div><div class="stat-l">Profile Assignment</div></div>
</div>
"@

    if ($event) {
        $profName2  = Coalesce @($event.windowsAutopilotDeploymentProfileDisplayName, "n/a")
        $espName2   = Coalesce @($event.windows10EnrollmentCompletionPageConfigurationDisplayName, "None")
        $evtUPN2    = Coalesce @($event.userPrincipalName, "Device only")
        $devPS2     = Coalesce @($event.devicePreparationStatus,  "unknown")
        $devSS2     = Coalesce @($event.deviceSetupStatus,        "unknown")
        $accSS2     = Coalesce @($event.accountSetupStatus,       "unknown")
        $failD2     = Coalesce @($event.enrollmentFailureDetails, "")
        $depBadge   = "badge-blue"
        if ($event.deploymentState -eq "success") { $depBadge = "badge-green" }
        if ($event.deploymentState -eq "failure")  { $depBadge = "badge-red"   }

        $html += @"
<div class="section-title">Deployment Timeline</div>
<table>
<thead><tr><th>Phase</th><th>Status</th><th>Duration</th></tr></thead>
<tbody>
  <tr><td>Overall</td><td><span class="badge $depBadge">$($event.deploymentState)</span></td><td>$(Format-Dur $event.deploymentTotalDuration)</td></tr>
  <tr><td>Device preparation</td><td>$devPS2</td><td>$(Format-Dur $event.devicePreparationDuration)</td></tr>
  <tr><td>ESP Device setup</td><td>$devSS2</td><td>$(Format-Dur $event.deviceSetupDuration)</td></tr>
  <tr><td>ESP Account setup</td><td>$accSS2</td><td>$(Format-Dur $event.accountSetupDuration)</td></tr>
</tbody>
</table>
<table><thead><tr><th>Property</th><th>Value</th></tr></thead><tbody>
  <tr><td>Build started</td><td>$(Format-DT $event.deploymentStartDateTime)</td></tr>
  <tr><td>Build ended</td><td>$(Format-DT $event.deploymentEndDateTime)</td></tr>
  <tr><td>Profile</td><td>$profName2</td></tr>
  <tr><td>ESP config</td><td>$espName2</td></tr>
  <tr><td>Enrolled user</td><td>$evtUPN2</td></tr>
</tbody></table>
"@
        if ($failD2) {
            $html += "<div class='section-title' style='color:#dc2626'>[X] Failure Detail</div><div style='background:#fef2f2;border-left:4px solid #dc2626;padding:16px 20px;border-radius:8px;font-family:monospace;font-size:13px;line-height:1.8'>$failD2</div>"
        }
    }

    if ($espApps.Count -gt 0) {
        $html += "<div class='section-title'>App Install Status</div><table><thead><tr><th>App</th><th>State</th><th>Error</th></tr></thead><tbody>"
        foreach ($app in ($espApps | Sort-Object state)) {
            $badge = "badge-blue"
            if ($app.state -eq "installed") { $badge = "badge-green" }
            if ($app.state -eq "failed")    { $badge = "badge-red"   }
            $dn    = Coalesce @($app.displayName, $app.settingName)
            $ec    = if ($app.errorCode -and $app.errorCode -ne 0) { "0x{0:X8}" -f $app.errorCode } else { "" }
            $html += "<tr><td>$dn</td><td><span class='badge $badge'>$($app.state)</span></td><td class='mono'>$ec</td></tr>"
        }
        $html += "</tbody></table>"
    }

    $html += "<div class='section-title'>On-Device Diagnostic Script</div>"
    $html += "<div style='background:#f0fdf4;border-left:4px solid #059669;padding:16px 20px;border-radius:8px;font-size:13px'>"
    $html += "<strong>Script:</strong> <span style='font-family:monospace'>$deviceScriptPath</span><br><br>"
    $html += "Run AS ADMINISTRATOR on the affected device. Collects MDM diag, Event Viewer, IME logs, registry keys and instant summary to <code>C:\AP-Diag\</code>.</div>"

    $html += Get-EIQHTMLFooter
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-EIQSuccess "HTML report: $htmlPath"
    Invoke-Item $htmlPath
}
