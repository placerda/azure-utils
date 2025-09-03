#!/usr/bin/env pwsh
#requires -Version 7
<#
Script: rm-rg.ps1
Overview:
    Safely and forcefully deletes an Azure Resource Group by removing common blockers first.
    Handles: NSG disassociations (NICs/subnets), Private Endpoints on subnets, Service Association Links (e.g., for Azure Container Apps),
    subnet delegations/service endpoints/route tables/NAT gateways, VNet peerings, Private DNS zone VNet links, resource group locks,
    plus "heavy" blockers: Container Apps, Managed Environments, Application Gateways, Azure Firewalls, Bastion, VMs/NICs.
    Triggers `az group delete --no-wait` and optionally polls until the RG is gone or a rollback is detected.

Prerequisites:
    - PowerShell 7+ (pwsh)
    - Azure CLI (az) installed and logged in: az login
    - Sufficient permissions (Owner or equivalent) on the target subscription/resource group to delete resources and locks
    - Network access to Azure management endpoints

Usage examples:
    # Interactive (prompts for subscription and resource group, no confirmation by default):
    .\ps\rm-rg.ps1

    # Skip prompts but still interactive for SUB/RG recall; do not wait for completion:
    .\ps\rm-rg.ps1 -NoWait

    # Prompt for confirmation before deletion:
    .\ps\rm-rg.ps1 -Confirm

    # Force (no confirmation) and wait with default timeout/poll:
    .\ps\rm-rg.ps1 -Force

Notes:
    - Polling stops when the RG is no longer returned (Deleted). If Azure reports Deleting and later Succeeded, the script exits early
      indicating deletion likely failed due to blockers.
    - Exit codes: 1 (input/validation), 2 (delete command failed), 3 (timeout), 4 (rollback to Succeeded after Deleting).
#>
param(
    [switch]$Force,
    [switch]$NoWait,
    [switch]$Confirm,
    [int]$TimeoutMinutes = 20,
    [int]$PollSeconds = 10
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Global (script-scope) vars that will be populated in Prompt-Context
$script:SUB = $null
$script:RG  = $null

# State file in system temp directory
$StateFile = Join-Path $env:TEMP 'cleanup-nsgs-last.ps1'

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

function Unset-Subnet-Props {
    param($rg, $vnet, $subnet)
    Write-Host "   - Clearing associations on subnet ${rg}/${vnet}/${subnet}"
    foreach ($prop in 'networkSecurityGroup','routeTable','natGateway','delegations','serviceEndpoints') {
        try { & az network vnet subnet update -g $rg --vnet-name $vnet -n $subnet --remove $prop | Out-Null } catch { Write-Host "     · (warn) could not remove $prop" -ForegroundColor DarkYellow }
    }
}

function Delete-PrivateEndpoints-For-Subnet {
    param($subnetId)
    Write-Host "   - Looking for Private Endpoints on this subnet…"
    try { $PEs = & az network private-endpoint list --query "[?subnet.id=='$subnetId'].{id:id}" -o tsv } catch { $PEs = '' }
    if ($PEs) {
        foreach ($pe in ($PEs -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($pe)) { continue }
            Write-Host "     · Deleting Private Endpoint: $pe"
            try { & az resource delete --ids $pe | Out-Null } catch { Write-Host "       (warn) failed: $pe" -ForegroundColor DarkYellow }
        }
    }
}

function Force-Delete-SAL {
    param([Parameter(Mandatory=$true)][string]$salId)
    Write-Host "   - Force-deleting SAL via REST: $salId"
    $apiVersion = '2023-09-01'  # Microsoft.Network
    # FIX: wrap $salId to avoid PowerShell treating "?api" as part of the variable name
    $uri = "https://management.azure.com${salId}?api-version=$apiVersion"
    try {
        az rest --method delete --url $uri --only-show-errors | Out-Null
    } catch {
        Write-Host "     (warn) REST SAL delete failed: $salId" -ForegroundColor DarkYellow
    }
}

function Delete-ServiceAssociationLinks {
    param($rg, $vnet, $subnet)
    # First delete the SAL child resources under the subnet
    try { $salIds = & az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet --query "serviceAssociationLinks[].id" -o tsv } catch { $salIds = '' }
    if ($salIds) {
        foreach ($sid in ($salIds -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($sid)) { continue }
            Write-Host "   - Deleting Service Association Link: $sid"
            & az resource delete --ids $sid | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "     (warn) failed to delete SAL: $sid" -ForegroundColor DarkYellow
                Force-Delete-SAL -salId $sid
            }
        }
    }
}

