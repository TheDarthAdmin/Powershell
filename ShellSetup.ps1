#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up PowerShell 7 and Windows Terminal: modules, Oh My Posh, Hack Nerd
    Font, the profile, and the Terminal settings file.

.DESCRIPTION
    Safe to run more than once. Everything it can detect, it skips. Everything
    it overwrites, it backs up first.

    Files are taken from the folder this script lives in when they are present
    there, and downloaded from GitHub only as a fallback. That way a local
    checkout installs the profile you are actually looking at rather than
    whatever is currently on the default branch.

.PARAMETER ProfilePath
    Where to write the profile. By default the script resolves the PowerShell 7
    profile location itself and creates the folder if needed.

.PARAMETER SkipModules
    Do not install PowerShell modules.

.PARAMETER SkipFont
    Do not install Hack Nerd Font.

.PARAMETER SkipTerminalSettings
    Do not touch the Windows Terminal settings.json.

.PARAMETER InstallBitwarden
    Also install the Bitwarden CLI via winget.

.EXAMPLE
    .\ShellSetup.ps1

.EXAMPLE
    .\ShellSetup.ps1 -SkipTerminalSettings -Verbose

.NOTES
    Run from a normal (non-elevated) prompt. Everything is installed for the
    current user, so administrator rights are not needed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProfilePath,
    [switch]$SkipModules,
    [switch]$SkipFont,
    [switch]$SkipTerminalSettings,
    [switch]$InstallBitwarden,
    [string]$NerdFontVersion = 'v3.4.0',
    [string]$SourceBranch    = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRawBase = "https://raw.githubusercontent.com/TheDarthAdmin/Powershell/$SourceBranch"
$LocalRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { $null }

#region Helpers ---------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

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

