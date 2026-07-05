<#
.SYNOPSIS
    EndpointIQ -- Intune, Entra ID & WHfB Admin Toolkit
.DESCRIPTION
    By Imran Awan | EndpointWeekly.com | github.com/Imran76Awan/EndpointIQ

    A professional PowerShell toolkit for enterprise endpoint engineers.
    Built from real-world experience managing large Microsoft environments.

    Features:
      - Device Health Scoring (0-100 composite)
      - Windows Hello for Business health audit (unique)
      - PRT auto-remediation (unique)
      - Stale device detection with cross-referenced Entra sign-in data
      - Tenant health dashboard
      - Multi-tenant support
      - All reports output as branded HTML + CSV

.EXAMPLE
    .\Start-EndpointIQ.ps1
#>

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

Import-Module (Join-Path $root "Modules\EIQ-Helpers.psm1") -Force
Import-Module (Join-Path $root "Modules\EIQ-Auth.psm1") -Force

# Ensure output folder exists
if (-not (Test-Path (Join-Path $root "Output"))) {
    New-Item -ItemType Directory -Path (Join-Path $root "Output") | Out-Null
}

# Install dependencies
$dep = "Microsoft.Graph.Authentication"
if (-not (Get-Module -ListAvailable -Name $dep)) {
    Write-Host "  Installing $dep..." -ForegroundColor Cyan
    Install-Module $dep -Scope CurrentUser -Force
}
Import-Module $dep -ErrorAction SilentlyContinue

# Connect
$ctx = Get-EIQContext
if (-not $ctx) {
    Write-EIQBanner
    Write-EIQInfo "Not connected. Starting authentication..."
    $savedTenant = Show-EIQTenantMenu
    $ctx = Connect-EIQGraph -TenantId $savedTenant
    if (-not $ctx) { Write-EIQError "Authentication failed. Exiting."; exit 1 }
}

function Run-Script {
    param([string]$RelativePath)
    $full = Join-Path $root $RelativePath
    if (Test-Path $full) {
        Write-Host ""
        & $full
        Write-Host ""
        Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } else {
        Write-EIQError "Script not found: $full"
        Start-Sleep 2
    }
}

$running = $true
while ($running) {
    Write-EIQBanner -Account $ctx.Account -Tenant $ctx.TenantId

    Write-EIQSection "📊" "INTUNE -- Device Management"
    Write-EIQItem "1"  "Get-DeviceHealthScore"    "Composite 0-100 health score for every device"         "UNIQUE"
    Write-EIQItem "2"  "Get-StaleDevices"          "Stale devices cross-referenced with Entra sign-in"     "AUTO-REMEDIATE"
    Write-EIQItem "3"  "Get-PolicyConflicts"       "Deep scan for CSP policy conflicts on a device"
    Write-EIQItem "4"  "Get-ComplianceReport"      "Non-compliant devices with failure reasons"
    Write-EIQItem "5"  "Get-AppDeploymentStatus"   "App install status and failure codes"
    Write-EIQItem "6"  "Get-RemediationStatus"     "Proactive remediation script results"
    Write-EIQItem "7"  "Invoke-BulkSync"           "Trigger MDM sync across a group of devices"

    Write-EIQSection "🔐" "WHFB -- Windows Hello for Business"
    Write-EIQItem "8"  "Get-WHFBHealthReport"      "Full WHfB + FIDO2 adoption audit across all users"     "UNIQUE"
    Write-EIQItem "9"  "Invoke-PRTRemediation"     "Diagnose and auto-fix PRT issues on this device"       "UNIQUE"
    Write-EIQItem "10" "Get-WHFBEnrollmentStatus"  "Per-device WHfB enrollment and key status"

    Write-EIQSection "🚀" "AUTOPILOT"
    Write-EIQItem "11" "Get-AutopilotReport"       "Full Autopilot device inventory and profiles"
    Write-EIQItem "12" "Get-DevicePrepStatus"      "Autopilot Device Preparation (v2) status"
    Write-EIQItem "20" "Get-AutopilotBuildDiagnostic" "Why did this build fail? Enter serial -> full timeline" "DIAGNOSTIC"

    Write-EIQSection "🏢" "ENTRA ID -- Identity"
    Write-EIQItem "13" "Get-SignInReport"           "Recent sign-ins, failures and risky sign-ins"
    Write-EIQItem "14" "Get-CAReport"               "Conditional Access policy audit"
    Write-EIQItem "15" "Get-RiskyUsers"             "Users flagged at risk in Identity Protection"
    Write-EIQItem "16" "Get-LicenseReport"          "License allocation and unassigned licenses"
    Write-EIQItem "17" "Get-GuestUserAudit"         "Guest accounts and their access levels"

    Write-EIQSection "📋" "REPORTS"
    Write-EIQItem "18" "Export-TenantHealthReport" "Full tenant dashboard -- share with your IT Manager"    "SIGNATURE"
    Write-EIQItem "19" "Export-DeviceInventory"    "Full 35-column device inventory CSV + HTML"

    Write-EIQSection "⚙" "SETTINGS"
    Write-EIQItem "T"  "Switch Tenant"             "Connect to a different tenant"
    Write-EIQItem "O"  "Open Output Folder"        "View all generated reports"
    Write-EIQItem "Q"  "Quit"                      "Exit EndpointIQ"

    Write-Host ""
    $choice = Read-Host "  Select option"

    switch ($choice.ToUpper()) {
        "1"  { Run-Script "Intune\Get-DeviceHealthScore.ps1" }
        "2"  { Run-Script "Intune\Get-StaleDevices.ps1" }
        "3"  { Run-Script "Intune\Get-PolicyConflicts.ps1" }
        "4"  { Run-Script "Intune\Get-ComplianceReport.ps1" }
        "5"  { Run-Script "Intune\Get-AppDeploymentStatus.ps1" }
        "6"  { Run-Script "Intune\Get-RemediationStatus.ps1" }
        "7"  { Run-Script "Intune\Invoke-BulkSync.ps1" }
        "8"  { Run-Script "WHFB\Get-WHFBHealthReport.ps1" }
        "9"  { Run-Script "WHFB\Invoke-PRTRemediation.ps1" }
        "10" { Run-Script "WHFB\Get-WHFBEnrollmentStatus.ps1" }
        "11" { Run-Script "Autopilot\Get-AutopilotReport.ps1" }
        "12" { Run-Script "Autopilot\Get-DevicePrepStatus.ps1" }
        "20" { Run-Script "Autopilot\Get-AutopilotBuildDiagnostic.ps1" }
        "13" { Run-Script "Entra\Get-SignInReport.ps1" }
        "14" { Run-Script "Entra\Get-CAReport.ps1" }
        "15" { Run-Script "Entra\Get-RiskyUsers.ps1" }
        "16" { Run-Script "Entra\Get-LicenseReport.ps1" }
        "17" { Run-Script "Entra\Get-GuestUserAudit.ps1" }
        "18" { Run-Script "Reports\Export-TenantHealthReport.ps1" }
        "19" { Run-Script "Reports\Export-DeviceInventory.ps1" }
        "T"  {
            $newTenant = Show-EIQTenantMenu
            Disconnect-MgGraph -ErrorAction SilentlyContinue
            $ctx = Connect-EIQGraph -TenantId $newTenant
        }
        "O"  { Invoke-Item (Join-Path $root "Output") }
        "Q"  { $running = $false }
        default { Write-EIQWarn "Invalid option." ; Start-Sleep 1 }
    }
}

Write-Host ""
Write-Host "  Thanks for using EndpointIQ. EndpointWeekly.com" -ForegroundColor DarkGray
Write-Host ""
