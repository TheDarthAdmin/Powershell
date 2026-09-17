<#
    MyPwshProfile.ps1 -- PowerShell 7 profile
    https://github.com/TheDarthAdmin/Powershell

    House rules for this file:
      * It never throws. Every section is wrapped, and a failing section
        becomes a warning instead of a broken shell.
      * It never installs anything. ShellSetup.ps1 installs; this file only
        loads what is already there.
      * It never touches the network at startup. Commands that need the
        network (Get-WanIp, Get-EntraTenantId, ...) only do so when you run them.
      * It stays quiet. Nothing is printed on a normal start.

    Run Get-ProfileCommand to list what this profile adds.
#>

# Windows PowerShell 5.1 uses a different profile path, but if this file is
# ever dot-sourced there by hand, stop instead of erroring on 7-only syntax.
if ($PSVersionTable.PSVersion.Major -lt 7) { return }

# ---------------------------------------------------------------------------
# Settings -- the only block you should need to edit
# ---------------------------------------------------------------------------
$ProfileSettings = @{
    # Oh My Posh theme name. ShellSetup.ps1 stores a local copy of it in
    # ~/.config/oh-my-posh so the prompt works offline.
    PoshTheme           = 'kali'

    # Extra patterns that keep a command line out of the on-disk history file.
    # PSReadLine 2.2+ already filters password/secret/token/apikey/asplaintext;
    # these add Microsoft 365 / Entra specifics on top of that.
    HistoryExtraPatterns = @(
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'   # JWT (access/ID tokens)
        '\bsig=[A-Za-z0-9%/+=]{20,}'                  # Azure SAS signature
        'AccountKey='                                  # storage connection strings
        'ClientSecret'                                 # -ClientSecret, ClientSecretCredential
        'Bearer\s+[A-Za-z0-9._-]{20,}'                 # Authorization headers
    )
}

$__profileTimer    = [Diagnostics.Stopwatch]::StartNew()
$__profileSections = [ordered]@{}
$__nonInteractive  = [Environment]::GetCommandLineArgs() -match '^-noni(nteractive)?$'

function Import-ProfileModule {
    <#  Imports a module if it is installed. Never installs, never throws. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    if (Get-Module -Name $Name) { return $true }
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Verbose "Module '$Name' is not installed. Run ShellSetup.ps1."
        return $false
    }
    try   { Import-Module -Name $Name -ErrorAction Stop; return $true }
    catch { Write-Verbose "Could not import '$Name': $($_.Exception.Message)"; return $false }
}

function Test-ProfileCommand {
    <#  True when an executable is on PATH. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command -Name $Name -CommandType Application -ErrorAction Ignore)
}

