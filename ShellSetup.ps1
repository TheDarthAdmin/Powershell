#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up PowerShell 7 and Windows Terminal: modules, Oh My Posh and its
    theme, Hack Nerd Font, the profile, the background image, and Windows
    Terminal settings.

.DESCRIPTION
    Safe to run more than once: whatever is already in place is skipped, and
    whatever gets replaced is backed up first (only when it actually changed).

    Started from Windows PowerShell 5.1, the script installs PowerShell 7 if
    needed and then re-runs itself under pwsh, so modules land in the folder
    PowerShell 7 actually searches.

    Files are taken from the folder this script lives in when they are there,
    and downloaded from GitHub only as a fallback. Run it from a local checkout
    to install the files you are looking at rather than whatever is on the
    default branch.

.PARAMETER Diagnose
    Print the paths and tool versions this script depends on, then exit
    without changing anything. Start here when something fails.

.PARAMETER ProfilePath
    Where to write the profile. By default the script resolves the PowerShell 7
    profile location itself, including OneDrive-redirected Documents folders.

.PARAMETER ModuleRoot
    Where to install modules. Defaults to the first writable per-user entry in
    $env:PSModulePath.

.PARAMETER TerminalSettingsMode
    Merge (default) applies this repo's settings on top of your existing
    Windows Terminal settings.json and keeps your other profiles, schemes and
    key bindings. Replace overwrites the file completely. Both take a backup.

.PARAMETER SkipWslProfiles
    Leave WSL profiles in Windows Terminal alone. By default, Merge mode gives
    every WSL profile the DarthAdmin colour scheme and background, because the
    Ubuntu and Debian packages ship their own scheme that overrides the defaults.

.PARAMETER PoshTheme
    Oh My Posh theme to store locally for offline use. Must match
    $ProfileSettings.PoshTheme in the profile. Default: darthadmin, this repo's
    own theme. Any built-in Oh My Posh theme name works too (kali, paradox, ...).

.PARAMETER InstallExtras
    Also install fzf with PSFzf (Ctrl+T / Ctrl+R fuzzy search) and the Ookla
    Speedtest CLI used by Start-Speedtest.

.PARAMETER NerdFontVersion
    Nerd Fonts release tag, e.g. v3.4.0. Default: latest.

.PARAMETER SourceBranch
    Branch to download files from when they are not next to the script.

.EXAMPLE
    .\ShellSetup.ps1 -WhatIf

.EXAMPLE
    .\ShellSetup.ps1 -InstallExtras

.EXAMPLE
    .\ShellSetup.ps1 -TerminalSettingsMode Replace -SkipFont

.NOTES
    Run from a normal (non-elevated) prompt. Everything installs for the
    current user, so administrator rights are not needed.
    https://github.com/TheDarthAdmin/Powershell
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Diagnose,
    [string]$ProfilePath,
    [string]$ModuleRoot,
    [switch]$SkipModules,
    [switch]$SkipFont,
    [switch]$SkipBackground,
    [switch]$SkipTerminalSettings,
    [ValidateSet('Merge', 'Replace')]
    [string]$TerminalSettingsMode = 'Merge',
    [switch]$SkipWslProfiles,
    [string]$PoshTheme       = 'darthadmin',
    [switch]$InstallExtras,
    [string]$NerdFontVersion = 'latest',
    [string]$SourceBranch    = 'main',
    # Internal: set when the script re-launches itself under PowerShell 7.
    [switch]$NoRelaunch
)

# 'irm ... | iex' runs this file as loose text, not as a script: the param
# block and [CmdletBinding()] are ignored, so there is no $PSCmdlet, -WhatIf does
# nothing, and Set-StrictMode and $ErrorActionPreference would leak into your
# shell. Detect that and re-run the same code as a script block, which binds
# everything properly and keeps its settings to itself.
if (-not $ExecutionContext.SessionState.PSVariable.Get('PSCmdlet')) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $__setupUrl = 'https://raw.githubusercontent.com/TheDarthAdmin/Powershell/main/ShellSetup.ps1'
    & ([scriptblock]::Create((Invoke-RestMethod -Uri $__setupUrl -UseBasicParsing)))
    Remove-Variable -Name __setupUrl -ErrorAction Ignore
    return
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 defaults: TLS 1.0 only on some builds, and a progress
# bar that makes Invoke-WebRequest many times slower on large downloads.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
$ProgressPreference = 'SilentlyContinue'

$RepoRawBase      = "https://raw.githubusercontent.com/TheDarthAdmin/Powershell/$SourceBranch"
$GalleryApi       = 'https://www.powershellgallery.com/api/v2/package'
$LocalRoot        = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$AppDataRoot      = Join-Path $env:LOCALAPPDATA 'PwshShellSetup'
$BackgroundName   = 'darthadmin-terminal.png'
$PoshThemeFolder  = Join-Path $HOME '.config\oh-my-posh'

#region Output helpers --------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

#endregion

#region Environment helpers ---------------------------------------------------

function Update-SessionPath {
    <#
    .SYNOPSIS
        Reloads PATH from the registry so tools installed by winget a moment ago
        resolve in this session without opening a new tab.
    #>
    [CmdletBinding()]
    param()

    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($machine, $user, $env:Path) -join ';' -split ';' |
               Where-Object { $_ } | Select-Object -Unique
    $env:Path = $entries -join ';'
}

function Get-PwshPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $cmd = Get-Command pwsh -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

