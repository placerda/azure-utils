#!/usr/bin/env pwsh
<#
Script: set-public.ps1
Overview:
    Makes networking for resources in a given Azure Resource Group public. Specifically targets
    Storage Accounts, Key Vaults, and Cosmos DB accounts and sets their public network access
    to Enabled and default firewall actions to Allow where applicable. Existing private endpoints
    or rules are left in place; the goal is to ensure public reachability regardless of current state.

Prerequisites:
    - PowerShell 7+ (pwsh)
    - Azure CLI (az) installed and logged in: az login
    - Sufficient permissions (Contributor or above) on the subscription/resource group
    - Network access to Azure management endpoints

Usage examples:
    # Interactive (prompts for subscription and resource group; reuses last values if present):
    .\ps\set-public.ps1

Notes:
    - The script stores last-used parameters in: $env:TEMP\set-public-last.ps1
    - For Storage Accounts: sets `--public-network-access Enabled` and `--default-action Allow`.
    - For Key Vaults: sets `--public-network-access Enabled` and `--default-action Allow` (bypass AzureServices).
    - For Cosmos DB accounts: sets `--public-network-access Enabled`, clears IP filters, and removes VNet rules (best-effort).
#>

param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Global (script-scope) vars that will be populated in Prompt-Context
$script:SUB = $null
$script:RG  = $null

# State file in system temp directory
$StateFile = Join-Path $env:TEMP 'set-public-last.ps1'

function Prompt-Context {
    if (Test-Path -Path $StateFile) {
        . $StateFile
        $script:SUB = $SUB; $script:RG = $RG
        Write-Host "Last used:" -ForegroundColor Cyan
        $subDisplay = if ([string]::IsNullOrWhiteSpace($script:SUB)) { '<none>' } else { $script:SUB }
        $rgDisplay  = if ([string]::IsNullOrWhiteSpace($script:RG))  { '<none>' } else { $script:RG }
        Write-Host "  Subscription: $subDisplay"
        Write-Host "  ResourceGroup: $rgDisplay"

        $reuseSub = Read-Host "Reuse subscription '$script:SUB'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseSub)) { $reuseSub = 'Y' }
        if ($reuseSub -match '^(n|no)$') { $script:SUB = Read-Host 'Subscription ID or name' }

        $reuseRG = Read-Host "Reuse resource group '$script:RG'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseRG)) { $reuseRG = 'Y' }
        if ($reuseRG -match '^(n|no)$') { $script:RG = Read-Host 'Resource group name' }
    }
    else {
        $script:SUB = Read-Host 'Subscription ID or name'
        $script:RG  = Read-Host 'Resource group name'
    }

    if ([string]::IsNullOrWhiteSpace($script:SUB) -or [string]::IsNullOrWhiteSpace($script:RG)) {
        Write-Host 'Subscription and resource group are required.' -ForegroundColor Red
        exit 1
    }

    $safeSub = $script:SUB -replace "'","''"
    $safeRg  = $script:RG  -replace "'","''"
    Set-Content -Path $StateFile -Value @("`$SUB = '$safeSub'","`$RG  = '$safeRg'") -Encoding UTF8
}

function Ensure-Subscription {
    Write-Host ">> Using subscription: $script:SUB"
    & az account set --subscription $script:SUB | Out-Null
    Write-Host ">> Verifying resource group '$script:RG' exists…"
    try { & az group show -n $script:RG | Out-Null } catch { Write-Host "Resource group '$script:RG' not found or access denied." -ForegroundColor Red; exit 1 }
}

