#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up PowerShell 7 and Windows Terminal: modules, Oh My Posh, Hack Nerd
    Font, the profile, and the Terminal settings file.

.DESCRIPTION
    Safe to run more than once. Everything it can detect, it skips. Everything
    it overwrites, it backs up first.

    Files are taken from the folder this script lives in when they are present
    there, and downloaded from GitHub only as a fallback. Run it from a local
    checkout to install the files you are actually looking at rather than
    whatever is on the default branch.

.PARAMETER Diagnose
    Print the paths and tool versions this script depends on, then exit without
    changing anything. Start here when something fails.

.PARAMETER ProfilePath
    Where to write the profile. By default the script resolves the PowerShell 7
    profile location itself.

.PARAMETER ModuleRoot
    Where to install modules. Defaults to the first writable per-user entry in
    $env:PSModulePath.

.EXAMPLE
    .\ShellSetup.ps1 -Diagnose

.EXAMPLE
    .\ShellSetup.ps1

.NOTES
    Run from a normal (non-elevated) PowerShell 7 prompt. Everything installs
    for the current user, so administrator rights are not needed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Diagnose,
    [string]$ProfilePath,
    [string]$ModuleRoot,
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
$GalleryApi  = 'https://www.powershellgallery.com/api/v2/package'
$LocalRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { $null }

#region Output helpers --------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

#endregion

#region Filesystem helpers ----------------------------------------------------

$script:LastWriteFailure = $null

function Test-DirectoryWritable {
    <#
        Creates the directory if needed, then proves it by writing and deleting
        a probe file. On failure the reason is left in $script:LastWriteFailure,
        because "not usable" without a reason is not a diagnosis.

        Creating a directory is not proof that you can put a file in it. On a
        OneDrive-redirected Documents folder, New-Item can report success while
        the subsequent file write fails.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $script:LastWriteFailure = $null

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        $probe = Join-Path $Path (".probe-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'probe')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        $script:LastWriteFailure = $_.Exception.Message
        Write-Verbose "Not writable: $Path -- $($_.Exception.Message)"
        return $false
    }
}

