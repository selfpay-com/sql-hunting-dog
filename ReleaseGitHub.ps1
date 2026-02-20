<#
.SYNOPSIS
    Commits, pushes, packages, and publishes a GitHub release.

.DESCRIPTION
    1. Commits all changed files and pushes to origin
    2. Packages the built VSIX into a zip
    3. Creates a GitHub release with the zip attached

.PARAMETER SSMSVersion
    SSMS major version. Default: 22

.PARAMETER Configuration
    Build configuration whose VSIX to package. Default: Release
#>

param(
    [string]$SSMSVersion   = "22",
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SSMSBasePath = "C:\Program Files\Microsoft SQL Server Management Studio $SSMSVersion\Release\Common7\IDE"
$repo         = "selfpay-com/sql-hunting-dog"
$year         = (Get-Date).Year

# -- Validate -----------------------------------------------------------------
$ghPath = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghPath) {
    Write-Error "GitHub CLI (gh) not found. Install it from https://cli.github.com"
    exit 1
}

# Detect full SSMS version
$ssmsExe = Join-Path $SSMSBasePath "SSMS.exe"
if (-not (Test-Path $ssmsExe)) {
    Write-Error "SSMS.exe not found at: $ssmsExe"
    exit 1
}
$SSMSFullVersion = (Get-Item $ssmsExe).VersionInfo.ProductVersion

$tag          = "v$SSMSFullVersion"
$releaseTitle = "SSMS $year - v$SSMSFullVersion"
$zipName      = "HuntingDog-SSMS-v$SSMSFullVersion.zip"

# Verify VSIX exists
$vsix = Join-Path $scriptDir "HuntingDog2019\bin\$Configuration\HuntingDog.vsix"
if (-not (Test-Path $vsix)) {
    Write-Error "VSIX not found: $vsix. Run ReleaseLocal.ps1 first."
    exit 1
}

# -- Package zip to temp ------------------------------------------------------
Write-Host ""
Write-Host "=== Package release zip ===" -ForegroundColor Cyan

$staging = Join-Path $env:TEMP "HuntingDog_Package_$(Get-Random)"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$zip = Join-Path $env:TEMP $zipName

try {
    Copy-Item -Path $vsix -Destination (Join-Path $staging "HuntingDog.vsix")

    $batContent = @"
@echo off
set VSIX_ID=HuntingDog.SelfPay.ed1b9330-4bff-4fb5-85a1-7cee4b0f3f3b
set INSTALLER="%ProgramFiles%\Microsoft SQL Server Management Studio $SSMSVersion\Release\Common7\IDE\VSIXInstaller.exe"

if not exist %INSTALLER% (
    echo VSIXInstaller.exe not found. Is SSMS $SSMSVersion installed?
    exit /b 1
)

echo Uninstalling previous HuntingDog extension...
%INSTALLER% /quiet /u:%VSIX_ID%

echo Installing HuntingDog extension...
%INSTALLER% /quiet "%~dp0HuntingDog.vsix"
if %errorlevel% neq 0 (
    echo Install failed.
    exit /b 1
)

echo Done.
"@
    $batContent | Set-Content -Path (Join-Path $staging "install.bat") -Encoding ASCII

    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip

    Write-Host "Created: $zip" -ForegroundColor Green
}
finally {
    Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
}

# -- Commit and push -----------------------------------------------------------
Write-Host ""
Write-Host "=== Commit and push ===" -ForegroundColor Cyan

Set-Location $scriptDir
$status = git status --porcelain
if ($status) {
    Write-Host "Changed files:" -ForegroundColor Yellow
    Write-Host $status
    Write-Host ""
    git add -A
    git commit -m "SSMS $SSMSVersion - v$SSMSFullVersion"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Commit failed."
        exit 1
    }
}
else {
    Write-Host "No changes to commit." -ForegroundColor Green
}

Write-Host ""
$pushChoice = Read-Host "Push to origin? (y/n)"
if ($pushChoice -ne "y") {
    Write-Host "Push skipped." -ForegroundColor Yellow
}
else {
    git push
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Push failed."
        exit 1
    }
    Write-Host "Pushed." -ForegroundColor Green
}

# -- Create release ------------------------------------------------------------
Write-Host ""
Write-Host "=== Create GitHub release ===" -ForegroundColor Cyan
Write-Host "Repo:    $repo" -ForegroundColor Cyan
Write-Host "Tag:     $tag" -ForegroundColor Cyan
Write-Host "Title:   $releaseTitle" -ForegroundColor Cyan
Write-Host "Asset:   $zip" -ForegroundColor Cyan
Write-Host ""

$releaseChoice = Read-Host "Create release? (y/n)"
if ($releaseChoice -ne "y") {
    Write-Host "Release skipped." -ForegroundColor Yellow
    exit 0
}

# Delete existing release with same tag if present
gh release view $tag --repo $repo 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Deleting existing release '$tag' ..." -ForegroundColor Yellow
    gh release delete $tag --repo $repo --yes --cleanup-tag
}

$notes = @"
## HuntingDog for SSMS $SSMSVersion (v$SSMSFullVersion)

### Installation
1. Download ``$zipName`` below
2. Extract the zip
3. Close SSMS $SSMSVersion if it is running
4. Run ``install.bat``

The installer will silently remove any previous version and install the new one.
"@

gh release create $tag $zip --repo $repo --title $releaseTitle --notes $notes
if ($LASTEXITCODE -ne 0) {
    Write-Error "GitHub release creation failed."
    exit 1
}

Write-Host ""
Write-Host "Release '$releaseTitle' published." -ForegroundColor Green

# -- Cleanup temp zip ----------------------------------------------------------
Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
