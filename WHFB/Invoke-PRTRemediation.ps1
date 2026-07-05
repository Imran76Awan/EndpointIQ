<#
.SYNOPSIS
    Diagnose and auto-remediate PRT (Primary Refresh Token) issues on devices.
.DESCRIPTION
    Unique to EndpointIQ. Imran Awan's PRT remediation speciality.

    Checks dsregcmd /status output for the targeted device and identifies:
      - AzureAdJoined / WorkplaceJoined state
      - SSO state and PRT presence
      - WAM (Web Account Manager) token broker health
      - Certificate validity

    Then offers automated remediation steps:
      - Re-register device identity
      - Clear and refresh PRT via WAM token
      - Force MDM sync post-remediation

    IMPORTANT: Run on the affected device itself, not remotely.
.EXAMPLE
    .\Invoke-PRTRemediation.ps1              # Full diagnostic + guided remediation
    .\Invoke-PRTRemediation.ps1 -DiagOnly    # Diagnostic output only, no changes
    .\Invoke-PRTRemediation.ps1 -AutoFix     # Auto-apply all safe remediations
#>
param(
    [switch]$DiagOnly,
    [switch]$AutoFix
)

$moduleRoot = Join-Path $PSScriptRoot "..\Modules"
Import-Module (Join-Path $moduleRoot "EIQ-Helpers.psm1") -Force