function Write-PathDiagnostic {
    <#  Walks a path segment by segment and reports which part is missing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $parts   = $Path -split '[\\/]'
    $current = ''

    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) { continue }

        $current = if ($current) { Join-Path $current $part } else { "$part\" }
        $exists  = Test-Path -LiteralPath $current

        if ($exists) { Write-Skip "  [ok]      $current" }
        else         { Write-Fail "  [missing] $current"; break }
    }
}

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
        from GitHub. Staged through a temp file so a failed or truncated
        download can never destroy the file being replaced.
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
        if ($parent -and -not (Test-DirectoryWritable -Path $parent)) {
            Write-Fail "Cannot write into '$parent'. Path breakdown:"
            Write-PathDiagnostic -Path $parent
            throw "The folder '$parent' exists or was created but will not accept files."
        }

        Backup-File -Path $Destination | Out-Null

        # Copy, not Move. File.Move (which Move-Item uses) is the operation that
        # fails on OneDrive placeholder folders; a stream copy goes through.
        Copy-Item -LiteralPath $temp -Destination $Destination -Force -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $Destination)) {
            throw "Wrote '$Destination' without error but the file is not there."
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region Path resolution -------------------------------------------------------

function Resolve-ProfilePath {
    <#
        Returns a PowerShell 7 profile path whose folder will actually accept a
        file, or $null.

        Candidates are probed with a real write rather than a directory
        creation, because a redirected Documents folder can pass the second and
        fail the first.
    #>
    [CmdletBinding()]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]

    # PowerShell 7's own answer first, because that is the only path it loads.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $candidates.Add($PROFILE.CurrentUserCurrentHost)
    }

    $docs = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
    if ($docs) { $candidates.Add((Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')) }

    foreach ($od in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
        if ($od) { $candidates.Add((Join-Path $od 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')) }
    }

    if ($env:USERPROFILE) {
        $candidates.Add((Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'))
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $folder = Split-Path -Path $candidate -Parent
        if (-not $folder) { continue }

        if (Test-DirectoryWritable -Path $folder) { return $candidate }
        Write-Skip "Not usable: $folder"
        if ($script:LastWriteFailure) { Write-Skip "  reason: $script:LastWriteFailure" }
    }

    return $null
}

function Test-InModulePath {
    <#  Is this folder one PowerShell actually searches for modules? #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $env:PSModulePath) { return $false }

    $sep      = [IO.Path]::PathSeparator
    $normalise = { $args[0].TrimEnd('\', '/').ToLowerInvariant() }

    $target = & $normalise $Path
    foreach ($entry in ($env:PSModulePath -split $sep)) {
        if ($entry -and (& $normalise $entry) -eq $target) { return $true }
    }
    return $false
}

function Resolve-UserModuleRoot {
    <#
        Returns an object with the chosen module folder and whether PowerShell
        searches it.

        Both matter. The previous version returned only a path, so when the
        PSModulePath entry turned out to be unwritable and we fell back to a
        fixed location, modules were installed somewhere PowerShell never looks
        — which is why the run reported "direct download (0.11.0)" and
        "Terminal-Icons missing" in the same breath. They were installed; they
        just were not discoverable.
    #>
    [CmdletBinding()]
    param()

    $sep = [IO.Path]::PathSeparator
    $userPrefixes = @($env:USERPROFILE, $HOME, $env:OneDrive, $env:OneDriveCommercial) |
                    Where-Object { $_ }

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:PSModulePath) {
        foreach ($entry in ($env:PSModulePath -split $sep)) {
            if ($entry -and ($userPrefixes | Where-Object { $entry -like "$_*" })) {
                $candidates.Add($entry)
            }
        }
    }

    # Fallbacks, in the order most likely to be both writable and expected.
    foreach ($base in @($env:OneDrive, $env:OneDriveCommercial, $env:USERPROFILE)) {
        if ($base) { $candidates.Add((Join-Path $base 'Documents\PowerShell\Modules')) }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-DirectoryWritable -Path $candidate) {
            return [PSCustomObject]@{
                Path         = $candidate
                InModulePath = Test-InModulePath -Path $candidate
            }
        }
        Write-Skip "Not usable: $candidate"
        if ($script:LastWriteFailure) { Write-Skip "  reason: $script:LastWriteFailure" }
    }

    return $null
}

function Add-ToUserModulePath {
    <#
        Adds a folder to PSModulePath for this session and for future ones.

        Needed when the module folder PowerShell would normally use is not
        writable: installing modules somewhere unsearched is no better than not
        installing them.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    $sep = [IO.Path]::PathSeparator

    if (-not $PSCmdlet.ShouldProcess('PSModulePath (user environment variable)', "Add '$Path'")) {
        return
    }

    try {
        $persisted = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
        $entries   = @()
        if ($persisted) { $entries = @($persisted -split $sep | Where-Object { $_ }) }

        if ($entries -notcontains $Path) {
            [Environment]::SetEnvironmentVariable(
                'PSModulePath', (($entries + $Path) -join $sep), 'User')
            Write-Ok "Added to your PSModulePath: $Path"
        }
        else {
            Write-Skip 'Already in your persisted PSModulePath.'
        }
    }
    catch {
        Write-Fail "Could not persist PSModulePath: $($_.Exception.Message)"
    }

    # Also apply to this session so the verification step below can see it.
    if (-not (Test-InModulePath -Path $Path)) {
        $env:PSModulePath = "$($env:PSModulePath)$sep$Path"
    }
}

#endregion

#region Module installation ---------------------------------------------------

function Install-ModuleFromGallery {
    <#
        Downloads the .nupkg from the PowerShell Gallery and unpacks it into the
        user's module folder.

        This exists because Install-Module on this machine fails with
        "Administrator rights are required" even with -Scope CurrentUser. That
        error comes from PackageManagement's NuGet provider, which wants to
        bootstrap itself machine-wide. A .nupkg is just a zip, and the module
        folder is just a folder, so neither PackageManagement nor PowerShellGet
        needs to be involved at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $tempZip = Join-Path ([IO.Path]::GetTempPath()) ("$Name-{0}.zip" -f [guid]::NewGuid().ToString('N'))
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("$Name-{0}"     -f [guid]::NewGuid().ToString('N'))

    try {
        Invoke-WebRequest -Uri "$GalleryApi/$Name" -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempDir -Force

        $nuspec = Get-ChildItem -LiteralPath $tempDir -Filter '*.nuspec' -File |
                  Select-Object -First 1
        if (-not $nuspec) { throw 'The package contained no .nuspec, so the version is unknown.' }

        $version = ([xml](Get-Content -LiteralPath $nuspec.FullName -Raw)).package.metadata.version
        if (-not $version) { throw 'Could not read the version from the .nuspec.' }

        # Strip NuGet packaging artefacts that are not part of the module.
        foreach ($cruft in '_rels', 'package') {
            $path = Join-Path $tempDir $cruft
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        foreach ($cruft in '[Content_Types].xml', $nuspec.Name) {
            $path = Join-Path $tempDir $cruft
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }

        $destination = Join-Path $DestinationRoot (Join-Path $Name $version)
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        Get-ChildItem -LiteralPath $tempDir -Force |
            Copy-Item -Destination $destination -Recurse -Force

        return [version]$version
    }
    finally {
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-RequiredModule {
    <#
        Tries up to three routes and verifies the result on disk. Presence is
        the only signal worth trusting: Install-Module reports errors it then
        recovers from, and recovers from errors it reports.

        -PreferDirectDownload skips the two scope-based routes. Both
        Install-PSResource -Scope CurrentUser and Install-Module -Scope
        CurrentUser write to the folder derived from your Documents location,
        so when that location is broken they cannot succeed and there is no
        point calling them just to print their failures.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DestinationRoot,
        [switch]$PreferDirectDownload
    )

    if (Get-Module -ListAvailable -Name $Name) {
        Write-Skip "$Name is already installed."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Install module')) { return }

    $attempts = @()

    if (-not $PreferDirectDownload) {
        # Route 1: PSResourceGet. Ships with PowerShell 7.4+ and does not use
        # PackageManagement, so it sidesteps the NuGet provider problem.
        if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
            try {
                Install-PSResource -Name $Name -Scope CurrentUser -TrustRepository `
                    -Reinstall -ErrorAction Stop -WarningAction SilentlyContinue
                $attempts += 'Install-PSResource'
            }
            catch {
                $attempts += "Install-PSResource failed ($($_.Exception.Message))"
            }
        }

        # Route 2: classic PowerShellGet.
        if (-not (Get-Module -ListAvailable -Name $Name)) {
            $installErrors = $null
            Install-Module -Name $Name -Repository PSGallery -Scope CurrentUser `
                -Force -AllowClobber -SkipPublisherCheck `
                -ErrorAction SilentlyContinue -WarningAction SilentlyContinue `
                -ErrorVariable installErrors

            if ($installErrors) {
                $attempts += "Install-Module failed ($($installErrors[0].Exception.Message))"
            }
            else {
                $attempts += 'Install-Module'
            }
        }
    }

    # Route 3: unpack the .nupkg by hand.
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        if (-not $DestinationRoot) {
            $attempts += 'nupkg fallback skipped (no writable module folder)'
        }
        else {
            try {
                Write-Skip "Falling back to a direct download for $Name..."
                $version = Install-ModuleFromGallery -Name $Name -DestinationRoot $DestinationRoot
                $attempts += "direct download ($version)"
            }
            catch {
                $attempts += "direct download failed ($($_.Exception.Message))"
            }
        }
    }

    $installed = Get-Module -ListAvailable -Name $Name |
                 Sort-Object Version -Descending | Select-Object -First 1

    if ($installed) {
        Write-Ok "$Name $($installed.Version) installed."
        Write-Verbose "Routes tried for $Name -- $($attempts -join '; ')"
        return
    }

    # Files may be on disk in a folder PowerShell does not search. That is a
    # different problem from a failed install and needs a different fix, so say
    # which one it is.
    $onDisk = if ($DestinationRoot) { Join-Path $DestinationRoot $Name } else { $null }

    if ($onDisk -and (Test-Path -LiteralPath $onDisk)) {
        Write-Fail "$Name was installed but PowerShell cannot see it."
        Write-Skip "  on disk at: $onDisk"
        Write-Skip '  that folder is not in $env:PSModulePath'
    }
    else {
        Write-Fail "$Name was NOT installed."
    }

    foreach ($attempt in $attempts) { Write-Skip "  $attempt" }
}

#endregion

#region Font installation -----------------------------------------------------

function Test-FontInstalled {
    <#
        Whitespace is stripped from both sides before comparing.

        The previous version searched the registry for "Hack Nerd Font" while
        the value names are built from filenames, so it was looking for
        "Hack Nerd Font" and the registry held "HackNerdFont-Bold (TrueType)".
        The font was installed and registered correctly; only the check was
        wrong. It also now accepts the files simply being present in the
        per-user font folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$NamePattern)

    $needle = ($NamePattern -replace '\s', '').ToLowerInvariant()

    $roots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($name in (Get-Item -LiteralPath $root).GetValueNames()) {
            if ((($name -replace '\s', '').ToLowerInvariant()) -like "*$needle*") { return $true }
        }
    }

    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (Test-Path -LiteralPath $fontDir) {
        $match = Get-ChildItem -LiteralPath $fontDir -File -ErrorAction SilentlyContinue |
                 Where-Object { (($_.BaseName -replace '\s', '').ToLowerInvariant()) -like "*$needle*" }
        if ($match) { return $true }
    }

    return $false
}

function Install-NerdFont {
    <#
        Installs into %LOCALAPPDATA%\Microsoft\Windows\Fonts and registers under
        HKCU, so no elevation is needed. Files already present at the right size
        are left alone rather than overwritten, because a .ttf loaded by a
        running process cannot be replaced and does not need to be.
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

        $copied = 0; $alreadyThere = 0; $registered = 0; $failed = @()

        foreach ($font in $fonts) {
            $dest     = Join-Path $fontDir $font.Name
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
                $registered++
            }
            catch {
                Write-Verbose "Could not register '$regName': $($_.Exception.Message)"
            }
        }

        $summary = "${FriendlyName}: $copied copied, $alreadyThere already present, $registered registered"
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

#endregion

#region Other helpers ---------------------------------------------------------

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

function Show-Diagnostics {
    [CmdletBinding()]
    param()

    Write-Step 'Host'
    Write-Skip "PowerShell     : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Skip "Script folder  : $(if ($LocalRoot) { $LocalRoot } else { '<none: running from a pipe>' })"

    Write-Step 'Profile candidates'
    Write-Skip "`$PROFILE                 : $($PROFILE.CurrentUserCurrentHost)"
    Write-Skip "MyDocuments              : $([Environment]::GetFolderPath('MyDocuments'))"
    Write-Skip "OneDrive                 : $($env:OneDrive)"
    Write-Skip "OneDriveCommercial       : $($env:OneDriveCommercial)"
    Write-Skip "USERPROFILE\Documents    : $(Join-Path $env:USERPROFILE 'Documents')"

    $profileFolder = Split-Path -Path $PROFILE.CurrentUserCurrentHost -Parent
    Write-Step "Writability of $profileFolder"
    if (Test-DirectoryWritable -Path $profileFolder) { Write-Ok 'Writable.' }
    else {
        Write-Fail 'NOT writable. Path breakdown:'
        Write-PathDiagnostic -Path $profileFolder
    }

    Write-Step 'PSModulePath (per-user entries)'
    $sep = [IO.Path]::PathSeparator
    if ($env:PSModulePath) {
        $env:PSModulePath -split $sep | Where-Object { $_ -and $_ -like "$env:USERPROFILE*" } |
            ForEach-Object { Write-Skip $_ }
    }
    $rootInfo = Resolve-UserModuleRoot
    if ($rootInfo) {
        Write-Skip "Resolved module root : $($rootInfo.Path)"
        Write-Skip "Searched by PowerShell: $($rootInfo.InModulePath)"
    }
    else {
        Write-Fail 'Resolved module root : none writable'
    }

    # A redirected Documents folder whose recorded path does not exist on disk
    # breaks $PROFILE and the per-user module folder at the same time, so check
    # for it explicitly and name the folder that is actually there.
    Write-Step 'Documents redirection'
    $recorded = [Environment]::GetFolderPath('MyDocuments')
    Write-Skip "Recorded Documents : $recorded"

    if ($recorded -and -not (Test-Path -LiteralPath $recorded)) {
        Write-Fail 'That folder does not exist. Siblings actually present:'
        $parent = Split-Path -Path $recorded -Parent
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Skip "  $($_.Name)" }
        }
    }
    elseif ($recorded) {
        Write-Ok 'That folder exists.'
    }

    Write-Step 'Package tooling'
    foreach ($cmd in 'Install-PSResource', 'Install-Module') {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { Write-Ok "$cmd available ($($found.Source) $($found.Version))" }
        else { Write-Fail "$cmd not available" }
    }

    Write-Step 'Fonts'
    Write-Skip "Hack Nerd Font detected : $(Test-FontInstalled -NamePattern 'Hack Nerd Font')"

    Write-Step 'Windows Terminal'
    Write-Skip "settings.json : $(Get-TerminalSettingsPath)"
    Write-Host ''
}

#endregion

#region Main ------------------------------------------------------------------

Write-Host ''
Write-Host 'PowerShell and Windows Terminal setup' -ForegroundColor White
Write-Host '-------------------------------------' -ForegroundColor DarkGray
Write-Host "Running under PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray

if ($Diagnose) {
    Show-Diagnostics
    return
}

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
    $preferDirect = $false

    if ($ModuleRoot) {
        $rootInfo = [PSCustomObject]@{
            Path         = $ModuleRoot
            InModulePath = Test-InModulePath -Path $ModuleRoot
        }
    }
    else {
        $rootInfo  = Resolve-UserModuleRoot
        $ModuleRoot = if ($rootInfo) { $rootInfo.Path } else { $null }
    }

    if (-not $ModuleRoot) {
        Write-Fail 'No writable per-user module folder found.'
    }
    else {
        Write-Skip "Module folder: $ModuleRoot"

        if (-not $rootInfo.InModulePath) {
            # We are not using the folder PowerShell would have used, so the
            # scope-based installers cannot help and whatever we put here will
            # be invisible until PSModulePath knows about it.
            $preferDirect = $true
            Write-Fail 'PowerShell does not currently search that folder.'
            Add-ToUserModulePath -Path $ModuleRoot
        }
    }

    $modules = @('Terminal-Icons', 'PowerColorLS')

    $psrl = Get-Module -ListAvailable -Name PSReadLine |
            Sort-Object Version -Descending | Select-Object -First 1
    if (-not $psrl -or $psrl.Version -lt [version]'2.2.0') { $modules += 'PSReadLine' }
    else { Write-Skip "PSReadLine $($psrl.Version) is recent enough." }

    foreach ($module in $modules) {
        Install-RequiredModule -Name $module -DestinationRoot $ModuleRoot `
            -PreferDirectDownload:$preferDirect
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
    Write-Skip 'Already installed.'
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

if (-not $ProfilePath) { $ProfilePath = Resolve-ProfilePath }

if (-not $ProfilePath) {
    Write-Fail 'No writable location for the profile was found.'
    Write-Skip 'Run with -Diagnose to see why, then pass a path explicitly:'
    Write-Skip '  .\ShellSetup.ps1 -ProfilePath "C:\path\to\Microsoft.PowerShell_profile.ps1"'
}
elseif ($PSCmdlet.ShouldProcess($ProfilePath, 'Install profile')) {
    try {
        Install-ConfigFile -FileName 'MyPwshProfile.ps1' -Destination $ProfilePath
        Write-Ok "Profile installed at $ProfilePath"

        if ($PSVersionTable.PSVersion.Major -ge 6 -and
            $ProfilePath -ne $PROFILE.CurrentUserCurrentHost) {

            $expectedFolder = Split-Path -Path $PROFILE.CurrentUserCurrentHost -Parent
            $recordedDocs   = [Environment]::GetFolderPath('MyDocuments')
            $realDocs       = Split-Path -Path (Split-Path -Path $ProfilePath -Parent) -Parent

            Write-Host ''
            Write-Fail 'This profile will NOT load automatically.'
            Write-Skip "PowerShell reads only: $($PROFILE.CurrentUserCurrentHost)"
            Write-Skip "and that folder is not writable: $expectedFolder"
            Write-Host ''
            Write-Skip 'Windows has your Documents folder recorded in one place and the'
            Write-Skip 'folder actually exists in another:'
            Write-Skip "  recorded : $recordedDocs"
            Write-Skip "  on disk  : $realDocs"
            Write-Host ''
            Write-Skip 'Point Windows at the real one, then sign out and back in:'
            Write-Skip ('  $real = "{0}"' -f $realDocs)
            Write-Skip "  `$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'"
            Write-Skip "  Set-ItemProperty `"`$k\User Shell Folders`" -Name Personal -Value `$real"
            Write-Skip "  Set-ItemProperty `"`$k\Shell Folders`"      -Name Personal -Value `$real"
            Write-Host ''
            Write-Skip 'Until then you can load it by hand with:'
            Write-Skip "  . '$ProfilePath'"
        }
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

if (Test-FontInstalled -NamePattern 'Hack Nerd Font') { Write-Ok 'Hack Nerd Font installed' }
else { Write-Fail 'Hack Nerd Font not installed' }

if ($ProfilePath -and (Test-Path -LiteralPath $ProfilePath)) { Write-Ok "Profile at $ProfilePath" }
else { Write-Fail 'Profile not installed' }

Write-Host ''
Write-Host 'Done. Restart Windows Terminal to pick up the changes.' -ForegroundColor Green
Write-Host ''

#endregion
