#!/usr/bin/env pwsh
#requires -Version 7
<#
.SYNOPSIS
  Creates an Azure Virtual Network with pre-configured subnets.

.DESCRIPTION
  This script creates an Azure VNet by:
  1. Prompting for Subscription ID, Resource Group name, VNet name, and address prefix
  2. Remembering the last execution values and asking to reuse them
  3. Creating the Resource Group if it doesn't exist
  4. Creating the VNet with the specified address prefix (default: 192.168.0.0/21)
  5. Creating 11 subnets with specific address prefixes, delegations, and service endpoints
  
  Can be run interactively or with parameters for automation.

.PARAMETER SubscriptionId
  The Azure Subscription ID (optional - will prompt if not provided)

.PARAMETER ResourceGroup
  The Resource Group name (optional - will prompt if not provided)

.PARAMETER VNetName
  The Virtual Network name (optional - will prompt if not provided)

.PARAMETER VNetAddressPrefix
  The VNet address prefix in CIDR notation (optional - will prompt if not provided, default: 192.168.0.0/21)

.PARAMETER Location
  The Azure region/location (optional - will prompt if not provided, default: eastus)

.PARAMETER SkipApim
  Skip creation of API Management subnet

.PARAMETER SkipPostgres
  Skip creation of PostgreSQL subnet

.PARAMETER Force
  Skip confirmation prompts when VNet already exists

.EXAMPLE
  .\create-vnet-with-subnets.ps1
  # Interactive mode with prompts

.EXAMPLE
  .\create-vnet-with-subnets.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -ResourceGroup "my-rg" -VNetName "my-vnet"
  # With parameters, will create all subnets with defaults

.EXAMPLE
  .\create-vnet-with-subnets.ps1 -ResourceGroup "my-rg" -VNetName "my-vnet" -SkipApim -SkipPostgres -Force
  # Skip APIM and PostgreSQL subnets
#>

param(
  [string]$SubscriptionId,
  [string]$ResourceGroup,
  [string]$VNetName,
  [string]$VNetAddressPrefix,
  [string]$Location,
  [switch]$SkipApim,
  [switch]$SkipPostgres,
  [switch]$Force
)

# Relaunch in pwsh if running under Windows PowerShell (non-Core)
if ($PSVersionTable.PSEdition -ne 'Core') {
  Write-Host "This script requires PowerShell Core (pwsh). Attempting to relaunch..." -ForegroundColor Yellow
  $scriptPath = $PSCommandPath
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath @PSBoundParameters
    exit $LASTEXITCODE
  } else {
    Write-Host "PowerShell Core (pwsh) not found. Please install it first." -ForegroundColor Red
    exit 1
  }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Globals
$script:SUB = $null
$script:RG  = $null
$script:VNET = $null
$script:VNET_PREFIX = $null
$script:LOCATION = $null

# State file (remember last subscription/RG/VNet)
$StateFile = Join-Path $env:TEMP 'create-vnet-with-subnets-last.ps1'

# Subnet configurations
$script:SubnetConfigs = @(
  @{
    Name = 'agent-subnet'
    AddressPrefix = '192.168.0.0/24'
    Delegation = 'Microsoft.App/environments'
    ServiceEndpoints = @('Microsoft.CognitiveServices')
  }
  @{
    Name = 'aca-environment-subnet'
    AddressPrefix = '192.168.1.0/24'
    Delegation = 'Microsoft.App/environments'
    ServiceEndpoints = @('Microsoft.AzureCosmosDB')
  }
  @{
    Name = 'pe-subnet'
    AddressPrefix = '192.168.2.0/26'
    Delegation = $null
    ServiceEndpoints = @('Microsoft.AzureCosmosDB')
  }
  @{
    Name = 'AzureBastionSubnet'
    AddressPrefix = '192.168.2.64/26'
    Delegation = $null
    ServiceEndpoints = @()
  }
  @{
    Name = 'AzureFirewallSubnet'
    AddressPrefix = '192.168.2.128/26'
    Delegation = $null
    ServiceEndpoints = @()
  }
  @{
    Name = 'gateway-subnet'
    AddressPrefix = '192.168.2.192/26'
    Delegation = $null
    ServiceEndpoints = @()
  }
  @{
    Name = 'AppGatewaySubnet'
    AddressPrefix = '192.168.3.0/27'
    Delegation = $null
    ServiceEndpoints = @()
  }
  @{
    Name = 'jumpbox-subnet'
    AddressPrefix = '192.168.3.64/27'
    Delegation = $null
    ServiceEndpoints = @()
  }
  @{
    Name = 'devops-build-agents-subnet'
    AddressPrefix = '192.168.3.96/27'
    Delegation = $null
    ServiceEndpoints = @()
  }
)

