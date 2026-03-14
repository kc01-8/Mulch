#!/usr/bin/env bash
iso_name="mulch-linux"
iso_label="MULCHLINUX_$(date +%Y%m)"
iso_publisher="Mulch Linux"
iso_application="Mulch Linux Installer"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=(
    'bios.syslinux.mbr'
    'bios.syslinux.eltorito'
    'uefi-ia32.grub.esp'
    'uefi-x64.grub.esp'
    'uefi-ia32.grub.eltorito'
    'uefi-x64.grub.eltorito'
)
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15')
file_permissions=(
    ["/root"]="0:0:750"
    ["/root/installer.sh"]="0:0:755"
    ["/usr/local/bin/install-system"]="0:0:755"
)
