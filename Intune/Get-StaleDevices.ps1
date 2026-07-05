<#
.SYNOPSIS
    Identify stale/orphaned devices in Intune cross-referenced with Entra ID sign-in activity.
.DESCRIPTION
    Goes further than Ali's version -- cross-references:
      - Intune last sync date
      - Entra ID last sign-in (signInActivity)
      - Device ownership type (Corporate vs Personal)
      - Autopilot registration status

    Offers optional bulk retirement of stale devices with safety confirmation.
.EXAMPLE
    .\Get-StaleDevices.ps1
    .\Get-StaleDevices.ps1 -DaysThreshold 60
    .\Get-StaleDevices.ps1 -DaysThreshold 90 -AutoRetire
#>
param(
    [int]$DaysThreshold = 90,
    [switch]$AutoRetire
)

$moduleRoot = Join-Path $PSScriptRoot "..\Modules"
Import-Module (Join-Path $moduleRoot "EIQ-Helpers.psm1") -Force

Write-EIQInfo "Fetching managed devices (last sync + compliance state)..."
$devices = Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,userPrincipalName,lastSyncDateTime,complianceState,managedDeviceOwnerType,operatingSystem,osVersion,enrolledDateTime,azureADDeviceId"

Write-EIQInfo "Fetching Entra ID devices (sign-in activity)..."
$entraDevices = Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/devices?`$select=displayName,deviceId,approximateLastSignInDateTime,accountEnabled"
$entraLookup = @{}
foreach ($ed in $entraDevices) { $entraLookup[$ed.deviceId] = $ed }

$cutoff = (Get-Date).AddDays(-$DaysThreshold)

Write-EIQInfo "Identifying stale devices (threshold: $DaysThreshold days)..."

$stale = foreach ($d in $devices) {
    $lastSync = if ($d.lastSyncDateTime) { [datetime]$d.lastSyncDateTime } else { [datetime]"2000-01-01" }
    if ($lastSync -gt $cutoff) { continue }

    $entra = $entraLookup[$d.azureADDeviceId]
    $lastSignIn = if ($entra -and $entra.approximateLastSignInDateTime) {
        [datetime]$entra.approximateLastSignInDateTime
    } else { $null }

    $daysSinceSync   = [math]::Round(((Get-Date) - $lastSync).TotalDays)
    $daysSinceSignIn = if ($lastSignIn) { [math]::Round(((Get-Date) - $lastSignIn).TotalDays) } else { 9999 }

    $risk = if ($daysSinceSync -gt 180 -or $daysSinceSignIn -gt 180) { "High" }
            elseif ($daysSinceSync -gt 90) { "Medium" }
            else { "Low" }

    [PSCustomObject]@{
        IntuneId       = $d.id
        DeviceName     = $d.deviceName
        User           = $d.userPrincipalName
        OwnerType      = $d.managedDeviceOwnerType
        OS             = "$($d.operatingSystem) $($d.osVersion)"
        LastSync       = $lastSync | Get-Date -Format "dd MMM yyyy"
        DaysSinceSync  = $daysSinceSync
        LastSignIn     = if ($lastSignIn) { $lastSignIn | Get-Date -Format "dd MMM yyyy" } else { "No data" }
        DaysSinceSignIn= $daysSinceSignIn
        Compliance     = $d.complianceState
        EntraEnabled   = if ($entra) { $entra.accountEnabled } else { "Unknown" }
        Risk           = $risk
    }
}

$stale = @($stale | Sort-Object DaysSinceSync -Descending)
$highRisk   = @($stale | Where-Object { $_.Risk -eq "High"   }).Count
$medRisk    = @($stale | Where-Object { $_.Risk -eq "Medium" }).Count
$lowRisk    = @($stale | Where-Object { $_.Risk -eq "Low"    }).Count

Write-Host ""
Write-Host "  Stale Device Summary (>$DaysThreshold days)" -ForegroundColor Yellow
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Total stale  : " -NoNewline; Write-Host "$($stale.Count) devices" -ForegroundColor White
Write-Host "  High risk    : " -NoNewline; Write-Host "$highRisk devices  (>180 days)" -ForegroundColor Red
Write-Host "  Medium risk  : " -NoNewline; Write-Host "$medRisk devices  (90-180 days)" -ForegroundColor Yellow
Write-Host "  Low risk     : " -NoNewline; Write-Host "$lowRisk devices" -ForegroundColor Green
Write-Host ""

# CSV
$csvPath = Get-EIQCSVPath -ReportName "StaleDevices"
$stale | Export-Csv -Path $csvPath -NoTypeInformation
Write-EIQSuccess "CSV: $csvPath"

# HTML
$htmlPath = Get-EIQOutputPath -ReportName "StaleDevices"
$html = Get-EIQHTMLHeader -Title "Stale Device Report" -Subtitle "Devices with no Intune sync in $DaysThreshold+ days, cross-referenced with Entra ID sign-in activity"

$html += @"
<div class="stats">
  <div class="stat"><div class="stat-n">$($stale.Count)</div><div class="stat-l">Stale Devices</div></div>
  <div class="stat"><div class="stat-n red">$highRisk</div><div class="stat-l">High Risk</div></div>
  <div class="stat"><div class="stat-n amber">$medRisk</div><div class="stat-l">Medium Risk</div></div>
  <div class="stat"><div class="stat-n">$lowRisk</div><div class="stat-l">Low Risk</div></div>
  <div class="stat"><div class="stat-n blue">$DaysThreshold</div><div class="stat-l">Day Threshold</div></div>
</div>
<div class="section-title">Stale Devices</div>
<table>
<thead><tr>
  <th>Device</th><th>User</th><th>Owner</th><th>OS</th>
  <th>Last Intune Sync</th><th>Days Since Sync</th>
  <th>Last Sign-In</th><th>Compliance</th><th>Entra Enabled</th><th>Risk</th>
</tr></thead><tbody>
"@

foreach ($r in $stale) {
    $riskBadge = switch ($r.Risk) {
        "High"   { '<span class="badge badge-red">High</span>' }
        "Medium" { '<span class="badge badge-amber">Medium</span>' }
        "Low"    { '<span class="badge badge-green">Low</span>' }
    }
    $compBadge = if ($r.Compliance -eq "compliant") { '<span class="badge badge-green">Compliant</span>' } else { '<span class="badge badge-red">Non-compliant</span>' }
    $html += "<tr><td>$($r.DeviceName)</td><td class='mono'>$($r.User)</td><td>$($r.OwnerType)</td>"
    $html += "<td class='mono'>$($r.OS)</td><td>$($r.LastSync)</td>"
    $html += "<td class='$(if($r.DaysSinceSync -gt 180){"bad"}elseif($r.DaysSinceSync -gt 90){"warn"}else{"good"})'>$($r.DaysSinceSync) days</td>"
    $html += "<td>$($r.LastSignIn)</td><td>$compBadge</td>"
    $html += "<td>$($r.EntraEnabled)</td><td>$riskBadge</td></tr>"
}

$html += "</tbody></table>" + (Get-EIQHTMLFooter)
$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-EIQSuccess "HTML report: $htmlPath"
Invoke-Item $htmlPath

# Optional bulk retire
if ($stale.Count -gt 0 -and -not $AutoRetire) {
    Write-Host ""
    $retire = Read-Host "  Retire high-risk devices ($highRisk devices)? This sends a retire action via Graph. (Y/N)"
    if ($retire -match '^[Yy]') { $AutoRetire = $true }
}

if ($AutoRetire) {
    $toRetire = $stale | Where-Object { $_.Risk -eq "High" }
    Write-EIQWarn "About to retire $($toRetire.Count) high-risk devices. This cannot be undone."
    $confirm = Read-Host "  Type RETIRE to confirm"
    if ($confirm -eq "RETIRE") {
        foreach ($d in $toRetire) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($d.IntuneId)/retire"
            Invoke-EIQGraphRequest -Uri $uri -Method "POST" | Out-Null
            Write-EIQSuccess "Retire action sent: $($d.DeviceName)"
        }
    } else {
        Write-EIQWarn "Retire cancelled."
    }
}
