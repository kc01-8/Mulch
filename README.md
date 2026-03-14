<div align="center">

# 🟣 Mulch Linux 🟣

**A curated Arch Linux distribution.**\
**Private by default. Game-ready out of the box.**

[![License](https://img.shields.io/github/license/kc01-8/mulch-linux?style=flat-square&color=9333ea&label=License)](https://github.com/kc01-8/mulch-linux/blob/main/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/kc01-8/mulch-linux?style=flat-square&color=22c55e&label=Latest)](https://github.com/kc01-8/mulch-linux/releases)
[![GitHub Stars](https://img.shields.io/github/stars/kc01-8/mulch-linux?style=flat-square&color=eab308&label=Stars)](https://github.com/kc01-8/mulch-linux/stargazers)

---

Minimal KDE Plasma desktop · Hand-picked software · Fully offline installation · Real privacy tools

[**Download ISO**](https://github.com/kc01-8/mulch-linux/releases) · [**Report Issue**](https://github.com/kc01-8/mulch-linux/issues) · [**Website**](https://kc01-8.github.io/MulchHomepage/)

</div>

---

## ✨ Features

<table>
<tr>
<td width="50%">

### 🔒 Private by Default
Mullvad VPN and Mullvad Browser ship pre-installed. Tor Browser included. KeePassXC with browser integration configured out of the box.

</td>
<td width="50%">

### 🎮 Game-Ready
Native Steam, Wine-staging, Gamemode, and every lib32 dependency pre-installed. Kernel tweaks for esync/fsync. Zero setup to start playing.

</td>
</tr>
<tr>
<td width="50%">

### ✈️ Fully Offline Install
Every package is on the ISO. No internet connection needed during installation. Boot it, run the installer, reboot into a complete system.

</td>
<td width="50%">

### ⚡ Zen Kernel
Linux Zen with BORE scheduler and full preemption. Lower input latency, fewer frame drops, smoother multitasking.

</td>
</tr>
<tr>
<td width="50%">

### 🖥️ Minimal KDE
Plasma Desktop with only Dolphin, Konsole, Spectacle, and Ark. No bloat. No PIM suite. No office suite. Yay preinstalled.

</td>
<td width="50%">

### 🛡️ LUKS Encryption
Optional full-disk encryption offered during install. Btrfs with subvolumes or ext4. Zram swap by default.

</td>
</tr>
</table>

<div align="center">

| `0` Flatpaks | `0` Snaps | `yay` AUR helper | `micro` Default editor |
|:---:|:---:|:---:|:---:|

</div>

---

## 📦 Pre-installed Software

<details open>
<summary><strong>🔐 Privacy & Security</strong></summary>

| Package | Description |
|:---|:---|
| Mullvad Browser | Privacy browser + KeePassXC extension |
| Tor Browser | Anonymous browsing |
| KeePassXC | Offline password manager |
| Mullvad VPN | VPN client, daemon auto-enabled |
| Signal Desktop | Encrypted messaging |

</details>

<details open>
<summary><strong>🎮 Gaming</strong></summary>

| Package | Description |
|:---|:---|
| Steam | Native package, auto-launches |
| Wine Staging | Windows compatibility layer |
| Gamemode | Gaming performance optimiser |

</details>

<details open>
<summary><strong>🎵 Media & Documents</strong></summary>

| Package | Description |
|:---|:---|
| mpv | Video player |
| Strawberry | Music player |
| qimgv | Image viewer |
| LazPaint | Image editor |
| Zathura | PDF viewer (mupdf backend) |
| Obsidian | Markdown knowledge base |

</details>

<details open>
<summary><strong>🔧 Utilities</strong></summary>

| Package | Description |
|:---|:---|
| qBittorrent | Torrent client |
| micro | Terminal text editor (default `$EDITOR`) |
| Ark | Archive manager + Dolphin integration |
| yay | AUR helper |

</details>

<details open>
<summary><strong>🖥️ Desktop</strong></summary>

| Package | Description |
|:---|:---|
| KDE Plasma | Minimal install |
| Dolphin | File manager |
| Konsole | Terminal emulator |
| Spectacle | Screenshot tool |

</details>

---

## 🚀 Quick Start

### Installing

> [!TIP]
> No internet connection is required during installation. Everything is on the ISO.

```bash
# Write ISO to USB (replace /dev/sdX)
sudo dd if=mulch-2025.07.iso of=/dev/sdX bs=4M status=progress

# Boot the USB, then run:
install-system
```

```
╔══════════════════════════════════════════════╗
║       Welcome to Mulch Linux Installer       ║
║                                              ║
║       No internet connection required.       ║
╚══════════════════════════════════════════════╝
```

The guided TUI installer handles partitioning, encryption, drivers, and everything else.

---

## 🏗️ Building the ISO

> [!IMPORTANT]
> Requires a working Arch Linux system with `archiso` installed.

```bash
# 1 — Install archiso
sudo pacman -S archiso

# 2 — Build AUR packages into a local repo (requires internet)
sudo ./build-aur-repo.sh

# 3 — Download the KeePassXC browser extension
./fetch-extensions.sh

# 4 — Build the ISO (requires internet for first run)
sudo ./build.sh
```

The final ISO appears in `out/`.

---

## 🖥️ GPU Support

The installer auto-detects your GPU and offers the appropriate drivers:

| GPU | Driver | Type |
|:---|:---|:---|
| NVIDIA | `nvidia-dkms` | Proprietary |
| AMD | `mesa` | Open-source |
| Intel | `mesa` | Open-source |

---

## ⚙️ Gaming Optimisations

<div align="center">

| Optimisation | Detail |
|:---|:---|
| `vm.max_map_count` | Raised to `2147483642` |
| File descriptor limits | Raised for esync/fsync |
| Gamemode | Pre-installed and configured |
| Wine Staging | Full dependency set included |
| Steam | Native package (no Flatpak) |
| Steam auto-launch | Launches minimised to tray on login |

</div>

---

<div align="center">

## 📄 License

This project is licensed under the terms found in [`LICENSE`](LICENSE).

Built on [Arch Linux](https://archlinux.org). Not affiliated with Arch Linux or any included project.

---

**[⬆ Back to top](#-mulch-linux)**

</div>
