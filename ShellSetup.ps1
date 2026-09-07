#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up PowerShell 7 and Windows Terminal: modules, Oh My Posh, Hack Nerd
    Font, the profile, and the Terminal settings file.

.DESCRIPTION
    Safe to run more than once. Everything it can detect, it skips. Everything
    it overwrites, it backs up first.

.PARAMETER ProfilePath
    Where to write the profile. Defaults to $PROFILE.CurrentUserCurrentHost,
    which already resolves to the OneDrive location when Documents is
    redirected, so you normally do not need this.

.PARAMETER SkipFont
    Do not install Hack Nerd Font.

.PARAMETER SkipTerminalSettings
    Do not touch the Windows Terminal settings.json.

.PARAMETER InstallBitwarden
    Also install the Bitwarden CLI via winget.

.EXAMPLE
    .\ShellSetup.ps1

.EXAMPLE
    .\ShellSetup.ps1 -SkipTerminalSettings

.NOTES
    Run from a normal (non-elevated) prompt. The font goes into your user
    profile, so administrator rights are not needed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProfilePath,
    [switch]$SkipFont,
    [switch]$SkipTerminalSettings,
    [switch]$InstallBitwarden,
    [string]$NerdFontVersion = 'v3.4.0',
    [string]$SourceBranch    = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRawBase = "https://raw.githubusercontent.com/TheDarthAdmin/Powershell/$SourceBranch"

#region Helpers ---------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Backup-File {
    <#  Copies a file next to itself with a timestamp. Returns the backup path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $backup = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Ok "Backed up existing file to $(Split-Path $backup -Leaf)"
    return $backup
}

function Save-RemoteFile {
    <#
        Downloads to a temp file first and only then moves it into place, so a
        failed or truncated download can never destroy the existing file.
        Optionally validates that the payload is parseable JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$ValidateJson
    )

    $temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $temp -UseBasicParsing

        if ((Get-Item -LiteralPath $temp).Length -eq 0) {
            throw "Downloaded file from $Uri was empty."
        }

        if ($ValidateJson) {
            $null = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
        }

        $parent = Split-Path -Path $Destination -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        Backup-File -Path $Destination | Out-Null
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-FontInstalled {
    <#
        The original checked $_.PSChildName on the result of Get-ItemProperty.
        That property is the name of the registry KEY ("Fonts"), not the font
        value names, so the test could never match and the font was reinstalled
        on every run. Read the value names instead, and check the per-user hive
        as well as the machine hive.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NamePattern)

    $roots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $names = (Get-Item -LiteralPath $root).GetValueNames()
        if ($names | Where-Object { $_ -like "*$NamePattern*" }) { return $true }
    }
    return $false
}

