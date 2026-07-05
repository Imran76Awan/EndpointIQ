<#
.SYNOPSIS
    Calculates a composite Health Score (0-100) for every managed device.
.DESCRIPTION
    Unique to EndpointIQ. Scores each device across 5 pillars:
      - Compliance (25pts)    -- is the device compliant?
      - Defender (25pts)      -- AV up to date, no active threats
      - Patch level (20pts)   -- last Windows update recency
      - Check-in recency (20pts) -- last Intune sync
      - Encryption (10pts)    -- BitLocker enabled

    Outputs an HTML report with colour-coded scores and a CSV for further analysis.
    Devices scoring below 60 are flagged as At Risk.
.EXAMPLE
    .\Get-DeviceHealthScore.ps1
    .\Get-DeviceHealthScore.ps1 -MinScore 0 -MaxScore 59   # At Risk devices only
    .\Get-DeviceHealthScore.ps1 -GroupId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>
param(
    [int]$MinScore = 0,
    [int]$MaxScore = 100,
    [string]$GroupId = ""
)

$moduleRoot = Join-Path $PSScriptRoot "..\Modules"
Import-Module (Join-Path $moduleRoot "EIQ-Helpers.psm1") -Force

Write-EIQInfo "Fetching managed devices..."

$uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,userPrincipalName,complianceState,lastSyncDateTime,osVersion,encryptionState,windowsProtectionState,managedDeviceOwnerType"
$devices = Get-EIQAllPages -Uri $uri

if (-not $devices) { Write-EIQError "No devices returned."; return }

Write-EIQInfo "Scoring $($devices.Count) devices..."

$results = foreach ($d in $devices) {
    $score = 0
    $breakdown = @{}

    # Pillar 1 -- Compliance (25pts)
    $compScore = switch ($d.complianceState) {
        "compliant"    { 25 }
        "unknown"      { 10 }
        "notApplicable"{ 15 }
        default        { 0  }
    }
    $score += $compScore
    $breakdown.Compliance = $compScore

    # Pillar 2 -- Defender (25pts)
    $wp = $d.windowsProtectionState
    $defScore = 0
    if ($wp) {
        if ($wp.realTimeProtectionEnabled)      { $defScore += 10 }
        if (-not $wp.malwareProtectionEnabled -eq $false) { $defScore += 5 }
        if ($wp.networkInspectionSystemEnabled) { $defScore += 5 }
        if ($wp.signatureUpdateOverdue -eq $false) { $defScore += 5 }
    }
    $score += $defScore
    $breakdown.Defender = $defScore

    # Pillar 3 -- Patch recency (20pts)
    $patchScore = 0
    if ($d.osVersion) {
        # Extract build number heuristic -- higher = more recent
        $build = ($d.osVersion -split '\.')[2] -as [int]
        if ($build -ge 22631)     { $patchScore = 20 }  # Win11 23H2+
        elseif ($build -ge 22000) { $patchScore = 15 }  # Win11 21H2+
        elseif ($build -ge 19045) { $patchScore = 10 }  # Win10 22H2
        elseif ($build -ge 19044) { $patchScore = 5  }  # Win10 21H2
        else                       { $patchScore = 0  }
    }
    $score += $patchScore
    $breakdown.Patch = $patchScore

    # Pillar 4 -- Check-in recency (20pts)
    $syncScore = 0
    if ($d.lastSyncDateTime) {
        $daysSince = ((Get-Date) - [datetime]$d.lastSyncDateTime).TotalDays
        if ($daysSince -le 1)      { $syncScore = 20 }
        elseif ($daysSince -le 3)  { $syncScore = 15 }
        elseif ($daysSince -le 7)  { $syncScore = 10 }
        elseif ($daysSince -le 14) { $syncScore = 5  }
        else                        { $syncScore = 0  }
    }
    $score += $syncScore
    $breakdown.CheckIn = $syncScore

    # Pillar 5 -- Encryption (10pts)
    $encScore = if ($d.encryptionState -eq "encrypted") { 10 } else { 0 }
    $score += $encScore
    $breakdown.Encryption = $encScore

    $lastSync = if ($d.lastSyncDateTime) { [datetime]$d.lastSyncDateTime | Get-Date -Format "dd MMM yyyy HH:mm" } else { "Never" }

    [PSCustomObject]@{
        DeviceName   = $d.deviceName
        User         = $d.userPrincipalName
        Score        = $score
        Grade        = if ($score -ge 80) { "Healthy" } elseif ($score -ge 60) { "Fair" } else { "At Risk" }
        Compliance   = $breakdown.Compliance
        Defender     = $breakdown.Defender
        Patch        = $breakdown.Patch
        CheckIn      = $breakdown.CheckIn
        Encryption   = $breakdown.Encryption
        OSVersion    = $d.osVersion
        LastSync     = $lastSync
        OwnerType    = $d.managedDeviceOwnerType
    }
}

