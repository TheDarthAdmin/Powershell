# PowerShell & Windows Terminal Setup

An opinionated setup for PowerShell 7 on Windows: a Nerd Font, an Oh My Posh
prompt that works offline, predictive IntelliSense, file-type icons, a custom
colour scheme and background, and a handful of Microsoft 365 / Intune helpers.

The setup script is safe to run more than once. It skips what is already in
place and backs up any file it changes.

![Terminal background](assets/darthadmin-terminal.png)

---

## Requirements

| | |
|---|---|
| OS | Windows 10 1809 or later / Windows 11 |
| Shell | PowerShell 7.2+ recommended (installed for you if missing) |
| Terminal | Windows Terminal (Store, Preview, or unpackaged) |
| Package manager | winget |

Administrator rights are **not** required. Fonts and modules install for the
current user only.

---

## Install

Clone the repo and run the script:

```powershell
git clone https://github.com/TheDarthAdmin/Powershell.git
cd Powershell
.\ShellSetup.ps1 -WhatIf   # see the plan first
.\ShellSetup.ps1
```

Or run it straight from the web:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/TheDarthAdmin/Powershell/main/ShellSetup.ps1)))
```

Options go after the closing parenthesis:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/TheDarthAdmin/Powershell/main/ShellSetup.ps1))) -InstallExtras
```

The shorter `irm ... | iex` also works, but it cannot take options: the
script notices it was piped into `iex` and re-runs itself in the form above.

Restart Windows Terminal when it finishes.

> Piping a script from the internet into `iex` runs whatever is at that URL with
> your permissions. Read the script first — that goes for this one too.

Started from Windows PowerShell 5.1, the script installs PowerShell 7 if needed
and re-runs itself under `pwsh`, so modules end up where PowerShell 7 looks.

### Options

| Parameter | Effect |
|---|---|
| `-WhatIf` | Show what would happen without changing anything |
| `-Diagnose` | Print paths, tool versions and writability checks, then exit |
| `-InstallExtras` | Also install fzf + PSFzf and the Ookla Speedtest CLI |
| `-TerminalSettingsMode Merge\|Replace` | `Merge` (default) keeps your own profiles, schemes and key bindings; `Replace` overwrites `settings.json` |
| `-PoshTheme <name>` | Oh My Posh theme to store locally (default `kali`; keep in sync with the profile) |
| `-ProfilePath <path>` | Write the profile somewhere other than `$PROFILE` |
| `-ModuleRoot <path>` | Install modules into a specific folder |
| `-NerdFontVersion <tag>` | Pin a Nerd Fonts release, e.g. `v3.4.0` (default `latest`) |
| `-SourceBranch <name>` | Branch to download files from when not running from a checkout (default `main`) |
| `-SkipModules` | Leave modules alone |
| `-SkipFont` | Leave fonts alone |
| `-SkipBackground` | Do not install the background image |
| `-SkipTerminalSettings` | Leave `settings.json` alone |

---

## What is in the repo

| Path | Purpose |
|---|---|
| `ShellSetup.ps1` | Installer |
| `MyPwshProfile.ps1` | The PowerShell 7 profile |
| `settings.json` | Windows Terminal settings, merged into yours |
| `assets/darthadmin-terminal.png` | Terminal background (2560×1440) |
| `PSScriptAnalyzerSettings.psd1` | Lint rules, used by the GitHub Action |

### `ShellSetup.ps1`

Installs, in order:

1. **PowerShell 7** — only when started from Windows PowerShell and `pwsh` is missing.
2. **Modules** — Terminal-Icons, PowerColorLS, CompletionPredictor, and
   PSReadLine when the bundled one is older than 2.2.2 (plus PSFzf with
   `-InstallExtras`). Falls back to unpacking the `.nupkg` directly when
   `Install-Module` insists on admin rights.
3. **Oh My Posh** via winget, plus a local copy of the theme in
   `~\.config\oh-my-posh`. Current Oh My Posh builds install as MSIX and no
   longer set `POSH_THEMES_PATH`, so the profile does not rely on it.
4. **Hack Nerd Font** — registered under `HKCU`, no elevation needed.
5. **The profile** — written to `$PROFILE.CurrentUserCurrentHost`, with a
   fallback and a clear fix when a redirected Documents folder is broken.
6. **The background** — copied to `%LOCALAPPDATA%\PwshShellSetup`, so Terminal
   never fetches an image over the network.
7. **Windows Terminal settings** — merged into your existing file by default.
   Comments in your original file are not preserved, which is why a
   timestamped `.bak-` copy is made first.

Files that have not changed are left alone, so re-running does not pile up
backups.

### `MyPwshProfile.ps1`

Never installs anything, never touches the network at startup, never throws,
and prints nothing on a normal start. A section that fails becomes a warning.

