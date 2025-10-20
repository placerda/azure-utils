#!/usr/bin/env pwsh
#requires -Version 7
<#
.SYNOPSIS
    Query Azure Orchestrator (Local or Remote)

.DESCRIPTION
    Interactive tool to query the orchestrator running locally or in Azure Container Apps.
    
    For local orchestrator:
    - Uses localhost:PORT/orchestrator endpoint
    - No authentication required
    
    For remote orchestrator:
    - Retrieves dapr-api-token from Container App
    - Uses HTTPS endpoint with token authentication
    - Supports JSON and streaming responses

.PARAMETER Mode
    Execution mode: "local" or "remote"

.PARAMETER Port
    Port for local orchestrator (default: 8080)

.PARAMETER Query
    The query text to send to the orchestrator

.PARAMETER OrchestratorUrl
    Full orchestrator URL (for remote mode)

.EXAMPLE
    # Interactive mode
    .\invoke-orchestrator.ps1

.EXAMPLE
    # Local mode
    .\invoke-orchestrator.ps1 -Mode local -Query "What is Azure?"

.EXAMPLE
    # Remote mode
    .\invoke-orchestrator.ps1 -Mode remote -Query "Explain containers"

.NOTES
    Requirements:
    - PowerShell 7+
    - For remote: Azure CLI authenticated (az login) with Container App access
#>

param(
    [ValidateSet("local", "remote", "")]
    [string]$Mode = "",
    [int]$Port = 80,
    [string]$Query = "",
    [string]$OrchestratorUrl = ""
)

# Relaunch in pwsh if running under Windows PowerShell (non-Core)
if ($PSVersionTable.PSEdition -ne 'Core') {
  $url = 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/invoke-orchestrator.ps1'
  $tmp = Join-Path $env:TEMP "invoke-orchestrator-$([guid]::NewGuid()).ps1"
  Invoke-WebRequest $url -OutFile $tmp
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp @PSBoundParameters
  exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# State file for remembering last configuration
$StateFile = Join-Path $env:TEMP 'invoke-orchestrator-last.ps1'

# Global variables
$script:MODE = $null
$script:PORT = 80
$script:ORCHESTRATOR_URL = $null
$script:SUB = $null
$script:RG  = $null
$script:APP = $null
$script:CON = $null
$script:TOKEN = $null
$script:CONVERSATION_ID = $null

function Write-Header {
    Write-Host ""
    Write-Host "🎯 Azure Orchestrator Query Tool" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
}

function Load-LastState {
    if (Test-Path -Path $StateFile) {
        try {
            . $StateFile
            # Don't load MODE - always ask for it
            $script:PORT = if ($PORT) { $PORT } else { 80 }
            $script:ORCHESTRATOR_URL = if ($ORCHESTRATOR_URL) { $ORCHESTRATOR_URL } else { $null }
            $script:SUB = if ($SUB) { $SUB } else { $null }
            $script:RG  = if ($RG) { $RG } else { $null }
            $script:APP = if ($APP) { $APP } else { $null }
            $script:CON = if ($CON) { $CON } else { $null }
            $script:TOKEN = if ($TOKEN) { $TOKEN } else { $null }
            $script:CONVERSATION_ID = if ($CONVERSATION_ID) { $CONVERSATION_ID } else { $null }
        } catch {
            # Ignore errors loading state file
        }
    }
}

function Save-State {
    try {
        $safeMode = if ($script:MODE) { $script:MODE } else { '' }
        $safePort = if ($script:PORT) { $script:PORT } else { 80 }
        $safeUrl = if ($script:ORCHESTRATOR_URL) { $script:ORCHESTRATOR_URL -replace "'","''" } else { '' }
        $safeSub = if ($script:SUB) { $script:SUB -replace "'","''" } else { '' }
        $safeRg  = if ($script:RG) { $script:RG -replace "'","''" } else { '' }
        $safeApp = if ($script:APP) { $script:APP -replace "'","''" } else { '' }
        $safeCon = if ($script:CON) { $script:CON -replace "'","''" } else { '' }
        $safeToken = if ($script:TOKEN) { $script:TOKEN -replace "'","''" } else { '' }
        $safeConvId = if ($script:CONVERSATION_ID) { $script:CONVERSATION_ID -replace "'","''" } else { '' }
        
        Set-Content -Path $StateFile -Value @(
            "`$MODE = '$safeMode'",
            "`$PORT = $safePort",
            "`$ORCHESTRATOR_URL = '$safeUrl'",
            "`$SUB = '$safeSub'",
            "`$RG = '$safeRg'",
            "`$APP = '$safeApp'",
            "`$CON = '$safeCon'",
            "`$TOKEN = '$safeToken'",
            "`$CONVERSATION_ID = '$safeConvId'"
        )
    } catch {
        # Ignore errors saving state
    }
}

function Get-ExecutionMode {
    if ($Mode) {
        $script:MODE = $Mode.ToLower()
        return $script:MODE
    }
    
    # Always ask for mode - don't reuse from last time
    Write-Host ""
    Write-Host "Select execution mode:" -ForegroundColor Cyan
    Write-Host "  1. Local (localhost:80)" -ForegroundColor White
    Write-Host "  2. Remote (Azure Container App)" -ForegroundColor White
    $choice = Read-Host "Enter choice [1 or 2] (default: 1)"
    
    # Default to option 1 if empty
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = "1"
    }
    
    if ($choice -eq "1") {
        $script:MODE = "local"
    } elseif ($choice -eq "2") {
        $script:MODE = "remote"
    } else {
        throw "Invalid choice. Please enter 1 or 2"
    }
    
    return $script:MODE
}

