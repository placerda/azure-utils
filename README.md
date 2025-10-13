# 🚀 azure-utils

A small toolbox of PowerShell scripts to simplify Azure cleanup and maintenance.  
Each script comes with a one-liner you can copy, paste, and run instantly.

## Prerequisites
- Azure CLI (`az`) installed and logged in: `az login`
- Permissions to manage the target resources
- **PowerShell 7+ (`pwsh`)**
- Azure CLI extensions configured to allow preview versions and install without prompts:
 ```
  az config set extension.dynamic_install_allow_preview=true
  az config set extension.use_dynamic_install=yes_without_prompt
```

## Copy & Run
> [!Tip]  
> Just copy the command below each script and run it in your PowerShell 7 terminal.

### 🔑 Fetch a Dapr token for local/dev — `ps/get-dapr-token.ps1`

Pulls a Container App Dapr API token so you can quickly wire up local or dev services.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/get-dapr-token.ps1').Content"
```

### 🧹 Clean up & delete a Resource Group — `ps/rm-rg.ps1`

Removes blockers (NSGs, Private Endpoints, subnet settings, PDNS links, locks, etc.) and forcefully deletes the RG.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-rg.ps1').Content"
```

### 🗂️ Remove docs from an AI Search index — `ps/rm-index-documents.ps1`

Deletes documents from a Search index (by key or filter) to keep it tidy.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-index-documents.ps1').Content"
```

### 🌐 Enable public access in a Resource Group — `ps/set-public.ps1`
Turns on public network access for Storage Accounts, Key Vaults, and Cosmos DB (doesn’t remove private endpoints).

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/set-public.ps1').Content"
````

### 🌐 Create an Azure Virtual Network — `ps/create-vnet.ps1`

Creates a new Azure VNet with interactive prompts. Remembers your last settings (subscription, resource group, VNet name, address prefix, location) and asks if you want to reuse them. Creates the resource group if it doesn't exist.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/create-vnet.ps1').Content"
```

### 🏗️ Create an Azure VNet with Pre-configured Subnets — `ps/create-vnet-with-subnets.ps1`

Creates an Azure VNet with 11 pre-configured subnets designed for enterprise workloads. Includes subnets for AI Foundry agents, Container Apps, Private Endpoints, Bastion, Firewall, Gateway, App Gateway, Jumpbox, DevOps agents, API Management (optional), and PostgreSQL (optional). Each subnet is configured with appropriate address ranges, delegations, and service endpoints.

**Features:**
- 🎯 **9 base subnets** always created (agent, ACA, PE, Bastion, Firewall, Gateway, App Gateway, jumpbox, DevOps)
- 🔧 **2 optional subnets** for API Management and PostgreSQL (use `-SkipApim` or `-SkipPostgres` to exclude)
- 📦 **Address space:** 192.168.0.0/21 (2048 IPs total)
- 🔐 **Delegations configured:** Microsoft.App/environments, Microsoft.DBforPostgreSQL/flexibleServers
- 🌐 **Service endpoints:** CognitiveServices, AzureCosmosDB where needed
- 💡 **PE subnet:** /26 (64 IPs) to prevent race conditions during parallel Private Endpoint creation
- 💾 **Remembers settings** like the original create-vnet.ps1

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/create-vnet-with-subnets.ps1').Content"
```

**Local usage examples:**
```powershell
# Interactive mode
.\ps\create-vnet-with-subnets.ps1

# With parameters
.\ps\create-vnet-with-subnets.ps1 -ResourceGroup "my-rg" -VNetName "my-vnet"

# Skip optional subnets
.\ps\create-vnet-with-subnets.ps1 -SkipApim -SkipPostgres
```

---

## License

MIT — see [LICENSING.md](./LICENSING.md)