# ---------------------------------------------------------------------------
# Oh My Posh
# ---------------------------------------------------------------------------
# Newer Oh My Posh builds install as MSIX and no longer set POSH_THEMES_PATH,
# which is what broke the old theme lookup. Resolution order:
#   1. ~/.config/oh-my-posh/<theme>.omp.json   (written by ShellSetup.ps1)
#   2. $env:POSH_THEMES_PATH/<theme>.omp.json  (older installers)
#   3. the bare theme name                     (Oh My Posh resolves it itself)
try {
    if (-not $__nonInteractive -and (Test-ProfileCommand oh-my-posh)) {
        $theme = $ProfileSettings.PoshTheme
        $poshConfig = @(
            (Join-Path $HOME ".config/oh-my-posh/$theme.omp.json")
            if ($env:POSH_THEMES_PATH) { Join-Path $env:POSH_THEMES_PATH "$theme.omp.json" }
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

        if (-not $poshConfig) { $poshConfig = $theme }

        (& oh-my-posh init pwsh --config $poshConfig) -join "`n" | Invoke-Expression
    }
}
catch { Write-Warning "Profile: Oh My Posh failed to initialise: $($_.Exception.Message)" }
$__profileSections['Oh My Posh'] = $__profileTimer.Elapsed.TotalMilliseconds; $__profileTimer.Restart()

# ---------------------------------------------------------------------------
# PSReadLine
# ---------------------------------------------------------------------------
try {
    if (-not $__nonInteractive -and (Import-ProfileModule -Name PSReadLine)) {
        $psrl = (Get-Module PSReadLine).Version

        Set-PSReadLineOption -EditMode Windows -BellStyle None `
            -HistoryNoDuplicates -HistorySearchCursorMovesToEnd -MaximumHistoryCount 10000

        # Predictions throw when output is redirected or the host has no VT
        # support, so they get their own try block.
        try {
            if ($psrl -ge [version]'2.2.0' -and $PSVersionTable.PSVersion -ge [version]'7.2') {
                # CompletionPredictor feeds tab-completion results into the
                # prediction list, which is what makes 'Plugin' worth enabling.
                $null = Import-ProfileModule -Name CompletionPredictor
                Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle ListView -WarningAction SilentlyContinue
            }
            elseif ($psrl -ge [version]'2.1.0') {
                Set-PSReadLineOption -PredictionSource History
            }
        }
        catch { Write-Verbose "Predictions disabled: $($_.Exception.Message)" }

        if ($psrl -ge [version]'2.2.0') {
            # Match the DarthAdmin Terminal colour scheme.
            Set-PSReadLineOption -Colors @{
                Command                = '#E5C07B'
                Parameter              = '#8A93A3'
                String                 = '#98C379'
                Variable               = '#E06C75'
                Operator               = '#56B6C2'
                Comment                = '#5C6370'
                InlinePrediction       = '#4B5160'
                ListPrediction         = '#E0314B'
                ListPredictionSelected = "$([char]27)[48;2;58;26;34m"
                Selection              = "$([char]27)[48;2;58;26;34m"
            }

            # Keep the built-in sensitive-data filter and add M365 patterns to it.
            $extra = ($ProfileSettings.HistoryExtraPatterns -join '|')
            Set-PSReadLineOption -AddToHistoryHandler {
                param([string]$Line)
                $default = [Microsoft.PowerShell.PSConsoleReadLine]::GetDefaultAddToHistoryOption($Line)
                if ($default -ne [Microsoft.PowerShell.AddToHistoryOption]::MemoryAndFile) { return $default }
                if ($Line -match $extra) { return [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly }
                return $default
            }.GetNewClosure()
        }

        Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
        Set-PSReadLineKeyHandler -Key F7        -Function ClearScreen

        # Alt+S: put the current line in history without running it, then clear
        # the prompt. Handy for parking a half-written command.
        Set-PSReadLineKeyHandler -Chord 'Alt+s' -BriefDescription SaveInHistory `
            -Description 'Save the current line in history without executing it' -ScriptBlock {
                $line = $null; $cursor = $null
                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
                [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($line)
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            }
    }
}
catch { Write-Warning "Profile: PSReadLine setup failed: $($_.Exception.Message)" }
$__profileSections['PSReadLine'] = $__profileTimer.Elapsed.TotalMilliseconds; $__profileTimer.Restart()

# ---------------------------------------------------------------------------
# Fuzzy finder (optional: ShellSetup.ps1 -InstallExtras)
# ---------------------------------------------------------------------------
try {
    if (-not $__nonInteractive -and (Test-ProfileCommand fzf) -and (Import-ProfileModule -Name PSFzf)) {
        # Ctrl+T: pick a file/folder into the command line. Ctrl+R: fuzzy history.
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
    }
}
catch { Write-Warning "Profile: PSFzf setup failed: $($_.Exception.Message)" }
$__profileSections['PSFzf'] = $__profileTimer.Elapsed.TotalMilliseconds; $__profileTimer.Restart()

# ---------------------------------------------------------------------------
# Listings: Terminal-Icons and PowerColorLS
# ---------------------------------------------------------------------------
try {
    if (-not $__nonInteractive) { $null = Import-ProfileModule -Name Terminal-Icons }

    if (Get-Module -ListAvailable -Name PowerColorLS) {
        function Invoke-PowerColorLS {
            <#
                .SYNOPSIS
                Detailed, colourised directory listing (alias: pls).
            #>
            [CmdletBinding()]
            param([Parameter(ValueFromRemainingArguments)][string[]]$Path)
            $null = Import-ProfileModule -Name PowerColorLS
            PowerColorLS -a -l --show-directory-size @Path
        }
        Set-Alias -Name pls -Value Invoke-PowerColorLS -Scope Global
    }
}
catch { Write-Warning "Profile: listing modules failed: $($_.Exception.Message)" }
$__profileSections['Listings'] = $__profileTimer.Elapsed.TotalMilliseconds; $__profileTimer.Restart()

# ---------------------------------------------------------------------------
# Native tab completion (registration only; nothing runs until you press Tab)
# ---------------------------------------------------------------------------
try {
    if (Test-ProfileCommand winget) {
        Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)
            [Console]::InputEncoding = [Console]::OutputEncoding = $OutputEncoding = [Text.UTF8Encoding]::new()
            $word = $wordToComplete.Replace('"', '""')
            $line = $commandAst.ToString().Replace('"', '""')
            winget complete --word="$word" --commandline "$line" --position $cursorPosition | ForEach-Object {
                [Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        }
    }

    if (Test-ProfileCommand dotnet) {
        Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)
            dotnet complete --position $cursorPosition "$commandAst" | ForEach-Object {
                [Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        }
    }
}
catch { Write-Warning "Profile: argument completers failed: $($_.Exception.Message)" }
$__profileSections['Completers'] = $__profileTimer.Elapsed.TotalMilliseconds; $__profileTimer.Restart()

# ---------------------------------------------------------------------------
# Navigation and file helpers
# ---------------------------------------------------------------------------
function ..  { Set-Location .. }
function ... { Set-Location ../.. }

function New-DirectoryAndEnter {
    <#
        .SYNOPSIS
        Creates a folder (and parents) and moves into it (alias: mkcd).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
        $dir = New-Item -ItemType Directory -Path $Path -Force
        Set-Location -LiteralPath $dir.FullName
    }
}
Set-Alias -Name mkcd -Value New-DirectoryAndEnter -Scope Global

function Update-FileTimestamp {
    <#
        .SYNOPSIS
        Creates an empty file, or updates its timestamp (alias: touch).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, ValueFromPipeline)][string[]]$Path)
    process {
        foreach ($p in $Path) {
            if (-not $PSCmdlet.ShouldProcess($p, 'Touch')) { continue }
            if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTime = Get-Date }
            else { $null = New-Item -ItemType File -Path $p }
        }
    }
}
Set-Alias -Name touch -Value Update-FileTimestamp -Scope Global

