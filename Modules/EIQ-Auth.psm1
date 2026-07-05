# EndpointIQ -- Authentication & Multi-Tenant Management
# Author: Imran Awan | EndpointWeekly.com

$script:TenantsFile = Join-Path $PSScriptRoot "..\tenants.json"

# App registration credentials — certificate-based (no browser popup)
$script:TenantId   = '2dfb2f0b-4d21-4268-9559-72926144c918'
$script:ClientId   = '7f523eab-8b8b-492d-97dd-40fc4dc60465'
$script:Thumbprint = 'EE834FD37142324FFBE4BA9280151453CB36E276'

$script:RequiredScopes = @(
    'DeviceManagementConfiguration.Read.All',
    'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementManagedDevices.ReadWrite.All',
    'DeviceManagementManagedDevices.PrivilegedOperations.All',
    'DeviceManagementServiceConfig.Read.All',
    'DeviceManagementApps.Read.All',
    'DeviceManagementRBAC.Read.All',
    'Device.Read.All',
    'Directory.Read.All',
    'Group.Read.All',
    'GroupMember.Read.All',
    'User.Read.All',
    'Policy.Read.All',
    'Application.Read.All',
    'BitlockerKey.Read.All',
    'AuditLog.Read.All',
    'IdentityRiskyUser.Read.All',
    'RoleManagement.Read.All',
    'Organization.Read.All',
    'UserAuthenticationMethod.Read.All'
)

function Install-EIQDependencies {
    $module = "Microsoft.Graph.Authentication"
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "  Installing $module..." -ForegroundColor Cyan
        Install-Module -Name $module -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module $module -ErrorAction SilentlyContinue
}

function Connect-EIQGraph {
    param([string]$TenantId = "")
    Install-EIQDependencies
    try {
        # Certificate-based app authentication — no browser popup
        Connect-MgGraph `
            -TenantId   $script:TenantId `
            -ClientId   $script:ClientId `
            -CertificateThumbprint $script:Thumbprint `
            -NoWelcome `
            -ErrorAction Stop
        $ctx = Get-MgContext
        Write-Host "  [OK] Connected as app: $($ctx.ClientId) | Tenant: $($ctx.TenantId)" -ForegroundColor Green
        return $ctx
    } catch {
        Write-Host "  [X] Authentication failed: $_" -ForegroundColor Red
        Write-Host "  Check that the certificate thumbprint is installed in CurrentUser\My store" -ForegroundColor Yellow
        return $null
    }
}

function Get-EIQContext {
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($ctx) {
        try {
            Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization" -Method GET | Out-Null
            return $ctx
        } catch {
            Disconnect-MgGraph -ErrorAction SilentlyContinue
        }
    }
    # Auto-connect using app credentials if no active session
    return Connect-EIQGraph
}

function Save-EIQTenant {
    param([string]$Account, [string]$TenantId)
    $tenants = Get-EIQTenants
    $existing = $tenants | Where-Object { $_.TenantId -eq $TenantId }
    if (-not $existing) {
        $tenants += [PSCustomObject]@{ Account = $Account; TenantId = $TenantId; LastUsed = (Get-Date -Format "yyyy-MM-dd HH:mm") }
        $tenants | ConvertTo-Json | Out-File $script:TenantsFile -Encoding UTF8
    }
}

function Get-EIQTenants {
    if (Test-Path $script:TenantsFile) {
        try { return @(Get-Content $script:TenantsFile | ConvertFrom-Json) } catch {}
    }
    return @()
}

function Show-EIQTenantMenu {
    $tenants = Get-EIQTenants
    if ($tenants.Count -eq 0) { return $null }
    Write-Host ""
    Write-Host "  Saved Tenants:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $tenants.Count; $i++) {
        Write-Host "    [$($i+1)] $($tenants[$i].Account)  ($($tenants[$i].TenantId))" -ForegroundColor White
    }
    Write-Host "    [N] Connect to a new tenant" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "  Select tenant"
    if ($choice -match '^\d+$' -and [int]$choice -le $tenants.Count) {
        return $tenants[[int]$choice - 1].TenantId
    }
    return $null
}

Export-ModuleMember -Function *