- **Oh My Posh** with the `kali` theme, loaded from the local copy.
- **PSReadLine** with ListView predictions from history *and* completions
  (CompletionPredictor), history search on the arrow keys, menu completion on
  Tab, and colours matched to the Terminal scheme.
- **History hygiene** — PSReadLine already keeps lines containing passwords,
  secrets or tokens out of the history file. The profile adds JWTs, SAS
  signatures, storage account keys, client secrets and bearer tokens.
- **Fuzzy search** (with `-InstallExtras`): `Ctrl+T` for files, `Ctrl+R` for history.
- **Tab completion** for `winget` and `dotnet`.
- **Terminal-Icons** in directory listings, **PowerColorLS** behind `pls`.
- Non-interactive sessions (`pwsh -NonInteractive`) skip the prompt and key
  bindings and only load the functions.

### `settings.json`

Hack Nerd Font everywhere, the **DarthAdmin** colour scheme, the background on
the PowerShell profile, a **PowerShell (Admin)** profile that opens elevated
with a red tab, and pane splitting/navigation key bindings.

---

## Commands added by the profile

Run `Get-ProfileCommand` for the live list.

| Command | Alias | What it does |
|---|---|---|
| `Get-DeviceJoinStatus` | | `dsregcmd /status` as an object |
| `Get-EntraTenantId <domain>` | | Tenant ID, region and cloud for any domain |
| `ConvertFrom-Jwt` | | Decodes an access/ID token; adds local expiry times |
| `Invoke-IntuneSync` | | MDM check-in (elevated) plus an IME app sync |
| `Open-IntuneLog` | | Opens the Intune Management Extension log folder |
| `Test-IsAdmin` | | True when the shell is elevated |
| `Invoke-PowerColorLS` | `pls` | Detailed, colourised directory listing |
| `New-DirectoryAndEnter` | `mkcd` | Create a folder and move into it |
| `Update-FileTimestamp` | `touch` | Create a file or update its timestamp |
| `..`, `...` | | Up one or two folders |
| `Get-WanIp` | | Your public IP address |
| `Start-Speedtest` | | Bandwidth test via the Ookla CLI |
| `Edit-Profile` | | Opens the profile in `$env:EDITOR`, VS Code or Notepad |
| `Get-ProfileLoadTime` | | Profile startup cost; `-Breakdown` per section |
| | `which` | `Get-Command` |

Key bindings: `↑`/`↓` history search, `Tab` menu complete, `F7` clear screen,
`Alt+S` save the current line to history without running it.

Examples:

```powershell
Get-EntraTenantId contoso.com
Get-DeviceJoinStatus | Select-Object AzureAdJoined, TenantName, DeviceId, AzureAdPrt
(Get-Clipboard) | ConvertFrom-Jwt | Select-Object aud, scp, roles, expLocal, IsExpired
```

`ConvertFrom-Jwt` decodes only; it does not validate the signature.

---

## Customising

**Prompt theme** — change `PoshTheme` in the settings block at the top of the
profile, then run `.\ShellSetup.ps1 -PoshTheme <name> -SkipModules -SkipFont`
to store the new theme locally. Browse themes at
<https://ohmyposh.dev/docs/themes>.

**Background** — replace `%LOCALAPPDATA%\PwshShellSetup\darthadmin-terminal.png`,
or point `backgroundImage` elsewhere. `backgroundImageOpacity` controls how
strongly it shows; remove the three `backgroundImage*` keys for a plain
background. The image keeps its detail on the right and bottom so text on the
left stays clean.

**Colours** — edit the `DarthAdmin` scheme in `settings.json`, or set
`colorScheme` to any built-in scheme.

**History filter** — extend `HistoryExtraPatterns` in the profile.

---

## Rolling back

Every file the setup replaces is kept next to the original:

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json.bak-*"
Get-ChildItem "$(Split-Path $PROFILE)\Microsoft.PowerShell_profile.ps1.bak-*"
```

Restore one with `Copy-Item <backup> <original> -Force`.

---

## Troubleshooting

Start with `.\ShellSetup.ps1 -Diagnose`.

**The prompt shows boxes or question marks.** Windows Terminal is not using the
Nerd Font. Check `profiles.defaults.font.face` is `Hack Nerd Font` and restart
Terminal — running apps do not pick up newly installed fonts.

**The prompt shows `CONFIG ERROR`.** The theme file is missing. Re-run the
setup, or check `~\.config\oh-my-posh\kali.omp.json` exists.

**`oh-my-posh` is not recognised after setup.** Open a new tab.

**Predictions do not appear.** `Get-Module PSReadLine` should report 2.2.2 or
later, and the window must be at least 50 columns wide for ListView.

**Shell startup feels slow.** `Get-ProfileLoadTime -Breakdown` shows which
section costs the most. It is usually Oh My Posh or Terminal-Icons.

---

## Development

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The same check runs on every push and pull request.

---

## Licence

MIT — see [`LICENSE`](LICENSE).