Set-Alias -Name which -Value Get-Command -Scope Global

function Test-IsAdmin {
    <#
        .SYNOPSIS
        True when this shell is elevated.
    #>
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Microsoft 365 / Entra / Intune helpers
# ---------------------------------------------------------------------------
function ConvertFrom-Jwt {
    <#
        .SYNOPSIS
        Decodes a JWT (access or ID token) so you can read its claims.

        .DESCRIPTION
        Decodes only. The signature is NOT validated, so never use the result
        to make a trust decision. Time claims (exp, nbf, iat) are converted to
        local DateTime and an IsExpired flag is added.

        .EXAMPLE
        $token | ConvertFrom-Jwt | Select-Object aud, scp, roles, expLocal, IsExpired
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][string]$Token)

    process {
        $parts = ($Token -replace '^Bearer\s+', '').Split('.')
        if ($parts.Count -lt 2) { Write-Error 'That does not look like a JWT.'; return }

        $decode = {
            param([string]$Segment)
            $s = $Segment.Replace('-', '+').Replace('_', '/')
            switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) | ConvertFrom-Json
        }

        $header  = & $decode $parts[0]
        $payload = & $decode $parts[1]

        foreach ($claim in 'exp', 'nbf', 'iat') {
            if ($payload.PSObject.Properties[$claim]) {
                $local = [DateTimeOffset]::FromUnixTimeSeconds([long]$payload.$claim).LocalDateTime
                $payload | Add-Member -NotePropertyName "$($claim)Local" -NotePropertyValue $local
            }
        }
        if ($payload.PSObject.Properties['exp']) {
            $payload | Add-Member -NotePropertyName IsExpired -NotePropertyValue ($payload.expLocal -lt (Get-Date))
        }
        $payload | Add-Member -NotePropertyName _Header -NotePropertyValue $header
        $payload
    }
}

