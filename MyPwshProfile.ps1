#Requires -Version 7.0
<#
    MyPwshProfile.ps1
    PowerShell 7+ profile.

    Design rules for this file:
      * It must never fail. A profile that throws leaves you with a broken shell.
      * It must never install anything. Installing from a profile is slow, can
        prompt, and breaks on locked-down machines. ShellSetup.ps1 installs;
        this file only loads what is already there.
      * It must never hit the network at startup.
#>

# ---------------------------------------------------------------------------
# Oh My Posh prompt
# ---------------------------------------------------------------------------
# The original fetched the theme from GitHub on every single shell start, which
# added latency and broke the prompt when offline. Oh My Posh ships its themes
# locally in $env:POSH_THEMES_PATH, so use that copy.
if (Get-Command oh-my-posh -CommandType Application -ErrorAction SilentlyContinue) {
    $poshTheme = if ($env:POSH_THEMES_PATH) {
        Join-Path $env:POSH_THEMES_PATH 'cloud-native-azure.omp.json'
    }

    if ($poshTheme -and (Test-Path -LiteralPath $poshTheme)) {
        oh-my-posh init pwsh --config $poshTheme | Invoke-Expression
    }
    else {
        oh-my-posh init pwsh | Invoke-Expression   # falls back to the default theme
    }
}
else {
    Write-Verbose 'oh-my-posh not found. Run ShellSetup.ps1 to install it.'
}

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------
function Import-ProfileModule {
    <#  Imports a module if it is installed. Returns $true on success.
        Never installs, never throws. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (Get-Module -Name $Name) { return $true }

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Verbose "Module '$Name' is not installed. Run ShellSetup.ps1."
        return $false
    }

    try {
        Import-Module -Name $Name -ErrorAction Stop
        return $true
    }
    catch {
        Write-Verbose "Could not import '$Name': $($_.Exception.Message)"
        return $false
    }
}

$null = Import-ProfileModule -Name Terminal-Icons

# ---------------------------------------------------------------------------
# PSReadLine
# ---------------------------------------------------------------------------
# PSReadLine ships with PowerShell, so the original 'if not available, install'
# check never fired and the version was never actually checked. Predictive
# IntelliSense needs 2.1+, ListView needs 2.2+ — so gate on the real version
# instead of assuming.
if (Import-ProfileModule -Name PSReadLine) {
    $psrlVersion = (Get-Module PSReadLine).Version

    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -BellStyle None

    if ($psrlVersion -ge [version]'2.2.0') {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        Set-PSReadLineOption -PredictionViewStyle ListView
    }
    elseif ($psrlVersion -ge [version]'2.1.0') {
        Set-PSReadLineOption -PredictionSource History
    }

    # Up/Down search history using what you have already typed.
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
    Set-PSReadLineKeyHandler -Key F7        -Function ClearScreen
}

# ---------------------------------------------------------------------------
# PowerColorLS
# ---------------------------------------------------------------------------
if (Import-ProfileModule -Name PowerColorLS) {
    function Invoke-PowerColorLS {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Path)
        PowerColorLS -a -l --show-directory-size @Path
    }
    Set-Alias -Name pls -Value Invoke-PowerColorLS -Scope Global
}

# ---------------------------------------------------------------------------
# Bitwarden CLI
# ---------------------------------------------------------------------------
function Unlock-BitwardenVault {
    <#
        .SYNOPSIS
        Unlocks the Bitwarden vault and stores the session key for this shell.

        .DESCRIPTION
        The previous version kept your master password in $env:BW_PASSWORD for
        the entire life of the shell, in plain text, readable by any process
        running as you. This version puts it in the environment only for the
        duration of the 'bw unlock' call and wipes it in a finally block, so it
        survives neither success, failure, nor Ctrl+C.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command bw -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning 'Bitwarden CLI not found. Install it with: winget install Bitwarden.CLI'
        return
    }

    try {
        $status = (bw status --raw 2>$null | ConvertFrom-Json).status
    }
    catch {
        $status = 'unknown'
    }

    if ($status -eq 'unauthenticated') {
        Write-Warning "You are not logged in. Run 'bw login' first."
        return
    }

    if ($status -eq 'unlocked' -and $env:BW_SESSION) {
        Write-Host 'Bitwarden vault is already unlocked.' -ForegroundColor Green
        return
    }

    $secure = Read-Host 'Bitwarden master password' -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) {
        Write-Warning 'No password entered. Aborted.'
        return
    }

    $session = $null
    try {
        $env:BW_PASSWORD = [System.Net.NetworkCredential]::new('', $secure).Password
        $session = bw unlock --passwordenv BW_PASSWORD --raw 2>$null
    }
    finally {
        Remove-Item -Path Env:\BW_PASSWORD -ErrorAction SilentlyContinue
        $secure.Dispose()
    }

    if ($session) {
        $env:BW_SESSION = $session
        Write-Host 'Bitwarden session started.' -ForegroundColor Green
    }
    else {
        Write-Warning 'Failed to unlock the Bitwarden vault. Wrong password?'
    }
}

