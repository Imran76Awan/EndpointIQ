# EndpointIQ -- Shared Helpers
# Author: Imran Awan | EndpointWeekly.com

function Write-EIQBanner {
    param([string]$Account = "Not Connected", [string]$Tenant = "")
    Clear-Host
    $connected = $Account -ne "Not Connected"
    Write-Host ""
    Write-Host "  ███████╗███╗   ██╗██████╗ ██████╗  ██████╗ ██╗███╗   ██╗████████╗    ██╗ ██████╗ " -ForegroundColor Cyan
    Write-Host "  ██╔════╝████╗  ██║██╔══██╗██╔══██╗██╔═══██╗██║████╗  ██║╚══██╔══╝    ██║██╔═══██╗" -ForegroundColor Cyan
    Write-Host "  █████╗  ██╔██╗ ██║██║  ██║██████╔╝██║   ██║██║██╔██╗ ██║   ██║       ██║██║   ██║" -ForegroundColor Cyan
    Write-Host "  ██╔══╝  ██║╚██╗██║██║  ██║██╔═══╝ ██║   ██║██║██║╚██╗██║   ██║       ██║██║▄▄ ██║" -ForegroundColor Cyan
    Write-Host "  ███████╗██║ ╚████║██████╔╝██║     ╚██████╔╝██║██║ ╚████║   ██║       ██║╚██████╔╝" -ForegroundColor Cyan
    Write-Host "  ╚══════╝╚═╝  ╚═══╝╚═════╝ ╚═╝      ╚═════╝ ╚═╝╚═╝  ╚═══╝   ╚═╝       ╚═╝ ╚══▀▀═╝ " -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  by Imran Awan  |  EndpointWeekly.com  |  github.com/Imran76Awan/EndpointIQ" -ForegroundColor DarkGray
    Write-Host "  ---------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray -NoNewline
    if ($connected) {
        Write-Host "  |  " -ForegroundColor DarkGray -NoNewline
        Write-Host "[*] Connected: " -ForegroundColor Green -NoNewline
        Write-Host "$Account" -ForegroundColor White -NoNewline
        if ($Tenant) { Write-Host "  ($Tenant)" -ForegroundColor DarkGray }
        else { Write-Host "" }
    } else {
        Write-Host "  |  " -ForegroundColor DarkGray -NoNewline
        Write-Host "[ ] Not Connected" -ForegroundColor Red
    }
    Write-Host ""
}

function Write-EIQSection {
    param([string]$Icon, [string]$Title)
    Write-Host ""
    Write-Host "  $Icon  $Title" -ForegroundColor Yellow
    Write-Host "  $('-' * 50)" -ForegroundColor DarkGray
}

function Write-EIQItem {
    param([string]$Key, [string]$Name, [string]$Desc, [string]$Tag = "")
    Write-Host "    " -NoNewline
    Write-Host "[$Key]" -ForegroundColor Green -NoNewline
    Write-Host " $Name" -ForegroundColor White -NoNewline
    if ($Tag) { Write-Host " [$Tag]" -ForegroundColor Magenta -NoNewline }
    Write-Host " -- $Desc" -ForegroundColor DarkGray
}

