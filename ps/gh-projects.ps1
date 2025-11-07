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
    - Copies Start Date, End Date (or Target Date), and Status fields to the consolidated project
    - Falls back to Iteration dates if direct dates are not available
    - Handles emoji cleanup in status field names
    - Uses case-insensitive field name matching
    
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
Write-Host "ℹ️  This tool synchronizes dates and status from source projects to a consolidated project." -ForegroundColor Blue
Write-Host "   It will:" -ForegroundColor Blue
Write-Host "   - Find issues in their original (source) projects" -ForegroundColor Blue
Write-Host "   - Copy Start Date, End Date, and Status to your consolidated project" -ForegroundColor Blue
Write-Host "   - Use Iteration dates when direct dates aren't available" -ForegroundColor Blue
Write-Host ""

Write-Host "Enter project information from the URL:" -ForegroundColor Cyan
Write-Host "Example: https://github.com/orgs/Azure/projects/885/views/2" -ForegroundColor Gray
Write-Host ""

$projectNumberInput = Read-Host "Project number [default: 885]"
$projectNumber = if ([string]::IsNullOrWhiteSpace($projectNumberInput)) { "885" } else { $projectNumberInput }
Write-Host "Using project number: $projectNumber" -ForegroundColor Gray

$projectOwnerInput = Read-Host "Organization/owner [default: Azure]"
$projectOwner = if ([string]::IsNullOrWhiteSpace($projectOwnerInput)) { "Azure" } else { $projectOwnerInput }
Write-Host "Using organization: $projectOwner" -ForegroundColor Gray

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
$targetFieldName = "Target Date"
$statusFieldName = "Status"
$iterationFieldName = "Iteration"

# Helper function for case-insensitive field name comparison
function Compare-FieldName {
    param($name1, $name2)
    return $name1 -and $name2 -and ($name1.ToLower() -eq $name2.ToLower())
}

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
          ... on ProjectV2IterationField {
            id
            name
            dataType
            configuration {
              iterations {
                id
                title
                startDate
                duration
              }
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
    } elseif ($field.configuration -and $field.configuration.iterations) {
        $iterationCount = $field.configuration.iterations.Count
        Write-Host "  - '$($field.name)' (Type: $($field.dataType), Iterations: $iterationCount)" -ForegroundColor Gray
    } else {
        Write-Host "  - '$($field.name)' (Type: $($field.dataType))" -ForegroundColor Gray
    }
}
Write-Host ""

# Create a hashtable for quick field lookup (case-insensitive)
$fieldMap = @{}
$fieldOptionsMap = @{}
$iterationMap = @{}