#endregion

#region Filesystem helpers ----------------------------------------------------

$script:LastWriteFailure = $null

function Test-DirectoryWritable {
    <#
    .SYNOPSIS
        Proves a directory accepts files by writing and deleting a probe file.

    .DESCRIPTION
        Creating a directory is not proof that you can put a file in it. On a
        OneDrive-redirected Documents folder New-Item can report success while
        the file write fails. On failure the reason is left in
        $script:LastWriteFailure.

        Under -WhatIf nothing is created: a missing folder is judged by probing
        its nearest existing parent instead.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $script:LastWriteFailure = $null

    try {
        $target = $Path
        if (-not (Test-Path -LiteralPath $target)) {
            if ($WhatIfPreference) {
                while ($target -and -not (Test-Path -LiteralPath $target)) { $target = Split-Path -Path $target -Parent }
                if (-not $target) { throw "No existing parent folder for '$Path'." }
            }
            else {
                New-Item -ItemType Directory -Path $target -Force -WhatIf:$false | Out-Null
            }
        }

        $probe = Join-Path $target (".probe-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'probe')
        Remove-Item -LiteralPath $probe -Force -WhatIf:$false -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        $script:LastWriteFailure = $_.Exception.Message
        Write-Verbose "Not writable: $Path -- $($_.Exception.Message)"
        return $false
    }
}

function Write-PathDiagnostic {
    <#
    .SYNOPSIS
        Walks a path segment by segment and reports which part is missing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $current = ''
    foreach ($part in ($Path -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        $current = if ($current) { Join-Path $current $part } else { "$part\" }

        if (Test-Path -LiteralPath $current) { Write-Skip "  [ok]      $current" }
        else { Write-Fail "  [missing] $current"; break }
    }
}

function Backup-File {
    <#
    .SYNOPSIS
        Copies a file next to itself with a timestamp. Returns the backup path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $backup = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Ok "Backed up existing file to $(Split-Path $backup -Leaf)"
    return $backup
}

function Get-SourceFile {
    <#
    .SYNOPSIS
        Stages a repo file in a temp location: from the local checkout when it
        is there, otherwise from GitHub. The caller deletes the temp file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FileName)

    $temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    $localSource = if ($LocalRoot) { Join-Path $LocalRoot $FileName } else { $null }

    if ($localSource -and (Test-Path -LiteralPath $localSource)) {
        Copy-Item -LiteralPath $localSource -Destination $temp -Force -WhatIf:$false
        Write-Skip "Source: local file $FileName"
    }
    else {
        $uri = "$RepoRawBase/$($FileName -replace '\\', '/')"
        Invoke-WebRequest -Uri $uri -OutFile $temp -UseBasicParsing
        Write-Skip "Source: $uri"
    }

    if ((Get-Item -LiteralPath $temp).Length -eq 0) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue -WhatIf:$false
        throw "Source file '$FileName' was empty."
    }
    return $temp
}

function Install-FileFromTemp {
    <#
    .SYNOPSIS
        Moves a staged file into place: skips it when unchanged, backs up the
        old version when it did change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $parent = Split-Path -Path $Destination -Parent
    if ($parent -and -not (Test-DirectoryWritable -Path $parent)) {
        Write-Fail "Cannot write into '$parent'. Path breakdown:"
        Write-PathDiagnostic -Path $parent
        throw "The folder '$parent' exists or was created but will not accept files."
    }

    if (Test-Path -LiteralPath $Destination) {
        $old = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        $new = (Get-FileHash -LiteralPath $Source      -Algorithm SHA256).Hash
        if ($old -eq $new) {
            Write-Skip "Unchanged: $Destination"
            return
        }
        Backup-File -Path $Destination | Out-Null
    }

    # Copy, not Move. File.Move (which Move-Item uses) is the operation that
    # fails on OneDrive placeholder folders; a stream copy goes through.
    Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Wrote '$Destination' without error but the file is not there."
    }
}

function Install-ConfigFile {
    <#
    .SYNOPSIS
        Puts a repo file in place. Staged through a temp file so a failed or
        truncated download can never destroy the file being replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$ValidateJson
    )

    $temp = Get-SourceFile -FileName $FileName
    try {
        if ($ValidateJson) { $null = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Jsonc }
        Install-FileFromTemp -Source $temp -Destination $Destination
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

#endregion

#region JSON helpers ----------------------------------------------------------

function ConvertFrom-Jsonc {
    <#
    .SYNOPSIS
        ConvertFrom-Json that accepts what Windows Terminal accepts: // and /* */
        comments and trailing commas. Windows PowerShell 5.1 rejects all three.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Json)

    process {
        $sb = New-Object System.Text.StringBuilder $Json.Length
        $i = 0; $n = $Json.Length; $inString = $false

        while ($i -lt $n) {
            $c = $Json[$i]

            if ($inString) {
                [void]$sb.Append($c)
                if ($c -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($Json[$i + 1]); $i += 2; continue }
                if ($c -eq '"') { $inString = $false }
                $i++; continue
            }

            if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }

            if ($c -eq '/' -and $i + 1 -lt $n -and $Json[$i + 1] -eq '/') {
                while ($i -lt $n -and $Json[$i] -ne "`n") { $i++ }
                continue
            }
            if ($c -eq '/' -and $i + 1 -lt $n -and $Json[$i + 1] -eq '*') {
                $end = $Json.IndexOf('*/', $i + 2)
                $i = if ($end -lt 0) { $n } else { $end + 2 }
                continue
            }
            if ($c -eq ',') {
                $j = $i + 1
                while ($j -lt $n -and [char]::IsWhiteSpace($Json[$j])) { $j++ }
                if ($j -lt $n -and ($Json[$j] -eq '}' -or $Json[$j] -eq ']')) { $i++; continue }
            }

            [void]$sb.Append($c); $i++
        }

        $sb.ToString() | ConvertFrom-Json
    }
}