# Conditional subnets
$script:ApimSubnet = @{
  Name = 'api-management-subnet'
  AddressPrefix = '192.168.3.32/27'
  Delegation = $null
  ServiceEndpoints = @()
}

$script:PostgresSubnet = @{
  Name = 'psql-subnet'
  AddressPrefix = '192.168.3.128/27'
  Delegation = 'Microsoft.DBforPostgreSQL/flexibleServers'
  ServiceEndpoints = @()
}

# -------------------- Helper Functions --------------------

function Test-AzureCLI {
  try {
    $null = az version --output json 2>$null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Ensure-LoggedIn {
  try {
    $account = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $account) {
      Write-Host "Not logged in to Azure. Please login..." -ForegroundColor Yellow
      az login
      if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to login to Azure." -ForegroundColor Red
        exit 1
      }
    }
  } catch {
    Write-Host "Error checking Azure login status. Please ensure Azure CLI is installed." -ForegroundColor Red
    exit 1
  }
}

function Prompt-Context {
  # Load previous state if exists
  if (Test-Path -Path $StateFile) {
    . $StateFile
    $script:SUB  = $SUB
    $script:RG   = $RG
    $script:VNET = $VNET
    $script:VNET_PREFIX = if ($VNET_PREFIX) { $VNET_PREFIX } else { '192.168.0.0/21' }
    $script:LOCATION = if ($LOCATION) { $LOCATION } else { 'eastus' }

    Write-Host "`nLast used:" -ForegroundColor Cyan
    Write-Host "  Subscription: $script:SUB"
    Write-Host "  Resource Group: $script:RG"
    Write-Host "  VNet: $script:VNET"
    Write-Host "  VNet Address Prefix: $script:VNET_PREFIX"
    Write-Host "  Location: $script:LOCATION"
  } else {
    # Set defaults for first run
    $script:VNET_PREFIX = '192.168.0.0/21'
    $script:LOCATION = 'eastus'
  }

  # --- Subscription ---
  if ($SubscriptionId) {
    $script:SUB = $SubscriptionId
    Write-Host "`nUsing provided Subscription: $script:SUB" -ForegroundColor Cyan
  } else {
    $reuseSub = if ($script:SUB) { Read-Host "Reuse last subscription ($script:SUB)? [Y/n]" } else { 'n' }
    if ([string]::IsNullOrWhiteSpace($reuseSub)) { $reuseSub = 'Y' }
    
    if ($reuseSub -match '^(n|no)$' -or -not $script:SUB) {
      $subs = az account list --query "[].{id:id,name:name}" --output tsv 2>$null
      if (-not $subs) { 
        Write-Host "   (error) No subscriptions found." -ForegroundColor Red
        exit 1 
      }
      
      $subsArr = @()
      foreach ($s in ($subs -split "`n")) {
        $parts = $s -split "`t"
        if ($parts.Count -ge 2) { 
          $subsArr += [PSCustomObject]@{ Id=$parts[0]; Name=$parts[1] } 
        }
      }
      
      Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
      for ($i=0; $i -lt $subsArr.Count; $i++) { 
        Write-Host " [$i] $($subsArr[$i].Name) ($($subsArr[$i].Id))" 
      }
      
      $subChoice = Read-Host "Select subscription index"
      try {
        $subChoiceInt = [int]$subChoice
        if ($subChoiceInt -lt 0 -or $subChoiceInt -ge $subsArr.Count) {
          Write-Host "Invalid subscription choice." -ForegroundColor Red
          exit 1
        }
        $script:SUB = $subsArr[$subChoiceInt].Id
      } catch {
        Write-Host "Invalid subscription choice. Please enter a valid number." -ForegroundColor Red
        exit 1
      }
    }
  }  
  az account set --subscription $script:SUB | Out-Null
  Write-Host "✓ Using subscription: $script:SUB" -ForegroundColor Green

  # --- Resource Group ---
  if ($ResourceGroup) {
    $script:RG = $ResourceGroup
    Write-Host "Using provided Resource Group: $script:RG" -ForegroundColor Cyan
  } else {
    $reuseRG = if ($script:RG) { Read-Host "Reuse last resource group ($script:RG)? [Y/n]" } else { 'n' }
    if ([string]::IsNullOrWhiteSpace($reuseRG)) { $reuseRG = 'Y' }
    
    if ($reuseRG -match '^(n|no)$' -or -not $script:RG) {
      $script:RG = Read-Host "Enter Resource Group name"
      if ([string]::IsNullOrWhiteSpace($script:RG)) {
        Write-Host "Resource Group name cannot be empty." -ForegroundColor Red
        exit 1
      }
    }
  }

  # --- VNet Name ---
  if ($VNetName) {
    $script:VNET = $VNetName
    Write-Host "Using provided VNet name: $script:VNET" -ForegroundColor Cyan
  } else {
    $reuseVNet = if ($script:VNET) { Read-Host "Reuse last VNet name ($script:VNET)? [Y/n]" } else { 'n' }
    if ([string]::IsNullOrWhiteSpace($reuseVNet)) { $reuseVNet = 'Y' }
    
    if ($reuseVNet -match '^(n|no)$' -or -not $script:VNET) {
      $script:VNET = Read-Host "Enter VNet name"
      if ([string]::IsNullOrWhiteSpace($script:VNET)) {
        Write-Host "VNet name cannot be empty." -ForegroundColor Red
        exit 1
      }
    }
  }

  # --- VNet Address Prefix ---
  if ($VNetAddressPrefix) {
    $script:VNET_PREFIX = $VNetAddressPrefix
    Write-Host "Using provided VNet address prefix: $script:VNET_PREFIX" -ForegroundColor Cyan
  } else {
    $reuseVNetPrefix = if ($script:VNET_PREFIX) { Read-Host "Reuse last VNet address prefix ($script:VNET_PREFIX)? [Y/n]" } else { 'n' }
    if ([string]::IsNullOrWhiteSpace($reuseVNetPrefix)) { $reuseVNetPrefix = 'Y' }
    
    if ($reuseVNetPrefix -match '^(n|no)$' -or -not $script:VNET_PREFIX) {
      $newPrefix = Read-Host "Enter VNet address prefix (default: 192.168.0.0/21)"
      if (-not [string]::IsNullOrWhiteSpace($newPrefix)) {
        $script:VNET_PREFIX = $newPrefix
      } else {
        $script:VNET_PREFIX = '192.168.0.0/21'
        Write-Host "Using default: 192.168.0.0/21" -ForegroundColor Yellow
      }
    }
  }

  # --- Location (if RG doesn't exist yet) ---
  $rgExists = Test-ResourceGroupExists -resourceGroup $script:RG
  if (-not $rgExists) {
    if ($Location) {
      $script:LOCATION = $Location
      Write-Host "Using provided location: $script:LOCATION" -ForegroundColor Cyan
    } else {
      $reuseLocation = if ($script:LOCATION) { Read-Host "Reuse last location ($script:LOCATION) for new Resource Group? [Y/n]" } else { 'n' }
      if ([string]::IsNullOrWhiteSpace($reuseLocation)) { $reuseLocation = 'Y' }
      
      if ($reuseLocation -match '^(n|no)$' -or -not $script:LOCATION) {
        $newLocation = Read-Host "Enter location for Resource Group (e.g., eastus, westus, brazilsouth) [default: eastus]"
        if (-not [string]::IsNullOrWhiteSpace($newLocation)) {
          $script:LOCATION = $newLocation
        } else {
          $script:LOCATION = 'eastus'
          Write-Host "Using default location: eastus" -ForegroundColor Yellow
        }
      }
    }
  } else {
    # RG exists, get its location for display
    try {
      $existingLocation = az group show --name $script:RG --query location --output tsv 2>$null
      if ($existingLocation) {
        $script:LOCATION = $existingLocation
      }
    } catch {
      if (-not $script:LOCATION) {
        $script:LOCATION = 'eastus'
      }
    }
  }

  # --- Save state ---
  $safeSub  = $script:SUB -replace "'","''"
  $safeRg   = $script:RG  -replace "'","''"
  $safeVNet = $script:VNET -replace "'","''"
  $safeVNetPrefix = $script:VNET_PREFIX -replace "'","''"
  $safeLoc  = $script:LOCATION -replace "'","''"
  
  Set-Content -Path $StateFile -Value @(
    "`$SUB = '$safeSub'",
    "`$RG  = '$safeRg'",
    "`$VNET = '$safeVNet'",
    "`$VNET_PREFIX = '$safeVNetPrefix'",
    "`$LOCATION = '$safeLoc'"
  ) -Encoding UTF8

  Write-Host "`nConfiguration:" -ForegroundColor Green
  Write-Host "  Subscription: $script:SUB" -ForegroundColor Green
  Write-Host "  Resource Group: $script:RG" -ForegroundColor Green
  Write-Host "  VNet: $script:VNET" -ForegroundColor Green
  Write-Host "  VNet Address Prefix: $script:VNET_PREFIX" -ForegroundColor Green
  Write-Host "  Location: $script:LOCATION" -ForegroundColor Green
  Write-Host ""
}

