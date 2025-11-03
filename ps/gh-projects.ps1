#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sync fields from source project items to a consolidated GitHub project.

.DESCRIPTION
    This script synchronizes Start Date, End Date, and Status fields from issues in their 
    original GitHub projects to a consolidated project. It's useful when you have a master 
    project that aggregates issues from multiple repositories/projects and want to keep 
    the date and status fields in sync automatically.
    
    The script:
    - Authenticates with GitHub CLI (prompts if needed)
    - Fetches all items from the consolidated project
    - For each item, finds the same issue in its original project
    - Copies Start Date, End Date, and Status fields to the consolidated project
    - Handles emoji cleanup in status field names
    
    Prerequisites:
    - GitHub CLI (gh) installed and authenticated
    - 'project' scope enabled for GitHub CLI
    - Access to both source and consolidated projects

.PARAMETER None
    Interactive mode - prompts for project number and organization

.EXAMPLE
    .\gh-projects.ps1
    
    Prompts for:
    - Project number (e.g., 885 from URL)
    - Organization/owner (e.g., Azure from URL)
    
    Then syncs all fields automatically.

.NOTES
    Author: Paulo Lacerda
    Repository: https://github.com/placerda/azure-utils
    
.LINK
    https://github.com/placerda/azure-utils
#>

<#
.SYNOPSIS
    Sync Start/End Dates from source projects to a consolidated project in GitHub.

.DESCRIPTION
    For each item in the consolidated project, finds the same issue/PR in its original project
    and copies the Start Date and End Date fields to the consolidated project.
#>

Write-Host "🔧 GitHub Projects Sync Tool" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Gray
Write-Host ""

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "❌ PowerShell 5.0 or higher is required" -ForegroundColor Red
    Write-Host "   Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    exit
}
Write-Host "✅ PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

# Check if Git is installed
try {
    $gitVersion = git --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ Git installed: $gitVersion" -ForegroundColor Green
    } else {
        throw
    }
} catch {
    Write-Host "⚠️  Git not found (optional)" -ForegroundColor Yellow
}

# Check if GitHub CLI is installed
try {
    $ghVersion = gh --version 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ GitHub CLI installed: $ghVersion" -ForegroundColor Green
    } else {
        throw
    }
} catch {
    Write-Host "❌ GitHub CLI (gh) not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install GitHub CLI from:" -ForegroundColor Yellow
    Write-Host "  https://cli.github.com/" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Or use winget:" -ForegroundColor Yellow
    Write-Host "  winget install GitHub.cli" -ForegroundColor Cyan
    exit
}

Write-Host ""

# Check for GitHub CLI authentication
Write-Host "Checking GitHub authentication..." -ForegroundColor Gray
$authStatus = gh auth status 2>&1 | Out-String

if ($authStatus -notmatch "Logged in") {
    Write-Host "❌ You need to login to GitHub first." -ForegroundColor Red
    Write-Host ""
    Write-Host "Opening GitHub login..." -ForegroundColor Yellow
    gh auth login --scopes project
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Login failed. Please try again." -ForegroundColor Red
        exit
    }
    Write-Host "✅ Authentication complete!" -ForegroundColor Green
} else {
    Write-Host "✅ Already authenticated" -ForegroundColor Green
    
    # Check if project scope is present
    if ($authStatus -notmatch "project") {
        Write-Host "⚠️  Need to add 'project' permission..." -ForegroundColor Yellow
        Write-Host ""
        gh auth refresh -s project
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Permissions updated!" -ForegroundColor Green
        } else {
            Write-Host "⚠️  Could not refresh permissions, but will try to continue..." -ForegroundColor Yellow
        }
    }
}

Write-Host ""

# Ask for the consolidated project number and owner
Write-Host "Enter project information from the URL:" -ForegroundColor Cyan
Write-Host "Example: https://github.com/orgs/Azure/projects/885/views/2" -ForegroundColor Gray
Write-Host ""

$projectNumber = Read-Host "Project number (e.g., 885)"
if (-not $projectNumber) {
    Write-Host "❌ Project number is required." -ForegroundColor Red
    exit
}

