#!/usr/bin/env pwsh
<#
Script: rm-index-documents.ps1
Overview:
    Deletes ALL documents from a specified Azure Cognitive Search index. The index/schema remains intact; only documents are removed.
    Works by discovering the index key field, enumerating document keys in pages, and sending batch delete actions to the Search data plane.
    Stores your last-used subscription, search service name, and index name in a temp state file for convenience.

Prerequisites:
    - PowerShell 7+ (pwsh)
    - Azure CLI (az) installed and logged in: az login
    - Permissions to read the Search service via ARM (to fetch admin keys) and to perform data-plane operations using the admin key
    - The Search service endpoint must be reachable from your network

Usage examples:
    # Interactive (prompts for subscription, service, and index; asks to confirm if -Confirm is set):
    .\ps\rm-index-documents.ps1 -Confirm

    # Larger batches (default 1000) and specific API version:
    .\ps\rm-index-documents.ps1 -BatchSize 2000 -ApiVersion 2020-06-30

Notes:
    - This script uses the admin key retrieved from ARM (listAdminKeys) and performs data-plane operations with Invoke-RestMethod.
    - It pages through results using @odata.nextLink and deletes in batches to avoid payload limits.
#>
param(
    [switch]$Confirm,
    [int]$BatchSize = 1000,
    [string]$ApiVersion = '2020-06-30'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# State vars
$script:SUB = $null
$script:SEARCH_NAME = $null
$script:INDEX_NAME = $null

# Persist last inputs (PowerShell dot-sourceable file)
$StateFile = Join-Path $env:TEMP 'rm-index-docs-last.ps1'

function Prompt-Context {
    if (Test-Path -Path $StateFile) {
        . $StateFile
        $script:SUB = $SUB; $script:SEARCH_NAME = $SEARCH_NAME; $script:INDEX_NAME = $INDEX_NAME
        Write-Host "Last used:" -ForegroundColor Cyan
        Write-Host "  Subscription: $([string]::IsNullOrWhiteSpace($script:SUB) ? '<none>' : $script:SUB)"
        Write-Host "  Search svc : $([string]::IsNullOrWhiteSpace($script:SEARCH_NAME) ? '<none>' : $script:SEARCH_NAME)"
        Write-Host "  Index      : $([string]::IsNullOrWhiteSpace($script:INDEX_NAME) ? '<none>' : $script:INDEX_NAME)"

        $reuseSub = Read-Host "Reuse subscription '$script:SUB'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseSub)) { $reuseSub = 'Y' }
        if ($reuseSub -match '^(n|no)$') { $script:SUB = Read-Host 'Subscription ID or name' }

        $reuseSvc = Read-Host "Reuse search service '$script:SEARCH_NAME'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseSvc)) { $reuseSvc = 'Y' }
        if ($reuseSvc -match '^(n|no)$') { $script:SEARCH_NAME = Read-Host 'Search service name' }

        $reuseIdx = Read-Host "Reuse index '$script:INDEX_NAME'? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($reuseIdx)) { $reuseIdx = 'Y' }
        if ($reuseIdx -match '^(n|no)$') { $script:INDEX_NAME = Read-Host 'Index name' }
    }
    else {
        $script:SUB = Read-Host 'Subscription ID or name'
        $script:SEARCH_NAME = Read-Host 'Search service name'
        $script:INDEX_NAME = Read-Host 'Index name'
    }

    if ([string]::IsNullOrWhiteSpace($script:SUB) -or [string]::IsNullOrWhiteSpace($script:SEARCH_NAME) -or [string]::IsNullOrWhiteSpace($script:INDEX_NAME)) {
        Write-Host 'Subscription, search service, and index are required.' -ForegroundColor Red
        exit 1
    }

    $safeSub = $script:SUB -replace "'","''"
    $safeSvc = $script:SEARCH_NAME -replace "'","''"
    $safeIdx = $script:INDEX_NAME -replace "'","''"
    Set-Content -Path $StateFile -Value @(
        "`$SUB='$safeSub'",
        "`$SEARCH_NAME='$safeSvc'",
        "`$INDEX_NAME='$safeIdx'"
    ) -Encoding UTF8
}

function Resolve-SearchResource {
    param([string]$searchName)
    Write-Host ">> Resolving search resource '$searchName' in subscription…"
    $rg = & az resource list --subscription $script:SUB --name $searchName --resource-type Microsoft.Search/searchServices --query "[0].resourceGroup" -o tsv
    if ([string]::IsNullOrWhiteSpace($rg)) {
        Write-Host "Search service '$searchName' not found in subscription $script:SUB." -ForegroundColor Red
        exit 1
    }
    return $rg
}

function Get-SubscriptionId {
    try { return (& az account show --subscription $script:SUB --query id -o tsv).Trim() }
    catch { return (& az account show --query id -o tsv).Trim() }
}

function Get-AdminKey {
    param([string]$rg, [string]$searchName)
    Write-Host ">> Fetching admin key…"
    $subId = Get-SubscriptionId
    $mgmtApi = '2023-11-01'
    $url = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Search/searchServices/$searchName/listAdminKeys?api-version=$mgmtApi"
    $raw = & az rest --method post --url $url --headers "Content-Type=application/json"
    $obj = $raw | ConvertFrom-Json
    $key = $obj.primaryKey
    if ([string]::IsNullOrWhiteSpace($key)) { Write-Host 'Could not retrieve admin key.' -ForegroundColor Red; exit 1 }
    return $key
}

function Get-Index-KeyFieldName {
    param([string]$endpoint, [string]$key, [string]$index, [string]$apiVersion)
    Write-Host ">> Inspecting index schema to locate key field…"
    $url = "$endpoint/indexes/${index}?api-version=$apiVersion"
    $obj = Invoke-RestMethod -Method Get -Uri $url -Headers @{ 'api-key' = $key }
    $keyField = ($obj.fields | Where-Object { $_.key -eq $true } | Select-Object -First 1).name
    if ([string]::IsNullOrWhiteSpace($keyField)) { Write-Host 'Could not find key field in index definition.' -ForegroundColor Red; exit 1 }
    return $keyField
}

function New-SearchUri {
    param([string]$endpoint, [string]$path, [hashtable]$query)
    $builder = [System.UriBuilder]::new("$endpoint$path")
    $pairs = @()
    foreach ($k in $query.Keys) {
        $v = $query[$k]
        if ($null -ne $v) {
            $ek = [System.Uri]::EscapeDataString([string]$k)
            $ev = [System.Uri]::EscapeDataString([string]$v)
            $pairs += ("$ek=$ev")
        }
    }
    $builder.Query = [string]::Join('&', $pairs)
    return $builder.Uri.AbsoluteUri
}

function Get-Docs-Page {
    param([string]$endpoint, [string]$key, [string]$index, [string]$apiVersion, [string]$keyField, [int]$top, [string]$continuation)
    try {
        if ($continuation) {
            $url = $continuation
        } else {
            $url = New-SearchUri -endpoint $endpoint -path "/indexes/$index/docs" -query @{ 'api-version'=$apiVersion; 'search'='*'; '$select'=$keyField; '$top'=$top }
        }
        $obj = Invoke-RestMethod -Method Get -Uri $url -Headers @{ 'api-key' = $key }
        $next = $null
        if ($obj.PSObject.Properties.Name -contains '@odata.nextLink') { $next = $obj.'@odata.nextLink' }
        return [PSCustomObject]@{ value = @($obj.value); nextLink = $next }
    } catch {
        Write-Host "(warn) Failed to get docs page: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return [PSCustomObject]@{ value=@(); nextLink=$null }
    }
}

function Delete-Batch {
    param([string]$endpoint, [string]$key, [string]$index, [string]$apiVersion, [array]$ids, [string]$keyField)
    if (-not $ids -or $ids.Count -eq 0) { return 0 }
    $actions = @()
    foreach ($id in $ids) {
        if ($null -eq $id -or [string]::IsNullOrWhiteSpace($id.ToString())) { continue }
        $h = @{ '@search.action' = 'delete' }
        $h[$keyField] = $id
        $actions += $h
    }
    if ($actions.Count -eq 0) { return 0 }
    $body = @{ value = $actions } | ConvertTo-Json -Depth 5
    $url = "$endpoint/indexes/${index}/docs/index?api-version=$apiVersion"
    Write-Host "   - Deleting $($actions.Count) documents…"
    Invoke-RestMethod -Method Post -Uri $url -Headers @{ 'api-key'=$key; 'Content-Type'='application/json' } -Body $body | Out-Null
    return $actions.Count
}

function Main {
    Prompt-Context

    Write-Host ">> Using subscription: $script:SUB"
    & az account set --subscription $script:SUB | Out-Null

    $rg = Resolve-SearchResource -searchName $script:SEARCH_NAME
    $adminKey = Get-AdminKey -rg $rg -searchName $script:SEARCH_NAME
    $endpoint = "https://$($script:SEARCH_NAME).search.windows.net"

    # Ensure index exists and determine key field
    $keyField = Get-Index-KeyFieldName -endpoint $endpoint -key $adminKey -index $script:INDEX_NAME -apiVersion $ApiVersion
    Write-Host "   · Key field: $keyField"

    if ($Confirm) {
        $sure = Read-Host "About to DELETE ALL documents from index '$($script:INDEX_NAME)' on service '$($script:SEARCH_NAME)'. Are you sure? [y/N]"
        if (-not ($sure.ToLower() -in @('y','yes'))) { Write-Host 'Aborted.'; return }
    }

    Write-Host ">> Enumerating document keys and deleting in batches of $BatchSize…"
    $total = 0
    while ($true) {
        $page = Get-Docs-Page -endpoint $endpoint -key $adminKey -index $script:INDEX_NAME -apiVersion $ApiVersion -keyField $keyField -top $BatchSize -continuation $null
        $ids = @()
        foreach ($doc in $page.value) { $ids += $doc.$keyField }
        if ($ids.Count -eq 0) { break }
        $deleted = Delete-Batch -endpoint $endpoint -key $adminKey -index $script:INDEX_NAME -apiVersion $ApiVersion -ids $ids -keyField $keyField
        $total += $deleted
        if (-not $page.nextLink) { continue }
        # Drain subsequent pages for current snapshot
        $nextUrl = $page.nextLink
        while ($nextUrl) {
            $page2 = Get-Docs-Page -endpoint $endpoint -key $adminKey -index $script:INDEX_NAME -apiVersion $ApiVersion -keyField $keyField -top $BatchSize -continuation $nextUrl
            $ids2 = @(); foreach ($doc in $page2.value) { $ids2 += $doc.$keyField }
            if ($ids2.Count -eq 0) { break }
            $deleted2 = Delete-Batch -endpoint $endpoint -key $adminKey -index $script:INDEX_NAME -apiVersion $ApiVersion -ids $ids2 -keyField $keyField
            $total += $deleted2
            $nextUrl = $page2.nextLink
        }
        # Loop back to first page after deletions
    }
    Write-Host "✅ Deleted $total documents from index '$($script:INDEX_NAME)'." -ForegroundColor Green
}

Main
