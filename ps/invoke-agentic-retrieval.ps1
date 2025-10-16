#!/usr/bin/env pwsh
#requires -Version 7
<#
.SYNOPSIS
    Azure AI Search Knowledge Agent Retrieval Tool

.DESCRIPTION
    Interactive tool to perform agentic retrieval queries using Azure AI Search Knowledge Agents.
    Retrieves relevant data from knowledge sources and formats the response beautifully.
    
    Uses the Azure AI Search REST API (2025-08-01-preview) to invoke knowledge agent retrieval
    with natural language queries and optional filters.

.PARAMETER SearchServiceName
    The name of the Azure AI Search service (without .search.windows.net)

.PARAMETER AgentName
    The name of the knowledge agent to query

.PARAMETER Query
    The natural language query text

.PARAMETER KnowledgeSourceName
    Optional: The specific knowledge source to query

.PARAMETER Filter
    Optional: OData filter expression (e.g., "category eq 'tech'")

.EXAMPLE
    # Interactive mode - will prompt for all required information
    .\invoke-agentic-retrieval.ps1

.EXAMPLE
    # Specify all parameters
    .\invoke-agentic-retrieval.ps1 -SearchServiceName "mysearch" -AgentName "my-agent" -Query "What is Azure?"

.EXAMPLE
    # With filter
    .\invoke-agentic-retrieval.ps1 -AgentName "my-agent" -Query "pricing info" -Filter "category eq 'pricing'"

.NOTES
    Requirements:
    - PowerShell 7+
    - Azure CLI authenticated (az login)
    - Cognitive Services User role on the AI Search service
#>

param(
    [string]$SearchServiceName = "",
    [string]$AgentName = "",
    [string]$Query = "",
    [string]$KnowledgeSourceName = "",
    [string]$Filter = ""
)

# Relaunch in pwsh if running under Windows PowerShell (non-Core)
if ($PSVersionTable.PSEdition -ne 'Core') {
  $url = 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/invoke-agentic-retrieval.ps1'
  $tmp = Join-Path $env:TEMP "invoke-agentic-retrieval-$([guid]::NewGuid()).ps1"
  Invoke-WebRequest $url -OutFile $tmp
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp @PSBoundParameters
  exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# State file for remembering last configuration
$StateFile = Join-Path $env:TEMP 'invoke-agentic-retrieval-last.ps1'

# Global variables
$script:SEARCH_ENDPOINT = $null
$script:AGENT_NAME = $null

function Write-Header {
    Write-Host ""
    Write-Host "🤖 Azure AI Search Knowledge Agent Retrieval" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
}

function Load-LastState {
    if (Test-Path -Path $StateFile) {
        try {
            . $StateFile
            $script:SEARCH_ENDPOINT = if ($SEARCH_ENDPOINT) { $SEARCH_ENDPOINT } else { $null }
            $script:AGENT_NAME = if ($AGENT_NAME) { $AGENT_NAME } else { $null }
        } catch {
            # Ignore errors loading state file
        }
    }
}

function Save-State {
    try {
        $safeSearchEndpoint = if ($script:SEARCH_ENDPOINT) { $script:SEARCH_ENDPOINT -replace "'","''" } else { '' }
        $safeAgentName = if ($script:AGENT_NAME) { $script:AGENT_NAME -replace "'","''" } else { '' }
        
        Set-Content -Path $StateFile -Value @(
            "`$SEARCH_ENDPOINT = '$safeSearchEndpoint'",
            "`$AGENT_NAME = '$safeAgentName'"
        )
    } catch {
        # Ignore errors saving state
    }
}

function Get-SearchEndpoint {
    if ($SearchServiceName) {
        $script:SEARCH_ENDPOINT = "https://$SearchServiceName.search.windows.net"
        return $script:SEARCH_ENDPOINT
    }
    
    # Try environment variable
    if ($env:SEARCH_SERVICE_ENDPOINT) {
        $script:SEARCH_ENDPOINT = $env:SEARCH_SERVICE_ENDPOINT
        Write-Host "✅ Using search endpoint from environment" -ForegroundColor Green
        return $script:SEARCH_ENDPOINT
    }
    
    # Prompt user if we have a last known endpoint
    if ($script:SEARCH_ENDPOINT) {
        $reuse = Read-Host "Reuse last search endpoint ($script:SEARCH_ENDPOINT)? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuse) -or $reuse -match '^(y|yes)$') {
            return $script:SEARCH_ENDPOINT
        }
    }
    
    # Manual input
    $searchService = Read-Host "Enter Search Service name (without .search.windows.net)"
    if ($searchService) {
        $script:SEARCH_ENDPOINT = "https://$searchService.search.windows.net"
        return $script:SEARCH_ENDPOINT
    }
    
    throw "Search service endpoint not provided"
}

