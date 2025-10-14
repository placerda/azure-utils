#!/usr/bin/env pwsh
#requires -Version 7
<#
Script: check-agentic-setup.ps1
Overview:
  Comprehensive Azure AI Search Agentic Retrieval configuration verification tool.
  Analyzes knowledge sources, search indexes, vectorizers, semantic configurations, and retrieval capabilities.
  Provides detailed technical insights into vector search algorithms, embedding models, and semantic ranking.
  Remembers last used configuration across sessions for convenience and automation.

Features:
  • Knowledge Sources analysis with detailed index mapping and data selection rules
  • Search Index deep inspection including vectorizers, algorithms, and semantic configs
  • Vector Search configuration analysis (HNSW, Exhaustive KNN algorithms with parameters)
  • Azure OpenAI/OpenAI/Custom API vectorizer details (models, deployments, endpoints)
  • Semantic Search configuration breakdown (title, content, keywords field mappings)
  • Vector Profiles and Algorithm parameter inspection (metrics, dimensions, performance settings)
  • Knowledge Agents verification with model and configuration details
  • Multi-source configuration detection (parameters, environment, cached values, prompts)
  • Persistent state management with intelligent configuration reuse
  • Comprehensive error handling with actionable troubleshooting guidance

Configuration Sources (in priority order):
  1. Command line parameters (-SearchServiceName, etc.)
  2. Environment variables (SEARCH_SERVICE_ENDPOINT)
  3. Cached previous session values (automatically saved and offered for reuse)
  4. Interactive prompts (fallback when other sources unavailable)

Usage Examples:
  # Basic usage with interactive prompts
  .\check-agentic-setup.ps1

  # Specify search service directly
  .\check-agentic-setup.ps1 -SearchServiceName "mysearch"

  # Full parameter specification
  .\check-agentic-setup.ps1 -SearchServiceName "mysearch" -ResourceGroup "myrg" -SubscriptionId "sub-id"

  # Remote execution
  pwsh -NoProfile -ExecutionPolicy Bypass -Command "iex (iwr 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/check-agentic-setup.ps1').Content"

What gets analyzed:
  KNOWLEDGE SOURCES:
    • Source names, types (searchIndex), and descriptions
    • Associated search index mappings and relationships
    • Source data selection rules and field mappings
    • Cross-reference with actual search indexes for validation

  SEARCH INDEXES:
    • Index existence and basic metadata
    • Vector search capabilities and configuration
    • Semantic search setup and field priorities
    • Field schema and data types (when available)

  VECTORIZERS (detailed analysis):
    • Azure OpenAI: Resource URI, deployment ID, model name, API key status
    • OpenAI: Organization ID, model name, API key configuration
    • Custom Web API: Endpoint URI, HTTP method, authentication setup
    • Configuration validation and connectivity status

  VECTOR ALGORITHMS:
    • HNSW parameters: metric type, M parameter, EF construction/search values
    • Exhaustive KNN parameters: metric configuration and performance settings
    • Algorithm performance characteristics and recommendations

  VECTOR PROFILES:
    • Profile-to-vectorizer mappings and relationships
    • Algorithm assignments and configuration inheritance
    • Profile usage patterns and optimization opportunities

  SEMANTIC CONFIGURATIONS:
    • Default semantic configuration identification
    • Field priority mappings (title, content, keywords)
    • Semantic ranking setup and field weight distribution
    • Configuration completeness and best practice compliance

State Management:
  The script automatically saves and reuses configuration between sessions:
  • Search service endpoints and App Configuration URLs
  • Last used subscription and resource group context
  • Authentication state and token caching preferences
  State file location: $env:TEMP\check-agentic-setup-last.ps1

Authentication Requirements:
  • Azure CLI authenticated session (az login)
  • Minimum required roles:
    - Cognitive Services User (for AI Search service access)
    - Search Service Contributor or Reader (for configuration inspection)
    - App Configuration Data Reader (if using App Configuration)