function Test-JsonObject {
    [OutputType([bool])]
    param($Value)
    $Value -is [System.Management.Automation.PSCustomObject]
}

function Merge-JsonNode {
    <#
    .SYNOPSIS
        Deep-merges $Source into $Target (both from ConvertFrom-Json).

    .DESCRIPTION
        Objects merge key by key with the source winning. Arrays of objects
        that Windows Terminal identifies by a key are merged by that key; any
        other array is replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Source
    )

    $arrayKeys = @{
        list        = 'guid'
        schemes     = 'name'
        themes      = 'name'
        actions     = 'id'
        keybindings = 'keys'
    }

    foreach ($prop in $Source.PSObject.Properties) {
        $name     = $prop.Name
        $srcValue = $prop.Value
        $existing = $Target.PSObject.Properties[$name]

        if (-not $existing) {
            $Target | Add-Member -NotePropertyName $name -NotePropertyValue $srcValue
            continue
        }

        $tgtValue = $existing.Value

        if ((Test-JsonObject $srcValue) -and (Test-JsonObject $tgtValue)) {
            Merge-JsonNode -Target $tgtValue -Source $srcValue
        }
        elseif ($srcValue -is [array] -and $tgtValue -is [array] -and $arrayKeys.ContainsKey($name)) {
            $key    = $arrayKeys[$name]
            $merged = New-Object System.Collections.Generic.List[object]
            foreach ($item in $tgtValue) { $merged.Add($item) }

            foreach ($item in $srcValue) {
                $id = if ((Test-JsonObject $item) -and $item.PSObject.Properties[$key]) { $item.$key } else { $null }
                $match = $null
                if ($null -ne $id) {
                    $match = $merged | Where-Object {
                        (Test-JsonObject $_) -and $_.PSObject.Properties[$key] -and $_.$key -eq $id
                    } | Select-Object -First 1
                }

                if ($match) { Merge-JsonNode -Target $match -Source $item }
                else        { $merged.Add($item) }
            }
            $existing.Value = $merged.ToArray()
        }
        else {
            $existing.Value = $srcValue
        }
    }
}

function Test-WslTerminalProfile {
    <#
    .SYNOPSIS
        True for Windows Terminal profiles that open a WSL distribution.
    #>
    [OutputType([bool])]
    param($TerminalProfile)

    $source  = if ($TerminalProfile.PSObject.Properties['source'])      { [string]$TerminalProfile.source }      else { '' }
    $command = if ($TerminalProfile.PSObject.Properties['commandline']) { [string]$TerminalProfile.commandline } else { '' }

    # Windows.Terminal.Wsl (built-in generator), Microsoft.WSL (WSL's own
    # fragment), and distro packages such as CanonicalGroupLimited.Ubuntu_*.
    ($source -match '(?i)wsl|canonical|debianproject|suse|kalilinux|almalinux|oracleamerica|redhat|fedora') -or
    ($command -match '(?i)(^|[\\/\s"])wsl(\.exe)?(\s|"|$)')
}

function Merge-TerminalConfig {
    <#
    .SYNOPSIS
        Applies this repo's settings.json on top of an existing one and returns
        the merged JSON text.

    .DESCRIPTION
        With -StyleWslProfiles, WSL profiles also get the colour scheme and
        background of the repo's PowerShell profile, so every tab looks alike.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingJson,
        [Parameter(Mandatory)][string]$RepoJson,
        [switch]$StyleWslProfiles,
        [switch]$NoBackground
    )

    $target = if ([string]::IsNullOrWhiteSpace($ExistingJson)) { [PSCustomObject]@{} } else { $ExistingJson | ConvertFrom-Jsonc }
    $source = $RepoJson | ConvertFrom-Jsonc

    # Very old settings files kept profiles as a bare array.
    if ($target.PSObject.Properties['profiles'] -and $target.profiles -is [array]) {
        $target.profiles = [PSCustomObject]@{ list = $target.profiles }
    }

    Merge-JsonNode -Target $target -Source $source

    if ($StyleWslProfiles -and $target.PSObject.Properties['profiles'] -and
        $target.profiles.PSObject.Properties['list']) {

        $look = [ordered]@{}
        if ($source.profiles.defaults.PSObject.Properties['colorScheme']) {
            $look['colorScheme'] = $source.profiles.defaults.colorScheme
        }

        $pwshProfile = $source.profiles.list |
            Where-Object { $_.PSObject.Properties['guid'] -and $_.guid -eq '{574e775e-4f2a-5b96-ac1e-a2962a402336}' } |
            Select-Object -First 1
        $copy = @('opacity', 'useAcrylic')
        if (-not $NoBackground) {
            $copy += 'backgroundImage', 'backgroundImageAlignment', 'backgroundImageOpacity', 'backgroundImageStretchMode'
        }
        foreach ($key in $copy) {
            if ($pwshProfile -and $pwshProfile.PSObject.Properties[$key]) { $look[$key] = $pwshProfile.$key }
        }

        foreach ($terminalProfile in @($target.profiles.list)) {
            if (-not (Test-WslTerminalProfile $terminalProfile)) { continue }
            foreach ($entry in $look.GetEnumerator()) {
                $terminalProfile | Add-Member -Force -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
            }
            Write-Skip "WSL profile styled: $($terminalProfile.name)"
        }
    }

    $target | ConvertTo-Json -Depth 32
}