foreach ($field in $projectFields) {
    $fieldMap[$field.name.ToLower()] = $field.id
    if ($field.options) {
        # Create a map of option names to option IDs for single-select fields
        $optionMap = @{}
        foreach ($option in $field.options) {
            $optionMap[$option.name] = $option.id
        }
        $fieldOptionsMap[$field.name.ToLower()] = $optionMap
    }
    if ($field.configuration -and $field.configuration.iterations) {
        # Create a map of iteration titles to their details
        $iterMap = @{}
        foreach ($iter in $field.configuration.iterations) {
            # Calculate end date from start date and duration
            if ($iter.startDate -and $iter.duration) {
                $startDate = [DateTime]::Parse($iter.startDate)
                $endDate = $startDate.AddDays($iter.duration)
                $iterMap[$iter.title] = @{
                    Id = $iter.id
                    Title = $iter.title
                    StartDate = $iter.startDate
                    EndDate = $endDate.ToString("yyyy-MM-dd")
                    Duration = $iter.duration
                }
            }
        }
        $iterationMap[$field.name.ToLower()] = $iterMap
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
          fieldValues(first: 30) {
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
              ... on ProjectV2ItemFieldIterationValue {
                title
                startDate
                duration
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

    # Debug: Show all projects this issue belongs to
    $allProjects = $projectInfo.data.repository.issue.projectItems.nodes
    if ($allProjects -and $allProjects.Count -gt 0) {
        Write-Host "  📁 Found in $($allProjects.Count) project(s):" -ForegroundColor DarkGray
        foreach ($proj in $allProjects) {
            Write-Host "     - $($proj.project.title)" -ForegroundColor DarkGray
        }
    }

    # Collect data from all SOURCE projects (excluding the consolidated project)
    # The consolidated project is the target, all others are sources
    $allSourceDates = $projectInfo.data.repository.issue.projectItems.nodes |
        Where-Object { $_.project.id -ne $projectId } |  # Exclude the consolidated project
        ForEach-Object {
            $dateFields = @{}
            $iterationInfo = $null
            $projectTitle = $_.project.title
            
            # Debug: Show which project we're processing
            Write-Host "  🔍 Checking project: $projectTitle" -ForegroundColor DarkGray
            
            foreach ($fieldValue in $_.fieldValues.nodes) {
                # Debug: Show field names found
                if ($fieldValue.field -and $fieldValue.field.name) {
                    Write-Host "     Field: '$($fieldValue.field.name)'" -ForegroundColor DarkGray
                }
                
                # Start Date (case-insensitive)
                if ((Compare-FieldName $fieldValue.field.name $startFieldName) -and $fieldValue.date) {
                    $dateFields['Start'] = $fieldValue.date
                    $dateFields['StartSource'] = 'Start Date'
                    Write-Host "     ✓ Found Start Date: $($fieldValue.date)" -ForegroundColor DarkGray
                }
                # End Date (case-insensitive, first priority)
                if ((Compare-FieldName $fieldValue.field.name $endFieldName) -and $fieldValue.date) {
                    $dateFields['End'] = $fieldValue.date
                    $dateFields['EndSource'] = 'End Date'
                    Write-Host "     ✓ Found End Date: $($fieldValue.date)" -ForegroundColor DarkGray
                }
                # Target Date (case-insensitive, fallback if End Date not found)
                if ((Compare-FieldName $fieldValue.field.name $targetFieldName) -and $fieldValue.date -and -not $dateFields['End']) {
                    $dateFields['End'] = $fieldValue.date
                    $dateFields['EndSource'] = 'Target Date'
                    Write-Host "     ✓ Found Target Date: $($fieldValue.date)" -ForegroundColor DarkGray
                }
                # Iteration (case-insensitive)
                if ((Compare-FieldName $fieldValue.field.name $iterationFieldName) -and $fieldValue.title) {
                    $iterationInfo = @{
                        Title = $fieldValue.title
                        StartDate = $fieldValue.startDate
                        Duration = $fieldValue.duration
                    }
                    Write-Host "     ✓ Found Iteration: $($fieldValue.title)" -ForegroundColor DarkGray
                    Write-Host "       - Start: $($fieldValue.startDate), Duration: $($fieldValue.duration) days" -ForegroundColor DarkGray
                }
                # Status (case-insensitive)
                if ((Compare-FieldName $fieldValue.field.name $statusFieldName) -and $fieldValue.name) {
                    # Remove everything before the first letter (emojis and symbols)
                    $cleanStatus = $fieldValue.name -replace '^[^a-zA-Z]+', ''
                    $dateFields['Status'] = $cleanStatus.Trim()
                    Write-Host "     ✓ Found Status: $($cleanStatus.Trim())" -ForegroundColor DarkGray
                }
            }
            
            # If we don't have Start or End dates, try to get them from Iteration
            if ($iterationInfo) {
                if (-not $dateFields['Start'] -and $iterationInfo.StartDate) {
                    $dateFields['Start'] = $iterationInfo.StartDate
                    $dateFields['StartSource'] = "Iteration ($($iterationInfo.Title))"
                    Write-Host "     ✓ Using Iteration Start Date: $($iterationInfo.StartDate)" -ForegroundColor DarkGray
                }
                if (-not $dateFields['End'] -and $iterationInfo.StartDate -and $iterationInfo.Duration) {
                    $startDate = [DateTime]::Parse($iterationInfo.StartDate)
                    $endDate = $startDate.AddDays($iterationInfo.Duration)
                    $dateFields['End'] = $endDate.ToString("yyyy-MM-dd")
                    $dateFields['EndSource'] = "Iteration ($($iterationInfo.Title))"
                    Write-Host "     ✓ Using Iteration End Date: $($endDate.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray
                }
            }
            
            if ($dateFields.Count -gt 0) { $dateFields }
        }
    
    # Select the best source: prioritize entries with both Start and End dates
    $sourceDates = $allSourceDates | 
        Sort-Object -Property @{Expression = {
            $score = 0
            if ($_.Start) { $score += 10 }
            if ($_.End) { $score += 10 }
            if ($_.Status) { $score += 1 }
            $score
        }; Descending = $true} |
        Select-Object -First 1

    if (-not $sourceDates) {
        Write-Host "  ⚠️  No dates or status found in source project" -ForegroundColor Yellow
        continue
    }

    if ($sourceDates.Start) {
        Write-Host "  ✓ Start:  $($sourceDates.Start) (from $($sourceDates.StartSource))" -ForegroundColor Gray
    }
    if ($sourceDates.End) {
        Write-Host "  ✓ End:    $($sourceDates.End) (from $($sourceDates.EndSource))" -ForegroundColor Gray
    }
    if ($sourceDates.Status) {
        Write-Host "  ✓ Status: $($sourceDates.Status)" -ForegroundColor Gray
    }

    # Update consolidated project item with dates and status
    # First update date fields
    foreach ($fieldName in @($startFieldName, $endFieldName)) {
        $dateValue = if ($fieldName -eq $startFieldName) { $sourceDates.Start } else { $sourceDates.End }
        if (-not $dateValue) { continue }

        # Find field ID using case-insensitive lookup
        $fieldId = $fieldMap[$fieldName.ToLower()]
        
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
        $statusFieldId = $fieldMap[$statusFieldName.ToLower()]
        
        if (-not $statusFieldId) {
            Write-Host "  ⚠️  Field '$statusFieldName' not found in project" -ForegroundColor Yellow
        } elseif (-not $fieldOptionsMap[$statusFieldName.ToLower()]) {
            Write-Host "  ⚠️  Field '$statusFieldName' is not a single-select field" -ForegroundColor Yellow
        } else {
            $statusOptionId = $fieldOptionsMap[$statusFieldName.ToLower()][$statusValue]
            
            if (-not $statusOptionId) {
                Write-Host "  ⚠️  Status option '$statusValue' not found" -ForegroundColor Yellow
                Write-Host "     Available options: $($fieldOptionsMap[$statusFieldName.ToLower()].Keys -join ', ')" -ForegroundColor Gray
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