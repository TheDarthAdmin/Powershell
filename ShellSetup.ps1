# === Install Required PowerShell Modules ===
Write-Host "Installing PowerShell modules..." -ForegroundColor Cyan

$modules = @(
    'oh-my-posh',
    'Terminal-Icons',
    'PSReadLine',
    'PowerColorLS'
)

foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Install-Module -Name $module -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
    }
}

# === Install Bitwarden CLI ===
if (-not (Get-Command bw -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Bitwarden CLI..." -ForegroundColor Cyan
    winget install --id Bitwarden.CLI --silent
}

# === Ask user where to store profile ===
Write-Host "Where do you want to store your PowerShell profile?" -ForegroundColor Cyan
Write-Host "1 = OneDrive\Documents\PowerShell" -ForegroundColor Yellow
Write-Host "2 = C:\Users\USERNAME\Documents\PowerShell" -ForegroundColor Yellow
$choice = Read-Host "Enter 1 or 2"

# === Determine profile path ===
if ($choice -eq '1') {
    $profileDestination = Join-Path $env:OneDrive "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
} elseif ($choice -eq '2') {
    $profileDestination = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PowerShell\Microsoft.PowerShell_profile.ps1"
} else {
    Write-Host "Invalid choice. Exiting." -ForegroundColor Red
    exit
}

# === Install PowerShell Profile ===
$profileUrl = "https://gist.githubusercontent.com/TheDarthAdmin/e689c86323cc65a767fd0fca68219947/raw/e7530a795c8e230f94188ac23c992b4c3988bcfb/MyPwshProfile.ps1"

# Create PowerShell folder if needed
$profileFolder = Split-Path $profileDestination -Parent
if (-not (Test-Path $profileFolder)) {
    New-Item -ItemType Directory -Path $profileFolder
}

Invoke-WebRequest -Uri $profileUrl -OutFile $profileDestination -UseBasicParsing
Write-Host "PowerShell profile installed at $profileDestination" -ForegroundColor Green

# === Install Windows Terminal Settings ===
$terminalSettingsDestination = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$terminalSettingsUrl = "https://gist.githubusercontent.com/TheDarthAdmin/40e772cc2d61c11a5df93b47c5abf48d/raw/540a1b87190baf02eb9d83f33a3f716c9537a5cf/settings.json"

Invoke-WebRequest -Uri $terminalSettingsUrl -OutFile $terminalSettingsDestination -UseBasicParsing
Write-Host "Windows Terminal settings installed at $terminalSettingsDestination" -ForegroundColor Green

Write-Host "Setup complete! Please restart your Terminal." -ForegroundColor Green