#endregion

#region Path resolution -------------------------------------------------------

function Resolve-ProfilePath {
    <#
    .SYNOPSIS
        Returns a PowerShell 7 profile path whose folder accepts files, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = New-Object System.Collections.Generic.List[string]

    # PowerShell 7's own answer first, because that is the only path it loads.
    if ($PSVersionTable.PSVersion.Major -ge 6) { $candidates.Add($PROFILE.CurrentUserCurrentHost) }

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
    <#
    .SYNOPSIS
        Is this folder one PowerShell actually searches for modules?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $env:PSModulePath) { return $false }
    $target = $Path.TrimEnd('\', '/').ToLowerInvariant()
    foreach ($entry in ($env:PSModulePath -split [IO.Path]::PathSeparator)) {
        if ($entry -and $entry.TrimEnd('\', '/').ToLowerInvariant() -eq $target) { return $true }
    }
    return $false
}

function Resolve-UserModuleRoot {
    <#
    .SYNOPSIS
        Returns the module folder to use and whether PowerShell searches it.

    .DESCRIPTION
        Both matter: modules installed into a folder PowerShell never searches
        are as good as not installed.
    #>
    [CmdletBinding()]
    param()

    $sep = [IO.Path]::PathSeparator
    $userPrefixes = @($env:USERPROFILE, $HOME, $env:OneDrive, $env:OneDriveCommercial) | Where-Object { $_ }
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:PSModulePath) {
        foreach ($entry in ($env:PSModulePath -split $sep)) {
            if ($entry -and ($userPrefixes | Where-Object { $entry -like "$_*" })) { $candidates.Add($entry) }
        }
    }
    foreach ($base in @($env:OneDrive, $env:OneDriveCommercial, $env:USERPROFILE)) {
        if ($base) { $candidates.Add((Join-Path $base 'Documents\PowerShell\Modules')) }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-DirectoryWritable -Path $candidate) {
            return [PSCustomObject]@{ Path = $candidate; InModulePath = Test-InModulePath -Path $candidate }
        }
        Write-Skip "Not usable: $candidate"
        if ($script:LastWriteFailure) { Write-Skip "  reason: $script:LastWriteFailure" }
    }
    return $null
}

function Add-ToUserModulePath {
    <#
    .SYNOPSIS
        Adds a folder to PSModulePath for this session and future ones.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    $sep = [IO.Path]::PathSeparator
    if (-not $PSCmdlet.ShouldProcess('PSModulePath (user environment variable)', "Add '$Path'")) { return }

    try {
        $persisted = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
        $entries   = @()
        if ($persisted) { $entries = @($persisted -split $sep | Where-Object { $_ }) }

        if ($entries -notcontains $Path) {
            [Environment]::SetEnvironmentVariable('PSModulePath', (($entries + $Path) -join $sep), 'User')
            Write-Ok "Added to your PSModulePath: $Path"
        }
        else { Write-Skip 'Already in your persisted PSModulePath.' }
    }
    catch { Write-Fail "Could not persist PSModulePath: $($_.Exception.Message)" }

    if (-not (Test-InModulePath -Path $Path)) { $env:PSModulePath = "$($env:PSModulePath)$sep$Path" }
}

#endregion

#region Module installation ---------------------------------------------------