function Install-ConfigFile {
    <#
        Puts a file in place from the local checkout if it is there, otherwise
        from GitHub. Writes to a temp file first and only then moves it into
        position, so a failed or truncated download can never destroy the file
        being replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$ValidateJson
    )

    $temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())

    try {
        $localSource = if ($LocalRoot) { Join-Path $LocalRoot $FileName }

        if ($localSource -and (Test-Path -LiteralPath $localSource)) {
            Copy-Item -LiteralPath $localSource -Destination $temp -Force
            Write-Skip "Source: local file $FileName"
        }
        else {
            $uri = "$RepoRawBase/$FileName"
            Invoke-WebRequest -Uri $uri -OutFile $temp -UseBasicParsing
            Write-Skip "Source: $uri"
        }

        if ((Get-Item -LiteralPath $temp).Length -eq 0) {
            throw "Source file '$FileName' was empty."
        }

        if ($ValidateJson) {
            $null = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
        }

        $parent = Split-Path -Path $Destination -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            # Report the path we failed on. "Could not find a part of the path"
            # with no path in it is not a useful error message.
            try   { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
            catch { throw "Could not create the folder '$parent': $($_.Exception.Message)" }
        }

        Backup-File -Path $Destination | Out-Null

        try   { Move-Item -LiteralPath $temp -Destination $Destination -Force -ErrorAction Stop }
        catch { throw "Could not write to '$Destination': $($_.Exception.Message)" }
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-ProfilePath {
    <#
        Works out where the PowerShell 7 profile belongs and returns a path whose
        folder exists and is writable.

        $PROFILE cannot be trusted here on its own. Run this script from Windows
        PowerShell 5.1 and $PROFILE points at Documents\WindowsPowerShell\,
        where a "#Requires -Version 7.0" profile will refuse to load. And when
        Documents is redirected to OneDrive, the registry value $PROFILE is built
        from can point at a folder that no longer exists, which is what produces
        "Could not find a part of the path". So: build a candidate list, and pick
        the first one we can actually create a folder in.
    #>
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]

    # If we are already in PowerShell 7, its own answer is the best answer.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $candidates.Add($PROFILE.CurrentUserCurrentHost)
    }

    $docs = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
    if ($docs) { $candidates.Add((Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')) }

    if ($env:OneDrive) {
        $candidates.Add((Join-Path $env:OneDrive 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'))
    }

    if ($env:OneDriveCommercial -and $env:OneDriveCommercial -ne $env:OneDrive) {
        $candidates.Add((Join-Path $env:OneDriveCommercial 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'))
    }

    $candidates.Add((Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'))

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $folder = Split-Path -Path $candidate -Parent
        if (-not $folder) { continue }

        if (Test-Path -LiteralPath $folder) {
            Write-Verbose "Profile folder already exists: $folder"
            return $candidate
        }

        try {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            Write-Verbose "Created profile folder: $folder"
            return $candidate
        }
        catch {
            Write-Verbose "Cannot use '$folder': $($_.Exception.Message)"
        }
    }

    return $null
}

function Initialize-PackageSource {
    <#
        The "Administrator rights are required" error from Install-Package comes
        from PowerShellGet 1.0.0.1, the version that ships with Windows
        PowerShell 5.1: its NuGet provider bootstrap ignores -Scope CurrentUser
        and tries to write to Program Files. The module install itself then
        usually succeeds anyway, which is why the first run reported both an
        error and a success. Bootstrap the provider per-user up front so the
        error never appears.
    #>
    [CmdletBinding()]
    param()

    try {
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
                 Sort-Object Version -Descending | Select-Object -First 1

        if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
            Write-Skip 'Bootstrapping the NuGet package provider for the current user...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Verbose "NuGet provider bootstrap failed: $($_.Exception.Message)"
    }

    try {
        $gallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
        if ($gallery.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
            Write-Skip 'PSGallery marked as trusted for this user.'
        }
    }
    catch {
        Write-Verbose "Could not configure PSGallery: $($_.Exception.Message)"
    }
}

function Install-GalleryModule {
    <#
        Installs a module and then checks whether it is actually there. The
        original trusted Install-Module's error stream, which reports failures
        it goes on to recover from, so the script printed "installed" directly
        underneath an error and would have printed it on a real failure too.
        Presence on disk is the only reliable signal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)

    if (Get-Module -ListAvailable -Name $Name) {
        Write-Skip "$Name is already installed."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Install-Module')) { return }

    $installErrors = $null
    Install-Module -Name $Name -Repository PSGallery -Scope CurrentUser `
        -Force -AllowClobber -SkipPublisherCheck `
        -ErrorAction SilentlyContinue -WarningAction SilentlyContinue `
        -ErrorVariable installErrors

    $installed = Get-Module -ListAvailable -Name $Name |
                 Sort-Object Version -Descending | Select-Object -First 1

    if ($installed) {
        Write-Ok "$Name $($installed.Version) installed."
        if ($installErrors) {
            Write-Verbose "$Name installed despite: $($installErrors[0].Exception.Message)"
        }
    }
    else {
        $reason = if ($installErrors) { $installErrors[0].Exception.Message } else { 'unknown error' }
        Write-Fail "$Name was NOT installed: $reason"
    }
}

function Test-FontInstalled {
    <#
        Reads the font value names out of the registry. Checks the per-user hive
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
        HKCU, so no elevation is needed.

        Font files already in place are left alone. A .ttf loaded by a running
        process cannot be overwritten, and there is no reason to: if the file is
        already the right size it is the same font, so skip the copy and just
        make sure the registry entry exists. One locked file no longer aborts
        the whole install.
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

        $fonts = @(Get-ChildItem -LiteralPath $extractPath -Include '*.ttf', '*.otf' -File -Recurse)
        if ($fonts.Count -eq 0) { throw 'No font files found in the archive.' }

        New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath $regPath)) { New-Item -Path $regPath -Force | Out-Null }

        $copied = 0; $alreadyThere = 0; $failed = @()

        foreach ($font in $fonts) {
            $dest = Join-Path $fontDir $font.Name

            $existing = if (Test-Path -LiteralPath $dest) { Get-Item -LiteralPath $dest } else { $null }

            if ($existing -and $existing.Length -eq $font.Length) {
                $alreadyThere++
            }
            else {
                try {
                    Copy-Item -LiteralPath $font.FullName -Destination $dest -Force -ErrorAction Stop
                    $copied++
                }
                catch {
                    if ($existing) {
                        # Locked by a running app but already present. Fine.
                        $alreadyThere++
                        Write-Verbose "In use, keeping existing copy: $($font.Name)"
                    }
                    else {
                        $failed += $font.Name
                        Write-Verbose "Failed to copy $($font.Name): $($_.Exception.Message)"
                        continue
                    }
                }
            }

            $type    = if ($font.Extension -eq '.otf') { '(OpenType)' } else { '(TrueType)' }
            $regName = '{0} {1}' -f [IO.Path]::GetFileNameWithoutExtension($font.Name), $type

            try {
                New-ItemProperty -Path $regPath -Name $regName -Value $dest `
                    -PropertyType String -Force -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Verbose "Could not register $regName : $($_.Exception.Message)"
            }
        }

        $summary = "${FriendlyName}: $copied file(s) installed"
        if ($alreadyThere) { $summary += ", $alreadyThere already present or in use" }
        Write-Ok "$summary."

        if ($failed.Count -gt 0) {
            Write-Fail "$($failed.Count) file(s) could not be installed: $($failed -join ', ')"
            Write-Skip 'Close Windows Terminal and any editors, then run the script again.'
        }
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
        Write-Fail "winget is not available. Install $FriendlyName manually."
        return
    }

    winget install --id $Id --exact --source winget `
        --accept-source-agreements --accept-package-agreements --silent

    if ($LASTEXITCODE -eq 0) { Write-Ok "$FriendlyName installed." }
    else { Write-Fail "winget returned exit code $LASTEXITCODE for $FriendlyName." }
}

#endregion

#region Main ------------------------------------------------------------------

Write-Host ''
Write-Host 'PowerShell and Windows Terminal setup' -ForegroundColor White
Write-Host '-------------------------------------' -ForegroundColor DarkGray
Write-Host "Running under PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray

if ($PSVersionTable.PSVersion.Major -lt 6) {
    Write-Host ''
    Write-Fail 'This is Windows PowerShell 5.1. The profile targets PowerShell 7,'
    Write-Skip 'so it will be written to the PowerShell 7 profile location rather'
    Write-Skip "than this shell's. Install PowerShell 7 with:"
    Write-Skip '  winget install Microsoft.PowerShell'
}

# --- 1. Modules -------------------------------------------------------------
Write-Step 'PowerShell modules'

if ($SkipModules) {
    Write-Skip 'Skipped (-SkipModules).'
}
else {
    Initialize-PackageSource

    $modules = @('Terminal-Icons', 'PowerColorLS')

    # PSReadLine ships in the box, so a plain -ListAvailable check never
    # installs a newer build. Only pull from the gallery when the shipped
    # version is too old for ListView predictions.
    $psrl = Get-Module -ListAvailable -Name PSReadLine |
            Sort-Object Version -Descending | Select-Object -First 1
    if (-not $psrl -or $psrl.Version -lt [version]'2.2.0') {
        $modules += 'PSReadLine'
    }
    else {
        Write-Skip "PSReadLine $($psrl.Version) is recent enough."
    }

    foreach ($module in $modules) {
        Install-GalleryModule -Name $module
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
Write-Step 'Hack Nerd Font'

if ($SkipFont) {
    Write-Skip 'Skipped (-SkipFont).'
}
elseif (Test-FontInstalled -NamePattern 'Hack Nerd Font') {
    Write-Skip 'Already registered.'
}
elseif ($PSCmdlet.ShouldProcess('Hack Nerd Font', 'Install')) {
    try {
        $fontUrl = "https://github.com/ryanoasis/nerd-fonts/releases/download/$NerdFontVersion/Hack.zip"
        Install-NerdFont -Url $fontUrl -FriendlyName 'Hack Nerd Font'
    }
    catch {
        Write-Fail "Font installation failed: $($_.Exception.Message)"
    }
}

# --- 4. PowerShell profile --------------------------------------------------
Write-Step 'PowerShell profile'

if (-not $ProfilePath) {
    $ProfilePath = Resolve-ProfilePath
}

if (-not $ProfilePath) {
    Write-Fail 'Could not find a writable location for the profile.'
    Write-Skip 'Pass one explicitly, for example:'
    Write-Skip '  .\ShellSetup.ps1 -ProfilePath "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"'
}
elseif ($PSCmdlet.ShouldProcess($ProfilePath, 'Install profile')) {
    try {
        Install-ConfigFile -FileName 'MyPwshProfile.ps1' -Destination $ProfilePath
        Write-Ok "Profile installed at $ProfilePath"
    }
    catch {
        Write-Fail "Could not install the profile: $($_.Exception.Message)"
    }
}

# --- 5. Windows Terminal settings -------------------------------------------
Write-Step 'Windows Terminal settings'

if ($SkipTerminalSettings) {
    Write-Skip 'Skipped (-SkipTerminalSettings).'
}
else {
    $terminalSettings = Get-TerminalSettingsPath

    if (-not $terminalSettings) {
        Write-Fail 'Windows Terminal was not found. Skipping its settings.'
    }
    elseif ($PSCmdlet.ShouldProcess($terminalSettings, 'Replace settings.json')) {
        try {
            Install-ConfigFile -FileName 'settings.json' -Destination $terminalSettings -ValidateJson
            Write-Ok "Terminal settings installed at $terminalSettings"
            Write-Skip 'Your previous settings.json is kept as a .bak- file next to it.'
        }
        catch {
            Write-Fail "Could not install the Terminal settings: $($_.Exception.Message)"
        }
    }
}

# --- 6. Verify --------------------------------------------------------------
Write-Step 'Result'

foreach ($module in @('Terminal-Icons', 'PowerColorLS', 'PSReadLine')) {
    $found = Get-Module -ListAvailable -Name $module |
             Sort-Object Version -Descending | Select-Object -First 1
    if ($found) { Write-Ok  "$module $($found.Version)" }
    else        { Write-Fail "$module missing" }
}

if (Get-Command oh-my-posh -CommandType Application -ErrorAction SilentlyContinue) {
    Write-Ok 'oh-my-posh on PATH'
}
else {
    Write-Fail 'oh-my-posh not on PATH in this session (open a new tab)'
}

if (Test-FontInstalled -NamePattern 'Hack Nerd Font') { Write-Ok 'Hack Nerd Font registered' }
else { Write-Fail 'Hack Nerd Font not registered' }

if ($ProfilePath -and (Test-Path -LiteralPath $ProfilePath)) { Write-Ok "Profile at $ProfilePath" }
else { Write-Fail 'Profile not installed' }

Write-Host ''
Write-Host 'Done. Restart Windows Terminal to pick up the changes.' -ForegroundColor Green
Write-Host ''

#endregion
