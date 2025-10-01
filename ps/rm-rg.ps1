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
  [int]$PollSeconds = 10,
  [string]$TenantId,
  # Optional service principal (workaround for Conditional Access blocking public client ID 04b07795-8ddb-461a-bbee-02f9e1bf7b46)
  [string]$SpClientId,
  [string]$SpClientSecret,
  [string]$SpTenantId,
  # Alternative secret sourcing
  [string]$SpClientSecretFile,
  [switch]$PromptSpSecret,
  # Keep switch for parity (no-op now that Az fallback is gone)
  [switch]$ForceSAL
)

# Relaunch in pwsh if running under Windows PowerShell (non-Core)
if ($PSVersionTable.PSEdition -ne 'Core') {
  $url = 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-rg.ps1'
  $tmp = Join-Path $env:TEMP "rm-rg-$([guid]::NewGuid()).ps1"
  Invoke-WebRequest $url -OutFile $tmp
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp @PSBoundParameters
  exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reduce Python user warnings from some CLI extensions (best-effort)
$env:PYTHONWARNINGS = 'ignore::UserWarning'

# Globals
$script:SUB = $null
$script:RG  = $null
$script:TENANT = $null

# State file (remember last subscription/RG)
$StateFile = Join-Path $env:TEMP 'cleanup-nsgs-last.ps1'

# -------------------- SAL (ACA) helpers --------------------
function Get-Subnet-SAL-Ids {
  param($rg, $vnet, $subnet)
  try {
    az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet --query "serviceAssociationLinks[].id" --output tsv
  } catch { '' }
}

# Retrieve detailed info for a SAL (serviceAssociationLink) returning a hashtable
function Get-SAL-Detail {
  param([string]$salId)
  if (-not $salId) { return $null }
  $apis = @('2024-03-01','2023-09-01')
  foreach ($api in $apis) {
    try {
      $json = az rest --method get --url "https://management.azure.com$salId?api-version=$api" --output json 2>$null
      if ($LASTEXITCODE -eq 0 -and $json) {
        return ($json | ConvertFrom-Json)
      }
    } catch { }
  }
  return $null
}

# Ensure required CLI extensions are present (best-effort, idempotent)
function Ensure-Cli-Extensions {
  param([string[]]$names)
  foreach ($n in $names) {
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    try {
      $present = az extension list --query "[?name=='$n'] | length(@)" --output tsv 2>$null
    } catch { $present = '0' }
    if ($present -ne '0') { continue }
    Write-Host "   - Installing CLI extension: $n" -ForegroundColor DarkCyan
    try { az extension add --name $n --only-show-errors | Out-Null } catch { Write-Host "     (warn) could not add extension $n" -ForegroundColor DarkYellow }
  }
}

# DevCenter targeted cleanup for subnet references (order: environments -> projects -> network connections -> devcenters)
function Remove-DevCenter-Resources-For-Subnet {
  param([string]$subnetId)
  if (-not $subnetId) { return }
  Ensure-Cli-Extensions -names @('devcenter')

  Write-Host "   - [DevCenter] Locating resources referencing subnet..."

  function _DelIds { param([string[]]$ids,[string]$label)
    foreach ($id in ($ids | Where-Object { $_ })) {
      Write-Host "     · Deleting ${label}: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "       (warn) failed ${label}: $id" -ForegroundColor DarkYellow }
    }
  }

  try { $envs = az resource list --query "[?type=='Microsoft.DevCenter/devcenters/projects/environments' && contains(to_string(properties),'$subnetId')].id" --output tsv } catch { $envs = '' }
  _DelIds -ids ($envs -split "`n") -label 'Dev Environment'

  try { $projects = az resource list --query "[?type=='Microsoft.DevCenter/devcenters/projects' && contains(to_string(properties),'$subnetId')].id" --output tsv } catch { $projects = '' }
  _DelIds -ids ($projects -split "`n") -label 'DevCenter Project'

  try { $netConns = az resource list --query "[?type=='Microsoft.DevCenter/networkConnections' && contains(to_string(properties),'$subnetId')].id" --output tsv } catch { $netConns = '' }
  _DelIds -ids ($netConns -split "`n") -label 'Network Connection'

  try { $devcenters = az resource list --query "[?type=='Microsoft.DevCenter/devcenters' && contains(to_string(properties),'Microsoft.DevCenter/networkConnections') && contains(to_string(properties),'$subnetId')].id" --output tsv } catch { $devcenters = '' }
  _DelIds -ids ($devcenters -split "`n") -label 'DevCenter'
}

function Ensure-ACA-Delegation {
  param($rg, $vnet, $subnet)
  try {
    $has = az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet --query "length(delegations[?serviceName=='Microsoft.App/environments'])" --output tsv
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
    Write-Host "   - Deleting Service Association Link: $sid"

    $apis = @('2024-03-01','2023-09-01')
    $deleted = $false
    foreach ($api in $apis) {
      $tries = 0
      do {
        try {
          az resource delete --ids $sid --api-version $api --only-show-errors | Out-Null
          $rc = $LASTEXITCODE
        } catch { $rc = 1 }
        if ($rc -ne 0 -and $tries -lt 3) { Start-Sleep -Seconds 3 }
        $tries++
      } while ($rc -ne 0 -and $tries -lt 4)
      if ($rc -eq 0) { $deleted = $true; break }
    }

    if (-not $deleted) { $ok = $false }
  }
  return $ok
}

function Wait-SAL-Gone {
  param(
    [string]$rg, [string]$vnet, [string]$subnet,
    [int]$maxSeconds = 180, [int]$pollSeconds = 6
  )
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $maxSeconds) {
    try {
      $left = az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet --query "length(serviceAssociationLinks)" --output tsv 2>$null
      if (-not $left -or [int]$left -eq 0) { return $true }
    } catch { return $true }
    Start-Sleep -Seconds $pollSeconds
  }
  return $false
}

