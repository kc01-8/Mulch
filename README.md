<div align="center">

<br>

# Mulch Linux

**A curated Arch Linux distribution.**<br>
**Private by default. Game-ready out of the box.**

<br>

[![Built on Arch](https://img.shields.io/badge/Built_on-Arch_Linux-1793D1?style=for-the-badge&logo=archlinux&logoColor=white)](https://archlinux.org)
[![License](https://img.shields.io/github/license/kc01-8/mulch-linux?style=for-the-badge&color=9333ea&label=License)](https://github.com/kc01-8/mulch-linux/blob/main/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/kc01-8/mulch-linux?style=for-the-badge&color=22c55e&label=Latest)](https://github.com/kc01-8/mulch-linux/releases)
[![GitHub Stars](https://img.shields.io/github/stars/kc01-8/mulch-linux?style=for-the-badge&color=eab308&label=Stars)](https://github.com/kc01-8/mulch-linux/stargazers)

<br>

Minimal KDE Plasma desktop · Hand-picked software · Fully offline installation · Real privacy tools

<br>

[**⬇ Download ISO**](https://github.com/kc01-8/mulch-linux/releases)&nbsp;&nbsp;&nbsp;·&nbsp;&nbsp;&nbsp;[**🐛 Report Issue**](https://github.com/kc01-8/mulch-linux/issues)&nbsp;&nbsp;&nbsp;·&nbsp;&nbsp;&nbsp;[**🌐 Website**](https://kc01-8.github.io/mulch-linux)

<br>

---

<br>

## ✨ Features

<br>

🔒 **Private by Default**<br>
Mullvad VPN and Mullvad Browser ship pre-installed. Tor Browser included.<br>
KeePassXC with browser integration configured out of the box.

<br>

🎮 **Game-Ready**<br>
Native Steam, Wine-staging, Gamemode, and every lib32 dependency pre-installed.<br>
Kernel tweaks for esync/fsync. Zero setup to start playing.

<br>

✈️ **Fully Offline Install**<br>
Every package is on the ISO. No internet connection needed during installation.<br>
Boot it, run the installer, reboot into a complete system.

<br>

⚡ **Zen Kernel**<br>
Linux Zen with BORE scheduler and full preemption.<br>
Lower input latency, fewer frame drops, smoother multitasking.

<br>

🖥️ **Minimal KDE**<br>
Plasma Desktop with only Dolphin, Konsole, Spectacle, and Ark.<br>
No bloat. No PIM suite. No office suite. Yay preinstalled.

<br>

🛡️ **LUKS Encryption**<br>
Optional full-disk encryption offered during install.<br>
Btrfs with subvolumes or ext4. Zram swap by default.

<br>

| `0` Flatpaks | `0` Snaps | `yay` AUR Helper | `micro` Default Editor |
|:---:|:---:|:---:|:---:|

<br>

---

<br>

## 📦 Pre-installed Software

<br>

### 🔐 Privacy & Security

| Package | Description |
|:---:|:---:|
| Mullvad Browser | Privacy browser + KeePassXC extension |
| Tor Browser | Anonymous browsing |
| KeePassXC | Offline password manager |
| Mullvad VPN | VPN client, daemon auto-enabled |
| Signal Desktop | Encrypted messaging |

<br>

### 🎮 Gaming

| Package | Description |
|:---:|:---:|
| Steam | Native package, auto-launches |
| Wine Staging | Windows compatibility layer |
| Gamemode | Gaming performance optimiser |

<br>

### 🎵 Media & Documents

| Package | Description |
|:---:|:---:|
| mpv | Video player |
| Strawberry | Music player |
| qimgv | Image viewer |
| LazPaint | Image editor |
| Zathura | PDF viewer (mupdf backend) |
| Obsidian | Markdown knowledge base |

<br>

### 🔧 Utilities

| Package | Description |
|:---:|:---:|
| qBittorrent | Torrent client |
| micro | Terminal text editor (default `$EDITOR`) |
| Ark | Archive manager + Dolphin integration |
| yay | AUR helper |

<br>

### 🖥️ Desktop

| Package | Description |
|:---:|:---:|
| KDE Plasma | Minimal install |
| Dolphin | File manager |
| Konsole | Terminal emulator |
| Spectacle | Screenshot tool |

<br>

---

<br>

## 🚀 Quick Start

<br>

> [!TIP]
> No internet connection is required during installation. Everything is on the ISO.

<br>

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

<br>

---

<br>

## 🏗️ Building the ISO

<br>

> [!IMPORTANT]
> Requires a working Arch Linux system with `archiso` installed.

<br>

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

<br>

---

<br>

## 🖥️ GPU Support

<br>

The installer auto-detects your GPU and offers the appropriate drivers:

<br>

| GPU | Driver | Type |
|:---:|:---:|:---:|
| NVIDIA | `nvidia-dkms` | Proprietary |
| AMD | `mesa` | Open-source |
| Intel | `mesa` | Open-source |

<br>

---

<br>

## ⚙️ Gaming Optimisations

<br>

| Optimisation | Detail |
|:---:|:---:|
| `vm.max_map_count` | Raised to `2147483642` |
| File descriptor limits | Raised for esync/fsync |
| Gamemode | Pre-installed and configured |
| Wine Staging | Full dependency set included |
| Steam | Native package (no Flatpak) |
| Steam auto-launch | Launches minimised to tray on login |

<br>

---

<br>

## 📄 License

This project is licensed under the terms found in [`LICENSE`](LICENSE).

Built on [Arch Linux](https://archlinux.org). Not affiliated with Arch Linux or any included project.

<br>

**[⬆ Back to top](#mulch-linux)**

<br>

</div>