function Test-ResourceGroupExists {
  param([string]$resourceGroup)
  try {
    $exists = az group exists --name $resourceGroup --output tsv 2>$null
    return $exists -eq 'true'
  } catch {
    return $false
  }
}

function Test-VNetExists {
  param([string]$resourceGroup, [string]$vnetName)
  try {
    $vnet = az network vnet show --resource-group $resourceGroup --name $vnetName --output json 2>$null
    return $LASTEXITCODE -eq 0 -and $vnet
  } catch {
    return $false
  }
}

function Create-ResourceGroup {
  param([string]$resourceGroup, [string]$location)
  
  Write-Host "Creating Resource Group '$resourceGroup' in location '$location'..." -ForegroundColor Cyan
  try {
    az group create --name $resourceGroup --location $location --output none
    if ($LASTEXITCODE -eq 0) {
      Write-Host "✓ Resource Group created successfully." -ForegroundColor Green
      return $true
    } else {
      Write-Host "✗ Failed to create Resource Group." -ForegroundColor Red
      return $false
    }
  } catch {
    Write-Host "✗ Error creating Resource Group: $_" -ForegroundColor Red
    return $false
  }
}

function Create-VNet {
  param(
    [string]$resourceGroup,
    [string]$vnetName,
    [string]$addressPrefix
  )
  
  Write-Host "Creating VNet '$vnetName' with address prefix '$addressPrefix'..." -ForegroundColor Cyan
  try {
    # Create VNet without any subnets initially
    az network vnet create `
      --resource-group $resourceGroup `
      --name $vnetName `
      --address-prefixes $addressPrefix `
      --subnet-name "temp-subnet" `
      --subnet-prefixes "192.168.0.0/27" `
      --output none
    
    if ($LASTEXITCODE -eq 0) {
      Write-Host "✓ VNet created successfully." -ForegroundColor Green
      
      # Delete the temporary subnet
      Write-Host "Removing temporary subnet..." -ForegroundColor Cyan
      az network vnet subnet delete `
        --resource-group $resourceGroup `
        --vnet-name $vnetName `
        --name "temp-subnet" `
        --output none 2>$null
      
      return $true
    } else {
      Write-Host "✗ Failed to create VNet." -ForegroundColor Red
      return $false
    }
  } catch {
    Write-Host "✗ Error creating VNet: $_" -ForegroundColor Red
    return $false
  }
}

