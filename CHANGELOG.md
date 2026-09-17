# Changelog

## 2026-09

### Removed
- Bitwarden CLI helpers (`Unlock-BitwardenVault`, `Lock-BitwardenVault`,
  `Get-BitwardenCredential`) and the `-InstallBitwarden` setup option.
- The remote background image URL in `settings.json`.

### Fixed
- Oh My Posh theme lookup on MSIX installs, which no longer set
  `POSH_THEMES_PATH`. The theme is now stored locally by the setup.
- Debug `theme: ...` line printed on every shell start.
- `-WhatIf` still ran winget installs.
- Modules installed from Windows PowerShell 5.1 were invisible to PowerShell 7;
  the setup now re-runs itself under `pwsh`.
- Windows Terminal `settings.json` was replaced wholesale, wiping other
  profiles. It is now merged by default.
- Re-running the setup created a new backup of every file even when nothing
  changed.
- Comment-based help in the profile used an inline `.SYNOPSIS` format that
  `Get-Help` cannot read.
- TLS 1.2 and download speed on Windows PowerShell 5.1.
- README out of sync with the code (theme name, missing parameters, missing LICENSE).

### Added
- DarthAdmin colour scheme and a generated background tuned for readability.
- Elevated "PowerShell (Admin)" Terminal profile.
- CompletionPredictor, extended history secret filtering, winget/dotnet tab
  completion, optional fzf/PSFzf.
- Microsoft 365 helpers: `Get-DeviceJoinStatus`, `Get-EntraTenantId`,
  `ConvertFrom-Jwt`, `Invoke-IntuneSync`, `Open-IntuneLog`.
- `mkcd`, `touch`, `..`, `Test-IsAdmin`, `Get-ProfileCommand`,
  `Get-ProfileLoadTime -Breakdown`.
- `Start-Speedtest` uses the Ookla CLI instead of executing a remote script.
- PSScriptAnalyzer settings and a GitHub Actions lint workflow.
