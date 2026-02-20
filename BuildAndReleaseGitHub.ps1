<#
.SYNOPSIS
    Full pipeline: clean, update deps, build, package, commit, push, release.

.DESCRIPTION
    1. Cleans the solution
    2. Copies DLL dependencies from the local SSMS installation
    3. Builds HuntingDog.sln
    4. Packages HuntingDog.vsix + install.bat into a zip
    5. Commits changed files and pushes to origin (with confirmation)
    6. Creates a GitHub release (with confirmation)

.PARAMETER SSMSVersion
    SSMS major version. Default: 22

.PARAMETER Configuration
    Build configuration. Default: Release
#>

param(
    [string]$SSMSVersion   = "22",
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SSMSBasePath = "C:\Program Files\Microsoft SQL Server Management Studio $SSMSVersion\Release\Common7\IDE"
$depsDir      = Join-Path $scriptDir "Dependencies\SSMS$SSMSVersion"
$sln          = Join-Path $scriptDir "HuntingDog.sln"
$repo         = "selfpay-com/sql-hunting-dog"

# =============================================================================
# STEP 1 - Validate prerequisites
# =============================================================================
Write-Host ""
Write-Host "=== Validate prerequisites ===" -ForegroundColor Cyan

if (-not (Test-Path $SSMSBasePath)) {
    Write-Error "SSMS $SSMSVersion IDE directory not found: $SSMSBasePath"
    exit 1
}

# Detect full SSMS version from installed executable
$ssmsExe = Join-Path $SSMSBasePath "SSMS.exe"
if (-not (Test-Path $ssmsExe)) {
    Write-Error "SSMS.exe not found at: $ssmsExe"
    exit 1
}
$SSMSFullVersion = (Get-Item $ssmsExe).VersionInfo.ProductVersion
Write-Host "SSMS version: $SSMSFullVersion" -ForegroundColor Green

$tag          = "v$SSMSFullVersion"
$releaseTitle = "SSMS $SSMSVersion - v$SSMSFullVersion"
$zipName      = "HuntingDog-SSMS-v$SSMSFullVersion.zip"

# Find MSBuild via vswhere
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = $null
if (Test-Path $vswhere) {
    $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild `
                          -find "MSBuild\**\Bin\MSBuild.exe" |
               Select-Object -First 1
}
if (-not $msbuild -or -not (Test-Path $msbuild)) {
    Write-Error "MSBuild not found. Please install Visual Studio or VS Build Tools."
    exit 1
}
Write-Host "MSBuild: $msbuild" -ForegroundColor Green

$ghPath = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghPath) {
    Write-Error "GitHub CLI (gh) not found. Install it from https://cli.github.com"
    exit 1
}
Write-Host "gh CLI: $($ghPath.Source)" -ForegroundColor Green

# =============================================================================
# STEP 2 - Clean the solution
# =============================================================================
Write-Host ""
Write-Host "=== Clean solution ===" -ForegroundColor Cyan

& $msbuild $sln /t:Clean /p:Configuration=$Configuration /verbosity:minimal
if ($LASTEXITCODE -ne 0) {
    Write-Error "Clean failed."
    exit 1
}
Write-Host "Clean succeeded." -ForegroundColor Green

# =============================================================================
# STEP 3 - Update dependencies
# =============================================================================
Write-Host ""
Write-Host "=== Update dependencies from SSMS $SSMSVersion ===" -ForegroundColor Cyan

$dllPaths = [ordered]@{
    "ConnectionDlg.AadInteractiveAuthProvider.dll" = "."
    "ConnectionDlg.dll"                            = "."
    "Microsoft.SqlServer.ConnectionInfo.dll"        = "."
    "Microsoft.SqlServer.ConnectionInfoExtended.dll"= "."
    "Microsoft.SqlServer.Management.Sdk.Sfc.dll"   = "."
    "Microsoft.SqlServer.RegSvrEnum.dll"            = "."
    "Microsoft.SqlServer.Smo.dll"                  = "."
    "Microsoft.SqlServer.SmoExtended.dll"          = "."
    "Microsoft.SqlServer.SqlEnum.dll"              = "."
    "Microsoft.VisualStudio.Utilities.dll"         = "."
    "SqlPackageBase.dll"                           = "."
    "SqlWorkbench.Interfaces.dll"                  = "."
    "Microsoft.VisualStudio.Interop.dll"           = "PublicAssemblies"
    "Microsoft.VisualStudio.Shell.15.0.dll"        = "PublicAssemblies"
    "Microsoft.VisualStudio.Shell.Framework.dll"   = "PublicAssemblies"
    "Microsoft.VisualStudio.Threading.dll"         = "PublicAssemblies\Microsoft.VisualStudio.Threading.17.x"
    "NLog.dll"                                     = $null
    "Xceed.Wpf.Toolkit.dll"                        = $null
}

if (-not (Test-Path $depsDir)) {
    New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
}

$failed = @()
foreach ($dll in $dllPaths.Keys) {
    $relDir = $dllPaths[$dll]

    if ($null -ne $relDir) {
        $src = Join-Path (Join-Path $SSMSBasePath $relDir) $dll
    }
    else {
        Write-Host "  Searching for $dll ..." -ForegroundColor DarkCyan
        $found = Get-ChildItem -Path $SSMSBasePath -Filter $dll -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) {
            $src = $found.FullName
            Write-Host "    Found: $src" -ForegroundColor DarkCyan
        }
        else {
            Write-Host "  NOT FOUND: $dll" -ForegroundColor Red
            $failed += $dll
            continue
        }
    }

    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $depsDir $dll) -Force
        Write-Host "  Copied $dll" -ForegroundColor Green
    }
    else {
        Write-Host "  NOT FOUND: $src" -ForegroundColor Red
        $failed += $dll
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing DLLs:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Error "Some dependencies are missing. Aborting."
    exit 1
}
Write-Host "All dependencies updated." -ForegroundColor Green

# =============================================================================
# STEP 4 - Build the solution
# =============================================================================
Write-Host ""
Write-Host "=== Build solution ($Configuration) ===" -ForegroundColor Cyan

& $msbuild $sln /t:Restore /p:Configuration=$Configuration /verbosity:minimal
if ($LASTEXITCODE -ne 0) {
    Write-Error "NuGet restore failed."
    exit 1
}

& $msbuild $sln /t:Build /p:Configuration=$Configuration /verbosity:minimal
if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed."
    exit 1
}

$vsix = Join-Path $scriptDir "HuntingDog2019\bin\$Configuration\HuntingDog.vsix"
if (-not (Test-Path $vsix)) {
    Write-Error "Build succeeded but VSIX not found at: $vsix"
    exit 1
}
Write-Host "Build succeeded." -ForegroundColor Green

# =============================================================================
# STEP 5 - Package zip to temp
# =============================================================================
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

# =============================================================================
# STEP 6 - Commit and push
# =============================================================================
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

# =============================================================================
# STEP 7 - GitHub release
# =============================================================================
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
    Remove-Item -Path $zip -Force -ErrorAction SilentlyContinue
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
