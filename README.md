# azure-utils

Utilities to make common Azure clean-up and maintenance tasks fast and reliable. The repository is organized by shell/language so you can pick the tools that fit your workflow. Each script includes a short header describing what it does, prerequisites, and usage examples.

## Directory layout
- `ps/` — PowerShell scripts (pwsh) that leverage Azure CLI and Azure management/data-plane APIs.
- `bash/` — Bash scripts for Linux/macOS environments.

More folders and scripts may be added over time. Explore the directories to see what’s available and read the script headers before running them.

## Prerequisites
- Azure CLI (az) installed and authenticated: `az login`
- Appropriate Azure permissions for the resources you intend to manage
- For PowerShell scripts: PowerShell 7+ (pwsh)
- For Bash scripts: a POSIX shell environment

## Quick start
1) Open the directory matching your shell (for example, `ps/`).
2) Read a script’s header for its overview, prerequisites, and examples.
3) Run from the repo root or the script’s folder. Many scripts are interactive and remember your last inputs.

Examples
```powershell
# PowerShell (pwsh)
.\ps\<script-name>.ps1 [options]
```

```bash
# Bash
bash/<script-name>.sh [options]
```

## Troubleshooting
- If a resource group deletion flips from `Deleting` back to `Succeeded`, there are blockers; check the script output for warnings/errors (for example, gateways, firewalls, or service association links), resolve them, and retry.
- If a data-plane operation returns 0 changes, verify the target has content and your account has the required permissions.

## License
This project is licensed under the MIT License. See [LICENSING.md](./LICENSING.md) for details.
