#!/usr/bin/env pwsh
#requires -Version 7
<#
Script: rm-rg.ps1
Overview:
  Safely and forcefully deletes an Azure Resource Group by removing common blockers first.
  Handles: NSG disassociations (NICs/subnets), Private Endpoints on subnets, Service Association Links (Azure Container Apps),
  subnet delegations/service endpoints/route tables/NAT gateways, VNet peerings, Private DNS zone VNet links, RG locks,
  plus heavy blockers: Container Apps, Managed Environments, Application Gateways, Azure Firewalls, Bastion, VMs/NICs.
  Triggers `az group delete --no-wait` and optionally polls.

Exit codes:
  1 (input/validation), 2 (delete cmd failed), 3 (timeout), 4 (rollback to Succeeded after Deleting).
#>

param(
  [switch]$Force,
  [switch]$NoWait,
  [switch]$Confirm,
  [int]$TimeoutMinutes = 20,
  [int]$PollSeconds = 10
)

# Relaunch em pwsh se estiver em Windows PowerShell (não-Core)
if ($PSVersionTable.PSEdition -ne 'Core') {
  $url = 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-rg.ps1'
  $tmp = Join-Path $env:TEMP "rm-rg-$([guid]::NewGuid()).ps1"
  Invoke-WebRequest $url -OutFile $tmp
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp @PSBoundParameters
  exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Globals
$script:SUB = $null
$script:RG  = $null

# State file para lembrar SUB/RG
$StateFile = Join-Path $env:TEMP 'cleanup-nsgs-last.ps1'

# ---------- Helpers SAL (ACA) ----------
function Get-Subnet-SAL-Ids {
  param($rg, $vnet, $subnet)
  try {
    az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet --query "serviceAssociationLinks[].id" -o tsv
  } catch { '' }
}

function Ensure-ACA-Delegation {
  param($rg, $vnet, $subnet)
  try {
    $has = az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet --query "length(delegations[?serviceName=='Microsoft.App/environments'])" -o tsv
  } catch { $has = '0' }
  if ($has -eq '0') {
    Write-Host "   - Adding delegation Microsoft.App/environments on ${rg}/${vnet}/${subnet}"
    az network vnet subnet update -g $rg --vnet-name $vnet -n $subnet --delegations Microsoft.App/environments | Out-Null
  }
}

function Delete-SALs-CLI {
  param($salIds)
  $ok = $true
  foreach ($sid in ($salIds -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($sid)) { continue }
    Write-Host "   - Deleting Service Association Link (CLI): $sid"

    # Tenta com 2 API versions; 5 tentativas cada; última tentativa é --verbose
    $apis = @('2024-03-01','2023-09-01')
    $deleted = $false
    foreach ($api in $apis) {
      $tries = 0
      do {
        try {
          if ($tries -eq 4) {
            Write-Host "     · final attempt with --verbose (api $api)"
            az resource delete --ids $sid --api-version $api --verbose
          } else {
            az resource delete --ids $sid --api-version $api --only-show-errors | Out-Null
          }
          $rc = $LASTEXITCODE
        } catch { $rc = 1 }
        if ($rc -ne 0 -and $tries -lt 4) { Start-Sleep -Seconds 5 }
        $tries++
      } while ($rc -ne 0 -and $tries -lt 5)
      if ($rc -eq 0) { $deleted = $true; break }
    }

    if (-not $deleted) {
      Write-Host "     (error) SAL delete failed (CLI) for $sid" -ForegroundColor Red
      $ok = $false
    }
  }
  return $ok
}

# ---------- Prompt ----------
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

# ---------- Net helpers ----------
function Unset-Subnet-Props {
  param($rg, $vnet, $subnet)
  Write-Host "   - Clearing associations on subnet ${rg}/${vnet}/${subnet}"
  foreach ($prop in 'networkSecurityGroup','routeTable','natGateway','delegations','serviceEndpoints') {
    try {
      az network vnet subnet update -g $rg --vnet-name $vnet -n $subnet --remove $prop | Out-Null
    } catch {
      Write-Host "     · (warn) could not remove $prop" -ForegroundColor DarkYellow
    }
  }
}

function Delete-PrivateEndpoints-For-Subnet {
  param($subnetId)
  Write-Host "   - Looking for Private Endpoints on this subnet…"
  try { $PEs = az network private-endpoint list --query "[?subnet.id=='$subnetId'].{id:id}" -o tsv } catch { $PEs = '' }
  if ($PEs) {
    foreach ($pe in ($PEs -split "`n")) {
      if ([string]::IsNullOrWhiteSpace($pe)) { continue }
      Write-Host "     · Deleting Private Endpoint: $pe"
      try { az resource delete --ids $pe | Out-Null } catch { Write-Host "       (warn) failed: $pe" -ForegroundColor DarkYellow }
    }
  }
}

function Delete-ServiceAssociationLinks {
  param($rg, $vnet, $subnet)
  $salIds = Get-Subnet-SAL-Ids -rg $rg -vnet $vnet -subnet $subnet
  if (-not $salIds) { return $true }  # nothing to do

  # SAL precisa da delegação ACA presente para ser removido
  Ensure-ACA-Delegation -rg $rg -vnet $vnet -subnet $subnet

  $ok = Delete-SALs-CLI -salIds $salIds
  if (-not $ok) {
    Write-Host "     (warn) Some SALs remain on ${rg}/${vnet}/${subnet}. Skipping subnet cleanup for now." -ForegroundColor DarkYellow
    return $false
  }

  # Confirma que acabou
  $left = Get-Subnet-SAL-Ids -rg $rg -vnet $vnet -subnet $subnet
  return (-not $left)
}

function Remove-VNet-Peerings {
  param($rg)
  Write-Host ">> Removing VNet peerings in '$rg' (if any)…"
  try { $vnets = (az network vnet list -g $rg --query "[].name" -o tsv) -split "`n" } catch { $vnets = @() }
  foreach ($v in $vnets) {
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    try { $peerings = (az network vnet peering list -g $rg --vnet-name $v --query "[].name" -o tsv) -split "`n" } catch { $peerings = @() }
    foreach ($p in $peerings) {
      if ([string]::IsNullOrWhiteSpace($p)) { continue }
      Write-Host "   - Deleting peering ${rg}/${v}/${p}"
      try { az network vnet peering delete -g $rg --vnet-name $v -n $p | Out-Null } catch { Write-Host "     (warn) peering delete failed: $p" -ForegroundColor DarkYellow }
    }
  }
}

function Remove-PrivateDns-VNetLinks {
  param($targetVNetId)
  Write-Host ">> Removing Private DNS zone links referencing VNet (best-effort)…"
  try { $zonesRaw = az network private-dns zone list --query "[].{n:name,rg:resourceGroup}" -o tsv } catch { $zonesRaw = '' }
  if (-not $zonesRaw) { return }

  foreach ($line in ($zonesRaw -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split "\t"
    if ($parts.Count -lt 2) { continue }
    $zName = $parts[0]; $zRg = $parts[1]

    try {
      $linksRaw = az network private-dns link vnet list -g $zRg -z $zName --query "[?virtualNetwork.id=='$targetVNetId'].{id:id,name:name}" -o tsv
    } catch { $linksRaw = '' }

    if (-not $linksRaw) { continue }
    foreach ($l in ($linksRaw -split "`n")) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      $lp = $l -split "\t"
      $lname = if ($lp.Count -ge 2) { $lp[1] } else { $null }
      if (-not $lname) { continue }

      Write-Host "   - Deleting Private DNS VNet link: $zRg/$zName/$lname"
      try { az network private-dns link vnet delete -g $zRg -z $zName -n $lname --yes | Out-Null } catch {
        Write-Host "     (warn) could not delete DNS link $lname" -ForegroundColor DarkYellow
      }
    }
  }
}

function Broad-Disassociate-NSG {
  param($NSG_ID)
  Write-Host ">> Broad disassociation across subscription for NSG: $NSG_ID"

  # NICs
  try {
    $nicsRaw = az network nic list --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].{rg:resourceGroup,name:name}" -o tsv
  } catch { $nicsRaw = '' }
  if ($nicsRaw) {
    foreach ($entry in ($nicsRaw -split "`n")) {
      if ([string]::IsNullOrWhiteSpace($entry)) { continue }
      $parts = $entry -split "`t"; $RG_NIC = $parts[0]; $NIC_NAME = $parts[1]
      Write-Host "   - Removing NSG from NIC ${RG_NIC}/${NIC_NAME}"
      try { az network nic update -g $RG_NIC -n $NIC_NAME --remove networkSecurityGroup | Out-Null } catch {
        Write-Host "     (warn) NIC update failed ${RG_NIC}/${NIC_NAME}" -ForegroundColor DarkYellow
      }
    }
  }

  # Subnets
  try { $vnetList = az network vnet list --query "[].{rg:resourceGroup,name:name}" -o tsv } catch { $vnetList = '' }
  if ($vnetList) {
    foreach ($v in ($vnetList -split "`n")) {
      if ([string]::IsNullOrWhiteSpace($v)) { continue }
      $parts = $v -split "`t"; $VNET_RG = $parts[0]; $VNET_NAME = $parts[1]

      try { $subsRaw = az network vnet subnet list -g $VNET_RG --vnet-name $VNET_NAME --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].name" -o tsv } catch { $subsRaw = '' }
      if ($subsRaw) {
        foreach ($S in ($subsRaw -split "`n")) {
          if ([string]::IsNullOrWhiteSpace($S)) { continue }
          Write-Host "   - Disassociating NSG from subnet ${VNET_RG}/${VNET_NAME}/${S}"
          try { az network vnet subnet update -g $VNET_RG --vnet-name $VNET_NAME -n $S --remove networkSecurityGroup | Out-Null } catch {
            Write-Host "     (warn) subnet update failed: ${VNET_RG}/${VNET_NAME}/${S}" -ForegroundColor DarkYellow
          }
        }
      }
    }
  }
}