function Create-Subnet {
  param(
    [string]$resourceGroup,
    [string]$vnetName,
    [hashtable]$subnetConfig
  )
  
  $subnetName = $subnetConfig.Name
  $addressPrefix = $subnetConfig.AddressPrefix
  $delegation = $subnetConfig.Delegation
  $serviceEndpoints = $subnetConfig.ServiceEndpoints
  
  Write-Host "  Creating subnet '$subnetName' ($addressPrefix)..." -ForegroundColor Cyan
  
  try {
    $params = @(
      '--resource-group', $resourceGroup,
      '--vnet-name', $vnetName,
      '--name', $subnetName,
      '--address-prefixes', $addressPrefix,
      '--output', 'none'
    )
    
    # Add delegation if specified
    if ($delegation) {
      $params += '--delegations'
      $params += $delegation
    }
    
    # Add service endpoints if specified
    if ($serviceEndpoints -and $serviceEndpoints.Count -gt 0) {
      $params += '--service-endpoints'
      $params += ($serviceEndpoints -join ' ')
    }
    
    az network vnet subnet create @params
    
    if ($LASTEXITCODE -eq 0) {
      Write-Host "    ✓ Subnet '$subnetName' created." -ForegroundColor Green
      return $true
    } else {
      Write-Host "    ✗ Failed to create subnet '$subnetName'." -ForegroundColor Red
      return $false
    }
  } catch {
    Write-Host "    ✗ Error creating subnet '$subnetName': $_" -ForegroundColor Red
    return $false
  }
}

