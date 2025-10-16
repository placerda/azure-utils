# 🚀 azure-utils

A small toolbox of PowerShell scripts to simplify Azure cleanup and maintenance.  
Each script comes with a one-liner you can copy, paste, and run instantly.

## Prerequisites

- **PowerShell 7+ (`pwsh`)**
- **Azure CLI (`az`)** installed and logged in:

  ```powershell
  az login
  ```

* **Permissions** to manage the target resources
* **Azure CLI extensions** configured to allow preview versions and install without prompts:

  ```powershell
  az config set extension.dynamic_install_allow_preview=true
  az config set extension.use_dynamic_install=yes_without_prompt
  ```

## How to Use

> [!TIP]
> Copy the command below each script and run it in PowerShell 7.

## 📑 Table of Contents

- [🧠 GPT-RAG](#gpt-rag)
- [🔍 AI Search](#ai-search)
- [🐳 Container Apps](#container-apps)
- [🌐 Networking](#networking)
- [🔷 Resource Group](#resource-group)

## GPT-RAG

### 🧠 Query Orchestrator (Local/Remote) — `ps/invoke-orchestrator.ps1`

Sends queries to the orchestrator running locally or in Azure Container Apps with conversation tracking and token caching.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/invoke-orchestrator.ps1').Content"
```

**Local usage examples:**

```powershell
# Interactive mode
.\ps\invoke-orchestrator.ps1

# Clear cache and start fresh
Remove-Item "$env:TEMP\invoke-orchestrator-last.ps1" -ErrorAction SilentlyContinue
.\ps\invoke-orchestrator.ps1
```

## Container Apps

### 🔑 Fetch a Dapr token for local/dev — `ps/get-dapr-token.ps1`

Retrieves a Container App Dapr API token for connecting local or dev services.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/get-dapr-token.ps1').Content"
```

## AI Search

### 🔍 Check Azure AI Search Agentic setup — `ps/check-agentic-setup.ps1`

Verifies Azure AI Search Agentic Retrieval configuration, knowledge sources, vectorizers, and semantic search settings.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/check-agentic-setup.ps1').Content"
```

### 🤖 Invoke Knowledge Agent Retrieval — `ps/invoke-agentic-retrieval.ps1`

Performs agentic retrieval queries using Azure AI Search Knowledge Agents with formatted results and activity tracking.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/invoke-agentic-retrieval.ps1').Content"
```

### 🗂️ Remove docs from an AI Search index — `ps/rm-index-documents.ps1`

Deletes documents from a Search index (by key or filter) to keep it tidy.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-index-documents.ps1').Content"
```

## Resource Group

### 🧹 Clean up and delete a Resource Group — `ps/rm-rg.ps1`

Removes blockers (NSGs, Private Endpoints, subnet settings, PDNS links, locks, etc.) and forcefully deletes the Resource Group.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-rg.ps1').Content"
```

### 🌐 Enable public access in a Resource Group — `ps/set-public.ps1`

Turns on public network access for Storage Accounts, Key Vaults, and Cosmos DB (does not remove private endpoints).

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/set-public.ps1').Content"
```

## Networking

### 🏗️ Create an Azure Virtual Network — `ps/create-vnet.ps1`

Creates a new Azure VNet with interactive prompts.
Remembers your last settings and creates the resource group if it doesn’t exist.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/create-vnet.ps1').Content"
```

### 🧩 Create an Azure VNet with Pre-configured Subnets — `ps/create-vnet-with-subnets.ps1`

Creates an Azure VNet with multiple pre-configured subnets for enterprise workloads.

**Features:**

* 9 base subnets (agent, ACA, PE, Bastion, Firewall, Gateway, App Gateway, Jumpbox, DevOps)
* 2 optional subnets for API Management and PostgreSQL (`-SkipApim`, `-SkipPostgres`)
* Address space: `192.168.0.0/21`
* Delegations: `Microsoft.App/environments`, `Microsoft.DBforPostgreSQL/flexibleServers`
* Service endpoints: `CognitiveServices`, `AzureCosmosDB`
* PE subnet `/26` to prevent race conditions
* Remembers previous settings like `create-vnet.ps1`

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

## License

MIT — see [LICENSING.md](./LICENSING.md)