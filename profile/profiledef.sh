#!/usr/bin/env bash
iso_name="mulch-linux"
iso_label="MULCHLINUX_$(date +%Y%m)"
iso_publisher="Mulch Linux"
iso_application="Mulch Linux Installer"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=(
    'bios.syslinux'
    'uefi.grub'
)
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' "${MULCH_COMPRESS_LEVEL:-19}" '-b' '1M')
file_permissions=(
    ["/etc/shadow"]="0:0:400"
    ["/etc/sudoers.d/live"]="0:0:440"
    ["/root"]="0:0:750"
    ["/root/installer.sh"]="0:0:755"
    ["/root/Desktop/install-mulch.desktop"]="0:0:755"
    ["/home/live"]="1000:1000:750"
    ["/home/live/Desktop/install-mulch.desktop"]="1000:1000:755"
    ["/usr/local/bin/install-system"]="0:0:755"
    ["/usr/local/bin/mulch-taskbar-setup"]="0:0:755"
    ["/usr/local/bin/mulch-welcome"]="0:0:755"
    ["/usr/local/bin/start-gui"]="0:0:755"
    ["/home/live/.config/Mullvad VPN/gui_settings.json"]="1000:1000:644"
)