function Get-LocalPort {
    if ($Port -ne 80) {
        $script:PORT = $Port
        return $script:PORT
    }
    
    # Always use port 80 for local mode
    $script:PORT = 80
    return $script:PORT
}

function Get-RemoteOrchestratorUrl {
    # Check if we have a cached URL
    if ($script:ORCHESTRATOR_URL) {
        Write-Host ""
        Write-Host "Last orchestrator URL: " -NoNewline
        Write-Host $script:ORCHESTRATOR_URL -ForegroundColor Cyan
        $reuse = Read-Host "Use this URL? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuse) -or $reuse -match '^(y|yes)$') {
            # Ensure cached URL has /orchestrator
            $url = $script:ORCHESTRATOR_URL.TrimEnd('/')
            if (-not $url.EndsWith('/orchestrator')) {
                $url = "$url/orchestrator"
                $script:ORCHESTRATOR_URL = $url
            }
            return $script:ORCHESTRATOR_URL
        }
    }
    
    Write-Host ""
    $url = Read-Host "Enter orchestrator app URL (e.g., https://ca-xxx-orchestrator.braveforest-3fb05aff.eastus2.azurecontainerapps.io)"
    
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Orchestrator URL not provided"
    }
    
    # Remove trailing slash if present
    $url = $url.TrimEnd('/')
    
    # Add /orchestrator path if not already present
    if (-not $url.EndsWith('/orchestrator')) {
        $url = "$url/orchestrator"
    }
    
    $script:ORCHESTRATOR_URL = $url
    
    # Extract app name and container name from URL
    # URL format: https://{appName}.{suffix}.{region}.azurecontainerapps.io/orchestrator
    # App name format: ca-{xxx}-{containerName}
    # The full app name is everything before the first dot (e.g., ca-l33fakstb3n3g-orchestrator)
    if ($url -match 'https?://([^./]+)\.') {
        $script:APP = $Matches[1]
        
        # Extract container name from app name (everything after last hyphen)
        # e.g., ca-l33fakstb3n3g-orchestrator -> orchestrator
        if ($script:APP -match '-([^-]+)$') {
            $script:CON = $Matches[1]
        }
    }
    
    return $script:ORCHESTRATOR_URL
}