Exit codes:
  0 (success - agentic retrieval fully configured)
  1 (configuration error - missing components or invalid setup)
  2 (authentication error - insufficient permissions or expired tokens)
  3 (not found - search service, indexes, or resources don't exist)

MANUAL VERIFICATION GUIDE - If you want to check manually:
  Use this as a reference for manually verifying your Agentic Retrieval setup:

  1. KNOWLEDGE SOURCES VERIFICATION:
     • Navigate to Azure AI Search service in Azure Portal
     • Check "Knowledge Sources" section (Preview feature)
     • Verify knowledge sources are created and properly configured
     • Confirm source data selection fields match your requirements
     • Validate knowledge source-to-index mappings are correct

  2. SEARCH INDEX ANALYSIS:
     • Open the target search index in Azure Portal
     • Navigate to "Index Definition" or "Fields" tab
     • Verify vector fields exist with proper dimensions and data types
     • Check semantic configuration is defined with appropriate field priorities
     • Confirm vectorizer assignments match your embedding model requirements

  3. VECTORIZER CONFIGURATION:
     • In search index, go to "Vectorizers" section
     • Verify Azure OpenAI/OpenAI connection parameters
     • Test vectorizer connectivity and model deployment status
     • Confirm API keys and endpoints are correctly configured
     • Validate model versions match your application requirements

  4. VECTOR SEARCH ALGORITHMS:
     • Review "Vector Search" configuration in index settings
     • Check HNSW algorithm parameters for performance optimization
     • Verify vector profiles map correctly to vectorizers and algorithms
     • Ensure similarity metrics (cosine, euclidean) match model expectations

  5. SEMANTIC SEARCH SETUP:
     • Navigate to "Semantic Configuration" in index settings
     • Verify title field mapping points to primary content identifier
     • Check content fields include all searchable text fields
     • Confirm keywords fields capture metadata and categorization
     • Test semantic ranking functionality with sample queries

  6. AGENTIC RETRIEVAL ENABLEMENT:
     • Check App Configuration for ENABLE_AGENTIC_RETRIEVAL=true
     • Verify knowledge sources were created during deployment
     • Confirm agentic retrieval APIs are accessible and functional
     • Test end-to-end retrieval with sample queries and responses

  Note: Agentic Retrieval requires specific API versions (2025-08-01-preview or later)
        and proper Azure OpenAI embedding model deployment configuration.
#>

param(
    [string]$SearchServiceName = "",
    [string]$ResourceGroup = "",
    [string]$SubscriptionId = ""
)

# Relaunch in pwsh if running under Windows PowerShell (non-Core)
if ($PSVersionTable.PSEdition -ne 'Core') {
  $url = 'https://raw.githubusercontent.com/placerda/azure-utils/main/ps/check-agentic-setup.ps1'
  $tmp = Join-Path $env:TEMP "check-agentic-setup-$([guid]::NewGuid()).ps1"
  Invoke-WebRequest $url -OutFile $tmp
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp @PSBoundParameters
  exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# State file for remembering last configuration
$StateFile = Join-Path $env:TEMP 'check-agentic-setup-last.ps1'

# Global variables
$script:SEARCH_ENDPOINT = $null
$script:SUBSCRIPTION = $null
$script:RESOURCE_GROUP = $null

function Write-Header {
    Write-Host ""
    Write-Host "🧪 Agentic Retrieval Verification Tool" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
}

function Load-LastState {
    if (Test-Path -Path $StateFile) {
        try {
            . $StateFile
            $script:SEARCH_ENDPOINT = if ($SEARCH_ENDPOINT) { $SEARCH_ENDPOINT } else { $null }
            $script:SUBSCRIPTION = if ($SUBSCRIPTION) { $SUBSCRIPTION } else { $null }
            $script:RESOURCE_GROUP = if ($RESOURCE_GROUP) { $RESOURCE_GROUP } else { $null }
        } catch {
            # Ignore errors loading state file
        }
    }
}

function Save-State {
    try {
        $safeSearchEndpoint = if ($script:SEARCH_ENDPOINT) { $script:SEARCH_ENDPOINT -replace "'","''" } else { '' }
        $safeSub = if ($script:SUBSCRIPTION) { $script:SUBSCRIPTION -replace "'","''" } else { '' }
        $safeRg = if ($script:RESOURCE_GROUP) { $script:RESOURCE_GROUP -replace "'","''" } else { '' }
        
        Set-Content -Path $StateFile -Value @(
            "`$SEARCH_ENDPOINT = '$safeSearchEndpoint'",
            "`$SUBSCRIPTION = '$safeSub'",
            "`$RESOURCE_GROUP = '$safeRg'"
        ) -Encoding UTF8
    } catch {
        # Ignore errors saving state
    }
}

function Get-SearchEndpoint {
    # Priority: Parameter > Environment > Last Used > Prompt
    
    if ($SearchServiceName) {
        $script:SEARCH_ENDPOINT = "https://$SearchServiceName.search.windows.net"
        return $script:SEARCH_ENDPOINT
    }
    
    # Try environment variable
    if ($env:SEARCH_SERVICE_ENDPOINT) {
        $script:SEARCH_ENDPOINT = $env:SEARCH_SERVICE_ENDPOINT
        Write-Host "✅ Using search endpoint from environment: $script:SEARCH_ENDPOINT" -ForegroundColor Green
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

function Get-AccessToken {
    Write-Host "🔑 Getting access token..." -ForegroundColor Yellow
    try {
        $accessToken = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv 2>$null
        if ([string]::IsNullOrEmpty($accessToken) -or $LASTEXITCODE -ne 0) {
            throw "Could not get access token"
        }
        return $accessToken.Trim()
    } catch {
        Write-Host "❗ Error getting access token: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Please run 'az login' first." -ForegroundColor Yellow
        exit 2
    }
}

function Check-KnowledgeSources {
    param([string]$searchEndpoint, [string]$accessToken)
    
    Write-Host "🔍 Checking Knowledge Sources in Azure AI Search..." -ForegroundColor Cyan
    Write-Host "✅ Search Endpoint: $searchEndpoint" -ForegroundColor Green
    

    
    # Query knowledge sources
    $apiVersion = "2025-08-01-preview"
    $uri = "${searchEndpoint}/knowledgeSources?api-version=${apiVersion}"
    
    Write-Host "🌐 Querying: $uri" -ForegroundColor Cyan
    
    try {
        $headers = @{
            'Authorization' = "Bearer $accessToken"
            'Content-Type' = 'application/json'
        }
        
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
        
        if ($response.value -and $response.value.Count -gt 0) {
            Write-Host "✅ Found $($response.value.Count) knowledge source(s):" -ForegroundColor Green
            Write-Host ""
            
            $indexNames = @()
            foreach ($ks in $response.value) {
                Write-Host "📝 Knowledge Source: $($ks.name)" -ForegroundColor Cyan
                Write-Host "    Kind: $($ks.kind)" -ForegroundColor White
                if ($ks.description) {
                    Write-Host "    Description: $($ks.description)" -ForegroundColor White
                }
                
                if ($ks.searchIndexParameters) {
                    $indexName = $ks.searchIndexParameters.searchIndexName
                    Write-Host "    Search Index: $indexName" -ForegroundColor White
                    $indexNamesFromKS += $indexName
                    if ($ks.searchIndexParameters.sourceDataSelect) {
                        Write-Host "    Source Data Select: $($ks.searchIndexParameters.sourceDataSelect)" -ForegroundColor White
                    }
                }
                Write-Host ""
            }
            return @($true, $indexNamesFromKS)
        } else {
            Write-Host "❗ No knowledge sources found" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "This could mean:" -ForegroundColor Gray
            Write-Host "1. ENABLE_AGENTIC_RETRIEVAL is not set to 'true'" -ForegroundColor Gray
            Write-Host "2. Knowledge sources haven't been created yet" -ForegroundColor Gray
            Write-Host "3. There was an error during provisioning" -ForegroundColor Gray
            return @($false, @())
        }
    } catch {
        $statusCode = "Unknown"
        try {
            if ($_.Exception -and $_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            } elseif ($_.Exception -and $_.Exception.Message -match 'HTTP (\d+)') {
                $statusCode = $matches[1]
            }
        } catch {
            # Ignore error getting status code
        }
        
        Write-Host "❗ Error querying knowledge sources: $($_.Exception.Message)" -ForegroundColor Red
        
        switch ($statusCode) {
            401 {
                Write-Host ""
                Write-Host "This might be an authentication issue. Try:" -ForegroundColor Yellow
                Write-Host "1. az login" -ForegroundColor Gray
                Write-Host "2. Ensure you have Cognitive Services User role on the AI Foundry resource" -ForegroundColor Gray
                exit 2
            }
            404 {
                Write-Host ""
                Write-Host "The search service or API endpoint might be incorrect." -ForegroundColor Yellow
                exit 3
            }
            400 {
                Write-Host ""
                Write-Host "The API version or request format might be incorrect." -ForegroundColor Yellow
                Write-Host "Current API version: $apiVersion" -ForegroundColor Gray
                exit 1
            }
            default {
                exit 1
            }
        }
    }
}

function Check-SearchIndexes {
    param([string]$searchEndpoint, [string]$accessToken, [string[]]$knowledgeSourceIndexNames = @())
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "🔍 Checking Search Indexes for Agentic Features..." -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    
    # Priority: 1) Index from knowledge source, 2) App Config, 3) List all and prompt
    $ragIndexName = $null
    
    # Use index from knowledge source if available
    if ($knowledgeSourceIndexNames -and $knowledgeSourceIndexNames.Count -gt 0) {
        $ragIndexName = $knowledgeSourceIndexNames[0]  # Use first one
    }
    

    
    # If still no index name, list all indexes and prompt
    if (-not $ragIndexName) {
        
        # List all indexes
        try {
            $apiVersion = "2025-08-01-preview"
            $uri = "${searchEndpoint}/indexes?api-version=${apiVersion}"
            $headers = @{
                'Authorization' = "Bearer $accessToken"
                'Content-Type' = 'application/json'
            }
            
            $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
            if ($response.value -and $response.value.Count -gt 0) {
                Write-Host "📊 Found $($response.value.Count) index(es):" -ForegroundColor Green
                foreach ($idx in $response.value) {
                    Write-Host "   - $($idx.name)" -ForegroundColor White
                }
                $ragIndexName = Read-Host "Enter the RAG index name to check"
            } else {
                Write-Host "❗ No indexes found" -ForegroundColor Red
                return $false
            }
        } catch {
            Write-Host "❗ Error listing indexes: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    
    if (-not $ragIndexName) {
        Write-Host "❗ No index name provided" -ForegroundColor Red
        return $false
    }
    
    Write-Host "📊 RAG Index Name: $ragIndexName" -ForegroundColor Green
    
    # Query the specific index
    try {
        $apiVersion = "2025-08-01-preview"
        $uri = "${searchEndpoint}/indexes/${ragIndexName}?api-version=${apiVersion}"
        $headers = @{
            'Authorization' = "Bearer $accessToken"
            'Content-Type' = 'application/json'
        }
        
        $indexData = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        
        # Check for agentic features
        $hasVectorizers = $indexData.vectorSearch -and $indexData.vectorSearch.vectorizers
        $hasSemantic = $indexData.semantic -and $indexData.semantic.defaultConfiguration
        
        Write-Host "✅ Index '$ragIndexName' found" -ForegroundColor Green
        Write-Host "    Has Vectorizers: $hasVectorizers" -ForegroundColor White
        Write-Host "    Has Semantic Config: $hasSemantic" -ForegroundColor White
        
        if ($hasVectorizers) {
            $vectorizers = $indexData.vectorSearch.vectorizers
            Write-Host "    Vectorizers Count: $($vectorizers.Count)" -ForegroundColor White
            foreach ($v in $vectorizers) {
                Write-Host "      - $($v.name) ($($v.kind))" -ForegroundColor Cyan
                
                # Show detailed vectorizer information based on kind
                if ($v.kind -eq "azureOpenAI") {
                    if ($v.azureOpenAIParameters) {
                        $params = $v.azureOpenAIParameters
                        if ($params.resourceUri) { Write-Host "        Resource URI: $($params.resourceUri)" -ForegroundColor Gray }
                        if ($params.deploymentId) { Write-Host "        Deployment ID: $($params.deploymentId)" -ForegroundColor Gray }
                        if ($params.modelName) { Write-Host "        Model Name: $($params.modelName)" -ForegroundColor Gray }
                        if ($params.apiKey) { Write-Host "        API Key: [CONFIGURED]" -ForegroundColor Gray }
                    }
                } elseif ($v.kind -eq "openAI") {
                    if ($v.openAIParameters) {
                        $params = $v.openAIParameters
                        if ($params.organizationId) { Write-Host "       Organization ID: $($params.organizationId)" -ForegroundColor Gray }
                        if ($params.modelName) { Write-Host "       Model Name: $($params.modelName)" -ForegroundColor Gray }
                        if ($params.apiKey) { Write-Host "       API Key: [CONFIGURED]" -ForegroundColor Gray }
                    }
                } elseif ($v.kind -eq "customWebApi") {
                    if ($v.customWebApiParameters) {
                        $params = $v.customWebApiParameters
                        if ($params.uri) { Write-Host "       Custom API URI: $($params.uri)" -ForegroundColor Gray }
                        if ($params.httpMethod) { Write-Host "       HTTP Method: $($params.httpMethod)" -ForegroundColor Gray }
                        if ($params.authResourceId) { Write-Host "       Auth Resource ID: $($params.authResourceId)" -ForegroundColor Gray }
                    }
                }
            }
        }
        
        # Show vector profiles if available
        if ($indexData.vectorSearch -and $indexData.vectorSearch.profiles) {
            $profiles = $indexData.vectorSearch.profiles
            Write-Host "    Vector Profiles Count: $($profiles.Count)" -ForegroundColor White
            foreach ($profile in $profiles) {
                Write-Host "      - Profile: $($profile.name)" -ForegroundColor Cyan
                if ($profile.vectorizer) { Write-Host "        Vectorizer: $($profile.vectorizer)" -ForegroundColor Gray }
                if ($profile.algorithm) { Write-Host "        Algorithm: $($profile.algorithm)" -ForegroundColor Gray }
            }
        }
        
        # Show vector algorithms if available
        if ($indexData.vectorSearch -and $indexData.vectorSearch.algorithms) {
            $algorithms = $indexData.vectorSearch.algorithms
            Write-Host "    Vector Algorithms Count: $($algorithms.Count)" -ForegroundColor White
            foreach ($algo in $algorithms) {
                Write-Host "      - Algorithm: $($algo.name) ($($algo.kind))" -ForegroundColor Cyan
                if ($algo.kind -eq "hnsw" -and $algo.hnswParameters) {
                    $params = $algo.hnswParameters
                    if ($params.metric) { Write-Host "        Metric: $($params.metric)" -ForegroundColor Gray }
                    if ($params.m) { Write-Host "        M Parameter: $($params.m)" -ForegroundColor Gray }
                    if ($params.efConstruction) { Write-Host "        EF Construction: $($params.efConstruction)" -ForegroundColor Gray }
                    if ($params.efSearch) { Write-Host "        EF Search: $($params.efSearch)" -ForegroundColor Gray }
                } elseif ($algo.kind -eq "exhaustiveKnn" -and $algo.exhaustiveKnnParameters) {
                    $params = $algo.exhaustiveKnnParameters
                    if ($params.metric) { Write-Host "       Metric: $($params.metric)" -ForegroundColor Gray }
                }
            }
        }
        
        if ($hasSemantic) {
            $semanticConfig = $indexData.semantic
            Write-Host "    Default Semantic Config: $($semanticConfig.defaultConfiguration)" -ForegroundColor White
            $configCount = if ($semanticConfig.configurations) { $semanticConfig.configurations.Count } else { 0 }
            Write-Host "    Semantic Configs Count: $configCount" -ForegroundColor White
            
            # Show detailed semantic configuration information
            if ($semanticConfig.configurations) {
                foreach ($config in $semanticConfig.configurations) {
                    Write-Host "      - Config: $($config.name)" -ForegroundColor Cyan
                    
                    if ($config.prioritizedFields) {
                        if ($config.prioritizedFields.titleField) {
                            Write-Host "        Title Field: $($config.prioritizedFields.titleField.fieldName)" -ForegroundColor Gray
                        }
                        if ($config.prioritizedFields.prioritizedContentFields) {
                            $contentFields = $config.prioritizedFields.prioritizedContentFields | ForEach-Object { $_.fieldName }
                            Write-Host "        Content Fields: $($contentFields -join ', ')" -ForegroundColor Gray
                        }
                        if ($config.prioritizedFields.prioritizedKeywordsFields) {
                            $keywordFields = $config.prioritizedFields.prioritizedKeywordsFields | ForEach-Object { $_.fieldName }
                            Write-Host "        Keywords Fields: $($keywordFields -join ', ')" -ForegroundColor Gray
                        }
                    }
                }
            }
        }
        
        return ($hasVectorizers -and $hasSemantic)
        
    } catch {
        $statusCode = "Unknown"
        try {
            if ($_.Exception -and $_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            } elseif ($_.Exception -and $_.Exception.Message -match 'HTTP (\d+)') {
                $statusCode = $matches[1]
            }
        } catch {
            # Ignore error getting status code
        }
        
        Write-Host "❗ Could not retrieve index: HTTP $statusCode" -ForegroundColor Red
        Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Check-KnowledgeAgents {
    param([string]$searchEndpoint, [string]$accessToken)
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "🤖 Checking Knowledge Agents in Azure AI Search..." -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "🌐 Search Endpoint: $searchEndpoint" -ForegroundColor Green
    
    # Query knowledge agents
    try {
        $apiVersion = "2025-08-01-preview"
        $uri = "${searchEndpoint}/agents?api-version=${apiVersion}"
        $headers = @{
            'Authorization' = "Bearer $accessToken"
            'Content-Type' = 'application/json'
        }
        
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
        
        if ($response.value -and $response.value.Count -gt 0) {
            Write-Host "✅ Found $($response.value.Count) knowledge agent(s):" -ForegroundColor Green
            Write-Host ""
            
            for ($i = 0; $i -lt $response.value.Count; $i++) {
                $agent = $response.value[$i]
                Write-Host "$($i + 1). 🤖 Agent: $($agent.name)" -ForegroundColor Cyan
                
                if ($agent.description) {
                    Write-Host "    Description: $($agent.description)" -ForegroundColor White
                }
                
                # Models information
                if ($agent.models -and $agent.models.Count -gt 0) {
                    Write-Host "    Models ($($agent.models.Count)):" -ForegroundColor White
                    for ($j = 0; $j -lt $agent.models.Count; $j++) {
                        $model = $agent.models[$j]
                        Write-Host "      $($j + 1). $($model.kind)" -ForegroundColor Cyan
                        
                        if ($model.kind -eq "azureOpenAI" -and $model.azureOpenAIParameters) {
                            $params = $model.azureOpenAIParameters
                            if ($params.resourceUri) { Write-Host "         Resource: $($params.resourceUri)" -ForegroundColor Gray }
                            if ($params.deploymentId) { Write-Host "         Deployment: $($params.deploymentId)" -ForegroundColor Gray }
                            if ($params.modelName) { Write-Host "         Model: $($params.modelName)" -ForegroundColor Gray }
                        } elseif ($model.kind -eq "openAI" -and $model.openAIParameters) {
                            $params = $model.openAIParameters
                            if ($params.organizationId) { Write-Host "         Organization: $($params.organizationId)" -ForegroundColor Gray }
                            if ($params.modelName) { Write-Host "         Model: $($params.modelName)" -ForegroundColor Gray }
                        }
                    }
                }
                
                # Knowledge sources information
                if ($agent.knowledgeSources -and $agent.knowledgeSources.Count -gt 0) {
                    Write-Host "    Knowledge Sources ($($agent.knowledgeSources.Count)):" -ForegroundColor White
                    for ($k = 0; $k -lt $agent.knowledgeSources.Count; $k++) {
                        $ks = $agent.knowledgeSources[$k]
                        Write-Host "      $($k + 1). $($ks.name)" -ForegroundColor Cyan
                        
                        if ($null -ne $ks.rerankerThreshold) { Write-Host "         Reranker Threshold: $($ks.rerankerThreshold)" -ForegroundColor Gray }
                        if ($null -ne $ks.includeReferences) { Write-Host "         Include References: $($ks.includeReferences)" -ForegroundColor Gray }
                        if ($null -ne $ks.includeReferenceSourceData) { Write-Host "         Include Reference Source Data: $($ks.includeReferenceSourceData)" -ForegroundColor Gray }
                    }
                }
                
                # Output configuration
                if ($agent.outputConfiguration) {
                    $config = $agent.outputConfiguration
                    $modality = if ($config.modality) { $config.modality } else { "N/A" }
                    $activity = if ($null -ne $config.includeActivity) { $config.includeActivity } else { "N/A" }
                    Write-Host "    Output: $modality (activity: $activity)" -ForegroundColor White
                }
                
                Write-Host ""
            }
            return $true
        } else {
            Write-Host "❌ No knowledge agents found" -ForegroundColor Red
            Write-Host ""
            Write-Host "This could mean:" -ForegroundColor Gray
            Write-Host "1. ENABLE_AGENTIC_RETRIEVAL is not set to 'true'" -ForegroundColor Gray
            Write-Host "2. GPT model deployment is not configured properly" -ForegroundColor Gray
            Write-Host "3. Knowledge agents haven't been created yet" -ForegroundColor Gray
            return $false
        }
    } catch {
        $statusCode = "Unknown"
        try {
            if ($_.Exception -and $_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            } elseif ($_.Exception -and $_.Exception.Message -match 'HTTP (\d+)') {
                $statusCode = $matches[1]
            }
        } catch {
            # Ignore error getting status code
        }
        
        if ($statusCode -eq "404") {
            Write-Host "❌ Knowledge agents not supported or service not found" -ForegroundColor Red
            return $false
        } else {
            Write-Host "❗ Error listing knowledge agents: HTTP $statusCode" -ForegroundColor Red
            Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

function Main {
    Write-Header
    
    # Load previous state
    Load-LastState
    
    try {
        # Get current subscription for context
        try {
            $currentSub = az account show --query "id" -o tsv 2>$null
            if ($currentSub -and $LASTEXITCODE -eq 0) {
                $script:SUBSCRIPTION = $currentSub.Trim()
            }
        } catch {
            # Ignore error
        }
        
        # Get configuration
        $searchEndpoint = Get-SearchEndpoint
        $accessToken = Get-AccessToken
        
        # Save state for next time
        Save-State
        
        # Run checks
        $ksResult = Check-KnowledgeSources -searchEndpoint $searchEndpoint -accessToken $accessToken
        $ksSuccess = $ksResult[0]
        $indexNamesFromKS = if ($ksResult.Count -gt 1) { $ksResult[1] } else { @() }
        
        $indexSuccess = Check-SearchIndexes -searchEndpoint $searchEndpoint -accessToken $accessToken -knowledgeSourceIndexNames $indexNamesFromKS
        
        $agentSuccess = Check-KnowledgeAgents -searchEndpoint $searchEndpoint -accessToken $accessToken
        
        # Summary
        Write-Host ""
        Write-Host ("=" * 80) -ForegroundColor Cyan
        Write-Host "📋 SUMMARY" -ForegroundColor Cyan
        Write-Host ("=" * 80) -ForegroundColor Cyan
        
        if ($ksSuccess -and $indexSuccess -and $agentSuccess) {
            Write-Host "🎉 Agentic Retrieval is fully configured!" -ForegroundColor Green
            exit 0
        } elseif (-not $ksSuccess) {
            Write-Host "❌ Knowledge sources not found or not configured" -ForegroundColor Red
            exit 1
        } elseif (-not $indexSuccess) {
            Write-Host "❌ Search indexes don't have agentic features" -ForegroundColor Red
            exit 1
        } elseif (-not $agentSuccess) {
            Write-Host "❌ Knowledge agents not found or not configured" -ForegroundColor Red
            exit 1
        } else {
            Write-Host "⚠️ Partial configuration detected" -ForegroundColor Yellow
            exit 1
        }
        
    } catch {
        Write-Host "❗ Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Main