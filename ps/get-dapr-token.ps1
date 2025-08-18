#!/usr/bin/env pwsh
<#
Script: get-dapr-token.ps1
Overview:
        Retrieves the Dapr or application API token from a container running inside an Azure Container App.
        The script connects to the specified container using `az containerapp exec`, probes common
        environment variables and token file locations (for example: /var/run/dapr/metadata/token).

Default behavior:
        - Copies the token to the clipboard.
        - Prints a success message.

Optional behavior:
        - With the `-PrintToTerminal` switch, the script will also print the token to stdout.

Features:
        - Persists last-used subscription, resource group, container app and container in a state file
            under $env:TEMP for convenient reuse across runs.
        - Attempts non-interactive discovery of tokens via environment variables and standard token
            file paths inside the container.
        - Runs remote commands via `az containerapp exec` with a short timeout and sanitizes output
            (removes ANSI sequences and noisy informational lines).

Prerequisites:
        - PowerShell 7+ (pwsh)
        - Azure CLI (`az`) installed and logged in: `az login`
        - The `containerapp` Azure CLI extension (the script will try to install it if missing)
        - RBAC permissions to access the Container App and execute commands
        - Network access to the Container App's execution endpoint

Usage examples:
        # Interactive prompts (reuses last values if present):
        .\ps\get-dapr-token.ps1

        # Print the retrieved token in the terminal as well:
        .\ps\get-dapr-token.ps1 -PrintToTerminal

Notes:
        - The script stores last-used parameters in a dot-sourceable file: $env:TEMP\get-dapr-token-last.ps1
        - Token discovery order: APP_API_TOKEN, DAPR_API_TOKEN, file pointed by DAPR_API_TOKEN_FILE,
            fallback to /var/run/dapr/metadata/token
        - The script sanitizes az and container output and enforces a timeout when running remote execs.
#>

param(
    [switch]$PrintToTerminal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# State (persisted in a dot-sourceable file under %TEMP%)
$script:SUB = $null
$script:RG  = $null
$script:APP = $null
$script:CON = $null
$StateFile  = Join-Path $env:TEMP 'get-dapr-token-last.ps1'

function Prompt-Context {
    if (Test-Path -Path $StateFile) {
        . $StateFile
        $script:SUB = $SUB; $script:RG = $RG; $script:APP = $APP; $script:CON = $CON
        Write-Host "Last used:" -ForegroundColor Cyan
        Write-Host "  Subscription : $([string]::IsNullOrWhiteSpace($script:SUB) ? '<none>' : $script:SUB)"
        Write-Host "  ResourceGroup: $([string]::IsNullOrWhiteSpace($script:RG)  ? '<none>' : $script:RG)"
        Write-Host "  ContainerApp : $([string]::IsNullOrWhiteSpace($script:APP) ? '<none>' : $script:APP)"
        Write-Host "  Container    : $([string]::IsNullOrWhiteSpace($script:CON) ? '<none>' : $script:CON)"

        $reuseSub = Read-Host "Reuse subscription '$script:SUB'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseSub)) { $reuseSub = 'Y' }
        if ($reuseSub -match '^(n|no)$') { $script:SUB = Read-Host 'Subscription ID or name' }

        $reuseRg = Read-Host "Reuse resource group '$script:RG'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseRg)) { $reuseRg = 'Y' }
        if ($reuseRg -match '^(n|no)$') { $script:RG = Read-Host 'Resource group name' }

        $reuseApp = Read-Host "Reuse container app '$script:APP'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseApp)) { $reuseApp = 'Y' }
        if ($reuseApp -match '^(n|no)$') { $script:APP = Read-Host 'Container app name' }

        $reuseCon = Read-Host "Reuse container '$script:CON'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseCon)) { $reuseCon = 'Y' }
        if ($reuseCon -match '^(n|no)$') { $script:CON = Read-Host 'Container name' }
    }
    else {
        $script:SUB = Read-Host 'Subscription ID or name'
        $script:RG  = Read-Host 'Resource group name'
        $script:APP = Read-Host 'Container app name'
        $script:CON = Read-Host 'Container name'
    }

    if ([string]::IsNullOrWhiteSpace($script:SUB) -or
        [string]::IsNullOrWhiteSpace($script:RG)  -or
        [string]::IsNullOrWhiteSpace($script:APP) -or
        [string]::IsNullOrWhiteSpace($script:CON)) {
        Write-Host 'All fields are required (subscription, resource group, container app, container).' -ForegroundColor Red
        exit 1
    }

    $safeSub = $script:SUB -replace "'","''"
    $safeRg  = $script:RG  -replace "'","''"
    $safeApp = $script:APP -replace "'","''"
    $safeCon = $script:CON -replace "'","''"
    Set-Content -Path $StateFile -Value @(
        "`$SUB = '$safeSub'",
        "`$RG  = '$safeRg'",
        "`$APP = '$safeApp'",
        "`$CON = '$safeCon'"
    ) -Encoding UTF8
}

function Ensure-ContainerApp-CLI {
    try {
        & az containerapp -h | Out-Null
    } catch {
        try {
            Write-Host ">> Installing Azure CLI 'containerapp' extension…"
            & az extension add -n containerapp | Out-Null
        } catch {
            Write-Host "(warn) Could not verify or install 'containerapp' commands; continuing anyway." -ForegroundColor DarkYellow
        }
    }
}

function Validate-Targets {
    Write-Host ">> Using subscription: $script:SUB"
    & az account set --subscription $script:SUB | Out-Null

    Write-Host ">> Validating Container App '$script:APP' in '$script:RG'…"
    try {
        & az containerapp show -g $script:RG -n $script:APP -o none
    } catch {
        Write-Host "Container App '$script:APP' not found in resource group '$script:RG'." -ForegroundColor Red
        exit 1
    }

    try {
        $containers = & az containerapp show -g $script:RG -n $script:APP --query "properties.template.containers[].name" -o tsv
        if ($containers) {
            $names = $containers -split "`n"
            if (-not ($names -contains $script:CON)) {
                Write-Host "(warn) Container '$script:CON' not listed in app template. Proceeding anyway." -ForegroundColor DarkYellow
            }
        }
    } catch { }
}

function Strip-ANSI {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return $text }
    $ansiPattern = '\x1B\[[0-9;]*[A-Za-z]'
    return ([regex]::Replace($text, $ansiPattern, ''))
}