function Get-ContainerAppDetails {
    Write-Host ""
    Write-Host "🔧 Container App Configuration" -ForegroundColor Cyan
    
    # Show app name and container name if derived from URL
    if ($script:APP) {
        Write-Host "Container App Name: " -NoNewline
        Write-Host $script:APP -ForegroundColor Yellow -NoNewline
        Write-Host " (from URL)"
    }
    
    if ($script:CON) {
        Write-Host "Container Name: " -NoNewline
        Write-Host $script:CON -ForegroundColor Yellow -NoNewline
        Write-Host " (from URL)"
    }
    
    # Subscription
    if ($script:SUB) {
        $reuse = Read-Host "Reuse subscription '$script:SUB'? [Y/n]"
        if ($reuse -match '^(n|no)$') { $script:SUB = Read-Host 'Subscription ID or name' }
    } else {
        $script:SUB = Read-Host 'Subscription ID or name'
    }

    # Resource Group
    if ($script:RG) {
        $reuse = Read-Host "Reuse resource group '$script:RG'? [Y/n]"
        if ($reuse -match '^(n|no)$') { $script:RG = Read-Host 'Resource group name' }
    } else {
        $script:RG = Read-Host 'Resource group name'
    }
    
    # Return details as hashtable
    return @{
        subscription = $script:SUB
        resourceGroup = $script:RG
        appName = $script:APP
        containerName = $script:CON
    }
}

function Get-ConversationId {
    # Check if we have a cached conversation ID
    if ($script:CONVERSATION_ID) {
        Write-Host ""
        Write-Host "Last conversation ID: " -NoNewline
        Write-Host $script:CONVERSATION_ID -ForegroundColor Cyan
        $reuse = Read-Host "Use this conversation ID? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuse) -or $reuse -match '^(y|yes)$') {
            return $script:CONVERSATION_ID
        }
    }
    
    Write-Host ""
    $convId = Read-Host "Enter conversation ID (leave empty for new conversation)"
    
    # Store the conversation ID (even if empty)
    $script:CONVERSATION_ID = $convId
    
    return $script:CONVERSATION_ID
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
        [hashtable]$ContainerAppDetails,
        [int]$TimeoutSec = 25
    )

    $azArgs = @(
        'containerapp','exec',
        '--name',          $ContainerAppDetails.appName,
        '--resource-group',$ContainerAppDetails.resourceGroup,
        '--container',     $ContainerAppDetails.containerName,
        '--command',       $Command
    )

    $job = Start-Job -ScriptBlock {
        param($azArgs)
        & az @azArgs 2>&1
    } -ArgumentList (,$azArgs)

    $completed = Wait-Job $job -Timeout $TimeoutSec
    if (-not $completed) {
        Stop-Job $job | Out-Null
        Remove-Job $job | Out-Null
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
    param(
        [string]$Path,
        [hashtable]$ContainerAppDetails
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $cmd = "/bin/sh -lc 'cat ""$Path"" 2>/dev/null || true'"
    return (Exec-Remote -Command $cmd -ContainerAppDetails $ContainerAppDetails).Trim()
}

function Get-DaprToken {
    param(
        [hashtable]$ContainerAppDetails
    )
    
    # Check if we have a cached token
    if ($script:TOKEN) {
        Write-Host ""
        $reuseToken = Read-Host "Reuse cached Dapr token? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseToken) -or $reuseToken -match '^(y|yes)$') {
            Write-Host "✅ Using cached token" -ForegroundColor Green
            return $script:TOKEN
        }
    }
    
    Write-Host ""
    Write-Host "🔑 Getting Dapr API token from Container App..." -ForegroundColor Yellow
    Write-Host "   (This may take a moment...)" -ForegroundColor Gray
    
    # Use provided details
    $sub = $ContainerAppDetails.subscription
    $rg = $ContainerAppDetails.resourceGroup
    $app = $ContainerAppDetails.appName
    $con = $ContainerAppDetails.containerName

    # Set subscription
    Write-Host "   Setting subscription..." -ForegroundColor Gray
    & az account set --subscription $sub | Out-Null

    # Get token from container
    Write-Host "   Retrieving token..." -ForegroundColor Gray
    $envText = Exec-Remote -Command 'env' -ContainerAppDetails $ContainerAppDetails
    if (-not $envText) { $envText = Exec-Remote -Command 'printenv' -ContainerAppDetails $ContainerAppDetails }

    $envMap = @{}
    foreach ($line in ($envText -split "(`r`n|`n|`r)")) {
        if ($line -match '^[A-Za-z_][A-Za-z0-9_]*=') {
            $pair = $line.Split('=',2)
            if ($pair.Count -eq 2) { $envMap[$pair[0]] = $pair[1] }
        }
    }

    $token = $null
    if ($envMap.APP_API_TOKEN) { $token = $envMap.APP_API_TOKEN }
    elseif ($envMap.DAPR_API_TOKEN) { $token = $envMap.DAPR_API_TOKEN }
    else {
        $file = $envMap.DAPR_API_TOKEN_FILE
        if ([string]::IsNullOrWhiteSpace($file)) { $file = '/var/run/dapr/metadata/token' }
        $fileOut = Read-File-In-Container -Path $file -ContainerAppDetails $ContainerAppDetails
        $token = Pick-Token $fileOut
    }

    if (-not $token) {
        throw "Dapr token not found in container. Ensure APP_API_TOKEN or DAPR_API_TOKEN is set."
    }

    Write-Host "✅ Token retrieved successfully" -ForegroundColor Green
    
    # Cache the token
    $script:TOKEN = $token
    
    return $token
}

