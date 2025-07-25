# 🖥️ PowerShell & Windows Terminal Setup

A simple yet powerful configuration to enhance your PowerShell environment and Windows Terminal experience. This repository includes:

- `ShellSetup.ps1`: A script to configure Windows Terminal with custom profiles and keybindings.
- `MyPwshProfile.ps1`: A personal PowerShell profile script that installs and configures useful modules and a modern prompt.

---

## 📁 Contents

### 🔧 `ShellSetup.ps1`

This script configures **Windows Terminal** via `settings.json`. It includes:

- Preconfigured profiles for:
  - PowerShell Core with Hack Nerd Font and background image
  - Windows PowerShell
- Dark color scheme: `"One Half Dark"`
- Background image: ![Background](https://iili.io/HWMjae.png)

### ⚙️ `MyPwshProfile.ps1`

This PowerShell profile enhances your shell with:

- **Oh-My-Posh** prompt (Cloud Native Azure theme)
- **Terminal Icons** for better visual representation
- **PSReadLine** with autosuggestions and list-style history
- Auto-installs required modules if not already installed
- Bitwarden CLI install via Winget (for secure secrets handling)

---

## 🚀 Usage

1. **Run `ShellSetup.ps1` manually** or paste its content into your Windows Terminal `settings.json`.
2. **Copy `MyPwshProfile.ps1` to your PowerShell profile path**, usually:
   ```powershell
   $PROFILE

Or install it directly via PowerShell:
```powershell
irm "https://gist.githubusercontent.com/TheDarthAdmin/b6c4b95f79e45b3f6481f5ab2f7cb0a0/raw/9efa5e17b1ffdd78cae11868a249d99a6ae27838/ShellSetup.ps1" |iex
