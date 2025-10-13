# Examples - Azure Utils

## rm-rg.ps1 - Resource Group Cleanup Script

### Overview
This script forcefully deletes Azure Resource Groups or their contents by automatically removing common blockers that prevent normal deletion, including:

- **Azure AI Search services** with shared private access and private endpoint connections
- NSG associations (NICs/subnets)
- Private Endpoints on subnets
- Service Association Links (Azure Container Apps)
- Container Apps and Managed Environments
- Application Gateways, Azure Firewalls, Bastion hosts
- VMs and leftover NICs
- VNet peerings and Private DNS zone links
- Resource locks

### Azure AI Search Cleanup

The script now includes specialized handling for Azure AI Search services that have:
- **Shared private link resources** - automatically removed before service deletion
- **Private endpoint connections** - cleaned up to allow service removal
- **Public network access disabled** - temporarily enabled to allow deletion

#### What the script does for Azure Search:
1. **Lists all Search services** in the resource group
2. **Removes shared private link resources** (the "shared private access" you see in the portal)
3. **Removes private endpoint connections** 
4. **Enables public network access** temporarily to allow deletion
5. **Deletes the Search service**

### Usage Examples

#### Delete entire resource group (default behavior):
```powershell
.\rm-rg.ps1
```

#### Delete only resources inside RG, keep the RG:
```powershell
.\rm-rg.ps1 -DeleteResourceGroup N
```

#### Force delete without confirmation:
```powershell
.\rm-rg.ps1 -Force
```

#### Delete and don't wait for completion:
```powershell
.\rm-rg.ps1 -NoWait
```

#### Use service principal authentication:
```powershell
.\rm-rg.ps1 -SpClientId "your-sp-id" -SpClientSecret "your-secret" -SpTenantId "your-tenant"
```

### Azure AI Search Scenario

If you have an Azure AI Search service with shared private access (like shown in your portal screenshot), the script will:

1. **Identify the search service** in the resource group
2. **Remove the shared private link** (`spl-srch-fpda3yecjsy3u-...` from your screenshot)
3. **Clean up any private endpoint connections**
4. **Enable public access** temporarily 
5. **Successfully delete the search service**

This resolves the issue where the search service was being left behind due to the shared private access blocking normal deletion.

### Parameters

- `-Force`: Skip confirmation prompts
- `-NoWait`: Don't wait for deletion completion
- `-Confirm`: Force confirmation even with -Force
- `-TimeoutMinutes`: Maximum wait time (default: 20)
- `-DeleteResourceGroup`: 'Y' (delete RG) or 'N' (delete contents only)
- `-TenantId`: Specify tenant ID
- Service Principal options: `-SpClientId`, `-SpClientSecret`, `-SpTenantId`

The script maintains state between runs, remembering your last used subscription, resource group, and tenant for convenience.