# ---------- Heavy resource cleanup ----------
function Delete-ContainerApps-In-RG {
  param($rg)
  Write-Host ">> Deleting Container Apps in '$rg'…"
  try { $ids = az resource list -g $rg --resource-type Microsoft.App/containerApps --query "[].id" -o tsv } catch { $ids = '' }
  foreach ($id in ($ids -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting CA: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
}
function Delete-ManagedEnvironments-In-RG {
  param($rg)
  Write-Host ">> Deleting Container Apps managed environments in '$rg'…"
  try { $ids = az resource list -g $rg --resource-type Microsoft.App/managedEnvironments --query "[].id" -o tsv } catch { $ids = '' }
  foreach ($id in ($ids -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting ME: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
}
function Delete-ApplicationGateways-In-RG {
  param($rg)
  Write-Host ">> Deleting Application Gateways in '$rg'…"
  try { $ids = az network application-gateway list -g $rg --query "[].id" -o tsv } catch { $ids = '' }
  foreach ($id in ($ids -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting AGW: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
}
function Delete-AzureFirewalls-In-RG {
  param($rg)
  Write-Host ">> Deleting Azure Firewalls in '$rg'…"
  try { $ids = az network firewall list -g $rg --query "[].id" -o tsv } catch { $ids = '' }
  foreach ($id in ($ids -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting AFW: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
}
function Delete-Bastions-In-RG {
  param($rg)
  Write-Host ">> Deleting Bastion hosts in '$rg'…"
  try { $ids = az network bastion list -g $rg --query "[].id" -o tsv } catch { $ids = '' }
  foreach ($id in ($ids -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting Bastion: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
}
function Delete-VMs-And-NICs-In-RG {
  param($rg)
  Write-Host ">> Deleting VMs and leftover NICs in '$rg'…"
  try { $vmIds = az vm list -g $rg --query "[].id" -o tsv } catch { $vmIds = '' }
  foreach ($id in ($vmIds -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting VM: $id"
      try { az vm delete --ids $id --yes | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
  Start-Sleep -Seconds 10
  try { $nicIds = az network nic list -g $rg --query "[?virtualMachine==null].id" -o tsv } catch { $nicIds = '' }
  foreach ($id in ($nicIds -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting NIC: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
}

# ---------- Main VNet breaker ----------
function Break-VNet-Blockers-In-RG {
  param($rg)
  Write-Host ">> Breaking VNet/Subnet blockers in '$rg'…"

  # 0) Proativo – remove recursos que ancoram subnets
  Delete-ContainerApps-In-RG       -rg $rg
  Delete-ManagedEnvironments-In-RG -rg $rg
  Delete-ApplicationGateways-In-RG -rg $rg
  Delete-AzureFirewalls-In-RG      -rg $rg
  Delete-Bastions-In-RG            -rg $rg
  Delete-VMs-And-NICs-In-RG        -rg $rg

  # 1) Itera VNets/subnets, apaga SAL antes de limpar delegations, depois tenta deletar
  try { $vnetNamesRaw = az network vnet list -g $rg --query "[].name" -o tsv } catch { $vnetNamesRaw = '' }
  if ($vnetNamesRaw) {
    $vnetNames = $vnetNamesRaw -split "`n"
    foreach ($VNET in $vnetNames) {
      if ([string]::IsNullOrWhiteSpace($VNET)) { continue }

      try { $subsRaw = az network vnet subnet list -g $rg --vnet-name $VNET --query "[].name" -o tsv } catch { $subsRaw = '' }
      if ($subsRaw) {
        foreach ($S in ($subsRaw -split "`n")) {
          if ([string]::IsNullOrWhiteSpace($S)) { continue }

          $accountId = (az account show --query id -o tsv).Trim()
          $SUBNET_ID = "/subscriptions/$accountId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$VNET/subnets/$S"

          # a) PEs
          Delete-PrivateEndpoints-For-Subnet -subnetId $SUBNET_ID
          # b) SALs (precisa sair antes de remover delegations)
          $salCleared = Delete-ServiceAssociationLinks -rg $rg -vnet $VNET -subnet $S
          if (-not $salCleared) {
            Write-Host "     (info) Deferring ${rg}/${VNET}/${S} until SALs are gone." -ForegroundColor DarkYellow
            continue
          }
          # c) Agora pode limpar props (inclui delegations)
          Unset-Subnet-Props -rg $rg -vnet $VNET -subnet $S
          # d) Deleta a subnet
          az network vnet subnet delete -g $rg --vnet-name $VNET -n $S | Out-Null
          if ($LASTEXITCODE -eq 0) {
            Write-Host "   - Deleted subnet ${rg}/${VNET}/$S"
          } else {
            Write-Host "     (info) subnet delete deferred: ${rg}/${VNET}/$S" -ForegroundColor DarkYellow
          }
        }
      }

      # e) Peerings e DNS links, depois tenta deletar a VNet
      Remove-VNet-Peerings -rg $rg
      $acct = (az account show --query id -o tsv).Trim()
      $vnetId = "/subscriptions/$acct/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$VNET"
      Remove-PrivateDns-VNetLinks -targetVNetId $vnetId

      az network vnet delete -g $rg -n $VNET | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host ">> Deleted VNet ${rg}/${VNET}"
      } else {
        Write-Host "   (info) VNet delete deferred: ${rg}/${VNET}" -ForegroundColor DarkYellow
      }
    }
  }
}

# ---------- Main ----------
function Main {
  Prompt-Context

  Write-Host ">> Using subscription: $script:SUB"
  az account set --subscription $script:SUB | Out-Null

  Write-Host ">> Verifying resource group '$script:RG' exists…"
  try { az group show -n $script:RG | Out-Null } catch {
    Write-Host "Resource group '$script:RG' not found or you do not have access." -ForegroundColor Red
    exit 1
  }

  Write-Host ">> Removing locks in RG (if any)…"
  try { $locks = az lock list --resource-group $script:RG --query "[].id" -o tsv } catch { $locks = '' }
  if ($locks) {
    foreach ($L in ($locks -split "`n")) {
      if ($L) { try { az lock delete --ids $L | Out-Null } catch { Write-Host "(warn) could not delete RG lock $L" -ForegroundColor DarkYellow } }
    }
  }

  Write-Host ">> Enumerating NSGs in '$script:RG'…"
  try { $nsgsRaw = az network nsg list -g $script:RG --query "[].id" -o tsv } catch { $nsgsRaw = '' }
  $NSG_IDS = if ($nsgsRaw) { $nsgsRaw -split "`n" } else { @() }
  foreach ($NSG_ID in $NSG_IDS) {
    if ([string]::IsNullOrWhiteSpace($NSG_ID)) { continue }
    $NSG_NAME = $NSG_ID.Split('/')[-1]
    Write-Host ">> Processing NSG: $NSG_NAME"

    try { $rgNicsRaw = az network nic list -g $script:RG --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].name" -o tsv } catch { $rgNicsRaw = '' }
    if ($rgNicsRaw) {
      foreach ($nic in ($rgNicsRaw -split "`n")) {
        if ($nic) {
          Write-Host "   - Removing NSG from NIC $script:RG/$nic"
          try { az network nic update -g $script:RG -n $nic --remove networkSecurityGroup | Out-Null } catch { Write-Host "     (warn) failed NIC update $nic" -ForegroundColor DarkYellow }
        }
      }
    }

    try { $vnetsRaw = az network vnet list -g $script:RG --query "[].name" -o tsv } catch { $vnetsRaw = '' }
    if ($vnetsRaw) {
      foreach ($VNET in ($vnetsRaw -split "`n")) {
        if (-not $VNET) { continue }
        try { $subsRaw = az network vnet subnet list -g $script:RG --vnet-name $VNET --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].name" -o tsv } catch { $subsRaw = '' }
        if ($subsRaw) {
          foreach ($S in ($subsRaw -split "`n")) {
            if ($S) {
              Write-Host "   - Disassociating NSG from subnet ${script:RG}/${VNET}/$S"
              try { az network vnet subnet update -g $script:RG --vnet-name $VNET -n $S --remove networkSecurityGroup | Out-Null } catch { Write-Host "     (warn) subnet update failed $S" -ForegroundColor DarkYellow }
            }
          }
        }
      }
    }

    try {
      az network nsg delete --ids $NSG_ID | Out-Null
    } catch {
      Write-Host "!! NSG delete failed; performing broad disassociation & retrying…"
      Broad-Disassociate-NSG -NSG_ID $NSG_ID
      try { az network nsg delete --ids $NSG_ID | Out-Null } catch { Write-Host "!! Final NSG delete failed: $NSG_ID" -ForegroundColor Red }
    }
  }

  Break-VNet-Blockers-In-RG -rg $script:RG

  Write-Host ">> Final lock cleanup at RG level…"
  try { $locks2 = az lock list --resource-group $script:RG --query "[].id" -o tsv } catch { $locks2 = '' }
  if ($locks2) {
    foreach ($L2 in ($locks2 -split "`n")) {
      if ($L2) { try { az lock delete --ids $L2 | Out-Null } catch { Write-Host "(warn) could not delete RG lock $L2" -ForegroundColor DarkYellow } }
    }
  }

  if ($Confirm -and -not $Force) {
    Write-Host
    $sure = Read-Host "About to DELETE resource group '$script:RG'. Are you sure? [y/N]"
    if (-not ($sure.ToLower() -in @('y','yes'))) {
      Write-Host 'Aborted before deleting the resource group.'
      return
    }
  }

  Write-Host ">> Deleting resource group '$script:RG'…"
  $deleteArgs = @('group','delete','-n',$script:RG,'--yes','--no-wait')
  try { az @deleteArgs | Out-Null } catch { Write-Host "(error) RG delete command failed: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }

  if ($NoWait) { Write-Host "Delete initiated (no-wait)." -ForegroundColor Green; return }

  Write-Host ">> Polling for deletion (timeout ${TimeoutMinutes}m, interval ${PollSeconds}s)…"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $sawDeleting = $false
  while ($true) {
    Start-Sleep -Seconds $PollSeconds
    try { $state = az group show -n $script:RG --query properties.provisioningState -o tsv 2>$null } catch { $state = 'Deleted' }
    if (-not $state) { $state = 'Deleted' }
    Write-Host "   - State: $state (elapsed $([int]$sw.Elapsed.TotalSeconds)s)"
    if ($state -eq 'Deleted') { break }
    if ($state -eq 'Deleting') { $sawDeleting = $true }
    if ($state -eq 'Succeeded' -and $sawDeleting) {
      Write-Host "Deletion appears to have rolled back to 'Succeeded'. The resource group still exists; deletion likely failed due to blockers (see errors above)." -ForegroundColor Yellow
      exit 4
    }
    if ($sw.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
      Write-Host "Timeout waiting for deletion. Investigate remaining resources:" -ForegroundColor Yellow
      try { az resource list -g $script:RG -o table } catch { }
      exit 3
    }
  }
  Write-Host "✅ Resource group deleted (or no longer returned)." -ForegroundColor Green
}

Main