function Delete-ACAEnvs-Referencing-Subnet {
  param($subnetId)
  try {
    $ids = az resource list --resource-type Microsoft.App/managedEnvironments --query "[?properties.vnetConfiguration.infrastructureSubnetId=='$subnetId'].id" --output tsv
  } catch { $ids = '' }
  foreach ($id in ($ids -split "`n")) {
    if ($id) {
      Write-Host "   - Deleting ACA Managed Environment (cross-RG): $id"
      try { az resource delete --ids $id | Out-Null } catch {
        Write-Host "     (warn) failed to delete ME: $id" -ForegroundColor DarkYellow
      }
    }
  }
}

function Delete-Subnet-Consumers-Broad {
  param([string]$subnetId)

  Write-Host "   - Scanning for resources that reference this subnet (DevCenter/DevOpsInfra/ConnectedEnv/ASE/Batch)…"

  $queries = @(
    "[?type=='Microsoft.App/connectedEnvironments' && contains(to_string(properties),'$subnetId')].id",
    "[?starts_with(type,'Microsoft.DevCenter/') && contains(to_string(properties),'$subnetId')].id",
    "[?starts_with(type,'Microsoft.DevOpsInfrastructure/') && contains(to_string(properties),'$subnetId')].id",
    "[?type=='Microsoft.Web/hostingEnvironments' && contains(to_string(properties),'$subnetId')].id",
    "[?type=='Microsoft.Batch/batchAccounts/pools' && contains(to_string(properties),'$subnetId')].id"
  )

  $refIds = @()
  foreach ($q in $queries) {
    try {
      $ids = az resource list --query $q --output tsv
      if ($ids) { $refIds += ($ids -split "`n") }
    } catch { }
  }

  $refIds = $refIds | Where-Object { $_ } | Sort-Object -Unique
  foreach ($rid in $refIds) {
    Write-Host "     · Deleting referencing resource: $rid"
    try { az resource delete --ids $rid | Out-Null } catch {
      Write-Host "       (warn) couldn't delete: $rid" -ForegroundColor DarkYellow
    }
  }

  $deadline = [DateTime]::UtcNow.AddMinutes(5)
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $still = az resource list --query "[?contains(to_string(properties),'$subnetId') && (starts_with(type,'Microsoft.DevCenter/') || starts_with(type,'Microsoft.DevOpsInfrastructure/') || type=='Microsoft.App/connectedEnvironments' || type=='Microsoft.Web/hostingEnvironments' || type=='Microsoft.Batch/batchAccounts/pools')].id" --output tsv
    } catch { $still = '' }
    if (-not $still) { break }
    Start-Sleep -Seconds 10
  }
}