function Remove-VNet-Peerings {
    param($rg)
    Write-Host ">> Removing VNet peerings in '$rg' (if any)…"
    try { $vnets = (& az network vnet list -g $rg --query "[].name" -o tsv) -split "`n" } catch { $vnets = @() }
    foreach ($v in $vnets) {
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        try { $peerings = (& az network vnet peering list -g $rg --vnet-name $v --query "[].name" -o tsv) -split "`n" } catch { $peerings = @() }
        foreach ($p in $peerings) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            Write-Host "   - Deleting peering ${rg}/${v}/${p}"
            try { & az network vnet peering delete -g $rg --vnet-name $v -n $p | Out-Null } catch { Write-Host "     (warn) peering delete failed: $p" -ForegroundColor DarkYellow }
        }
    }
}

function Remove-PrivateDns-VNetLinks {
    param($targetVNetId)
    Write-Host ">> Removing Private DNS zone links referencing VNet (best-effort)…"
    try { $zonesRaw = & az network private-dns zone list --query "[].{n:name,rg:resourceGroup}" -o tsv } catch { $zonesRaw = '' }
    if (-not $zonesRaw) { return }
    foreach ($line in ($zonesRaw -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "\t"; if ($parts.Count -lt 2) { continue }
        $zName = $parts[0]; $zRg = $parts[1]
        try { $linksRaw = & az network private-dns link vnet list -g $zRg -z $zName --query "[?virtualNetwork.id=='$targetVNetId'].{id:id,name:name}" -o tsv } catch { $linksRaw = '' }
        if (-not $linksRaw) { continue }
        foreach ($l in ($linksRaw -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $lp = $l -split "\t"; $lname = if ($lp.Count -ge 2) { $lp[1] } else { $null }
            if (-not $lname) { continue }
            Write-Host "   - Deleting Private DNS VNet link: $zRg/$zName/$lname"
            try { & az network private-dns link vnet delete -g $zRg -z $zName -n $lname --yes | Out-Null } catch { Write-Host "     (warn) could not delete DNS link $lname" -ForegroundColor DarkYellow }
        }
    }
}

function Broad-Disassociate-NSG {
    param($NSG_ID)
    Write-Host ">> Broad disassociation across subscription for NSG: $NSG_ID"

    # NICs anywhere
    try { $nicsRaw = & az network nic list --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].{rg:resourceGroup,name:name}" -o tsv } catch { $nicsRaw = '' }
    if ($nicsRaw) {
        foreach ($entry in ($nicsRaw -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $parts = $entry -split "\t"; $RG_NIC = $parts[0]; $NIC_NAME = $parts[1]
            Write-Host "   - Removing NSG from NIC ${RG_NIC}/${NIC_NAME}"
            try { & az network nic update -g $RG_NIC -n $NIC_NAME --remove networkSecurityGroup | Out-Null } catch { Write-Host "     (warn) NIC update failed ${RG_NIC}/${NIC_NAME}" -ForegroundColor DarkYellow }
        }
    }

    # Subnets anywhere
    try { $vnetList = & az network vnet list --query "[].{rg:resourceGroup,name:name}" -o tsv } catch { $vnetList = '' }
    if ($vnetList) {
        foreach ($v in ($vnetList -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            $parts = $v -split "\t"; $VNET_RG = $parts[0]; $VNET_NAME = $parts[1]
            try { $subsRaw = & az network vnet subnet list -g $VNET_RG --vnet-name $VNET_NAME --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].name" -o tsv } catch { $subsRaw = '' }
            if ($subsRaw) {
                foreach ($S in ($subsRaw -split "`n")) {
                    if ([string]::IsNullOrWhiteSpace($S)) { continue }
                    Write-Host "   - Disassociating NSG from subnet ${VNET_RG}/${VNET_NAME}/${S}"
                    try { & az network vnet subnet update -g $VNET_RG --v_