$filtered = $results | Where-Object { $_.Score -ge $MinScore -and $_.Score -le $MaxScore } | Sort-Object Score

$healthy  = @($filtered | Where-Object { $_.Grade -eq "Healthy"  }).Count
$fair     = @($filtered | Where-Object { $_.Grade -eq "Fair"     }).Count
$atRisk   = @($filtered | Where-Object { $_.Grade -eq "At Risk"  }).Count
$avgScore = if ($filtered.Count -gt 0) { [math]::Round(($filtered | Measure-Object Score -Average).Average, 1) } else { 0 }

# CSV export
$csvPath = Get-EIQCSVPath -ReportName "DeviceHealthScore"
$filtered | Export-Csv -Path $csvPath -NoTypeInformation
Write-EIQSuccess "CSV: $csvPath"

# HTML report
$htmlPath = Get-EIQOutputPath -ReportName "DeviceHealthScore"
$html = Get-EIQHTMLHeader -Title "Device Health Score Report" -Subtitle "Composite 0-100 scoring across Compliance, Defender, Patch, Check-in & Encryption"

$html += @"
<div class="stats">
  <div class="stat"><div class="stat-n">$($filtered.Count)</div><div class="stat-l">Devices Scored</div></div>
  <div class="stat"><div class="stat-n">$avgScore</div><div class="stat-l">Average Score</div></div>
  <div class="stat"><div class="stat-n">$healthy</div><div class="stat-l">Healthy (80-100)</div></div>
  <div class="stat"><div class="stat-n amber">$fair</div><div class="stat-l">Fair (60-79)</div></div>
  <div class="stat"><div class="stat-n red">$atRisk</div><div class="stat-l">At Risk (&lt;60)</div></div>
</div>

<div class="section-title">Device Health Scores</div>
<table>
<thead><tr>
  <th>Device</th><th>User</th><th>Score</th><th>Grade</th>
  <th>Compliance</th><th>Defender</th><th>Patch</th><th>Check-In</th><th>Encryption</th>
  <th>OS Version</th><th>Last Sync</th>
</tr></thead>
<tbody>
"@

foreach ($r in $filtered) {
    $scoreColor = if ($r.Score -ge 80) { "good" } elseif ($r.Score -ge 60) { "warn" } else { "bad" }
    $gradeBadge = switch ($r.Grade) {
        "Healthy" { '<span class="badge badge-green">Healthy</span>' }
        "Fair"    { '<span class="badge badge-amber">Fair</span>' }
        "At Risk" { '<span class="badge badge-red">At Risk</span>' }
    }
    $bar = "<div class='score-bar'><div class='score-fill' style='width:$($r.Score)%;background:$(if($r.Score -ge 80){"#059669"}elseif($r.Score -ge 60){"#f59e0b"}else{"#ef4444"})'></div></div>"
    $html += "<tr><td>$($r.DeviceName)</td><td>$($r.User)</td>"
    $html += "<td class='$scoreColor'><strong>$($r.Score)</strong>/100<br>$bar</td>"
    $html += "<td>$gradeBadge</td>"
    $html += "<td>$($r.Compliance)/25</td><td>$($r.Defender)/25</td><td>$($r.Patch)/20</td>"
    $html += "<td>$($r.CheckIn)/20</td><td>$($r.Encryption)/10</td>"
    $html += "<td class='mono'>$($r.OSVersion)</td><td>$($r.LastSync)</td></tr>"
}

$html += "</tbody></table>"
$html += Get-EIQHTMLFooter

$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-EIQSuccess "HTML report: $htmlPath"

# Console summary
Write-Host ""
Write-Host "  Health Score Summary" -ForegroundColor Yellow
Write-Host "  --------------------------------" -ForegroundColor DarkGray
Write-Host "  Average Score : " -NoNewline; Write-Host "$avgScore / 100" -ForegroundColor Cyan
Write-Host "  Healthy       : " -NoNewline; Write-Host "$healthy devices" -ForegroundColor Green
Write-Host "  Fair          : " -NoNewline; Write-Host "$fair devices" -ForegroundColor Yellow
Write-Host "  At Risk       : " -NoNewline; Write-Host "$atRisk devices" -ForegroundColor Red
Write-Host ""

Invoke-Item $htmlPath