function Delete-ServiceAssociationLinks {
  param($rg, $vnet, $subnet)

  $salIds = Get-Subnet-SAL-Ids -rg $rg -vnet $vnet -subnet $subnet
  if (-not $salIds) { return $true }

  # Detect DevCenter owners to clean up first
  $acctId = (az account show --query id --output tsv 2>$null).Trim()
  $subnetIdFull = "/subscriptions/$acctId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$vnet/subnets/$subnet"

  $needsDevCenterCleanup = $false
  foreach ($sid in ($salIds -split "`n")) {
    if (-not $sid) { continue }
    $detail = Get-SAL-Detail -salId $sid
    if ($detail -and $detail.properties.serviceName -match 'Microsoft\.DevCenter/networkConnections') {
      $needsDevCenterCleanup = $true; break
    }
  }
  if ($needsDevCenterCleanup) {
    Write-Host "   - SAL indicates DevCenter network connection; performing DevCenter dependency cleanup first..." -ForegroundColor Cyan
    Remove-DevCenter-Resources-For-Subnet -subnetId $subnetIdFull
    $salIds = Get-Subnet-SAL-Ids -rg $rg -vnet $vnet -subnet $subnet
    if (-not $salIds) { return $true }
  }

  # SAL delete needs ACA delegation present during the operation
  Ensure-ACA-Delegation -rg $rg -vnet $vnet -subnet $subnet

  # CLI path
  $ok = Delete-SALs-CLI -salIds $salIds
  if ($ok) {
    if (Wait-SAL-Gone -rg $rg -vnet $vnet -subnet $subnet -maxSeconds 180) { return $true }
  }

  # Optional last resort via raw REST delete (still CLI-based)
  if ($ForceSAL) {
    Write-Host "     (info) ForceSAL enabled: attempting raw DELETE via az rest..." -ForegroundColor Cyan
    foreach ($sid in ($salIds -split "`n")) {
      if (-not $sid) { continue }
      foreach ($api in @('2024-03-01','2023-09-01')) {
        Write-Host "       · REST DELETE $api $sid" -ForegroundColor DarkCyan
        try { az rest --method delete --url "https://management.azure.com$sid?api-version=$api" --only-show-errors | Out-Null } catch { }
        Start-Sleep 1
      }
    }
    if (Wait-SAL-Gone -rg $rg -vnet $vnet -subnet $subnet -maxSeconds 60) { return $true }
  }

  return $false
}