function Install-NerdFont {
    <#
        Installs into %LOCALAPPDATA%\Microsoft\Windows\Fonts and registers under
        HKCU. The original copied into C:\Windows\Fonts *and* called
        Shell.Application CopyHere for the same file, which needs admin rights
        and pops a "file already exists" dialog on the second pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FriendlyName
    )

    $zipPath     = Join-Path $env:TEMP 'NerdFont.zip'
    $extractPath = Join-Path $env:TEMP 'NerdFontExtract'
    $fontDir     = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regPath     = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

    try {
        Write-Skip "Downloading $FriendlyName..."
        Invoke-WebRequest -Uri $Url -OutFile $zipPath -UseBasicParsing

        if (Test-Path -LiteralPath $extractPath) {
            Remove-Item -LiteralPath $extractPath -Recurse -Force
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $fonts = Get-ChildItem -LiteralPath $extractPath -Include '*.ttf', '*.otf' -File -Recurse
        if (-not $fonts) { throw "No font files found in the archive." }

        New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }

        $count = 0
        foreach ($font in $fonts) {
            $dest = Join-Path $fontDir $font.Name
            Copy-Item -LiteralPath $font.FullName -Destination $dest -Force

            $type    = if ($font.Extension -eq '.otf') { '(OpenType)' } else { '(TrueType)' }
            $regName = '{0} {1}' -f [IO.Path]::GetFileNameWithoutExtension($font.Name), $type

            New-ItemProperty -Path $regPath -Name $regName -Value $dest `
                -PropertyType String -Force | Out-Null
            $count++
        }

        Write-Ok "$FriendlyName installed ($count files, current user only)."
    }
    finally {
        Remove-Item -LiteralPath $zipPath     -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractPath -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Get-TerminalSettingsPath {
    <#  Handles Store, Preview, and unpackaged installs of Windows Terminal. #>
    [CmdletBinding()]
    param()

    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )

    # Prefer a path that already exists; otherwise the parent folder existing is
    # good enough to tell us Terminal is installed but has never been launched.
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath (Split-Path $path -Parent)) { return $path }
    }
    return $null
}

function Install-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$FriendlyName,
        [string]$CommandName
    )

    if ($CommandName -and (Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Skip "$FriendlyName is already installed."
        return
    }

    if (-not (Get-Command winget -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning "winget is not available. Install $FriendlyName manually."
        return
    }

    winget install --id $Id --exact --source winget `
        --accept-source-agreements --accept-package-agreements --silent

    if ($LASTEXITCODE -eq 0) { Write-Ok "$FriendlyName installed." }
    else { Write-Warning "winget returned exit code $LASTEXITCODE for $FriendlyName." }
}

#endregion

#region Main ------------------------------------------------------------------

Write-Host ''
Write-Host 'PowerShell and Windows Terminal setup' -ForegroundColor White
Write-Host '-------------------------------------' -ForegroundColor DarkGray

# --- 1. Modules -------------------------------------------------------------
Write-Step 'PowerShell modules'

$modules = @('Terminal-Icons', 'PowerColorLS')

# PSReadLine ships in the box, so a plain -ListAvailable check never installs a
# newer build. Only pull from the gallery when the shipped version is too old
# for ListView predictions.
$psrl = Get-Module -ListAvailable -Name PSReadLine |
        Sort-Object Version -Descending | Select-Object -First 1
if (-not $psrl -or $psrl.Version -lt [version]'2.2.0') {
    $modules += 'PSReadLine'
}

foreach ($module in $modules) {
    if (Get-Module -ListAvailable -Name $module) {
        Write-Skip "$module is already installed."
        continue
    }

    if ($PSCmdlet.ShouldProcess($module, 'Install-Module')) {
        try {
            Install-Module -Name $module -Repository PSGallery -Scope CurrentUser `
                -Force -AllowClobber -SkipPublisherCheck
            Write-Ok "$module installed."
        }
        catch {
            Write-Warning "Could not install $module : $($_.Exception.Message)"
        }
    }
}

# --- 2. Oh My Posh ----------------------------------------------------------
Write-Step 'Oh My Posh'
Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -FriendlyName 'Oh My Posh' -CommandName 'oh-my-posh'

if ($InstallBitwarden) {
    Write-Step 'Bitwarden CLI'
    Install-WingetPackage -Id 'Bitwarden.CLI' -FriendlyName 'Bitwarden CLI' -CommandName 'bw'
}

# --- 3. Hack Nerd Font ------------------------------------------------------
# The original used 'return' here when the font was already present. At script
# scope that ends the ENTIRE script, so the profile and Terminal settings were
# silently never installed. Use an if/else instead.
if ($SkipFont) {
    Write-Step 'Hack Nerd Font'
    Write-Skip 'Skipped (-SkipFont).'
}
else {
    Write-Step 'Hack Nerd Font'
    if (Test-FontInstalled -NamePattern 'Hack Nerd Font') {
        Write-Skip 'Already installed.'
    }
    elseif ($PSCmdlet.ShouldProcess('Hack Nerd Font', 'Install')) {
        try {
            $fontUrl = "https://github.com/ryanoasis/nerd-fonts/releases/download/$NerdFontVersion/Hack.zip"
            Install-NerdFont -Url $fontUrl -FriendlyName 'Hack Nerd Font'
        }
        catch {
            Write-Warning "Font installation failed: $($_.Exception.Message)"
        }
    }
}

# --- 4. PowerShell profile --------------------------------------------------
Write-Step 'PowerShell profile'

if (-not $ProfilePath) {
    # $PROFILE already points at the OneDrive-redirected Documents folder when
    # Documents is redirected, so there is nothing to ask the user about. The
    # original prompt also called 'exit' on bad input, which kills the whole
    # host session when the script is piped into iex.
    $ProfilePath = $PROFILE.CurrentUserCurrentHost
}

try {
    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Install profile')) {
        Save-RemoteFile -Uri "$RepoRawBase/MyPwshProfile.ps1" -Destination $ProfilePath
        Write-Ok "Profile installed at $ProfilePath"
    }
}
catch {
    Write-Warning "Could not install the profile: $($_.Exception.Message)"
}

# --- 5. Windows Terminal settings -------------------------------------------
Write-Step 'Windows Terminal settings'

if ($SkipTerminalSettings) {
    Write-Skip 'Skipped (-SkipTerminalSettings).'
}
else {
    $terminalSettings = Get-TerminalSettingsPath

    if (-not $terminalSettings) {
        Write-Warning 'Windows Terminal was not found. Skipping its settings.'
    }
    elseif ($PSCmdlet.ShouldProcess($terminalSettings, 'Replace settings.json')) {
        try {
            Save-RemoteFile -Uri "$RepoRawBase/settings.json" `
                            -Destination $terminalSettings -ValidateJson
            Write-Ok "Terminal settings installed at $terminalSettings"
            Write-Skip 'Your previous settings.json is kept as a .bak- file next to it.'
        }
        catch {
            Write-Warning "Could not install the Terminal settings: $($_.Exception.Message)"
        }
    }
}

# --- Done -------------------------------------------------------------------
Write-Host ''
Write-Host 'Setup complete. Restart Windows Terminal to pick up the changes.' -ForegroundColor Green
Write-Host ''

#endregion