$projectOwner = Read-Host "Organization/owner (e.g., Azure)"
if (-not $projectOwner) {
    Write-Host "❌ Organization/owner is required." -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "📥 Fetching project information..." -ForegroundColor Yellow

# Get the project ID from the project number and owner
try {
    $projectInfo = gh project view $projectNumber --owner $projectOwner --format json 2>&1 | Out-String
    
    # Check if we got an authentication error
    if ($projectInfo -match "authentication token is missing required scopes") {
        Write-Host "⚠️  Need to refresh permissions..." -ForegroundColor Yellow
        gh auth refresh -s project
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Permissions updated! Retrying..." -ForegroundColor Green
            $projectInfo = gh project view $projectNumber --owner $projectOwner --format json | ConvertFrom-Json
        } else {
            throw "Failed to refresh permissions"
        }
    } else {
        $projectInfo = $projectInfo | ConvertFrom-Json
    }
    
    $projectId = $projectInfo.id
    Write-Host "✅ Found project: $($projectInfo.title)" -ForegroundColor Green
    Write-Host "   Project ID: $projectId" -ForegroundColor Gray
} catch {
    Write-Host "❌ Failed to fetch project information." -ForegroundColor Red
    Write-Host "   Make sure the project number and owner are correct." -ForegroundColor Yellow
    Write-Host "   Error: $_" -ForegroundColor Gray
    exit
}

Write-Host ""
Write-Host ""
Write-Host "📋 Fetching project items..." -ForegroundColor Yellow

# Define field names (adjust to your actual field names)
$startFieldName = "Start Date"
$endFieldName = "End Date"
$statusFieldName = "Status"