# -------------------- Prompt --------------------
function Prompt-Context {
  if (Test-Path -Path $StateFile) {
    . $StateFile
    $script:SUB    = $SUB
    $script:RG     = $RG
    $script:TENANT = $TENANT

    Write-Host "`nLast used:" -ForegroundColor Cyan
    Write-Host "  Subscription: $script:SUB"
    Write-Host "  ResourceGroup: $script:RG"
    Write-Host "  Tenant: $script:TENANT"
  }

  # --- Subscription ---
  $reuseSub = if ($script:SUB) { Read-Host "Reuse last subscription ($script:SUB)? [Y/n]" } else { 'n' }
  if ([string]::IsNullOrWhiteSpace($reuseSub)) { $reuseSub = 'Y' }
  if ($reuseSub -match '^(n|no)$' -or -not $script:SUB) {
    $subs = az account list --query "[].{id:id,name:name}" --output tsv 2>$null
    if (-not $subs) { Write-Host "   (error) No subscriptions found." -ForegroundColor Red; exit 1 }
    $subsArr = @()
    foreach ($s in ($subs -split "`n")) {
      $parts = $s -split "`t"
      if ($parts.Count -ge 2) { $subsArr += [PSCustomObject]@{ Id=$parts[0]; Name=$parts[1] } }
    }
    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    for ($i=0; $i -lt $subsArr.Count; $i++) { Write-Host " [$i] $($subsArr[$i].Name) ($($subsArr[$i].Id))" }
    $subChoice = Read-Host "Select subscription index"
    if (-not $subChoice -or $subChoice -ge $subsArr.Count) { Write-Host "Invalid subscription choice." -ForegroundColor Red; exit 1 }
    $script:SUB = $subsArr[$subChoice].Id
  }
  az account set --subscription $script:SUB | Out-Null

  # --- Resource group ---
  $reuseRG = if ($script:RG) { Read-Host "Reuse last resource group ($script:RG)? [Y/n]" } else { 'n' }
  if ([string]::IsNullOrWhiteSpace($reuseRG)) { $reuseRG = 'Y' }
  if ($reuseRG -match '^(n|no)$' -or -not $script:RG) {
    $rgs = az group list --query "[].{name:name,location:location}" --output tsv 2>$null
    if (-not $rgs) { Write-Host "   (error) No resource groups found." -ForegroundColor Red; exit 1 }
    $rgArr = @()
    foreach ($r in ($rgs -split "`n")) {
      $parts = $r -split "`t"
      if ($parts.Count -ge 2) { $rgArr += [PSCustomObject]@{ Name=$parts[0]; Location=$parts[1] } }
    }
    Write-Host "`nAvailable resource groups:" -ForegroundColor Cyan
    for ($i=0; $i -lt $rgArr.Count; $i++) { Write-Host " [$i] $($rgArr[$i].Name) (location=$($rgArr[$i].Location))" }
    $rgChoice = Read-Host "Select resource group index"
    if (-not $rgChoice -or $rgChoice -ge $rgArr.Count) { Write-Host "Invalid RG choice." -ForegroundColor Red; exit 1 }
    $script:RG = $rgArr[$rgChoice].Name
  }

  # --- Tenant ---
  $reuseTenant = if ($script:TENANT) { Read-Host "Reuse last tenant ($script:TENANT)? [Y/n]" } else { 'n' }
  if ([string]::IsNullOrWhiteSpace($reuseTenant)) { $reuseTenant = 'Y' }
  if ($reuseTenant -match '^(n|no)$' -or -not $script:TENANT) {
    try { $script:TENANT = (az account show --query tenantId --output tsv 2>$null).Trim() } catch { $script:TENANT = '' }
  }

  # --- Save state ---
  $safeSub    = $script:SUB -replace "'","''"
  $safeRg     = $script:RG  -replace "'","''"
  $safeTenant = $script:TENANT -replace "'","''"
  Set-Content -Path $StateFile -Value @(
    "`$SUB = '$safeSub'",
    "`$RG  = '$safeRg'",
    "`$TENANT = '$safeTenant'"
  ) -Encoding UTF8

  Write-Host "`nSelected Subscription: $script:SUB" -ForegroundColor Green
  Write-Host "Selected Resource Group: $script:RG" -ForegroundColor Green
  Write-Host "Tenant: $script:TENANT" -ForegroundColor Green
}