function Write-EIQSuccess { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-EIQWarn    { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-EIQError   { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red }
function Write-EIQInfo    { param([string]$Msg) Write-Host "  -> $Msg" -ForegroundColor Cyan }
function Write-EIQStep    { param([string]$Msg) Write-Host "  . $Msg" -ForegroundColor DarkGray }

function Get-EIQOutputPath {
    param([string]$ReportName)
    $base = Join-Path $PSScriptRoot "..\Output"
    $dated = Join-Path $base (Get-Date -Format "yyyy-MM-dd")
    if (-not (Test-Path $dated)) { New-Item -ItemType Directory -Path $dated -Force | Out-Null }
    $file = "$ReportName-$(Get-Date -Format 'HHmmss').html"
    return (Join-Path $dated $file)
}

function Get-EIQCSVPath {
    param([string]$ReportName)
    $base = Join-Path $PSScriptRoot "..\Output"
    $dated = Join-Path $base (Get-Date -Format "yyyy-MM-dd")
    if (-not (Test-Path $dated)) { New-Item -ItemType Directory -Path $dated -Force | Out-Null }
    $file = "$ReportName-$(Get-Date -Format 'HHmmss').csv"
    return (Join-Path $dated $file)
}

function Get-EIQHTMLHeader {
    param([string]$Title, [string]$Subtitle = "")
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$Title -- EndpointIQ</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1117;color:#e2e8f0;min-height:100vh}
  .header{background:linear-gradient(135deg,#059669,#047857);padding:32px 40px;display:flex;justify-content:space-between;align-items:center}
  .header-left h1{font-size:24px;font-weight:700;color:#fff}
  .header-left p{font-size:13px;color:#a7f3d0;margin-top:4px}
  .header-right{text-align:right;font-size:12px;color:#6ee7b7}
  .brand{font-size:13px;font-weight:700;color:#6ee7b7;letter-spacing:1px}
  .meta{font-size:11px;color:#a7f3d0;margin-top:2px}
  .container{max-width:1400px;margin:0 auto;padding:32px 40px}
  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin-bottom:32px}
  .stat{background:#1e2330;border:1px solid #2d3748;border-radius:12px;padding:20px;text-align:center}
  .stat-n{font-size:32px;font-weight:700;color:#059669}
  .stat-n.red{color:#ef4444}
  .stat-n.amber{color:#f59e0b}
  .stat-n.blue{color:#3b82f6}
  .stat-n.purple{color:#8b5cf6}
  .stat-l{font-size:12px;color:#64748b;margin-top:4px;text-transform:uppercase;letter-spacing:0.5px}
  table{width:100%;border-collapse:collapse;background:#1e2330;border-radius:12px;overflow:hidden;border:1px solid #2d3748}
  thead tr{background:#059669}
  thead th{padding:12px 16px;text-align:left;font-size:12px;font-weight:600;color:#fff;text-transform:uppercase;letter-spacing:0.5px}
  tbody tr{border-bottom:1px solid #2d3748;transition:background .15s}
  tbody tr:hover{background:#252d3d}
  tbody tr:last-child{border-bottom:none}
  td{padding:11px 16px;font-size:13px;color:#cbd5e1}
  td.good{color:#4ade80}
  td.warn{color:#fbbf24}
  td.bad{color:#f87171}
  td.mono{font-family:monospace;font-size:12px}
  .badge{display:inline-block;padding:2px 10px;border-radius:20px;font-size:11px;font-weight:600}
  .badge-green{background:#064e3b;color:#6ee7b7}
  .badge-red{background:#450a0a;color:#fca5a5}
  .badge-amber{background:#451a03;color:#fcd34d}
  .badge-blue{background:#1e3a5f;color:#93c5fd}
  .badge-purple{background:#2e1065;color:#c4b5fd}
  .section-title{font-size:16px;font-weight:600;color:#e2e8f0;margin-bottom:16px;margin-top:32px;display:flex;align-items:center;gap:8px}
  .footer{text-align:center;padding:24px;font-size:11px;color:#374151;border-top:1px solid #1e2330;margin-top:40px}
  .score-bar{height:6px;border-radius:3px;background:#2d3748;overflow:hidden}
  .score-fill{height:100%;border-radius:3px}
</style>
</head>
<body>
<div class="header">
  <div class="header-left">
    <h1>$Title</h1>
    $(if($Subtitle){"<p>$Subtitle</p>"})
  </div>
  <div class="header-right">
    <div class="brand">ENDPOINTIQ</div>
    <div class="meta">by Imran Awan . EndpointWeekly.com</div>
    <div class="meta">Generated: $(Get-Date -Format 'dd MMM yyyy HH:mm')</div>
  </div>
</div>
<div class="container">
"@
}

function Get-EIQHTMLFooter {
    return @"
</div>
<div class="footer">EndpointIQ by Imran Awan &nbsp;|&nbsp; <a href="https://endpointweekly.com" style="color:#059669">EndpointWeekly.com</a> &nbsp;|&nbsp; github.com/Imran76Awan/EndpointIQ &nbsp;|&nbsp; Generated $(Get-Date -Format 'dd MMM yyyy HH:mm')</div>
</body></html>
"@
}

function Invoke-EIQGraphRequest {
    param([string]$Uri, [string]$Method = "GET", [object]$Body = $null)
    $params = @{ Uri = $Uri; Method = $Method; Headers = @{ "Content-Type" = "application/json" } }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    try {
        $response = Invoke-MgGraphRequest @params
        return $response
    } catch {
        Write-EIQError "Graph request failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-EIQAllPages {
    param([string]$Uri)
    $all = @()
    $next = $Uri
    do {
        $r = Invoke-EIQGraphRequest -Uri $next
        if ($r -and $r.value) { $all += $r.value }
        $next = $r.'@odata.nextLink'
    } while ($next)
    return $all
}

Export-ModuleMember -Function *
