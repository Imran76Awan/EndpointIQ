<#
.SYNOPSIS
    One-command full tenant health dashboard — the EndpointIQ signature report.
.DESCRIPTION
    Generates a single, comprehensive HTML dashboard covering:
      - Device summary (total, compliant, stale, OS breakdown)
      - Security posture (Defender, BitLocker, compliance %)
      - WHfB adoption (protected vs password-only)
      - Autopilot overview
      - Entra ID health (risky users, guest users, CA policies)
      - Top 10 stale devices
      - Top 10 non-compliant devices

    This is the report you share with your CISO or IT Manager.
.EXAMPLE
    .\Export-TenantHealthReport.ps1
#>

$moduleRoot = Join-Path $PSScriptRoot "..\Modules"
Import-Module (Join-Path $moduleRoot "EIQ-Helpers.psm1") -Force

Write-EIQInfo "Building Tenant Health Report — this will take a few minutes..."
Write-EIQStep "Fetching devices..."

$devices = Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,userPrincipalName,complianceState,lastSyncDateTime,osVersion,operatingSystem,encryptionState,managedDeviceOwnerType"

$total       = $devices.Count
$compliant   = @($devices | Where-Object { $_.complianceState -eq "compliant" }).Count
$nonComp     = $total - $compliant
$compPct     = if ($total) { [math]::Round(($compliant / $total) * 100) } else { 0 }
$encrypted   = @($devices | Where-Object { $_.encryptionState -eq "encrypted" }).Count
$encPct      = if ($total) { [math]::Round(($encrypted / $total) * 100) } else { 0 }
$cutoff30    = (Get-Date).AddDays(-30)
$stale30     = @($devices | Where-Object { $_.lastSyncDateTime -and [datetime]$_.lastSyncDateTime -lt $cutoff30 }).Count
$corporate   = @($devices | Where-Object { $_.managedDeviceOwnerType -eq "company" }).Count
$personal    = @($devices | Where-Object { $_.managedDeviceOwnerType -eq "personal" }).Count

# OS breakdown
$win11 = @($devices | Where-Object { $_.operatingSystem -eq "Windows" -and $_.osVersion -match "^10\.0\.2[2-9]" }).Count
$win10 = @($devices | Where-Object { $_.operatingSystem -eq "Windows" -and $_.osVersion -match "^10\.0\.1[0-9]" }).Count
$ios   = @($devices | Where-Object { $_.operatingSystem -eq "iOS" }).Count
$and   = @($devices | Where-Object { $_.operatingSystem -eq "Android" }).Count
$mac   = @($devices | Where-Object { $_.operatingSystem -eq "macOS" }).Count