function Install-ModuleFromGallery {
    <#
    .SYNOPSIS
        Downloads a .nupkg from the PowerShell Gallery and unpacks it into the
        user's module folder.

    .DESCRIPTION
        Install-Module can fail with "Administrator rights are required" even
        with -Scope CurrentUser, because PackageManagement's NuGet provider
        wants to bootstrap itself machine-wide. A .nupkg is just a zip and a
        module folder is just a folder, so neither is needed.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $tempZip = Join-Path ([IO.Path]::GetTempPath()) ("$Name-{0}.zip" -f [guid]::NewGuid().ToString('N'))
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("$Name-{0}"     -f [guid]::NewGuid().ToString('N'))

    try {
        Invoke-WebRequest -Uri "$GalleryApi/$Name" -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempDir -Force

        $nuspec = Get-ChildItem -LiteralPath $tempDir -Filter '*.nuspec' -File | Select-Object -First 1
        if (-not $nuspec) { throw 'The package contained no .nuspec, so the version is unknown.' }

        $version = ([xml](Get-Content -LiteralPath $nuspec.FullName -Raw)).package.metadata.version
        if (-not $version) { throw 'Could not read the version from the .nuspec.' }

        # NuGet packaging artefacts are not part of the module. Prerelease
        # suffixes are not valid in a module folder name either.
        foreach ($cruft in '_rels', 'package', '[Content_Types].xml', $nuspec.Name) {
            $path = Join-Path $tempDir $cruft
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        $folderVersion = ($version -split '-')[0]

        $destination = Join-Path $DestinationRoot (Join-Path $Name $folderVersion)
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        Get-ChildItem -LiteralPath $tempDir -Force | Copy-Item -Destination $destination -Recurse -Force
        return [version]$folderVersion
    }
    finally {
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-RequiredModule {
    <#
    .SYNOPSIS
        Installs a module through up to three routes and verifies it on disk.

    .DESCRIPTION
        Presence is the only signal worth trusting: Install-Module reports
        errors it then recovers from, and recovers from errors it reports.
        -PreferDirectDownload skips the scope-based routes, which cannot work
        when the Documents-derived module folder is broken.
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
        # Route 1: PSResourceGet (PowerShell 7.4+), which avoids PackageManagement.
        if (Get-Command Install-PSResource -ErrorAction Ignore) {
            try {
                Install-PSResource -Name $Name -Scope CurrentUser -TrustRepository `
                    -Reinstall -ErrorAction Stop -WarningAction SilentlyContinue
                $attempts += 'Install-PSResource'
            }
            catch { $attempts += "Install-PSResource failed ($($_.Exception.Message))" }
        }

        # Route 2: classic PowerShellGet.
        if (-not (Get-Module -ListAvailable -Name $Name)) {
            $installErrors = $null
            Install-Module -Name $Name -Repository PSGallery -Scope CurrentUser `
                -Force -AllowClobber -SkipPublisherCheck `
                -ErrorAction SilentlyContinue -WarningAction SilentlyContinue `
                -ErrorVariable installErrors
            if ($installErrors) { $attempts += "Install-Module failed ($($installErrors[0].Exception.Message))" }
            else { $attempts += 'Install-Module' }
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
            catch { $attempts += "direct download failed ($($_.Exception.Message))" }
        }
    }

    $installed = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    if ($installed) {
        Write-Ok "$Name $($installed.Version) installed."
        Write-Verbose "Routes tried for $Name -- $($attempts -join '; ')"
        return
    }

    $onDisk = if ($DestinationRoot) { Join-Path $DestinationRoot $Name } else { $null }
    if ($onDisk -and (Test-Path -LiteralPath $onDisk)) {
        Write-Fail "$Name was installed but PowerShell cannot see it."
        Write-Skip "  on disk at: $onDisk"
        Write-Skip '  that folder is not in $env:PSModulePath'
    }
    else { Write-Fail "$Name was NOT installed." }

    foreach ($attempt in $attempts) { Write-Skip "  $attempt" }
}

#endregion

#region Font installation -----------------------------------------------------

function Test-FontInstalled {
    <#
    .SYNOPSIS
        Looks for a font in the HKCU/HKLM font registrations or the per-user
        font folder, ignoring whitespace ("Hack Nerd Font" vs "HackNerdFont-Bold").
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$NamePattern)

    $needle = ($NamePattern -replace '\s', '').ToLowerInvariant()

    foreach ($root in 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
                      'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
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
    .SYNOPSIS
        Installs a Nerd Font for the current user (no elevation).

    .DESCRIPTION
        Files already present at the same size are left alone, because a .ttf
        loaded by a running process cannot be replaced and does not need to be.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FriendlyName
    )

    $zipPath     = Join-Path ([IO.Path]::GetTempPath()) ("NerdFont-{0}.zip" -f [guid]::NewGuid().ToString('N'))
    $extractPath = Join-Path ([IO.Path]::GetTempPath()) ("NerdFont-{0}"     -f [guid]::NewGuid().ToString('N'))
    $fontDir     = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $regPath     = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

    try {
        Write-Skip "Downloading $FriendlyName..."
        Invoke-WebRequest -Uri $Url -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $fonts = @(Get-ChildItem -Path $extractPath -Include '*.ttf', '*.otf' -File -Recurse)
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
                    if ($existing) { $alreadyThere++; Write-Verbose "In use, keeping existing copy: $($font.Name)" }
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
                New-ItemProperty -Path $regPath -Name $regName -Value $dest -PropertyType String -Force -ErrorAction Stop | Out-Null
                $registered++
            }
            catch { Write-Verbose "Could not register '$regName': $($_.Exception.Message)" }
        }

        Write-Ok "${FriendlyName}: $copied copied, $alreadyThere already present, $registered registered."
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
    <#
    .SYNOPSIS
        Finds settings.json for Store, Preview, and unpackaged Windows Terminal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    foreach ($path in $candidates) { if (Test-Path -LiteralPath $path) { return $path } }
    foreach ($path in $candidates) { if (Test-Path -LiteralPath (Split-Path $path -Parent)) { return $path } }
    return $null
}

function Install-WingetPackage {
    <#
    .SYNOPSIS
        Installs a winget package unless its command already resolves.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$FriendlyName,
        [string]$CommandName
    )

    if ($CommandName -and (Get-Command $CommandName -CommandType Application -ErrorAction Ignore)) {
        Write-Skip "$FriendlyName is already installed."
        return
    }
    if (-not (Get-Command winget -CommandType Application -ErrorAction Ignore)) {
        Write-Fail "winget is not available. Install $FriendlyName manually."
        return
    }
    if (-not $PSCmdlet.ShouldProcess($FriendlyName, "winget install $Id")) { return }

    winget install --id $Id --exact --source winget `
        --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
    $code = $LASTEXITCODE

    Update-SessionPath

    switch ($code) {
        0           { Write-Ok "$FriendlyName installed." }
        -1978335189 { Write-Skip "$FriendlyName is already up to date." }   # 0x8A15002B
        -1978335135 { Write-Skip "$FriendlyName is already installed." }    # 0x8A150061
        default     { Write-Fail "winget returned exit code $code for $FriendlyName." }
    }
}

function Install-PoshTheme {
    <#
    .SYNOPSIS
        Stores an Oh My Posh theme in ~/.config/oh-my-posh so the profile can
        load it offline. Newer (MSIX) Oh My Posh builds no longer ship themes
        next to the executable or set POSH_THEMES_PATH.

    .DESCRIPTION
        Looks in this repo's themes folder first (local checkout, then GitHub),
        then in POSH_THEMES_PATH, then in the Oh My Posh repository.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $destination = Join-Path $PoshThemeFolder "$Name.omp.json"
    $temp = $null

    try {
        try {
            $temp = Get-SourceFile -FileName "themes/$Name.omp.json"
        }
        catch {
            Write-Verbose "Not a repo theme: $Name ($($_.Exception.Message))"
            $temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())

            $local = if ($env:POSH_THEMES_PATH) { Join-Path $env:POSH_THEMES_PATH "$Name.omp.json" } else { $null }
            if ($local -and (Test-Path -LiteralPath $local)) {
                Copy-Item -LiteralPath $local -Destination $temp -Force -WhatIf:$false
                Write-Skip "Source: $local"
            }
            else {
                $uri = "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/$Name.omp.json"
                Invoke-WebRequest -Uri $uri -OutFile $temp -UseBasicParsing
                Write-Skip "Source: $uri"
            }
        }

        $null = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Jsonc
        Install-FileFromTemp -Source $temp -Destination $destination
        Write-Ok "Theme '$Name' available at $destination"
    }
    finally {
        if ($temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }
}

function Show-SetupDiagnostic {
    [CmdletBinding()]
    param()

    Write-Step 'Host'
    Write-Skip "PowerShell     : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Skip "pwsh on PATH   : $(Get-PwshPath)"
    Write-Skip "Script folder  : $(if ($LocalRoot) { $LocalRoot } else { '<none: running from a pipe>' })"

    Write-Step 'Profile candidates'
    Write-Skip "`$PROFILE              : $($PROFILE.CurrentUserCurrentHost)"
    Write-Skip "MyDocuments           : $([Environment]::GetFolderPath('MyDocuments'))"
    Write-Skip "OneDrive              : $($env:OneDrive)"
    Write-Skip "OneDriveCommercial    : $($env:OneDriveCommercial)"
    Write-Skip "USERPROFILE\Documents : $(Join-Path $env:USERPROFILE 'Documents')"

    $profileFolder = Split-Path -Path $PROFILE.CurrentUserCurrentHost -Parent
    Write-Step "Writability of $profileFolder"
    if (Test-DirectoryWritable -Path $profileFolder) { Write-Ok 'Writable.' }
    else { Write-Fail 'NOT writable. Path breakdown:'; Write-PathDiagnostic -Path $profileFolder }

    Write-Step 'PSModulePath (per-user entries)'
    if ($env:PSModulePath) {
        $env:PSModulePath -split [IO.Path]::PathSeparator |
            Where-Object { $_ -and $_ -like "$env:USERPROFILE*" } | ForEach-Object { Write-Skip $_ }
    }
    $rootInfo = Resolve-UserModuleRoot
    if ($rootInfo) {
        Write-Skip "Resolved module root   : $($rootInfo.Path)"
        Write-Skip "Searched by PowerShell : $($rootInfo.InModulePath)"
    }
    else { Write-Fail 'Resolved module root : none writable' }

    Write-Step 'Documents redirection'
    $recorded = [Environment]::GetFolderPath('MyDocuments')
    Write-Skip "Recorded Documents : $recorded"
    if ($recorded -and -not (Test-Path -LiteralPath $recorded)) {
        Write-Fail 'That folder does not exist. Siblings actually present:'
        $parent = Split-Path -Path $recorded -Parent
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | ForEach-Object { Write-Skip "  $($_.Name)" }
        }
    }
    elseif ($recorded) { Write-Ok 'That folder exists.' }

    Write-Step 'Tools'
    foreach ($cmd in 'Install-PSResource', 'Install-Module') {
        $found = Get-Command $cmd -ErrorAction Ignore
        if ($found) { Write-Ok "$cmd available ($($found.Source) $($found.Version))" } else { Write-Fail "$cmd not available" }
    }
    foreach ($exe in 'winget', 'oh-my-posh', 'fzf', 'speedtest') {
        $found = Get-Command $exe -CommandType Application -ErrorAction Ignore | Select-Object -First 1
        if ($found) { Write-Ok "$exe : $($found.Source)" } else { Write-Skip "$exe : not found" }
    }

    Write-Step 'Oh My Posh theme'
    $themeFile = Join-Path $PoshThemeFolder "$PoshTheme.omp.json"
    Write-Skip "Local copy       : $themeFile ($(Test-Path -LiteralPath $themeFile))"
    Write-Skip "POSH_THEMES_PATH : $($env:POSH_THEMES_PATH)"

    Write-Step 'Fonts'
    Write-Skip "Hack Nerd Font detected : $(Test-FontInstalled -NamePattern 'Hack Nerd Font')"

    Write-Step 'Windows Terminal'
    Write-Skip "settings.json : $(Get-TerminalSettingsPath)"
    Write-Skip "background    : $(Join-Path $AppDataRoot $BackgroundName)"
    Write-Host ''
}