function Clean-Exec-Output {
    param([string]$raw)
    $clean = (Strip-ANSI ($raw | Out-String))
    $lines = $clean -split "(`r`n|`n|`r)" | ForEach-Object { $_.Trim() }
    $filtered = $lines | Where-Object {
        $_ -and
        ($_ -notmatch '^\s*INFO:') -and
        ($_ -notmatch 'Use ctrl \+ D to exit') -and
        ($_ -notmatch 'Successfully connected to container') -and
        ($_ -notmatch 'Revision:') -and
        ($_ -notmatch 'Replica:')
    }
    return ($filtered -join "`n")
}

function Exec-Remote {
    param(
        [string]$Command,
        [int]$TimeoutSec = 25
    )

    $azArgs = @(
        'containerapp','exec',
        '--name',          $script:APP,
        '--resource-group',$script:RG,
        '--container',     $script:CON,
        '--command',       $Command
    )

    $job = Start-Job -ScriptBlock {
        param($azArgs)
        & az @azArgs 2>&1
    } -ArgumentList (,$azArgs)

    $completed = Wait-Job $job -Timeout $TimeoutSec
    if (-not $completed) {
        Stop-Job $job -Force | Out-Null
        Remove-Job $job -Force | Out-Null
        throw "az containerapp exec timed out after $TimeoutSec seconds (command: $Command)"
    }

    $raw = Receive-Job $job
    Remove-Job $job | Out-Null

    return (Clean-Exec-Output (($raw -join "`n")))
}

function Pick-Token {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $lines = $text -split "(`r`n|`n|`r)" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $candidates = $lines | Where-Object {
        ($_ -notmatch '^[{[]') -and
        ($_ -notmatch '^(WARNING:|ERROR:|INFO:|Use )') -and
        ($_ -notmatch '\s') -and
        ($_.Length -ge 10)
    }
    if ($candidates -and $candidates.Count -gt 0) { return $candidates[-1] }
    return ''
}

function Read-File-In-Container {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $cmd = "/bin/sh -lc 'cat ""$Path"" 2>/dev/null || true'"
    return (Exec-Remote $cmd).Trim()
}

function Try-NonInteractive {
    $envText = Exec-Remote -Command 'env'
    if (-not $envText) { $envText = Exec-Remote -Command 'printenv' }

    $envMap = @{}
    foreach ($line in ($envText -split "(`r`n|`n|`r)")) {
        if ($line -match '^[A-Za-z_][A-Za-z0-9_]*=') {
            $pair = $line.Split('=',2)
            if ($pair.Count -eq 2) { $envMap[$pair[0]] = $pair[1] }
        }
    }

    if ($envMap.APP_API_TOKEN) { return $envMap.APP_API_TOKEN }
    if ($envMap.DAPR_API_TOKEN) { return $envMap.DAPR_API_TOKEN }

    $file = $envMap.DAPR_API_TOKEN_FILE
    if ([string]::IsNullOrWhiteSpace($file)) { $file = '/var/run/dapr/metadata/token' }
    $fileOut = Read-File-In-Container -Path $file
    return (Pick-Token $fileOut)
}

function Exec-And-Get-Dapr-Token {
    Write-Host ">> Getting dapr token from plain env/file read…"
    $token = Try-NonInteractive

    if (-not $token) {
        Write-Host "Dapr token not found. Ensure the container sets APP_API_TOKEN / DAPR_API_TOKEN, or exposes a readable token file." -ForegroundColor Yellow
        exit 1
    }

    if ($token.Length -lt 20) {
        Write-Host "(warn) Retrieved a very short token ('$token'). Double-check your token configuration." -ForegroundColor DarkYellow
    }

    try {
        Set-Clipboard -Value $token
        Write-Host "✅ Token copied to clipboard." -ForegroundColor Green
    } catch {
        Write-Host "(warn) Could not copy token to clipboard." -ForegroundColor DarkYellow
    }

    if ($PrintToTerminal) {
        Write-Host $token
    }
}

function Main {
    Prompt-Context
    Ensure-ContainerApp-CLI
    Validate-Targets
    Exec-And-Get-Dapr-Token
}

Main