function Get-AgentName {
    if ($AgentName) {
        $script:AGENT_NAME = $AgentName
        return $script:AGENT_NAME
    }
    
    # Prompt user if we have a last known agent name
    if ($script:AGENT_NAME) {
        $reuse = Read-Host "Reuse last agent name ($script:AGENT_NAME)? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuse) -or $reuse -match '^(y|yes)$') {
            return $script:AGENT_NAME
        }
    }
    
    # Manual input
    $agent = Read-Host "Enter Knowledge Agent name"
    if ($agent) {
        $script:AGENT_NAME = $agent
        return $script:AGENT_NAME
    }
    
    throw "Agent name not provided"
}

function Get-AccessToken {
    Write-Host "🔑 Getting access token..." -ForegroundColor Yellow
    try {
        $token = az account get-access-token --resource "https://search.azure.com" --query "accessToken" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $token) {
            return $token.Trim()
        }
        throw "Failed to get access token"
    } catch {
        Write-Host "❌ Failed to get access token" -ForegroundColor Red
        Write-Host "Please run: az login" -ForegroundColor Yellow
        exit 1
    }
}

function Invoke-AgenticRetrieval {
    param(
        [string]$searchEndpoint,
        [string]$agentName,
        [string]$accessToken,
        [string]$query,
        [string]$knowledgeSourceName = "",
        [string]$filter = ""
    )
    
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "📊 RETRIEVAL REQUEST" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "🔍 Query: $query" -ForegroundColor White
    Write-Host "🤖 Agent: $agentName" -ForegroundColor White
    Write-Host "🌐 Endpoint: $searchEndpoint" -ForegroundColor White
    if ($knowledgeSourceName) {
        Write-Host "📚 Knowledge Source: $knowledgeSourceName" -ForegroundColor White
    }
    if ($filter) {
        Write-Host "🔎 Filter: $filter" -ForegroundColor White
    }
    Write-Host ""
    
    # Build request body
    $requestBody = @{
        messages = @(
            @{
                role = "user"
                content = @(
                    @{
                        type = "text"
                        text = $query
                    }
                )
            }
        )
    }
    
    # Add knowledge source params if specified
    if ($knowledgeSourceName -or $filter) {
        $ksParams = @{
            kind = "searchIndex"
        }
        if ($knowledgeSourceName) {
            $ksParams.knowledgeSourceName = $knowledgeSourceName
        }
        if ($filter) {
            $ksParams.filterAddOn = $filter
        }
        $requestBody.knowledgeSourceParams = @($ksParams)
    }
    
    $jsonBody = $requestBody | ConvertTo-Json -Depth 10
    
    # Display the body being sent for transparency
    Write-Host ""
    Write-Host "📦 Request Body:" -ForegroundColor Cyan
    Write-Host $jsonBody -ForegroundColor Gray
    Write-Host ""
    
    try {
        $apiVersion = "2025-08-01-preview"
        $uri = "${searchEndpoint}/agents('${agentName}')/retrieve?api-version=${apiVersion}"
        $headers = @{
            'Authorization' = "Bearer $accessToken"
            'Content-Type' = 'application/json'
        }
        
        Write-Host "⏳ Sending retrieval request..." -ForegroundColor Yellow
        $startTime = Get-Date
        
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $jsonBody -ErrorAction Stop
        
        $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
        
        Write-Host "✅ Response received in $([math]::Round($elapsed, 0))ms" -ForegroundColor Green
        Write-Host ""
        
        # Format and display response
        Format-RetrievalResponse -response $response
        
        return $true
        
    } catch {
        $statusCode = "Unknown"
        $errorMessage = if ($null -ne $_.Exception -and $null -ne $_.Exception.Message) {
            $_.Exception.Message
        } else {
            "Unknown error occurred"
        }
        $errorBody = $null
        
        # Try to get detailed error from response
        if ($null -ne $_.ErrorDetails -and $null -ne $_.ErrorDetails.Message) {
            try {
                $errorBody = $_.ErrorDetails.Message
                $errorObj = $errorBody | ConvertFrom-Json
                if ($errorObj.error -and $errorObj.error.message) {
                    $errorMessage = $errorObj.error.message
                }
            } catch {
                # Use ErrorDetails as-is
                $errorBody = $_.ErrorDetails.Message
            }
        }
        
        # Try to get status code
        try {
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
        } catch {
            # Keep unknown status
        }
        
        Write-Host ""
        Write-Host "❌ Retrieval failed: HTTP $statusCode" -ForegroundColor Red
        Write-Host "   Error: $errorMessage" -ForegroundColor Red
        
        if ($statusCode -eq 400) {
            Write-Host ""
            Write-Host "💡 Bad Request. This usually means:" -ForegroundColor Yellow
            Write-Host "   1. Invalid request body format" -ForegroundColor Gray
            Write-Host "   2. Agent name or configuration issue" -ForegroundColor Gray
            Write-Host "   3. Knowledge source parameters incorrect" -ForegroundColor Gray
            if ($errorBody) {
                Write-Host ""
                Write-Host "Full error response:" -ForegroundColor Yellow
                Write-Host $errorBody -ForegroundColor Gray
            }
        } elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
            Write-Host ""
            Write-Host "💡 Authentication issue. Try:" -ForegroundColor Yellow
            Write-Host "   1. az login" -ForegroundColor Gray
            Write-Host "   2. Ensure you have Cognitive Services User role" -ForegroundColor Gray
        } elseif ($statusCode -eq 404) {
            Write-Host ""
            Write-Host "💡 Agent or service not found. Check:" -ForegroundColor Yellow
            Write-Host "   1. Agent name is correct" -ForegroundColor Gray
            Write-Host "   2. Search service name is correct" -ForegroundColor Gray
        }
        
        return $false
    }
}