function Get-EntraTenantId {
    <#
        .SYNOPSIS
        Looks up the Entra tenant ID and cloud for a domain, anonymously.

        .EXAMPLE
        Get-EntraTenantId contoso.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$Domain,
        [int]$TimeoutSec = 10
    )
    process {
        $uri = "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration"
        try {
            $cfg = Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
            [PSCustomObject]@{
                Domain        = $Domain
                TenantId      = ([uri]$cfg.issuer).Segments[1].TrimEnd('/')
                RegionScope   = $cfg.tenant_region_scope
                CloudInstance = $cfg.cloud_instance_name
            }
        }
        catch { Write-Warning "No Entra tenant found for '$Domain': $($_.Exception.Message)" }
    }
}

function Get-DeviceJoinStatus {
    <#
        .SYNOPSIS
        dsregcmd /status as an object instead of a wall of text.

        .EXAMPLE
        Get-DeviceJoinStatus | Select-Object AzureAdJoined, TenantName, DeviceId, AzureAdPrt
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-ProfileCommand dsregcmd)) { Write-Warning 'dsregcmd is only available on Windows.'; return }

    $result = [ordered]@{}
    foreach ($line in (dsregcmd /status)) {
        if ($line -match '^\s*([A-Za-z][A-Za-z0-9 ]+?)\s*:\s*(.*)$') {
            $key = $Matches[1] -replace '\s', ''
            $val = $Matches[2].Trim()
            $val = switch ($val) { 'YES' { $true } 'NO' { $false } default { $val } }
            if (-not $result.Contains($key)) { $result[$key] = $val }
        }
    }
    [PSCustomObject]$result
}

function Open-IntuneLog {
    <#
        .SYNOPSIS
        Opens the Intune Management Extension log folder.
    #>
    [CmdletBinding()]
    param()
    $path = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
    if (Test-Path -LiteralPath $path) { Invoke-Item -LiteralPath $path }
    else { Write-Warning "Not found: $path (is the Intune Management Extension installed?)" }
}

function Invoke-IntuneSync {
    <#
        .SYNOPSIS
        Triggers an Intune check-in on this device.

        .DESCRIPTION
        Starts the MDM PushLaunch scheduled task (needs an elevated shell) and
        asks the Intune Management Extension to re-evaluate apps and scripts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $IsWindows) { Write-Warning 'Windows only.'; return }

    if (Test-IsAdmin) {
        $task = Get-ScheduledTask -TaskName PushLaunch -ErrorAction SilentlyContinue |
                Where-Object TaskPath -like '\Microsoft\Windows\EnterpriseMgmt\*' | Select-Object -First 1
        if ($task -and $PSCmdlet.ShouldProcess('MDM PushLaunch task', 'Start')) {
            $task | Start-ScheduledTask
            Write-Information 'MDM sync started.' -InformationAction Continue
        }
        elseif (-not $task) { Write-Warning 'No PushLaunch task found. Is this device MDM-enrolled?' }
    }
    else {
        Write-Warning 'Not elevated: skipping the MDM sync. Run from an admin shell for a full check-in.'
    }

    if ((Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue) -and
        $PSCmdlet.ShouldProcess('Intune Management Extension', 'Request app sync')) {
        Start-Process 'intunemanagementextension://syncapp'
        Write-Information 'IME app sync requested.' -InformationAction Continue
    }
}

# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------
function Get-WanIp {
    <#
        .SYNOPSIS
        Returns your public IP address.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 5)
    try   { (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec $TimeoutSec).ToString().Trim() }
    catch { Write-Warning "Could not determine the public IP: $($_.Exception.Message)" }
}

