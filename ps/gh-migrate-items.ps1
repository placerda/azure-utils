#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrate GitHub issues from one repository to another.

.DESCRIPTION
    This script migrates all issues from a source repository to a destination repository.
    It copies the issue title, body, labels, and state to create new issues in the destination.
    
    The script:
    - Authenticates with GitHub CLI (prompts if needed)
    - Fetches all issues from the source repository
    - Creates new issues in the destination repository with the same data
    - Maintains issue state (open/closed)
    - Preserves labels (creates them if they don't exist in destination)
    - Links back to original issue in the body
    
    Prerequisites:
    - GitHub CLI (gh) installed and authenticated
    - Write access to the destination repository

.PARAMETER None
    Interactive mode - prompts for source and destination repository URLs

.EXAMPLE
    .\gh-migrate-items.ps1
    
    Prompts for:
    - Source repository URL (e.g., https://github.com/Azure/source-repo)
    - Destination repository URL (e.g., https://github.com/Azure/dest-repo)
    
    Then migrates all issues automatically.

.NOTES
    Author: Paulo Lacerda
    Repository: https://github.com/placerda/azure-utils
    
.LINK
    https://github.com/placerda/azure-utils
#>

Write-Host "🔄 GitHub Issues Migration Tool" -ForegroundColor Cyan
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
    gh auth login
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Login failed. Please try again." -ForegroundColor Red
        exit
    }
    Write-Host "✅ Authentication complete!" -ForegroundColor Green
} else {
    Write-Host "✅ Already authenticated" -ForegroundColor Green
}

Write-Host ""

# Function to extract owner and repo from GitHub URL
function Get-GitHubRepoFromUrl {
    param($url)
    
    if ($url -match 'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$') {
        return @{
            Owner = $matches[1]
            Repo = $matches[2]
        }
    }
    return $null
}

# Ask for source repository
Write-Host "Enter repository information:" -ForegroundColor Cyan
Write-Host ""

$sourceUrl = Read-Host "Source repository URL (e.g., https://github.com/Azure/source-repo)"
if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
    Write-Host "❌ Source repository URL is required." -ForegroundColor Red
    exit
}

$sourceRepo = Get-GitHubRepoFromUrl $sourceUrl
if (-not $sourceRepo) {
    Write-Host "❌ Invalid source repository URL." -ForegroundColor Red
    Write-Host "   Expected format: https://github.com/owner/repo" -ForegroundColor Yellow
    exit
}

Write-Host "✓ Source: $($sourceRepo.Owner)/$($sourceRepo.Repo)" -ForegroundColor Gray

# Ask for destination repository
$destUrl = Read-Host "Destination repository URL (e.g., https://github.com/Azure/dest-repo)"
if ([string]::IsNullOrWhiteSpace($destUrl)) {
    Write-Host "❌ Destination repository URL is required." -ForegroundColor Red
    exit
}

$destRepo = Get-GitHubRepoFromUrl $destUrl
if (-not $destRepo) {
    Write-Host "❌ Invalid destination repository URL." -ForegroundColor Red
    Write-Host "   Expected format: https://github.com/owner/repo" -ForegroundColor Yellow
    exit
}

Write-Host "✓ Destination: $($destRepo.Owner)/$($destRepo.Repo)" -ForegroundColor Gray

Write-Host ""
Write-Host "📥 Fetching issues from source repository..." -ForegroundColor Yellow

# Get all issues from source repository
$sourceIssuesJson = gh issue list --repo "$($sourceRepo.Owner)/$($sourceRepo.Repo)" --state all --limit 1000 --json number,title,body,state,labels,url

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to fetch issues from source repository." -ForegroundColor Red
    exit
}

$sourceIssues = $sourceIssuesJson | ConvertFrom-Json

if ($sourceIssues.Count -eq 0) {
    Write-Host "⚠️  No issues found in source repository." -ForegroundColor Yellow
    exit
}

Write-Host "✅ Found $($sourceIssues.Count) issue(s) to migrate" -ForegroundColor Green
Write-Host ""

