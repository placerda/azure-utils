# azure-utils

Handy scripts to speed up common Azure cleanup and maintenance. Each script has a quick description and a ready-to-run one-liner.

## Prerequisites
- Azure CLI (`az`) installed and logged in: `az login`
- Permissions to manage the target resources
- **PowerShell 7+ (`pwsh`)** for the commands below

## Run it quick with PowerShell 7
> **Note**  
> Just copy and paste the commands below into your PowerShell 7 terminal and run them.  

### Make RG resources publicly reachable - `ps/set-public.ps1`
Turns on public network access for Storage Accounts, Key Vaults, and Cosmos DB in a resource group (doesn’t remove private endpoints).
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/set-public.ps1').Content"
````

---

### Get a Dapr token for local/dev use - `ps/get-dapr-token.ps1`

Pulls a Dapr API token (for local/dev scenarios) so you can wire up services quickly.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/get-dapr-token.ps1').Content"
```

---

### Safe, forceful Resource Group cleanup & delete - `ps/rm-rg.ps1`

Clears out common blockers (NSGs, Private Endpoints, SALs, subnet settings, peerings, PDNS links, locks) and then deletes the RG.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-rg.ps1').Content"
```

---

### Remove documents from an Azure AI Search index - `ps/rm-index-documents.ps1`

Deletes documents from a target Search index (by key or filter) to keep the index clean.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/rm-index-documents.ps1').Content"
```

---

## Directory layout

* `ps/` — PowerShell 7 (pwsh) scripts using Azure CLI and Azure APIs
* `bash/` — Bash scripts for Linux/macOS (available, but not covered in Quick Start)

## License

MIT — see [LICENSING.md](./LICENSING.md).