# Get project fields via GraphQL
Write-Host "Fetching project fields..." -ForegroundColor Gray
$fieldsQuery = @"
{
  node(id: "$projectId") {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2Field {
            id
            name
            dataType
          }
          ... on ProjectV2SingleSelectField {
            id
            name
            dataType
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}
"@

$fieldsResult = gh api graphql -f query=$fieldsQuery | ConvertFrom-Json
$projectFields = $fieldsResult.data.node.fields.nodes

Write-Host "Available fields in project:" -ForegroundColor Gray
foreach ($field in $projectFields) {
    if ($field.options) {
        $optionNames = ($field.options | ForEach-Object { $_.name }) -join ', '
        Write-Host "  - '$($field.name)' (Type: $($field.dataType), Options: $optionNames)" -ForegroundColor Gray
    } else {
        Write-Host "  - '$($field.name)' (Type: $($field.dataType))" -ForegroundColor Gray
    }
}
Write-Host ""

# Create a hashtable for quick field lookup
$fieldMap = @{}
$fieldOptionsMap = @{}
foreach ($field in $projectFields) {
    $fieldMap[$field.name] = $field.id
    if ($field.options) {
        # Create a map of option names to option IDs for single-select fields
        $optionMap = @{}
        foreach ($option in $field.options) {
            $optionMap[$option.name] = $option.id
        }
        $fieldOptionsMap[$field.name] = $optionMap
    }
}

# Get all items in the consolidated project
$query = @"
{
  node(id: "$projectId") {
    ... on ProjectV2 {
      items(first: 100) {
        nodes {
          id
          content {
            ... on Issue { id title number repository { nameWithOwner } }
            ... on PullRequest { id title number repository { nameWithOwner } }
          }
        }
      }
    }
  }
}
"@

$itemsJson = gh api graphql -f query=$query | ConvertFrom-Json

$items = $itemsJson.data.node.items.nodes

Write-Host "✅ Found $($items.Count) items to process" -ForegroundColor Green
Write-Host ""

foreach ($item in $items) {
    $content = $item.content
    if (-not $content) { continue }

    $repo = $content.repository.nameWithOwner
    $number = $content.number

    Write-Host "Processing: $repo#$number" -ForegroundColor Cyan
    Write-Host "  Title: $($content.title)" -ForegroundColor Gray

    # Find the same issue in its project to get Start/End dates
    $repoOwner = $repo.Split('/')[0]
    $repoName = $repo.Split('/')[1]
    
    $issueQuery = @"
{
  repository(owner: "$repoOwner", name: "$repoName") {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          project {
            title
            id
          }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldDateValue {
                date
                field {
                  ... on ProjectV2FieldCommon {
                    name
                  }
                }
              }
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field {
                  ... on ProjectV2FieldCommon {
                    name
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
"@
    
    $projectInfo = gh api graphql -f query=$issueQuery | ConvertFrom-Json

    $sourceDates = $projectInfo.data.repository.issue.projectItems.nodes |
        ForEach-Object {
            $dateFields = @{}
            foreach ($fieldValue in $_.fieldValues.nodes) {
                if ($fieldValue.field.name -eq $startFieldName -and $fieldValue.date) {
                    $dateFields['Start'] = $fieldValue.date
                }
                if ($fieldValue.field.name -eq $endFieldName -and $fieldValue.date) {
                    $dateFields['End'] = $fieldValue.date
                }
                if ($fieldValue.field.name -eq $statusFieldName -and $fieldValue.name) {
                    # Remove everything before the first letter (emojis and symbols)
                    $cleanStatus = $fieldValue.name -replace '^[^a-zA-Z]+', ''
                    $dateFields['Status'] = $cleanStatus.Trim()
                }
            }
            if ($dateFields.Count -gt 0) { $dateFields }
        } | Select-Object -First 1

    if (-not $sourceDates) {
        Write-Host "  ⚠️  No dates or status found in source project" -ForegroundColor Yellow
        continue
    }

    Write-Host "  ✓ Start:  $($sourceDates.Start)" -ForegroundColor Gray
    Write-Host "  ✓ End:    $($sourceDates.End)" -ForegroundColor Gray
    Write-Host "  ✓ Status: $($sourceDates.Status)" -ForegroundColor Gray

    # Update consolidated project item with dates and status
    # First update date fields
    foreach ($fieldName in @($startFieldName, $endFieldName)) {
        $dateValue = if ($fieldName -eq $startFieldName) { $sourceDates.Start } else { $sourceDates.End }
        if (-not $dateValue) { continue }

        $fieldId = $fieldMap[$fieldName]
        
        if (-not $fieldId) {
            Write-Host "  ⚠️  Field '$fieldName' not found in project" -ForegroundColor Yellow
            Write-Host "     Available fields: $($fieldMap.Keys -join ', ')" -ForegroundColor Gray
            continue
        }

        $mutation = @"
mutation {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: "$projectId"
      itemId: "$($item.id)"
      fieldId: "$fieldId"
      value: { date: "$dateValue" }
    }
  ) {
    projectV2Item {
      id
    }
  }
}
"@

        try {
            gh api graphql -f query=$mutation | Out-Null
            Write-Host "  ✅ Updated $fieldName to $dateValue" -ForegroundColor Green
        } catch {
            Write-Host "  ❌ Failed to update $fieldName : $_" -ForegroundColor Red
        }
    }
    
    # Update status field (single-select)
    if ($sourceDates.Status) {
        $statusValue = $sourceDates.Status
        $statusFieldId = $fieldMap[$statusFieldName]
        
        if (-not $statusFieldId) {
            Write-Host "  ⚠️  Field '$statusFieldName' not found in project" -ForegroundColor Yellow
        } elseif (-not $fieldOptionsMap[$statusFieldName]) {
            Write-Host "  ⚠️  Field '$statusFieldName' is not a single-select field" -ForegroundColor Yellow
        } else {
            $statusOptionId = $fieldOptionsMap[$statusFieldName][$statusValue]
            
            if (-not $statusOptionId) {
                Write-Host "  ⚠️  Status option '$statusValue' not found" -ForegroundColor Yellow
                Write-Host "     Available options: $($fieldOptionsMap[$statusFieldName].Keys -join ', ')" -ForegroundColor Gray
            } else {
                $statusMutation = @"
mutation {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: "$projectId"
      itemId: "$($item.id)"
      fieldId: "$statusFieldId"
      value: { singleSelectOptionId: "$statusOptionId" }
    }
  ) {
    projectV2Item {
      id
    }
  }
}
"@

                try {
                    gh api graphql -f query=$statusMutation | Out-Null
                    Write-Host "  ✅ Updated $statusFieldName to $statusValue" -ForegroundColor Green
                } catch {
                    Write-Host "  ❌ Failed to update $statusFieldName : $_" -ForegroundColor Red
                }
            }
        }
    }
    
    Write-Host ""
}

Write-Host "✅ Sync completed!" -ForegroundColor Green