function Make-Storage-Public {
    param([string]$rg)
    Write-Host ">> Processing Storage Accounts in '$rg'…"
    try { $namesRaw = & az storage account list -g $rg --query "[].name" -o tsv } catch { $namesRaw = '' }
    if (-not $namesRaw) { Write-Host "   - None found."; return }
    foreach ($name in ($namesRaw -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        Write-Host "   - ${rg}/${name} -> public access (Allow)"
        try {
            & az storage account update -g $rg -n $name --public-network-access Enabled --default-action Allow | Out-Null
        } catch {
            Write-Host "     (warn) update failed for storage '$name': $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        # Optional: clear ip and vnet rules (best-effort)
        try {
            $ips = & az storage account network-rule list -g $rg -n $name --query "ipRules[].ipAddressOrRange" -o tsv 2>$null
            if ($ips) {
                foreach ($ip in ($ips -split "`n")) { if ($ip) { & az storage account network-rule remove -g $rg -n $name --ip-address $ip | Out-Null } }
            }
        } catch { }
        try {
            $subnets = & az storage account network-rule list -g $rg -n $name --query "virtualNetworkRules[].virtualNetworkResourceId" -o tsv 2>$null
            if ($subnets) {
                foreach ($sn in ($subnets -split "`n")) { if ($sn) { & az storage account network-rule remove -g $rg -n $name --subnet $sn | Out-Null } }
            }
        } catch { }
    }
}

function Make-KeyVaults-Public {
    param([string]$rg)
    Write-Host ">> Processing Key Vaults in '$rg'…"
    try { $namesRaw = & az keyvault list -g $rg --query "[].name" -o tsv } catch { $namesRaw = '' }
    if (-not $namesRaw) { Write-Host "   - None found."; return }
    foreach ($name in ($namesRaw -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        Write-Host "   - ${rg}/${name} -> public access (Allow)"
        try {
            & az keyvault update -g $rg -n $name --public-network-access Enabled --default-action Allow --bypass AzureServices | Out-Null
        } catch {
            Write-Host "     (warn) update failed for key vault '$name': $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        # Optional: remove explicit network rules (best-effort). There isn't a direct clear-all; setting default action Allow suffices.
    }
}

function Make-Cosmos-Public {
    param([string]$rg)
    Write-Host ">> Processing Cosmos DB accounts in '$rg'…"
    try { $namesRaw = & az cosmosdb list -g $rg --query "[].name" -o tsv } catch { $namesRaw = '' }
    if (-not $namesRaw) { Write-Host "   - None found."; return }
    foreach ($name in ($namesRaw -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        Write-Host "   - ${rg}/${name} -> public access (Enable + clear filters)"
        # 1) Enable Public Network Access without touching ip-range here (avoids empty-arg error)
        try { & az cosmosdb update -g $rg -n $name --public-network-access Enabled | Out-Null } catch { Write-Host "     (warn) update failed for cosmos '$name' (publicNetworkAccess): $($_.Exception.Message)" -ForegroundColor DarkYellow }

        # 2) Remove explicit IP rules (best-effort)
        try { $ips = & az cosmosdb network-rule list -g $rg -n $name --query "ipRules[].ipAddressOrRange" -o tsv 2>$null } catch { $ips = '' }
        if ($ips) {
            foreach ($ip in ($ips -split "`n")) {
                if ([string]::IsNullOrWhiteSpace($ip)) { continue }
                try { & az cosmosdb network-rule remove -g $rg -n $name --ip-address $ip | Out-Null } catch { Write-Host "     (warn) failed to remove IP rule: $ip" -ForegroundColor DarkYellow }
            }
        }

        # 3) Remove all VNet rules (best-effort). Query for both subnetId and id variants
        $vnets = ''
        try { $vnets = & az cosmosdb network-rule list -g $rg -n $name --query "virtualNetworkRules[].subnetId" -o tsv 2>$null } catch { $vnets = '' }
        if (-not $vnets) {
            try { $vnets = & az cosmosdb network-rule list -g $rg -n $name --query "virtualNetworkRules[].id" -o tsv 2>$null } catch { $vnets = '' }
        }
        if ($vnets) {
            foreach ($sn in ($vnets -split "`n")) {
                if ([string]::IsNullOrWhiteSpace($sn)) { continue }
                try { & az cosmosdb network-rule remove -g $rg -n $name --subnet $sn | Out-Null } catch { Write-Host "     (warn) failed to remove VNet rule: $sn" -ForegroundColor DarkYellow }
            }
        }

        # 4) Disable virtual network enforcement if supported (ignore errors if not)
        try { & az cosmosdb update -g $rg -n $name --enable-virtual-network false | Out-Null } catch { }

        # 5) Optional fallback: explicitly clear ipRangeFilter via --set (try both paths); ignore errors
        try { & az cosmosdb update -g $rg -n $name --set ipRangeFilter= | Out-Null } catch { try { & az cosmosdb update -g $rg -n $name --set properties.ipRangeFilter= | Out-Null } catch { } }
    }
}

function Main {
    Prompt-Context
    Ensure-Subscription

    Make-Storage-Public -rg $script:RG
    Make-KeyVaults-Public -rg $script:RG
    Make-Cosmos-Public -rg $script:RG

    Write-Host "✅ Completed making resources public (best-effort)." -ForegroundColor Green
}

Main