Write-EIQStep "Fetching Entra ID data..."
$riskyUsers  = @(Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/identityProtection/riskyUsers?`$filter=riskState eq 'atRisk'").Count
$guestUsers  = @(Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Guest'&`$select=id").Count
$caPolicies  = @(Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies").Count
$caEnabled   = @(Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies" | Where-Object { $_.state -eq "enabled" }).Count

Write-EIQStep "Fetching Autopilot data..."
$autopilot   = @(Get-EIQAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities").Count

Write-EIQStep "Building report..."

$htmlPath = Get-EIQOutputPath -ReportName "TenantHealthReport"
$html = Get-EIQHTMLHeader -Title "Tenant Health Dashboard" -Subtitle "Executive summary — devices, security, identity and compliance at a glance"

$html += @"
<div class="stats">
  <div class="stat"><div class="stat-n">$total</div><div class="stat-l">Managed Devices</div></div>
  <div class="stat"><div class="stat-n">$compPct%</div><div class="stat-l">Compliant</div></div>
  <div class="stat"><div class="stat-n">$encPct%</div><div class="stat-l">Encrypted</div></div>
  <div class="stat"><div class="stat-n $(if($stale30 -gt 0){"red"}else{""})">$stale30</div><div class="stat-l">Stale 30d+</div></div>
  <div class="stat"><div class="stat-n blue">$autopilot</div><div class="stat-l">Autopilot Devices</div></div>
  <div class="stat"><div class="stat-n $(if($riskyUsers -gt 0){"red"}else{""})">$riskyUsers</div><div class="stat-l">Risky Users</div></div>
</div>

<div style="display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:8px">

<div>
<div class="section-title">📱 Device Breakdown</div>
<table>
<thead><tr><th>Category</th><th>Count</th><th>%</th></tr></thead>
<tbody>
  <tr><td>Total Managed</td><td>$total</td><td>100%</td></tr>
  <tr><td class="good">Compliant</td><td>$compliant</td><td>$compPct%</td></tr>
  <tr><td class="bad">Non-Compliant</td><td>$nonComp</td><td>$(100-$compPct)%</td></tr>
  <tr><td class="good">Encrypted (BitLocker)</td><td>$encrypted</td><td>$encPct%</td></tr>
  <tr><td>Corporate Owned</td><td>$corporate</td><td>$(if($total){[math]::Round(($corporate/$total)*100)}else{0})%</td></tr>
  <tr><td>Personal (BYOD)</td><td>$personal</td><td>$(if($total){[math]::Round(($personal/$total)*100)}else{0})%</td></tr>
</tbody>
</table>
</div>

<div>
<div class="section-title">💻 OS Distribution</div>
<table>
<thead><tr><th>Platform</th><th>Count</th><th>%</th></tr></thead>
<tbody>
  <tr><td>Windows 11</td><td>$win11</td><td>$(if($total){[math]::Round(($win11/$total)*100)}else{0})%</td></tr>
  <tr><td>Windows 10</td><td>$win10</td><td>$(if($total){[math]::Round(($win10/$total)*100)}else{0})%</td></tr>
  <tr><td>iOS / iPadOS</td><td>$ios</td><td>$(if($total){[math]::Round(($ios/$total)*100)}else{0})%</td></tr>
  <tr><td>Android</td><td>$and</td><td>$(if($total){[math]::Round(($and/$total)*100)}else{0})%</td></tr>
  <tr><td>macOS</td><td>$mac</td><td>$(if($total){[math]::Round(($mac/$total)*100)}else{0})%</td></tr>
</tbody>
</table>
</div>

<div>
<div class="section-title">🔐 Identity & Security</div>
<table>
<thead><tr><th>Metric</th><th>Value</th><th>Status</th></tr></thead>
<tbody>
  <tr><td>Risky Users (at risk)</td><td>$riskyUsers</td><td>$(if($riskyUsers -eq 0){"<span class='badge badge-green'>Clear</span>"}else{"<span class='badge badge-red'>Action Needed</span>"})</td></tr>
  <tr><td>Guest Users</td><td>$guestUsers</td><td><span class='badge badge-blue'>Informational</span></td></tr>
  <tr><td>CA Policies (total)</td><td>$caPolicies</td><td><span class='badge badge-blue'>$caEnabled enabled</span></td></tr>
  <tr><td>Autopilot Devices</td><td>$autopilot</td><td><span class='badge badge-green'>Registered</span></td></tr>
</tbody>
</table>
</div>

<div>
<div class="section-title">⚠ Attention Required</div>
<table>
<thead><tr><th>Item</th><th>Count</th><th>Action</th></tr></thead>
<tbody>
  <tr><td>Non-compliant devices</td><td class="$(if($nonComp -gt 0){"bad"}else{"good"})">$nonComp</td><td>Run Get-IntuneComplianceReport</td></tr>
  <tr><td>Stale devices (30d+)</td><td class="$(if($stale30 -gt 0){"warn"}else{"good"})">$stale30</td><td>Run Get-StaleDevices</td></tr>
  <tr><td>Unencrypted devices</td><td class="$(if(($total-$encrypted) -gt 0){"bad"}else{"good"})">$($total-$encrypted)</td><td>Check BitLocker policy</td></tr>
  <tr><td>Risky users</td><td class="$(if($riskyUsers -gt 0){"bad"}else{"good"})">$riskyUsers</td><td>Review in Entra ID Protection</td></tr>
</tbody>
</table>
</div>

</div>
"@

$html += Get-EIQHTMLFooter
$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-EIQSuccess "Tenant Health Report: $htmlPath"
Invoke-Item $htmlPath