function Get-DsregStatus {
    $raw = dsregcmd /status 2>&1
    $result = @{}
    foreach ($line in $raw) {
        if ($line -match '^\s+(\w[\w\s]+?)\s*:\s*(.+)$') {
            $result[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $result
}

function Show-StatusLine {
    param([string]$Label, [string]$Value, [string]$GoodValue = "YES")
    $isGood = $Value -eq $GoodValue
    $icon   = if ($isGood) { "[OK]" } else { "[X]" }
    $color  = if ($isGood) { "Green" } else { "Red" }
    Write-Host "  $icon " -ForegroundColor $color -NoNewline
    Write-Host "$Label : " -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor $(if ($isGood) { "White" } else { "Red" })
}

Write-Host ""
Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
Write-Host "   EndpointIQ -- PRT Remediation Tool" -ForegroundColor Cyan
Write-Host "   by Imran Awan | EndpointWeekly.com" -ForegroundColor DarkGray
Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
Write-Host ""

Write-EIQInfo "Running dsregcmd /status diagnostic..."
Write-Host ""

$s = Get-DsregStatus

$azureAdJoined   = $s['AzureAdJoined']
$domainJoined    = $s['DomainJoined']
$workplaceJoined = $s['WorkplaceJoined']
$ssoState        = $s['SSO State']
$prtPresent      = if ($s['AzureAdPrt'] -eq 'YES') { "YES" } else { "NO" }
$prtExpiry       = $s['AzureAdPrtExpiryTime']
$mfaDone         = $s['AzureAdPrtAuthority']
$entDevice       = $s['EnterprisePrtAuthority']
$wamBroker       = $s['WamDefaultSet']
$certPresent     = $s['KeySignTest']

Write-Host "  -- Device Identity ----------------------" -ForegroundColor Yellow
Show-StatusLine "Azure AD Joined    " $azureAdJoined
Show-StatusLine "Domain Joined      " $domainJoined
Show-StatusLine "Workplace Joined   " $workplaceJoined

Write-Host ""
Write-Host "  -- PRT Health ---------------------------" -ForegroundColor Yellow
Show-StatusLine "PRT Present        " $prtPresent
if ($prtExpiry) {
    Write-Host "  -> PRT Expiry       : $prtExpiry" -ForegroundColor DarkGray
}
Show-StatusLine "WAM Default Set    " $wamBroker
Show-StatusLine "Key Sign Test      " $certPresent "PASSED"

Write-Host ""

# Identify issues
$issues = @()
if ($azureAdJoined -ne "YES" -and $workplaceJoined -ne "YES") { $issues += "Device is not Azure AD Joined or Registered" }
if ($prtPresent -ne "YES")  { $issues += "PRT is missing -- user cannot get SSO" }
if ($wamBroker -ne "YES")   { $issues += "WAM token broker is not set -- SSO token acquisition will fail" }
if ($certPresent -ne "PASSED") { $issues += "Device certificate (KeySignTest) failed -- WHfB and cert-based auth will not work" }

if ($issues.Count -eq 0) {
    Write-EIQSuccess "No PRT issues detected. Device identity is healthy."
    exit 0
}

Write-Host "  -- Issues Found -------------------------" -ForegroundColor Red
foreach ($i in $issues) { Write-EIQError $i }
Write-Host ""

if ($DiagOnly) {
    Write-EIQWarn "DiagOnly mode -- no changes made."
    exit 0
}

Write-Host "  -- Available Remediations ---------------" -ForegroundColor Yellow
Write-Host "    [1] Re-register device with Azure AD (dsregcmd /join)" -ForegroundColor White
Write-Host "    [2] Clear WAM token state and force PRT refresh" -ForegroundColor White
Write-Host "    [3] Force Intune MDM sync after fix" -ForegroundColor White
Write-Host "    [4] Run all safe remediations" -ForegroundColor Cyan
Write-Host "    [0] Exit without changes" -ForegroundColor DarkGray
Write-Host ""

$choice = if ($AutoFix) { "4" } else { Read-Host "  Select remediation" }

function Do-Rejoin {
    Write-EIQInfo "Triggering dsregcmd /leave then /join..."
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
        Write-EIQError "Must run as Administrator for re-join. Right-click and Run as Administrator."
        return
    }
    Start-Process -FilePath "dsregcmd" -ArgumentList "/leave" -Wait -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Start-Process -FilePath "dsregcmd" -ArgumentList "/join" -Wait -WindowStyle Hidden
    Write-EIQSuccess "Re-join complete. Sign out and back in to refresh PRT."
}

function Do-WAMRefresh {
    Write-EIQInfo "Clearing WAM broker state..."
    # Clear cached WAM tokens by resetting the AAD broker plugin cache
    $pluginPath = "$env:LOCALAPPDATA\Microsoft\Windows\CloudAPPlugin"
    if (Test-Path $pluginPath) {
        Remove-Item "$pluginPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-EIQSuccess "WAM cache cleared at: $pluginPath"
    }
    Write-EIQInfo "Running dsregcmd /refreshprt..."
    Start-Process -FilePath "dsregcmd" -ArgumentList "/refreshprt" -Wait -WindowStyle Hidden
    Write-EIQSuccess "PRT refresh triggered. Re-check with dsregcmd /status in 60 seconds."
}

function Do-MDMSync {
    Write-EIQInfo "Triggering Intune MDM sync..."
    try {
        $session = New-Object -ComObject "Microsoft.Management.Infrastructure.CimSession" -ErrorAction SilentlyContinue
        Invoke-CimMethod -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_DMSessionActions" -MethodName "GenericAlert" -ErrorAction SilentlyContinue
        Write-EIQSuccess "MDM sync triggered."
    } catch {
        # Fallback -- restart IntuneManagementExtension service
        Restart-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
        Write-EIQSuccess "IntuneManagementExtension restarted."
    }
}

switch ($choice) {
    "1" { Do-Rejoin }
    "2" { Do-WAMRefresh }
    "3" { Do-MDMSync }
    "4" { Do-Rejoin; Do-WAMRefresh; Do-MDMSync }
    "0" { Write-EIQWarn "No changes made."; exit 0 }
    default { Write-EIQWarn "Invalid selection." }
}

Write-Host ""
Write-EIQInfo "Re-running diagnostic to verify fix..."
Start-Sleep -Seconds 5
$s2 = Get-DsregStatus
$prtAfter = if ($s2['AzureAdPrt'] -eq 'YES') { "YES" } else { "NO" }
Write-Host ""
Show-StatusLine "PRT Present (after)" $prtAfter
Write-Host ""
if ($prtAfter -eq "YES") {
    Write-EIQSuccess "PRT remediation successful."
} else {
    Write-EIQWarn "PRT still missing. Sign out and back in to complete the token refresh."
    Write-EIQStep "If this persists, the device may need to be re-enrolled in Intune."
}