function Start-Speedtest {
    <#
        .SYNOPSIS
        Runs a bandwidth test with the official Ookla Speedtest CLI.

        .NOTES
        Replaces the old version, which downloaded and executed a remote script
        on every call. Install the CLI with: winget install Ookla.Speedtest.CLI
        (or ShellSetup.ps1 -InstallExtras).
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-ProfileCommand speedtest)) {
        Write-Warning 'Speedtest CLI not found. Install it with: winget install Ookla.Speedtest.CLI'
        return
    }
    speedtest --accept-license --accept-gdpr
}

# ---------------------------------------------------------------------------
# Profile helpers
# ---------------------------------------------------------------------------
function Edit-Profile {
    <#
        .SYNOPSIS
        Opens this profile in $env:EDITOR, VS Code or Notepad.
    #>
    [CmdletBinding()]
    param()
    $editor = @($env:EDITOR, 'code', 'notepad') |
              Where-Object { $_ -and (Get-Command $_ -ErrorAction SilentlyContinue) } |
              Select-Object -First 1
    if ($editor) { & $editor $PROFILE.CurrentUserCurrentHost }
    else { Write-Warning 'No editor found. Set $env:EDITOR.' }
}

function Get-ProfileLoadTime {
    <#
        .SYNOPSIS
        Measures what this profile costs at startup.

        .DESCRIPTION
        Starts the same pwsh executable with and without the profile and
        reports the difference. -Breakdown shows the per-section timings
        recorded when the current session started.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 20)][int]$Iterations = 3,
        [switch]$Breakdown
    )

    if ($Breakdown) {
        $ProfileLoadBreakdown.GetEnumerator() |
            ForEach-Object { [PSCustomObject]@{ Section = $_.Key; Milliseconds = [math]::Round($_.Value, 1) } }
        return
    }

    $exe = (Get-Process -Id $PID).Path
    $time = {
        param([string[]]$ArgList)
        (1..$Iterations | ForEach-Object {
            (Measure-Command { & $exe @ArgList }).TotalMilliseconds
        } | Measure-Object -Average).Average
    }

    $with    = & $time @('-NoLogo', '-Command', 'exit')
    $without = & $time @('-NoLogo', '-NoProfile', '-Command', 'exit')

    [PSCustomObject]@{
        WithProfileMs    = [math]::Round($with, 0)
        WithoutProfileMs = [math]::Round($without, 0)
        ProfileCostMs    = [math]::Round($with - $without, 0)
    }
}

function Get-ProfileCommand {
    <#
        .SYNOPSIS
        Lists the commands and aliases this profile adds.
    #>
    [CmdletBinding()]
    param()
    $names = 'Invoke-PowerColorLS', 'New-DirectoryAndEnter', 'Update-FileTimestamp', 'Test-IsAdmin',
             'ConvertFrom-Jwt', 'Get-EntraTenantId', 'Get-DeviceJoinStatus', 'Open-IntuneLog',
             'Invoke-IntuneSync', 'Get-WanIp', 'Start-Speedtest', 'Edit-Profile',
             'Get-ProfileLoadTime', 'Get-ProfileCommand'
    foreach ($name in $names) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $alias = (Get-Alias -Definition $name -ErrorAction SilentlyContinue).Name -join ', '
        [PSCustomObject]@{
            Command  = $name
            Alias    = $alias
            Synopsis = ((Get-Help $name -ErrorAction SilentlyContinue).Synopsis -replace '\s+', ' ').Trim()
        }
    }
}

# ---------------------------------------------------------------------------
# Tidy up
# ---------------------------------------------------------------------------
$__profileSections['Functions'] = $__profileTimer.Elapsed.TotalMilliseconds
$ProfileLoadBreakdown = $__profileSections
Remove-Variable -Name __profileTimer, __profileSections, __nonInteractive, theme, poshConfig, psrl, extra `
    -ErrorAction Ignore