#endregion

#region Main ------------------------------------------------------------------

Write-Host ''
Write-Host 'PowerShell and Windows Terminal setup' -ForegroundColor White
Write-Host '-------------------------------------' -ForegroundColor DarkGray
Write-Host "Running under PowerShell $($PSVersionTable.PSVersion)$(if ($WhatIfPreference) { '  [WhatIf: no changes]' })" -ForegroundColor DarkGray

# --- 0. Get into PowerShell 7 ----------------------------------------------
# Modules installed from Windows PowerShell land in Documents\WindowsPowerShell,
# which PowerShell 7 does not search. Doing the whole run under pwsh avoids that.
if ($PSVersionTable.PSVersion.Major -lt 7 -and -not $NoRelaunch -and -not $Diagnose) {
    Write-Step 'PowerShell 7'
    $pwsh = Get-PwshPath
    if (-not $pwsh) {
        Install-WingetPackage -Id 'Microsoft.PowerShell' -FriendlyName 'PowerShell 7' -CommandName 'pwsh'
        $pwsh = Get-PwshPath
    }

    if (-not $pwsh) {
        Write-Fail 'PowerShell 7 is not available, so the setup cannot continue.'
        Write-Skip 'Install it with: winget install Microsoft.PowerShell'
        return
    }

    # A script piped into iex has no file to relaunch, so save a copy.
    $scriptFile = $PSCommandPath
    if (-not $scriptFile) {
        $scriptFile = Join-Path ([IO.Path]::GetTempPath()) 'ShellSetup.ps1'
        Invoke-WebRequest -Uri "$RepoRawBase/ShellSetup.ps1" -OutFile $scriptFile -UseBasicParsing
    }

    $forward = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptFile, '-NoRelaunch')
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'NoRelaunch') { continue }
        if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($entry.Value.IsPresent) { $forward += "-$($entry.Key)" }
        }
        else { $forward += "-$($entry.Key)"; $forward += "$($entry.Value)" }
    }

    Write-Ok "Continuing under $pwsh"
    & $pwsh @forward
    return
}