# -------------------- Network helpers --------------------
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
  try { $PEs = az network private-endpoint list --query "[?subnet.id=='$subnetId'].{id:id}" --output tsv } catch { $PEs = '' }
  if ($PEs) {
    foreach ($pe in ($PEs -split "`n")) {
      if ([string]::IsNullOrWhiteSpace($pe)) { continue }
      Write-Host "     · Deleting Private Endpoint: $pe"
      try { az resource delete --ids $pe | Out-Null } catch { Write-Host "       (warn) failed: $pe" -ForegroundColor DarkYellow }
    }
  }
}

function Remove-VNet-Peerings {
  param($rg)
  Write-Host ">> Removing VNet peerings in '$rg' (if any)…"
  try { $vnets = (az network vnet list -g $rg --query "[].name" --output tsv) -split "`n" } catch { $vnets = @() }
  foreach ($v in $vnets) {
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    try { $peerings = (az network vnet peering list -g $rg --vnet-name $v --query "[].name" --output tsv) -split "`n" } catch { $peerings = @() }
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
  try { $zonesRaw = az network private-dns zone list --query "[].{n:name,rg:resourceGroup}" --output tsv } catch { $zonesRaw = '' }
  if (-not $zonesRaw) { return }

  foreach ($line in ($zonesRaw -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split "\t"
    if ($parts.Count -lt 2) { continue }
    $zName = $parts[0]
    $zRg   = $parts[1]

    try {
      $linksRaw = az network private-dns link vnet list -g $zRg -z $zName --query "[?virtualNetwork.id=='$targetVNetId'].{id:id,name:name}" --output tsv
    } catch { $linksRaw = '' }

    if (-not $linksRaw) { continue }
    foreach ($l in ($linksRaw -split "`n")) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      $lp = $l -split "\t"
      $lname = if ($lp.Count -ge 2) { $lp[1] } else { $null }
      if (-not $lname) { continue }

      Write-Host "   - Deleting Private DNS VNet link: $zRg/$zName/$lname"
      try {
        az network private-dns link vnet delete -g $zRg -z $zName -n $lname --yes | Out-Null
      } catch {
        Write-Host "     (warn) could not delete DNS link $lname" -ForegroundColor DarkYellow
      }
    }
  }
}

function Broad-Disassociate-NSG {
  param($NSG_ID)
  Write-Host ">> Broad disassociation across subscription for NSG: $NSG_ID"

  try {
    $nicsRaw = az network nic list --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].{rg:resourceGroup,name:name}" --output tsv
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

  try { $vnetList = az network vnet list --query "[].{rg:resourceGroup,name:name}" --output tsv } catch { $vnetList = '' }
  if ($vnetList) {
    foreach ($v in ($vnetList -split "`n")) {
      if ([string]::IsNullOrWhiteSpace($v)) { continue }
      $parts = $v -split "`t"; $VNET_RG = $parts[0]; $VNET_NAME = $parts[1]

      try { $subsRaw = az network vnet subnet list -g $VNET_RG --vnet-name $VNET_NAME --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].name" --output tsv } catch { $subsRaw = '' }
      if ($subsRaw) {
        foreach ($S in ($subsRaw -split "`n")) {
          if ([string]::IsNullOrWhiteSpace($S)) { continue }
          Write-Host "   - Disassociating NSG from subnet ${VNET_RG}/${VNET_NAME}/${S}"
          try {
            az network vnet subnet update -g $VNET_RG --vnet-name $VNET_NAME -n $S --remove networkSecurityGroup | Out-Null
          } catch {
            Write-Host "     (warn) subnet update failed: ${VNET_RG}/${VNET_NAME}/${S}" -ForegroundColor DarkYellow
          }
        }
      }
    }
  }
}

# -------------------- Heavy resource cleanup --------------------
function Delete-ContainerApps-In-RG {
  param($rg)
  Write-Host ">> Deleting Container Apps in '$rg'…"
  try { $ids = az resource list -g $rg --resource-type Microsoft.App/containerApps --query "[].id" --output tsv } catch { $ids = '' }
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
  try { $ids = az resource list -g $rg --resource-type Microsoft.App/managedEnvironments --query "[].id" --output tsv } catch { $ids = '' }
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
  try { $ids = az network application-gateway list -g $rg --query "[].id" --output tsv } catch { $ids = '' }
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
  try { $ids = az network firewall list -g $rg --query "[].id" --output tsv } catch { $ids = '' }
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
  try { $ids = az network bastion list -g $rg --query "[].id" --output tsv } catch { $ids = '' }
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
  try { $vmIds = az vm list -g $rg --query "[].id" --output tsv } catch { $vmIds = '' }
  foreach ($id in ($vmIds -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting VM: $id"
      try { az vm delete --ids $id --yes | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
  Start-Sleep -Seconds 10
  try { $nicIds = az network nic list -g $rg --query "[?virtualMachine==null && privateEndpoint==null].id" --output tsv } catch { $nicIds = '' }
  foreach ($id in ($nicIds -split "`n")) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
      Write-Host "   - Deleting NIC: $id"
      try { az resource delete --ids $id | Out-Null } catch { Write-Host "     (warn) failed: $id" -ForegroundColor DarkYellow }
    }
  }
}

function Detach-VNet-DdosPlan {
  param($rg, $vnet)
  try {
    az network vnet show -g $rg -n $vnet --query "ddosProtectionPlan.id" --output tsv | Out-Null
    if ($LASTEXITCODE -eq 0) {
      az network vnet update -g $rg -n $vnet --remove ddosProtectionPlan | Out-Null
      Write-Host "   - Detached DDoS plan from ${rg}/${vnet}"
    }
  } catch { }
}

function Try-Delete-VNet {
  param($rg, $vnet, [int]$attempts = 6)
  for ($i = 0; $i -lt $attempts; $i++) {
    az network vnet delete -g $rg -n $vnet | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host ">> Deleted VNet ${rg}/${vnet}"; return $true }
    if ($i -eq 0) { Detach-VNet-DdosPlan -rg $rg -vnet $vnet }
    Start-Sleep -Seconds ([int][math]::Pow(2, $i) * 5)
  }
  return $false
}

# -------------------- Main VNet breaker --------------------
function Break-VNet-Blockers-In-RG {
  param($rg)
  Write-Host ">> Breaking VNet/Subnet blockers in '$rg'…"

  Delete-ContainerApps-In-RG       -rg $rg
  Delete-ManagedEnvironments-In-RG -rg $rg
  Delete-ApplicationGateways-In-RG -rg $rg
  Delete-AzureFirewalls-In-RG      -rg $rg
  Delete-Bastions-In-RG            -rg $rg
  Delete-VMs-And-NICs-In-RG        -rg $rg

  try { $vnetNamesRaw = az network vnet list -g $rg --query "[].name" --output tsv } catch { $vnetNamesRaw = '' }
  if ($vnetNamesRaw) {
    $vnetNames = $vnetNamesRaw -split "`n"

    foreach ($VNET in $vnetNames) {
      if ([string]::IsNullOrWhiteSpace($VNET)) { continue }

      $passes = 0
      do {
        $passes++
        $deferred = @()

        try { $subsRaw = az network vnet subnet list -g $rg --vnet-name $VNET --query "[].name" --output tsv } catch { $subsRaw = '' }
        if ($subsRaw) {
          foreach ($S in ($subsRaw -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($S)) { continue }

            $accountId = (az account show --query id --output tsv).Trim()
            $SUBNET_ID = "/subscriptions/$accountId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$VNET/subnets/$S"

            Delete-Subnet-Consumers-Broad -subnetId $SUBNET_ID
            Delete-PrivateEndpoints-For-Subnet -subnetId $SUBNET_ID
            Delete-ACAEnvs-Referencing-Subnet -subnetId $SUBNET_ID

            $salCleared = Delete-ServiceAssociationLinks -rg $rg -vnet $VNET -subnet $S
            if (-not $salCleared) {
              Write-Host "     (info) Deferring ${rg}/${VNET}/${S} until SALs are gone." -ForegroundColor DarkYellow
              $deferred += $S
              continue
            }

            Unset-Subnet-Props -rg $rg -vnet $VNET -subnet $S

            az network vnet subnet delete -g $rg --vnet-name $VNET -n $S | Out-Null
            if ($LASTEXITCODE -eq 0) {
              Write-Host "   - Deleted subnet ${rg}/${VNET}/$S"
            } else {
              Write-Host "     (info) Subnet delete deferred: ${rg}/${VNET}/$S" -ForegroundColor DarkYellow
              $deferred += $S
            }
          }
        }

        if ($deferred.Count -gt 0 -and $passes -lt 4) {
          Write-Host "   - Waiting before next subnet pass (remaining: $($deferred -join ', '))..."
          Start-Sleep -Seconds (10 * $passes)
        }
      } while ($deferred.Count -gt 0 -and $passes -lt 4)

      Remove-VNet-Peerings -rg $rg
      $acct  = (az account show --query id --output tsv).Trim()
      $vnetId = "/subscriptions/$acct/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$VNET"
      Remove-PrivateDns-VNetLinks -targetVNetId $vnetId

      if (-not (Try-Delete-VNet -rg $rg -vnet $VNET)) {
        Write-Host "   (info) VNet delete deferred: ${rg}/${VNET}" -ForegroundColor DarkYellow
      }
    }
  }
}

# -------------------- Main --------------------
function Main {
  Prompt-Context

  Write-Host ">> Using subscription: $script:SUB"
  # Optional SP login (pure CLI)
  if (-not $SpClientId -and $env:AZ_SUBDEL_SP_CLIENT_ID) { $SpClientId = $env:AZ_SUBDEL_SP_CLIENT_ID }
  if (-not $SpClientSecret -and $env:AZ_SUBDEL_SP_CLIENT_SECRET) { $SpClientSecret = $env:AZ_SUBDEL_SP_CLIENT_SECRET }
  if (-not $SpTenantId -and $env:AZ_SUBDEL_SP_TENANT_ID) { $SpTenantId = $env:AZ_SUBDEL_SP_TENANT_ID }

  if (-not $SpClientSecret -and $SpClientSecretFile) {
    try {
      if (Test-Path -Path $SpClientSecretFile) {
        $SpClientSecret = (Get-Content -Raw -Path $SpClientSecretFile).Trim()
      } else {
        Write-Host "   (warn) Secret file not found: $SpClientSecretFile" -ForegroundColor DarkYellow
      }
    } catch {
      Write-Host "   (warn) Could not read secret file: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
  }
  if ($SpClientId -and -not $SpClientSecret -and $PromptSpSecret) {
    try {
      $sec = Read-Host "Service principal client secret (input hidden)" -AsSecureString
      if ($sec) { $SpClientSecret = [System.Net.NetworkCredential]::new('', $sec).Password }
    } catch {
      Write-Host "   (warn) Secure prompt failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
  }
  if ($SpClientId -and $SpClientSecret) {
    $loginTenant = if ($SpTenantId) { $SpTenantId } elseif ($script:TENANT) { $script:TENANT } elseif ($TenantId) { $TenantId } else { '' }
    if ($loginTenant) {
      Write-Host "   - Logging in with service principal (clientId=$SpClientId tenant=$loginTenant)" -ForegroundColor Cyan
      try { az login --service-principal -u $SpClientId -p $SpClientSecret --tenant $loginTenant --only-show-errors | Out-Null } catch { Write-Host "   (error) SP login failed: $($_.Exception.Message)" -ForegroundColor Red }
    } else {
      Write-Host "   (warn) Service principal tenant not resolved; skipping SP login." -ForegroundColor DarkYellow
    }
  } elseif ($SpClientId -and -not $SpClientSecret) {
    Write-Host "   (info) SP client id provided but no secret (and none loaded). Use -SpClientSecretFile <path>, set env AZ_SUBDEL_SP_CLIENT_SECRET, or add -PromptSpSecret to input it securely." -ForegroundColor DarkYellow
  }

  az account set --subscription $script:SUB | Out-Null

  # Persist detected tenant if blank
  if ([string]::IsNullOrWhiteSpace($script:TENANT)) {
    try { $script:TENANT = (az account show --query tenantId --output tsv 2>$null).Trim() } catch { $script:TENANT = '' }
    $safeSub    = $script:SUB -replace "'","''"
    $safeRg     = $script:RG  -replace "'","''"
    $safeTenant = $script:TENANT -replace "'","''"
    Set-Content -Path $StateFile -Value @(
      "`$SUB = '$safeSub'",
      "`$RG  = '$safeRg'",
      "`$TENANT = '$safeTenant'"
    ) -Encoding UTF8
  }

  Write-Host ">> Verifying resource group '$script:RG' exists…"
  try { az group show -n $script:RG | Out-Null } catch {
    Write-Host "Resource group '$script:RG' not found or you do not have access." -ForegroundColor Red
    exit 1
  }

  Write-Host ">> Removing locks in RG (if any)…"
  try { $locks = az lock list --resource-group $script:RG --query "[].id" --output tsv } catch { $locks = '' }
  if ($locks) {
    foreach ($L in ($locks -split "`n")) {
      if ($L) { try { az lock delete --ids $L | Out-Null } catch { Write-Host "(warn) could not delete RG lock $L" -ForegroundColor DarkYellow } }
    }
  }

  Write-Host ">> Enumerating NSGs in '$script:RG'…"
  try { $nsgsRaw = az network nsg list -g $script:RG --query "[].id" --output tsv } catch { $nsgsRaw = '' }
  $NSG_IDS = if ($nsgsRaw) { $nsgsRaw -split "`n" } else { @() }
  foreach ($NSG_ID in $NSG_IDS) {
    if ([string]::IsNullOrWhiteSpace($NSG_ID)) { continue }
    $NSG_NAME = $NSG_ID.Split('/')[-1]
    Write-Host ">> Processing NSG: $NSG_NAME"

    try { $rgNicsRaw = az network nic list -g $script:RG --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].name" --output tsv } catch { $rgNicsRaw = '' }
    if ($rgNicsRaw) {
      foreach ($nic in ($rgNicsRaw -split "`n")) {
        if ($nic) {
          Write-Host "   - Removing NSG from NIC $script:RG/$nic"
          try { az network nic update -g $script:RG -n $nic --remove networkSecurityGroup | Out-Null } catch { Write-Host "     (warn) failed NIC update $nic" -ForegroundColor DarkYellow }
        }
      }
    }

    try { $vnetsRaw = az network vnet list -g $script:RG --query "[].name" --output tsv } catch { $vnetsRaw = '' }
    if ($vnetsRaw) {
      foreach ($VNET in ($vnetsRaw -split "`n")) {
        if (-not $VNET) { continue }
        try { $subsRaw = az network vnet subnet list -g $script:RG --vnet-name $VNET --query "[?networkSecurityGroup && networkSecurityGroup.id=='$NSG_ID'].name" --output tsv } catch { $subsRaw = '' }
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
  try { $locks2 = az lock list --resource-group $script:RG --query "[].id" --output tsv } catch { $locks2 = '' }
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
    try { $state = az group show -n $script:RG --query properties.provisioningState --output tsv 2>$null } catch { $state = 'Deleted' }
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
      try { az resource list -g $script:RG --output table } catch { }
      exit 3
    }
  }
  Write-Host "✅ Resource group deleted (or no longer returned)." -ForegroundColor Green
}

Main