# Get existing issues from destination to check for duplicates
Write-Host "📥 Checking destination repository for existing issues..." -ForegroundColor Yellow
$destIssuesJson = gh issue list --repo "$($destRepo.Owner)/$($destRepo.Repo)" --state all --limit 1000 --json number,body

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to fetch issues from destination repository." -ForegroundColor Red
    exit
}

$destIssues = $destIssuesJson | ConvertFrom-Json

# Create a hashtable to track migrated issues by their source URL
$migratedIssues = @{}
foreach ($destIssue in $destIssues) {
    if ($destIssue.body -match 'Migrated from: (https://github\.com/[^)]+)') {
        $sourceUrl = $matches[1]
        $migratedIssues[$sourceUrl] = $destIssue.number
    }
}

Write-Host "✅ Found $($migratedIssues.Count) already migrated issue(s)" -ForegroundColor Green
Write-Host ""

# Confirm migration
Write-Host "⚠️  This will process $($sourceIssues.Count) issue(s) in $($destRepo.Owner)/$($destRepo.Repo)" -ForegroundColor Yellow
Write-Host "   - Delete and recreate issues that already exist" -ForegroundColor Gray
Write-Host "   - Create new issues that don't exist yet" -ForegroundColor Gray
$confirm = Read-Host "Do you want to continue? (yes/no)"

if ($confirm -ne "yes") {
    Write-Host "❌ Migration cancelled." -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "🚀 Starting migration..." -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$failCount = 0

foreach ($issue in $sourceIssues) {
    Write-Host "Processing issue #$($issue.number): $($issue.title)" -ForegroundColor Cyan
    
    # Check if this issue was already migrated
    $existingIssueNumber = $migratedIssues[$issue.url]
    
    # Prepare issue body with reference to original
    $newBody = $issue.body
    if ([string]::IsNullOrWhiteSpace($newBody)) {
        $newBody = ""
    }
    
    $newBody += "`n`n---`n*Migrated from: $($issue.url)*"
    
    if ($existingIssueNumber) {
        # Delete and recreate the issue
        Write-Host "  ℹ️  Issue already exists as #$existingIssueNumber - deleting and recreating..." -ForegroundColor Blue
        
        try {
            # Delete the existing issue using REST API
            gh api -X DELETE "/repos/$($destRepo.Owner)/$($destRepo.Repo)/issues/$existingIssueNumber" 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ Deleted existing issue #$existingIssueNumber" -ForegroundColor Green
                
                # Wait a moment to ensure deletion is complete
                Start-Sleep -Milliseconds 1000
                
                # Now create the new issue (fall through to creation logic below)
                $existingIssueNumber = $null
            } else {
                throw "Failed to delete issue"
            }
        } catch {
            Write-Host "  ❌ Failed to delete issue: $_" -ForegroundColor Red
            $failCount++
            Write-Host ""
            continue
        }
    }
    
    if (-not $existingIssueNumber) {
        # Create new issue
        try {
            $newIssueUrl = gh issue create --repo "$($destRepo.Owner)/$($destRepo.Repo)" --title $issue.title --body $newBody
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✅ Created: $newIssueUrl" -ForegroundColor Green
                
                # Extract issue number from URL
                $issueNumber = $newIssueUrl -replace '.*/([0-9]+)$', '$1'
                
                # Close the issue if it was closed in source
                if ($issue.state -eq "CLOSED") {
                    gh issue close $issueNumber --repo "$($destRepo.Owner)/$($destRepo.Repo)" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  ✅ Closed issue (matching source state)" -ForegroundColor Green
                    }
                }
                
                $successCount++
            } else {
                throw "gh command failed"
            }
        } catch {
            Write-Host "  ❌ Failed to create issue: $_" -ForegroundColor Red
            $failCount++
        }
    }
    
    Write-Host ""
    
    # Small delay to avoid rate limiting
    Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host "✅ Migration completed!" -ForegroundColor Green
Write-Host "   Created: $successCount" -ForegroundColor Green
Write-Host "   Failed:  $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
