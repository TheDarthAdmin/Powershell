# PowerShell & Windows Terminal Setup

An opinionated setup for PowerShell 7 on Windows: a Nerd Font, an Oh My Posh
prompt, predictive history, file-type icons, and a few Bitwarden and networking
helpers.

The setup script is safe to run more than once. It skips what is already
installed and backs up any file it replaces.

---

## Requirements

| | |
|---|---|
| OS | Windows 10 1809 or later / Windows 11 |
| Shell | PowerShell 7.0+ (`winget install Microsoft.PowerShell`) |
| Terminal | Windows Terminal (Store, Preview, or unpackaged) |
| Package manager | winget, for Oh My Posh and the Bitwarden CLI |

Administrator rights are **not** required. The font is installed for the
current user only.

---

## Install

Clone or download the repo and run the script:

```powershell
git clone https://github.com/TheDarthAdmin/Powershell.git
cd Powershell
.\ShellSetup.ps1
```

Or run it straight from the web:

```powershell
irm https://raw.githubusercontent.com/TheDarthAdmin/Powershell/main/ShellSetup.ps1 | iex
```

To pass options through the one-liner, wrap it in a script block:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/TheDarthAdmin/Powershell/main/ShellSetup.ps1))) -SkipTerminalSettings
```

Restart Windows Terminal when it finishes.

> Piping a script from the internet into `iex` runs whatever is at that URL with
> your permissions. Read the script first — that goes for this one too.

### Options

| Parameter | Effect |
|---|---|
| `-ProfilePath <path>` | Write the profile somewhere other than `$PROFILE` |
| `-SkipFont` | Leave fonts alone |
| `-SkipTerminalSettings` | Leave `settings.json` alone |
| `-InstallBitwarden` | Also install the Bitwarden CLI |
| `-NerdFontVersion <tag>` | Pin a different Nerd Fonts release (default `v3.4.0`) |
| `-WhatIf` | Show what would happen without changing anything |

Start with `-WhatIf` if you want to see the plan before committing to it.

---

## What is in the repo

### `ShellSetup.ps1`

Installs, in order:

1. **Modules** — Terminal-Icons and PowerColorLS, plus PSReadLine from the
   gallery only when the version shipped with your PowerShell is older than
   2.2.
2. **Oh My Posh** — via winget, skipped if `oh-my-posh` already resolves.
3. **Hack Nerd Font** — downloaded from the Nerd Fonts releases and registered
   under `HKCU`, so no elevation is needed.
4. **The profile** — written to `$PROFILE.CurrentUserCurrentHost`, which
   already resolves to the OneDrive path when Documents is redirected.
5. **Windows Terminal settings** — the existing `settings.json` is copied to a
   timestamped `.bak-` file first, and the download is validated as JSON before
   anything is overwritten.

### `MyPwshProfile.ps1`

Loaded on every shell start, so it does three things and no more: it never
installs anything, never touches the network, and never throws. If a module is
missing it says so under `-Verbose` and moves on.

- Oh My Posh with the *cloud-native-azure* theme, read from the local theme
  cache rather than fetched from GitHub at every prompt.
- PSReadLine with ListView predictions, history search on the arrow keys, and
  menu completion on Tab. Options are gated on the installed version.
- Terminal-Icons for file-type glyphs in directory listings.
- PowerColorLS behind the `pls` alias.

### `settings.json`

Windows Terminal configuration: One Half Dark, Hack Nerd Font applied to every
profile, a background image on the PowerShell profile, and pane
splitting/navigation keybindings.

---

## Commands added by the profile

| Command | What it does |
|---|---|
| `pls` | Detailed, colourised directory listing |
| `Unlock-BitwardenVault` | Prompts for the master password and stores the session key |
| `Lock-BitwardenVault` | Locks the vault and clears the session key |
| `Get-BitwardenCredential <name>` | Returns a vault item as a `PSCredential` |
| `Get-WanIp` | Your public IP address |
| `Start-Speedtest` | Runs a bandwidth test |
| `Edit-Profile` | Opens this profile in VS Code or Notepad |
| `Get-ProfileLoadTime` | Times a cold shell start |
| `which` | Alias for `Get-Command` |

Example:

```powershell
Unlock-BitwardenVault
$cred = Get-BitwardenCredential 'Azure App Registration'
Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantId
```

### A note on the Bitwarden helpers

Your master password is placed in `BW_PASSWORD` only for the duration of the
`bw unlock` call and is wiped in a `finally` block, so it does not survive
success, failure, or Ctrl+C. The session key stays in `BW_SESSION` for the life
of the shell, which is how the Bitwarden CLI is designed to work — run
`Lock-BitwardenVault` when you are done, and do not use these helpers on a
machine you share.

`Get-BitwardenCredential` returns a `PSCredential` by default so the password
stays in a `SecureString`. Pass `-AsPlainText` if you really need the strings.

---

## Customising

**Prompt theme** — edit the theme filename near the top of the profile. Run
`Get-PoshThemes` to preview what is available.

**Background image** — point `backgroundImage` in `settings.json` at a local
file instead of a URL if you would rather not fetch an image over the network
at every launch:

```json
"backgroundImage": "%USERPROFILE%\\Pictures\\terminal-bg.png"
```

Remove the `backgroundImage` and `backgroundImageOpacity` keys for a plain
background.

**Font size** — `profiles.defaults.font.size`.

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

**The prompt shows boxes or question marks.** Windows Terminal is not using the
Nerd Font. Check `profiles.defaults.font.face` is `Hack Nerd Font` and restart
Terminal — newly installed fonts are not picked up by running apps.

**`oh-my-posh` is not recognised after setup.** winget updated PATH but your
current session still has the old copy. Open a new tab.

**Predictions do not appear.** Run `Get-Module PSReadLine` — ListView needs
2.2.0 or later. `Install-Module PSReadLine -Force -SkipPublisherCheck` and
restart the shell.

**Shell startup feels slow.** `Get-ProfileLoadTime` gives you a number to work
with. Most of it is usually Oh My Posh initialisation.

---

## Licence

MIT — see `LICENSE`.