function Format-RetrievalResponse {
    param($response)
    
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "📋 RETRIEVAL RESPONSE" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
    
    # Display main response content
    $hasTextResponse = $false
    if ($response.response -and $response.response.Count -gt 0) {
        foreach ($msg in $response.response) {
            if ($msg.content) {
                foreach ($content in $msg.content) {
                    if ($content.type -eq "text" -and $content.text) {
                        if (-not $hasTextResponse) {
                            Write-Host "💬 Response Content:" -ForegroundColor Green
                            Write-Host ""
                            $hasTextResponse = $true
                        }
                        try {
                            # Try to parse as JSON for prettier display
                            $parsedContent = $content.text | ConvertFrom-Json -ErrorAction Stop
                            Write-Host ($parsedContent | ConvertTo-Json -Depth 10) -ForegroundColor White
                        } catch {
                            # Display as plain text if not JSON
                            Write-Host $content.text -ForegroundColor White
                        }
                    }
                }
            }
        }
        if ($hasTextResponse) {
            Write-Host ""
        }
    }
    
    # Show message if no text response (extractive data mode)
    if (-not $hasTextResponse) {
        Write-Host "💬 Response Content:" -ForegroundColor Green
        Write-Host "   ℹ️  No synthesized response - agent is in extractive data mode" -ForegroundColor Gray
        Write-Host "   📚 Retrieved documents are available in References below for grounding" -ForegroundColor Gray
        Write-Host ""
    }
    
    # Display references
    if ($response.references -and $response.references.Count -gt 0) {
        Write-Host ""
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host "📚 REFERENCES ($($response.references.Count) documents)" -ForegroundColor Cyan
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host ""
        
        for ($i = 0; $i -lt $response.references.Count; $i++) {
            $ref = $response.references[$i]
            Write-Host "[$($i + 1)] Reference ID: $($ref.id)" -ForegroundColor Yellow
            Write-Host "    Type: $($ref.type)" -ForegroundColor White
            
            if ($null -ne $ref.rerankerScore) {
                Write-Host "    Reranker Score: $([math]::Round($ref.rerankerScore, 2))" -ForegroundColor White
            }
            
            if ($ref.docKey) {
                Write-Host "    Document Key: $($ref.docKey)" -ForegroundColor White
            }
            
            if ($ref.activitySource -ne $null) {
                Write-Host "    Activity Source: $($ref.activitySource)" -ForegroundColor Gray
            }
            
            # Display source data if available
            if ($ref.sourceData) {
                Write-Host "    Source Data:" -ForegroundColor Cyan
                $ref.sourceData.PSObject.Properties | ForEach-Object {
                    $value = if ($_.Value -is [string] -and $_.Value.Length -gt 100) {
                        $_.Value.Substring(0, 100) + "..."
                    } else {
                        $_.Value
                    }
                    Write-Host "      $($_.Name): $value" -ForegroundColor Gray
                }
            }
            
            Write-Host ""
        }
    }
    
    # Display activity records
    if ($response.activity -and $response.activity.Count -gt 0) {
        Write-Host ""
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host "⚡ ACTIVITY LOG ($($response.activity.Count) activities)" -ForegroundColor Cyan
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host ""
        
        $totalElapsed = 0
        $totalInputTokens = 0
        $totalOutputTokens = 0
        
        foreach ($activity in $response.activity) {
            $icon = switch ($activity.type) {
                "modelQueryPlanning" { "🧠" }
                "modelAnswerSynthesis" { "✨" }
                "searchIndex" { "🔍" }
                "semanticReranker" { "🎯" }
                default { "📊" }
            }
            
            Write-Host "$icon Activity ID $($activity.id): $($activity.type)" -ForegroundColor Yellow
            
            if ($null -ne $activity.PSObject.Properties['elapsedMs'] -and $null -ne $activity.elapsedMs) {
                Write-Host "   ⏱️  Elapsed: $($activity.elapsedMs)ms" -ForegroundColor White
                $totalElapsed += $activity.elapsedMs
            }
            
            if ($null -ne $activity.PSObject.Properties['inputTokens'] -and $null -ne $activity.inputTokens) {
                Write-Host "   📥 Input Tokens: $($activity.inputTokens)" -ForegroundColor White
                $totalInputTokens += $activity.inputTokens
            }
            
            if ($null -ne $activity.PSObject.Properties['outputTokens'] -and $null -ne $activity.outputTokens) {
                Write-Host "   📤 Output Tokens: $($activity.outputTokens)" -ForegroundColor White
                $totalOutputTokens += $activity.outputTokens
            }
            
            if ($null -ne $activity.PSObject.Properties['knowledgeSourceName'] -and $activity.knowledgeSourceName) {
                Write-Host "   📚 Knowledge Source: $($activity.knowledgeSourceName)" -ForegroundColor White
            }
            
            if ($null -ne $activity.PSObject.Properties['count'] -and $null -ne $activity.count) {
                Write-Host "   📊 Results Count: $($activity.count)" -ForegroundColor White
            }
            
            if ($null -ne $activity.PSObject.Properties['searchIndexArguments'] -and $activity.searchIndexArguments) {
                Write-Host "   🔎 Search Arguments:" -ForegroundColor Cyan
                if ($activity.searchIndexArguments.search) {
                    Write-Host "      Query: $($activity.searchIndexArguments.search)" -ForegroundColor Gray
                }
                if ($activity.searchIndexArguments.filter) {
                    Write-Host "      Filter: $($activity.searchIndexArguments.filter)" -ForegroundColor Gray
                }
            }
            
            if ($null -ne $activity.PSObject.Properties['queryTime'] -and $activity.queryTime) {
                Write-Host "   🕐 Query Time: $($activity.queryTime)" -ForegroundColor Gray
            }
            
            Write-Host ""
        }
        
        # Display totals
        Write-Host ("─" * 60) -ForegroundColor DarkGray
        Write-Host "📊 TOTALS" -ForegroundColor Cyan
        Write-Host "   ⏱️  Total Elapsed: ${totalElapsed}ms" -ForegroundColor White
        if ($totalInputTokens -gt 0) {
            Write-Host "   📥 Total Input Tokens: $totalInputTokens" -ForegroundColor White
        }
        if ($totalOutputTokens -gt 0) {
            Write-Host "   📤 Total Output Tokens: $totalOutputTokens" -ForegroundColor White
        }
        if ($totalInputTokens -gt 0 -or $totalOutputTokens -gt 0) {
            Write-Host "   🎯 Total Tokens: $($totalInputTokens + $totalOutputTokens)" -ForegroundColor White
        }
        Write-Host ""
    }
}

