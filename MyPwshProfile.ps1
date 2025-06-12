# --------------------------------------
# Oh-My-Posh Prompt
# --------------------------------------
oh-my-posh init pwsh --config 'https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/cloud-native-azure.omp.json' | Invoke-Expression

# --------------------------------------
# Terminal Icons
# --------------------------------------
if (-not (Get-Module -ListAvailable -Name Terminal-Icons)) {
    Install-Module -Name Terminal-Icons -Repository PSGallery -Force -Scope CurrentUser
}
Import-Module -Name Terminal-Icons

# --------------------------------------
# PSReadLine - Autocomplete and History
# --------------------------------------
if (-not (Get-Module -ListAvailable -Name PSReadLine)) {
    Install-Module -Name PSReadLine -AllowPreRelease -Scope CurrentUser -Force -SkipPublisherCheck
}
Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows

# --------------------------------------
# PowerColorLS
# --------------------------------------
if (-not (Get-Module -ListAvailable -Name PowerColorLS)) {
    Install-Module -Name PowerColorLS -Repository PSGallery -Force -Scope CurrentUser
}
Import-Module -Name PowerColorLS

function PowerColorLSWithOption {
    PowerColorLS -a -l --show-directory-size
}
Set-Alias -Name pls -Value PowerColorLSWithOption

# --------------------------------------
# Bitwarden CLI Functions
# --------------------------------------
function Start-BitwardenSession {
    if (-not $env:BW_PASSWORD) {
        $securePassword = Read-Host "Bitwarden Vault Key:" -AsSecureString
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        )
        $env:BW_PASSWORD = $plainPassword
    }

    $bwSession = bw unlock --passwordenv BW_PASSWORD --raw

    if ($bwSession) {
        $env:BW_SESSION = $bwSession
        Write-Host "Bitwarden session started successfully." -ForegroundColor Green
    } else {
        Write-Host "Failed to unlock Bitwarden vault." -ForegroundColor Red
    }
}

function Get-BwCredentials {
    param (
        [Parameter(Mandatory)]
        [string]$ItemName
    )

    $item = bw list items --search $ItemName | ConvertFrom-Json | Select-Object -First 1
    if (-not $item) {
        Write-Host "Item '$ItemName' not found." -ForegroundColor Red
        return
    }

    $fullItem = bw get item $item.id | ConvertFrom-Json
    $username = $fullItem.login.username
    $password = $fullItem.login.password

    [PSCustomObject]@{
        ClientID = $username
        SecretID = $password
    }
}

# --------------------------------------
# Utility Functions
# --------------------------------------
function Get-WanIp {
    (Invoke-WebRequest ifconfig.me/ip).Content
}

function Start-Speedtest {
    irm asheroto.com/speedtest | iex
}