function Invoke-OrchestratorQuery {
    param(
        [string]$mode,
        [string]$url,
        [string]$query,
        [string]$conversationId = "",
        [string]$token = $null
    )
    
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "📊 ORCHESTRATOR REQUEST" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "🔍 Query: $query" -ForegroundColor White
    Write-Host "🌐 Mode: $mode" -ForegroundColor White
    Write-Host "🔗 URL: $url" -ForegroundColor White
    Write-Host ""
    
    # Build request
    $headers = @{
        'Content-Type' = 'application/json'
    }
    
    if ($mode -eq "local") {
        $headers['dapr-api-token'] = 'dev-token'
        Write-Host "🔐 Using local dev-token authentication" -ForegroundColor Gray
    } elseif ($mode -eq "remote" -and $token) {
        $headers['dapr-api-token'] = $token
        Write-Host "🔐 Using remote Dapr API token authentication" -ForegroundColor Gray
    }
    
    # Build body following OrchestratorRequest schema
    $body = @{
        ask = $query
        conversation_id = $conversationId
        client_principal_id = ""
        client_principal_name = ""
        client_group_names = @()
        access_token = ""
    } | ConvertTo-Json -Depth 10
    
    # Display the body being sent for transparency
    Write-Host ""
    Write-Host "📦 Request Body:" -ForegroundColor Cyan
    Write-Host $body -ForegroundColor Gray
    Write-Host ""
    
    try {
        Write-Host "⏳ Sending request..." -ForegroundColor Yellow
        $startTime = Get-Date
        
        # Make the request and capture response
        $response = Invoke-WebRequest -Uri $url -Method POST -Headers $headers -Body $body -ErrorAction Stop
        
        $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
        
        Write-Host "✅ Response received in $([math]::Round($elapsed, 0))ms" -ForegroundColor Green
        Write-Host ""
        
        # Format and display response
        Format-OrchestratorResponse -response $response
        
        return $true
        
    } catch {
        $statusCode = "Unknown"
        $errorMessage = $_.Exception.Message
        
        try {
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
                $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $errorBody = $reader.ReadToEnd()
                $reader.Close()
                
                $errorMessage = $errorBody
            }
        } catch {
            # Use original error message
        }
        
        Write-Host ""
        Write-Host "❌ Request failed: HTTP $statusCode" -ForegroundColor Red
        Write-Host "   Error: $errorMessage" -ForegroundColor Red
        
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            Write-Host ""
            Write-Host "💡 Authentication issue. Check:" -ForegroundColor Yellow
            Write-Host "   1. Dapr API token is correct" -ForegroundColor Gray
            Write-Host "   2. Token has not expired" -ForegroundColor Gray
        } elseif ($statusCode -eq 404) {
            Write-Host ""
            Write-Host "💡 Endpoint not found. Check:" -ForegroundColor Yellow
            Write-Host "   1. URL is correct" -ForegroundColor Gray
            Write-Host "   2. Orchestrator is running" -ForegroundColor Gray
        }
        
        return $false
    }
}