function Main {
    Write-Header
    
    # Load previous state
    Load-LastState
    
    try {
        # Get configuration
        $searchEndpoint = Get-SearchEndpoint
        $agentName = Get-AgentName
        $accessToken = Get-AccessToken
        
        # Get query if not provided
        $queryText = $Query
        if (-not $queryText) {
            Write-Host ""
            $queryText = Read-Host "Enter your query"
            if (-not $queryText) {
                throw "Query not provided"
            }
        }
        
        # Get optional knowledge source name if not provided
        $ksName = $KnowledgeSourceName
        if (-not $ksName) {
            Write-Host ""
            $ksInput = Read-Host "Knowledge Source name (optional, press Enter to skip)"
            if ($ksInput) {
                $ksName = $ksInput
            }
        }
        
        # Get optional filter if not provided
        $filterExpr = $Filter
        if (-not $filterExpr) {
            Write-Host ""
            $filterInput = Read-Host "OData filter (optional, press Enter to skip)"
            if ($filterInput) {
                $filterExpr = $filterInput
            }
        }
        
        # Save state for next time
        Save-State
        
        # Perform retrieval
        $success = Invoke-AgenticRetrieval `
            -searchEndpoint $searchEndpoint `
            -agentName $agentName `
            -accessToken $accessToken `
            -query $queryText `
            -knowledgeSourceName $ksName `
            -filter $filterExpr
        
        if ($success) {
            Write-Host ""
            Write-Host "✅ Retrieval completed successfully!" -ForegroundColor Green
            exit 0
        } else {
            exit 1
        }
        
    } catch {
        Write-Host ""
        # Safely extract error message
        $errorMsg = if ($null -ne $_.Exception -and $null -ne $_.Exception.Message) { 
            $_.Exception.Message 
        } elseif ($null -ne $_) { 
            $_.ToString() 
        } else { 
            "Unknown error occurred" 
        }
        Write-Host "❌ Error: $errorMsg" -ForegroundColor Red
        exit 1
    }
}

Main