function Lock-BitwardenVault {
    <#  .SYNOPSIS  Locks the vault and clears the session key from this shell. #>
    [CmdletBinding()]
    param()

    if (Get-Command bw -CommandType Application -ErrorAction SilentlyContinue) {
        bw lock 2>$null | Out-Null
    }
    Remove-Item -Path Env:\BW_SESSION -ErrorAction SilentlyContinue
    Write-Host 'Bitwarden vault locked.' -ForegroundColor Green
}

function Get-BitwardenCredential {
    <#
        .SYNOPSIS
        Gets an item from Bitwarden as a PSCredential.

        .EXAMPLE
        $cred = Get-BitwardenCredential 'Azure App Registration'
        Connect-AzAccount -ServicePrincipal -Credential $cred

        .EXAMPLE
        Get-BitwardenCredential 'Azure App Registration' -AsPlainText
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ItemName,

        # Returns username and password as plain text instead of a PSCredential.
        [switch]$AsPlainText
    )

    if (-not (Get-Command bw -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Warning 'Bitwarden CLI not found.'
        return
    }

    if (-not $env:BW_SESSION) {
        Write-Warning 'No active session. Run Unlock-BitwardenVault first.'
        return
    }

    try {
        $items = @(bw list items --search $ItemName --session $env:BW_SESSION 2>$null | ConvertFrom-Json)
    }
    catch {
        Write-Warning "Bitwarden search failed: $($_.Exception.Message)"
        return
    }

    if ($items.Count -eq 0) {
        Write-Warning "No item matching '$ItemName' was found."
        return
    }

    # The original silently took the first hit. Say so out loud instead — picking
    # the wrong credential without telling anyone is a bad failure mode.
    if ($items.Count -gt 1) {
        Write-Warning "$($items.Count) items match '$ItemName'. Using '$($items[0].name)'."
    }

    $item = bw get item $items[0].id --session $env:BW_SESSION 2>$null | ConvertFrom-Json
    if (-not $item.login) {
        Write-Warning "Item '$($items[0].name)' has no login fields."
        return
    }

    $username = $item.login.username
    $password = $item.login.password

    if ($AsPlainText) {
        return [PSCustomObject]@{
            Name     = $item.name
            Username = $username
            Password = $password
        }
    }

    [PSCredential]::new($username, (ConvertTo-SecureString $password -AsPlainText -Force))
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
function Get-WanIp {
    <#  .SYNOPSIS  Returns your public IP address. #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 5)

    try {
        (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec $TimeoutSec).ToString().Trim()
    }
    catch {
        Write-Warning "Could not determine the public IP: $($_.Exception.Message)"
    }
}

function Start-Speedtest {
    <#
        .SYNOPSIS
        Runs asheroto's speedtest script.

        .NOTES
        This downloads and executes a script from the internet every time you
        call it. Only run it if you trust that source, and re-check the URL now
        and then.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $url = 'https://asheroto.com/speedtest'
    if ($PSCmdlet.ShouldProcess($url, 'Download and run remote script')) {
        Invoke-RestMethod -Uri $url | Invoke-Expression
    }
}

function Edit-Profile {
    <#  .SYNOPSIS  Opens this profile in your editor. #>
    [CmdletBinding()]
    param()

    $editor = if (Get-Command code -CommandType Application -ErrorAction SilentlyContinue) { 'code' }
              elseif (Get-Command notepad -CommandType Application -ErrorAction SilentlyContinue) { 'notepad' }

    if ($editor) { & $editor $PROFILE.CurrentUserCurrentHost }
    else { Write-Warning 'No editor found.' }
}

function Get-ProfileLoadTime {
    <#  .SYNOPSIS  Measures how long a fresh pwsh session takes to start. #>
    [CmdletBinding()]
    param([int]$Iterations = 3)

    1..$Iterations | ForEach-Object {
        (Measure-Command { pwsh -NoLogo -Command '' }).TotalMilliseconds
    } | Measure-Object -Average -Minimum -Maximum
}

Set-Alias -Name which -Value Get-Command -Scope Global