function Create-AllSubnets {
  param(
    [string]$resourceGroup,
    [string]$vnetName
  )
  
  Write-Host "`nCreating subnets..." -ForegroundColor Cyan
  
  $successCount = 0
  $failCount = 0
  
  # Create base subnets
  foreach ($subnetConfig in $script:SubnetConfigs) {
    $result = Create-Subnet -resourceGroup $resourceGroup -vnetName $vnetName -subnetConfig $subnetConfig
    if ($result) {
      $successCount++
    } else {
      $failCount++
    }
  }
  
  # Create API Management subnet if not skipped
  if (-not $SkipApim) {
    $result = Create-Subnet -resourceGroup $resourceGroup -vnetName $vnetName -subnetConfig $script:ApimSubnet
    if ($result) {
      $successCount++
    } else {
      $failCount++
    }
  } else {
    Write-Host "  Skipping API Management subnet (SkipApim flag set)." -ForegroundColor Yellow
  }
  
  # Create PostgreSQL subnet if not skipped
  if (-not $SkipPostgres) {
    $result = Create-Subnet -resourceGroup $resourceGroup -vnetName $vnetName -subnetConfig $script:PostgresSubnet
    if ($result) {
      $successCount++
    } else {
      $failCount++
    }
  } else {
    Write-Host "  Skipping PostgreSQL subnet (SkipPostgres flag set)." -ForegroundColor Yellow
  }
  
  Write-Host "`n✓ Subnet creation complete: $successCount succeeded, $failCount failed." -ForegroundColor Green
  
  return $failCount -eq 0
}

# -------------------- Main Script --------------------

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Azure VNet Creator with Subnets" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
if (-not (Test-AzureCLI)) {
  Write-Host "Azure CLI is not installed or not in PATH." -ForegroundColor Red
  Write-Host "Please install it from: https://docs.microsoft.com/cli/azure/install-azure-cli" -ForegroundColor Yellow
  exit 1
}

# Ensure logged in
Ensure-LoggedIn

# Prompt for context (subscription, RG, VNet)
Prompt-Context

# Check if Resource Group exists, create if not
$rgExists = Test-ResourceGroupExists -resourceGroup $script:RG

if (-not $rgExists) {
  Write-Host "Resource Group '$script:RG' does not exist." -ForegroundColor Yellow
  $createRG = Read-Host "Create it? [Y/n]"
  if ([string]::IsNullOrWhiteSpace($createRG)) { $createRG = 'Y' }
  
  if ($createRG -match '^(y|yes)$') {
    $success = Create-ResourceGroup -resourceGroup $script:RG -location $script:LOCATION
    if (-not $success) {
      Write-Host "Cannot proceed without Resource Group." -ForegroundColor Red
      exit 1
    }
  } else {
    Write-Host "Cannot proceed without Resource Group." -ForegroundColor Red
    exit 1
  }
} else {
  Write-Host "✓ Resource Group '$script:RG' exists." -ForegroundColor Green
}

# Check if VNet exists
$vnetExists = Test-VNetExists -resourceGroup $script:RG -vnetName $script:VNET

if ($vnetExists) {
  Write-Host "⚠ VNet '$script:VNET' already exists in Resource Group '$script:RG'." -ForegroundColor Yellow
  
  if (-not $Force) {
    $overwrite = Read-Host "VNet already exists. Do you want to exit? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($overwrite)) { $overwrite = 'Y' }
    
    if ($overwrite -match '^(y|yes)$') {
      Write-Host "Operation cancelled. VNet already exists." -ForegroundColor Yellow
      exit 0
    }
  } else {
    Write-Host "Force flag enabled. Attempting to create subnets in existing VNet..." -ForegroundColor Yellow
  }
  
  # Try to create subnets in existing VNet
  $subnetSuccess = Create-AllSubnets -resourceGroup $script:RG -vnetName $script:VNET
  if (-not $subnetSuccess) {
    Write-Host "⚠ Some subnets failed to create. Check the output above." -ForegroundColor Yellow
  }
} else {
  Write-Host "Creating VNet '$script:VNET' in Resource Group '$script:RG'..." -ForegroundColor Cyan
  $success = Create-VNet -resourceGroup $script:RG -vnetName $script:VNET -addressPrefix $script:VNET_PREFIX
  if (-not $success) {
    Write-Host "✗ Failed to create VNet." -ForegroundColor Red
    exit 1
  }
  
  # Create all subnets
  $subnetSuccess = Create-AllSubnets -resourceGroup $script:RG -vnetName $script:VNET
  if (-not $subnetSuccess) {
    Write-Host "⚠ Some subnets failed to create. Check the output above." -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  VNet Creation Complete" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Resource Group: $script:RG" -ForegroundColor Green
Write-Host "  VNet Name: $script:VNET" -ForegroundColor Green
Write-Host "  Address Prefix: $script:VNET_PREFIX" -ForegroundColor Green
Write-Host "  Location: $script:LOCATION" -ForegroundColor Green
Write-Host "  Base Subnets: 9" -ForegroundColor Green
Write-Host "  API Management: $(if ($SkipApim) { 'Skipped' } else { 'Created' })" -ForegroundColor Green
Write-Host "  PostgreSQL: $(if ($SkipPostgres) { 'Skipped' } else { 'Created' })" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

exit 0
