# EndpointIQ — Authentication & Multi-Tenant Management
# Author: Imran Awan | EndpointWeekly.com

$script:TenantsFile = Join-Path $PSScriptRoot "..\tenants.json"

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
    $params = @{ Scopes = $script:RequiredScopes; NoWelcome = $true; ErrorAction = "Stop" }
    if ($TenantId) { $params.TenantId = $TenantId }
    try {
        Connect-MgGraph @params
        $ctx = Get-MgContext
        Save-EIQTenant -Account $ctx.Account -TenantId $ctx.TenantId
        return $ctx
    } catch {
        Write-Host "  Authentication failed: $_" -ForegroundColor Red
        return $null
    }
}

function Get-EIQContext {
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $ctx) { return $null }
    try {
        Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization" -Method GET | Out-Null
        return $ctx
    } catch {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        return $null
    }
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