if ($Diagnose) {
    Show-SetupDiagnostic
    return
}

# --- 1. Modules -------------------------------------------------------------
Write-Step 'PowerShell modules'

if ($SkipModules) {
    Write-Skip 'Skipped (-SkipModules).'
}
else {
    $preferDirect = $false
    $rootInfo = $null

    if ($ModuleRoot) {
        $rootInfo = [PSCustomObject]@{ Path = $ModuleRoot; InModulePath = Test-InModulePath -Path $ModuleRoot }
    }
    else {
        $rootInfo   = Resolve-UserModuleRoot
        $ModuleRoot = if ($rootInfo) { $rootInfo.Path } else { $null }
    }

    if (-not $ModuleRoot) {
        Write-Fail 'No writable per-user module folder found.'
    }
    else {
        Write-Skip "Module folder: $ModuleRoot"
        if (-not $rootInfo.InModulePath) {
            $preferDirect = $true
            Write-Fail 'PowerShell does not currently search that folder.'
            Add-ToUserModulePath -Path $ModuleRoot
        }
    }

    $modules = @('Terminal-Icons', 'PowerColorLS')

    $psrl = Get-Module -ListAvailable -Name PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $psrl -or $psrl.Version -lt [version]'2.2.2') { $modules += 'PSReadLine' }
    else { Write-Skip "PSReadLine $($psrl.Version) is recent enough." }

    if ($PSVersionTable.PSVersion -ge [version]'7.2') { $modules += 'CompletionPredictor' }
    if ($InstallExtras) { $modules += 'PSFzf' }

    foreach ($module in $modules) {
        Install-RequiredModule -Name $module -DestinationRoot $ModuleRoot -PreferDirectDownload:$preferDirect
    }
}

# --- 2. Command-line tools --------------------------------------------------
Write-Step 'Oh My Posh'
Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -FriendlyName 'Oh My Posh' -CommandName 'oh-my-posh'

if ($PSCmdlet.ShouldProcess("$PoshTheme.omp.json", 'Store Oh My Posh theme locally')) {
    try { Install-PoshTheme -Name $PoshTheme }
    catch { Write-Fail "Could not store the theme: $($_.Exception.Message)" }
}

if ($InstallExtras) {
    Write-Step 'Extras'
    Install-WingetPackage -Id 'junegunn.fzf'        -FriendlyName 'fzf'           -CommandName 'fzf'
    Install-WingetPackage -Id 'Ookla.Speedtest.CLI' -FriendlyName 'Speedtest CLI' -CommandName 'speedtest'
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
        $fontUrl = if ($NerdFontVersion -eq 'latest') {
            'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.zip'
        }
        else {
            "https://github.com/ryanoasis/nerd-fonts/releases/download/$NerdFontVersion/Hack.zip"
        }
        Install-NerdFont -Url $fontUrl -FriendlyName 'Hack Nerd Font'
    }
    catch { Write-Fail "Font installation failed: $($_.Exception.Message)" }
}

# --- 4. PowerShell profile --------------------------------------------------
Write-Step 'PowerShell profile'

$profilePathGiven = [bool]$ProfilePath
if (-not $ProfilePath) { $ProfilePath = Resolve-ProfilePath }

