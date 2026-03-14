# Mulch Linux

A fully offline Arch Linux installer with KDE Plasma, gaming support, and a curated set of applications.

## Pre-installed Software

| Category       | Packages                                       |
|----------------|------------------------------------------------|
| Desktop        | KDE Plasma (minimal)                           |
| Browser        | Mullvad Browser (+ KeePassXC ext), Tor Browser |
| Privacy/VPN    | Mullvad VPN, KeePassXC                         |
| Media          | mpv, Strawberry, qimgv                         |
| Documents      | Zathura (PDF), Obsidian, 7zip                  |
| Communication  | Signal Desktop                                 |
| Gaming         | Steam (native), Wine, Gamemode                 |
| Torrents       | qBittorrent                                    |
| Graphics       | LazPaint                                       |
| Editor         | micro (default $EDITOR)                        |
| AUR Helper     | yay                                            |
|----------------|------------------------------------------------|

## Building the ISO

Requires a working Arch Linux system with `archiso` installed.

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

## Installing

Boot the ISO. At the shell prompt run:

```bash
install-system
```

Follow the guided TUI installer. No internet connection is required.

## GPU Support

The installer auto-detects your GPU and offers:
- NVIDIA (nvidia-dkms, proprietary)
- AMD (mesa, open-source)
- Intel (mesa, open-source)

## Gaming Optimisations Included

- vm.max_map_count raised to 2147483642
- File descriptor limits raised for esync/fsync
- Gamemode
- Wine-staging + dependencies
- Native Steam (no Flatpak)
- Steam auto-launches on login (minimised to tray)