function Format-OrchestratorResponse {
    param($response)
    
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "📋 ORCHESTRATOR RESPONSE" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
    
    $contentType = $response.Headers.'Content-Type'
    Write-Host "📄 Content-Type: $contentType" -ForegroundColor Gray
    Write-Host "📊 Status Code: $($response.StatusCode)" -ForegroundColor Gray
    Write-Host ""
    
    $content = $response.Content
    
    # Check if content is JSON
    if ($contentType -match 'application/json') {
        try {
            $jsonObj = $content | ConvertFrom-Json
            Write-Host "💬 Response (JSON):" -ForegroundColor Green
            Write-Host ""
            Write-Host ($jsonObj | ConvertTo-Json -Depth 10) -ForegroundColor White
        } catch {
            Write-Host "💬 Response (Raw):" -ForegroundColor Green
            Write-Host ""
            Write-Host $content -ForegroundColor White
        }
    }
    # Check if content is streaming (text/event-stream or ndjson)
    elseif ($contentType -match '(text/event-stream|application/x-ndjson|text/plain)') {
        Write-Host "📡 Response (Streaming):" -ForegroundColor Green
        Write-Host ""
        
        # Split by lines and format each
        $lines = $content -split "`n"
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed) {
                # Try to parse as JSON
                if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
                    try {
                        $jsonLine = $trimmed | ConvertFrom-Json
                        Write-Host "  📦 " -NoNewline -ForegroundColor Cyan
                        Write-Host ($jsonLine | ConvertTo-Json -Compress) -ForegroundColor White
                    } catch {
                        Write-Host "  ▸ $trimmed" -ForegroundColor White
                    }
                } else {
                    Write-Host "  ▸ $trimmed" -ForegroundColor White
                }
            }
        }
    }
    # Plain text or unknown
    else {
        Write-Host "💬 Response:" -ForegroundColor Green
        Write-Host ""
        Write-Host $content -ForegroundColor White
    }
    
    Write-Host ""
}

function Main {
    Write-Header
    
    # Load previous state
    Load-LastState
    
    try {
        # Get execution mode
        $mode = Get-ExecutionMode
        
        # Build URL based on mode
        $url = $null
        $token = $null
        
        if ($mode -eq "local") {
            $port = Get-LocalPort
            Write-Host ""
            Write-Host "📍 Using port: $port" -ForegroundColor Cyan
            $url = "http://localhost:${port}/orchestrator"
        } else {
            $url = Get-RemoteOrchestratorUrl
            Write-Host ""
            Write-Host "📍 Using URL: " -NoNewline
            Write-Host $url -ForegroundColor Cyan
            $containerAppDetails = Get-ContainerAppDetails
            $token = Get-DaprToken -ContainerAppDetails $containerAppDetails
        }
        
        # Get query if not provided
        $queryText = $Query
        if (-not $queryText) {
            Write-Host ""
            $queryText = Read-Host "Enter your query"
            if (-not $queryText) {
                throw "Query not provided"
            }
        }
        
        # Get conversation ID
        $conversationId = Get-ConversationId
        
        # Save state for next time
        Save-State
        
        # Perform query
        $success = Invoke-OrchestratorQuery `
            -mode $mode `
            -url $url `
            -query $queryText `
            -conversationId $conversationId `
            -token $token
        
        if ($success) {
            Write-Host ""
            Write-Host "✅ Query completed successfully!" -ForegroundColor Green
            exit 0
        } else {
            exit 1
        }
        
    } catch {
        Write-Host ""
        Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Main