if (-not $ProfilePath) {
    Write-Fail 'No writable location for the profile was found.'
    Write-Skip 'Run with -Diagnose to see why, then pass a path explicitly:'
    Write-Skip '  .\ShellSetup.ps1 -ProfilePath "C:\path\to\Microsoft.PowerShell_profile.ps1"'
}
elseif ($PSCmdlet.ShouldProcess($ProfilePath, 'Install profile')) {
    try {
        Install-ConfigFile -FileName 'MyPwshProfile.ps1' -Destination $ProfilePath
        Write-Ok "Profile at $ProfilePath"

        if ($profilePathGiven -and $ProfilePath -ne $PROFILE.CurrentUserCurrentHost) {
            Write-Skip "PowerShell 7 only loads $($PROFILE.CurrentUserCurrentHost) on its own."
            Write-Skip "Dot-source this file from there if you want it loaded: . '$ProfilePath'"
        }
        elseif ($ProfilePath -ne $PROFILE.CurrentUserCurrentHost) {
            # The resolver had to fall back, which means the Documents folder
            # PowerShell uses for $PROFILE is broken. Explain how to fix it.
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
    catch { Write-Fail "Could not install the profile: $($_.Exception.Message)" }
}

# --- 5. Background image ----------------------------------------------------
Write-Step 'Terminal background'
$backgroundPath = Join-Path $AppDataRoot $BackgroundName

if ($SkipBackground) {
    Write-Skip 'Skipped (-SkipBackground).'
}
elseif ($PSCmdlet.ShouldProcess($backgroundPath, 'Install background image')) {
    try {
        Install-ConfigFile -FileName "assets/$BackgroundName" -Destination $backgroundPath
        Write-Ok "Background at $backgroundPath"
    }
    catch { Write-Fail "Could not install the background: $($_.Exception.Message)" }
}

# --- 6. Windows Terminal settings -------------------------------------------
Write-Step "Windows Terminal settings ($TerminalSettingsMode)"

if ($SkipTerminalSettings) {
    Write-Skip 'Skipped (-SkipTerminalSettings).'
}
else {
    $terminalSettings = Get-TerminalSettingsPath

    if (-not $terminalSettings) {
        Write-Fail 'Windows Terminal was not found. Skipping its settings.'
    }
    elseif ($PSCmdlet.ShouldProcess($terminalSettings, "$TerminalSettingsMode settings.json")) {
        try {
            if ($TerminalSettingsMode -eq 'Replace') {
                Install-ConfigFile -FileName 'settings.json' -Destination $terminalSettings -ValidateJson
                if (-not $SkipWslProfiles) {
                    Write-Skip 'WSL profiles are only styled in Merge mode; run again without -TerminalSettingsMode Replace.'
                }
            }
            else {
                $repoTemp = Get-SourceFile -FileName 'settings.json'
                $outTemp  = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
                try {
                    $existing = if (Test-Path -LiteralPath $terminalSettings) { Get-Content -LiteralPath $terminalSettings -Raw } else { '' }
                    $merged   = Merge-TerminalConfig -ExistingJson $existing -RepoJson (Get-Content -LiteralPath $repoTemp -Raw) `
                                    -StyleWslProfiles:(-not $SkipWslProfiles) -NoBackground:$SkipBackground
                    $null     = $merged | ConvertFrom-Json   # sanity check before touching the real file
                    [IO.File]::WriteAllText($outTemp, $merged, (New-Object System.Text.UTF8Encoding $false))
                    Install-FileFromTemp -Source $outTemp -Destination $terminalSettings
                }
                finally {
                    Remove-Item -LiteralPath $repoTemp, $outTemp -Force -ErrorAction SilentlyContinue -WhatIf:$false
                }
            }
            Write-Ok "Terminal settings at $terminalSettings"
        }
        catch { Write-Fail "Could not update the Terminal settings: $($_.Exception.Message)" }
    }
}

# --- 7. Verify --------------------------------------------------------------
Write-Step 'Result'

$expectedModules = @('Terminal-Icons', 'PowerColorLS', 'PSReadLine')
if ($PSVersionTable.PSVersion -ge [version]'7.2') { $expectedModules += 'CompletionPredictor' }
if ($InstallExtras) { $expectedModules += 'PSFzf' }

foreach ($module in $expectedModules) {
    $found = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
    if ($found) { Write-Ok "$module $($found.Version)" } else { Write-Fail "$module missing" }
}

$tools = [ordered]@{ 'oh-my-posh' = 'Oh My Posh' }
if ($InstallExtras) { $tools['fzf'] = 'fzf'; $tools['speedtest'] = 'Speedtest CLI' }
foreach ($tool in $tools.GetEnumerator()) {
    if (Get-Command $tool.Key -CommandType Application -ErrorAction Ignore) { Write-Ok "$($tool.Value) on PATH" }
    else { Write-Fail "$($tool.Value) not on PATH in this session (open a new tab)" }
}

$checks = [ordered]@{
    'Oh My Posh theme' = Join-Path $PoshThemeFolder "$PoshTheme.omp.json"
    'Profile'          = $ProfilePath
    'Background'       = $backgroundPath
}
foreach ($check in $checks.GetEnumerator()) {
    if ($check.Value -and (Test-Path -LiteralPath $check.Value)) { Write-Ok "$($check.Key) installed" }
    else { Write-Fail "$($check.Key) not installed" }
}

if (Test-FontInstalled -NamePattern 'Hack Nerd Font') { Write-Ok 'Hack Nerd Font installed' }
else { Write-Fail 'Hack Nerd Font not installed' }

Write-Host ''
Write-Host 'Done. Restart Windows Terminal to pick up the changes.' -ForegroundColor Green
Write-Host ''

#endregion
