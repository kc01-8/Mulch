#!/usr/bin/env bash
set -uo pipefail

INSTALLER_VERSION="1.0"
LOG="/tmp/installer.log"
MOUNT="/mnt"
OFFLINE_REPO="/opt/offline-repo"
EXT_DIR="/root/target-configs/extensions"

SEL_KEYMAP="us"
SEL_DISK=""
SEL_ENCRYPT="no"
SEL_ENCRYPT_PASS=""
SEL_FS="btrfs"
SEL_SWAP="zram"
SEL_HOSTNAME="mulch"
SEL_USERNAME=""
SEL_USER_PASS=""
SEL_ROOT_PASS=""
SEL_TIMEZONE="UTC"
SEL_LOCALE="en_US.UTF-8"
SEL_GPU="auto"
SEL_KERNEL="linux-zen"

IS_UEFI=0
PART_BOOT=""
PART_ROOT=""
PART_SWAP=""
LUKS_NAME="cryptroot"
BACKTITLE="Mulch Linux Installer v${INSTALLER_VERSION}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
msg()  { echo -e "${G}==>${N} $*"; }
warn() { echo -e "${Y}==> WARNING:${N} $*"; }
err()  { echo -e "${R}==> ERROR:${N} $*"; }
log()  { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }


detect_uefi() {
    [[ -d /sys/firmware/efi/efivars ]] && IS_UEFI=1 || IS_UEFI=0
}

detect_gpu() {
    if lspci 2>/dev/null | grep -qi 'nvidia'; then
        echo "nvidia"
    elif lspci 2>/dev/null | grep -qiE 'amd.*(radeon|rx|vega|navi|graphics)|ati'; then
        echo "amd"
    elif lspci 2>/dev/null | grep -qiE 'intel.*(graphics|uhd|iris|xe)'; then
        echo "intel"
    else
        echo "none"
    fi
}

detect_cpu() {
    if grep -qi amd /proc/cpuinfo; then
        echo "amd"
    else
        echo "intel"
    fi
}

_dialog() {
    dialog --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3
}

_msgbox() {
    dialog --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "$3" "$4"
}

_yesno() {
    dialog --backtitle "$BACKTITLE" --title "$1" --yesno "$2" "$3" "$4"
    return $?
}

_inputbox() {
    _dialog --title "$1" --inputbox "$2" "$3" "$4" "$5"
}

_passwordbox() {
    _dialog --title "$1" --insecure --passwordbox "$2" "$3" "$4"
}

_menu() {
    local title="$1"; shift
    local text="$1"; shift
    local h="$1"; shift
    local w="$1"; shift
    local mh="$1"; shift
    _dialog --title "$title" --menu "$text" "$h" "$w" "$mh" "$@"
}

stage_welcome() {
    _msgbox "Welcome" \
"Welcome to the Mulch Linux Installer.

This installer will set up Arch Linux with:
 - KDE Plasma (minimal)
 - Privacy tools (Mullvad, KeePassXC, Tor Browser)
 - Media & productivity apps
 - Full gaming support (native Steam)

All packages are on this ISO, no internet required.

Press OK to continue." 18 62
}

stage_keymap() {
    SEL_KEYMAP=$(_menu "Keyboard Layout" "Select your keyboard layout:" 18 50 10 \
        us      "US English" \
        uk      "UK English" \
        de      "German" \
        fr      "French" \
        es      "Spanish" \
        it      "Italian" \
        pt      "Portuguese" \
        ru      "Russian" \
        jp106   "Japanese" \
        br-abnt2 "Brazilian" \
    ) || SEL_KEYMAP="us"
    loadkeys "$SEL_KEYMAP" 2>/dev/null || true
}

stage_disk() {
    local -a items=()
    while IFS= read -r line; do
        local dev size model
        dev=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $4}')
        model=$(echo "$line" | awk '{$1=$2=$3=$4=""; print $0}' | xargs)
        [[ -z "$model" ]] && model="Disk"
        items+=("$dev" "${size} ${model}")
    done < <(lsblk -dpno NAME,TYPE,TRAN,SIZE,MODEL | grep -E 'disk' | grep -v 'loop\|sr\|rom')

    if [[ ${#items[@]} -eq 0 ]]; then
        _msgbox "Error" "No disks found." 8 40
        exit 1
    fi

    SEL_DISK=$(_menu "Disk Selection" \
        "Select the disk to install to.\n\n⚠  ALL DATA ON THIS DISK WILL BE ERASED!" \
        18 65 8 "${items[@]}")

    _yesno "Confirm" \
        "All data on ${SEL_DISK} will be permanently erased.\n\nContinue?" 10 50 \
        || { stage_disk; return; }
}

stage_encrypt() {
    if _yesno "Encryption" \
        "Enable full-disk encryption (LUKS)?\n\nStrongly recommended." 10 50; then
        SEL_ENCRYPT="yes"
        SEL_ENCRYPT_PASS=$(_passwordbox "Encryption" "Enter encryption passphrase:" 10 50)
        local confirm
        confirm=$(_passwordbox "Encryption" "Confirm encryption passphrase:" 10 50)
        if [[ "$SEL_ENCRYPT_PASS" != "$confirm" ]]; then
            _msgbox "Error" "Passphrases do not match. Try again." 8 40
            stage_encrypt
            return
        fi
    else
        SEL_ENCRYPT="no"
    fi
}

stage_filesystem() {
    SEL_FS=$(_menu "Filesystem" "Select root filesystem:" 12 50 4 \
        ext4  "ext4 (ideal, stable - recommended)" \
        btrfs "Btrfs (windows compatible, snapshots)" \

    ) || SEL_FS="ext4"
}

stage_swap() {
    SEL_SWAP=$(_menu "Swap" "Select swap method:" 14 55 4 \
        zram      "zram (compressed RAM - recommended)" \
        partition "Swap partition (RAM-sized)" \
        none      "No swap" \
    ) || SEL_SWAP="zram"
}

stage_hostname() {
    SEL_HOSTNAME=$(_inputbox "Hostname" "Enter hostname:" 10 50 "mulch") \
        || SEL_HOSTNAME="mulchlinux"
}

stage_user() {
    SEL_USERNAME=$(_inputbox "User Account" "Enter username:" 10 50 "") || true
    while [[ -z "$SEL_USERNAME" ]]; do
        _msgbox "Error" "Username cannot be empty." 8 40
        SEL_USERNAME=$(_inputbox "User Account" "Enter username:" 10 50 "") || true
    done

    SEL_USER_PASS=$(_passwordbox "User Password" \
        "Enter password for ${SEL_USERNAME}:" 10 50)
    local confirm
    confirm=$(_passwordbox "User Password" "Confirm password:" 10 50)
    if [[ "$SEL_USER_PASS" != "$confirm" ]]; then
        _msgbox "Error" "Passwords do not match." 8 40
        stage_user; return
    fi
}

stage_root_pass() {
    if _yesno "Root Password" \
        "Use the same password for root?" 8 45; then
        SEL_ROOT_PASS="$SEL_USER_PASS"
    else
        SEL_ROOT_PASS=$(_passwordbox "Root Password" "Enter root password:" 10 50)
        local confirm
        confirm=$(_passwordbox "Root Password" "Confirm root password:" 10 50)
        if [[ "$SEL_ROOT_PASS" != "$confirm" ]]; then
            _msgbox "Error" "Passwords do not match." 8 40
            stage_root_pass; return
        fi
    fi
}

stage_timezone() {
    local region city
    region=$(_menu "Timezone" "Select region:" 20 50 12 \
        America  "" \
        Europe   "" \
        Asia     "" \
        Africa   "" \
        Australia "" \
        Pacific  "" \
    ) || region="America"

    local -a cities=()
    while IFS= read -r c; do
        cities+=("$c" "")
    done < <(find /usr/share/zoneinfo/"$region" -maxdepth 1 -type f -printf '%f\n' | sort)

    city=$(_menu "Timezone" "Select city:" 20 50 12 "${cities[@]}") || city="New_York"
    SEL_TIMEZONE="${region}/${city}"
}

stage_locale() {
    SEL_LOCALE=$(_menu "Locale" "Select locale:" 16 55 8 \
        "en_US.UTF-8" "English (US)" \
        "en_GB.UTF-8" "English (UK)" \
        "de_DE.UTF-8" "German" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        "pt_BR.UTF-8" "Portuguese (BR)" \
        "ja_JP.UTF-8" "Japanese" \
        "ru_RU.UTF-8" "Russian" \
    ) || SEL_LOCALE="en_US.UTF-8"
}

stage_gpu() {
    local detected
    detected=$(detect_gpu)

    SEL_GPU=$(_menu "GPU Driver" \
        "Detected GPU: ${detected}\nSelect driver to install:" 16 60 5 \
        nvidia  "NVIDIA proprietary" \
        amd     "AMD open-source (mesa)" \
        intel   "Intel open-source (mesa)" \
        none    "None / Virtual machine" \
    ) || SEL_GPU="$detected"
}

stage_kernel() {
    SEL_KERNEL=$(_menu "Kernel" "Select kernel:" 14 60 4 \
        linux-zen "Linux Zen (optimised for desktop/gaming)" \
        linux     "Linux (default stable)" \
        linux-lts "Linux LTS (long-term support)" \
    ) || SEL_KERNEL="linux-zen"
}

stage_summary() {
    local enc_display="No"
    [[ "$SEL_ENCRYPT" == "yes" ]] && enc_display="Yes (LUKS)"

    local uefi_display="BIOS/Legacy"
    [[ $IS_UEFI -eq 1 ]] && uefi_display="UEFI"

    _yesno "Review Settings" \
"Boot mode:    ${uefi_display}
Disk:         ${SEL_DISK}
Encryption:   ${enc_display}
Filesystem:   ${SEL_FS}
Swap:         ${SEL_SWAP}
Kernel:       ${SEL_KERNEL}
Hostname:     ${SEL_HOSTNAME}
Username:     ${SEL_USERNAME}
Timezone:     ${SEL_TIMEZONE}
Locale:       ${SEL_LOCALE}
GPU driver:   ${SEL_GPU}

Proceed with installation?" 22 55 \
        || { _msgbox "Cancelled" "Installation cancelled." 8 40; exit 0; }
}

do_partition() {
    log "Partitioning ${SEL_DISK}"
    wipefs -af "$SEL_DISK" >> "$LOG" 2>&1
    sgdisk -Z "$SEL_DISK" >> "$LOG" 2>&1

    if [[ $IS_UEFI -eq 1 ]]; then
        sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI"  "$SEL_DISK" >> "$LOG" 2>&1
        if [[ "$SEL_SWAP" == "partition" ]]; then
            local ram_mb
            ram_mb=$(free -m | awk '/Mem:/{print $2}')
            sgdisk -n 2:0:+${ram_mb}M -t 2:8200 -c 2:"swap" "$SEL_DISK" >> "$LOG" 2>&1
            sgdisk -n 3:0:0 -t 3:8300 -c 3:"root" "$SEL_DISK" >> "$LOG" 2>&1
        else
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"root" "$SEL_DISK" >> "$LOG" 2>&1
        fi
    else
        parted -s "$SEL_DISK" mklabel msdos >> "$LOG" 2>&1
        parted -s "$SEL_DISK" mkpart primary fat32 1MiB 513MiB >> "$LOG" 2>&1
        parted -s "$SEL_DISK" set 1 boot on >> "$LOG" 2>&1
        if [[ "$SEL_SWAP" == "partition" ]]; then
            local ram_mb
            ram_mb=$(free -m | awk '/Mem:/{print $2}')
            parted -s "$SEL_DISK" mkpart primary linux-swap 513MiB $((513 + ram_mb))MiB >> "$LOG" 2>&1
            parted -s "$SEL_DISK" mkpart primary $((513 + ram_mb))MiB 100% >> "$LOG" 2>&1
        else
            parted -s "$SEL_DISK" mkpart primary 513MiB 100% >> "$LOG" 2>&1
        fi
    fi

    partprobe "$SEL_DISK" 2>/dev/null; sleep 2

    local p=""
    [[ "$SEL_DISK" == *nvme* || "$SEL_DISK" == *mmcblk* ]] && p="p"

    PART_BOOT="${SEL_DISK}${p}1"
    if [[ "$SEL_SWAP" == "partition" ]]; then
        PART_SWAP="${SEL_DISK}${p}2"
        PART_ROOT="${SEL_DISK}${p}3"
    else
        PART_ROOT="${SEL_DISK}${p}2"
    fi
    log "PART_BOOT=$PART_BOOT  PART_ROOT=$PART_ROOT  PART_SWAP=${PART_SWAP:-none}"
}

do_encrypt() {
    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        log "Setting up LUKS on ${PART_ROOT}"
        echo -n "$SEL_ENCRYPT_PASS" | cryptsetup luksFormat "$PART_ROOT" -d - >> "$LOG" 2>&1
        echo -n "$SEL_ENCRYPT_PASS" | cryptsetup luksOpen "$PART_ROOT" "$LUKS_NAME" -d - >> "$LOG" 2>&1
        PART_ROOT="/dev/mapper/${LUKS_NAME}"
    fi
}

do_format() {
    log "Formatting partitions"
    mkfs.fat -F32 "$PART_BOOT" >> "$LOG" 2>&1

    if [[ -n "${PART_SWAP:-}" ]]; then
        mkswap "$PART_SWAP" >> "$LOG" 2>&1
    fi

    case "$SEL_FS" in
        btrfs)
            mkfs.btrfs -f "$PART_ROOT" >> "$LOG" 2>&1
            ;;
        ext4)
            mkfs.ext4 -F "$PART_ROOT" >> "$LOG" 2>&1
            ;;
    esac
}

do_mount() {
    log "Mounting filesystems"
    if [[ "$SEL_FS" == "btrfs" ]]; then
        mount "$PART_ROOT" "$MOUNT" >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@"         >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@home"     >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@log"      >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@cache"    >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@tmp"      >> "$LOG" 2>&1
        umount "$MOUNT"

        local opts="noatime,compress=zstd:1,space_cache=v2"
        mount -o "subvol=@,${opts}"      "$PART_ROOT" "$MOUNT"
        mkdir -p "${MOUNT}"/{home,var/log,var/cache,tmp,boot}
        mount -o "subvol=@home,${opts}"  "$PART_ROOT" "${MOUNT}/home"
        mount -o "subvol=@log,${opts}"   "$PART_ROOT" "${MOUNT}/var/log"
        mount -o "subvol=@cache,${opts}" "$PART_ROOT" "${MOUNT}/var/cache"
        mount -o "subvol=@tmp,${opts}"   "$PART_ROOT" "${MOUNT}/tmp"
    else
        mount "$PART_ROOT" "$MOUNT"
        mkdir -p "${MOUNT}/boot"
    fi

    mount "$PART_BOOT" "${MOUNT}/boot"

    if [[ -n "${PART_SWAP:-}" ]]; then
        swapon "$PART_SWAP"
    fi

    # verify mount worked
    if ! mountpoint -q "$MOUNT"; then
        die_install "Failed to mount root filesystem"
    fi
    log "Root mounted successfully at ${MOUNT}"
}

do_fstab() {
    log "Generating fstab"
    genfstab -U "$MOUNT" >> "${MOUNT}/etc/fstab"
}

do_configure() {
    log "Configuring system"

    # verify chroot works before proceeding
    if ! arch-chroot "$MOUNT" /bin/true >> "$LOG" 2>&1; then
        die_install "arch-chroot failed. The base system may not be installed correctly."
    fi

    arch-chroot "$MOUNT" ln -sf "/usr/share/zoneinfo/${SEL_TIMEZONE}" /etc/localtime
    arch-chroot "$MOUNT" hwclock --systohc

    sed -i "s/^#${SEL_LOCALE}/${SEL_LOCALE}/" "${MOUNT}/etc/locale.gen"
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' "${MOUNT}/etc/locale.gen"
    arch-chroot "$MOUNT" locale-gen >> "$LOG" 2>&1
    echo "LANG=${SEL_LOCALE}" > "${MOUNT}/etc/locale.conf"

    echo "KEYMAP=${SEL_KEYMAP}" > "${MOUNT}/etc/vconsole.conf"

    echo "KEYMAP=${SEL_KEYMAP}" > "${MOUNT}/etc/vconsole.conf"
    # set a console font to suppress mkinitcpio warning
    echo "FONT=ter-v16b" >> "${MOUNT}/etc/vconsole.conf"

    echo "$SEL_HOSTNAME" > "${MOUNT}/etc/hostname"
    cat > "${MOUNT}/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${SEL_HOSTNAME}.localdomain ${SEL_HOSTNAME}
EOF

    cat > "${MOUNT}/etc/pacman.conf" <<'PACCONF'
[options]
HoldPkg     = pacman glibc
Architecture = x86_64
Color
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
PACCONF

    # set up mirrorlist
    cat > "${MOUNT}/etc/pacman.d/mirrorlist" <<'MIRRORLIST'
## Worldwide
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

## Generated — run 'sudo reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist' to update
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://mirror.leaseweb.net/archlinux/$repo/os/$arch
Server = https://archlinux.mirror.liteserver.nl/$repo/os/$arch
Server = https://mirror.f4st.host/archlinux/$repo/os/$arch
MIRRORLIST

    local hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
    fi
    sed -i "s|^HOOKS=.*|HOOKS=(${hooks})|" "${MOUNT}/etc/mkinitcpio.conf"

    if [[ "$SEL_GPU" == "nvidia" ]]; then
        sed -i 's/^MODULES=(.*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
            "${MOUNT}/etc/mkinitcpio.conf"
    fi

    # suppress missing firmware warnings for unused modules
    mkdir -p "${MOUNT}/etc/modprobe.d"
    echo "blacklist qat_6xxx" > "${MOUNT}/etc/modprobe.d/no-qat.conf"

    arch-chroot "$MOUNT" mkinitcpio -P >> "$LOG" 2>&1

    echo "root:${SEL_ROOT_PASS}" | arch-chroot "$MOUNT" chpasswd
    arch-chroot "$MOUNT" useradd -m -G wheel,video,audio,input,gamemode \
        -s /bin/bash "$SEL_USERNAME"
    echo "${SEL_USERNAME}:${SEL_USER_PASS}" | arch-chroot "$MOUNT" chpasswd
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        "${MOUNT}/etc/sudoers"

    arch-chroot "$MOUNT" systemctl enable sddm          >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable NetworkManager >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable bluetooth      >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable fstrim.timer   >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable ufw            >> "$LOG" 2>&1

    if [[ -f "${MOUNT}/usr/lib/systemd/system/mullvad-daemon.service" ]]; then
        arch-chroot "$MOUNT" systemctl enable mullvad-daemon >> "$LOG" 2>&1
    fi

    log "System configured successfully"
}

do_bootloader() {
    log "Installing bootloader"

    local grub_cmdline=""

    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        local phys_part p=""
        [[ "$SEL_DISK" == *nvme* || "$SEL_DISK" == *mmcblk* ]] && p="p"
        case "$SEL_SWAP" in
            partition) phys_part="${SEL_DISK}${p}3" ;;
            *)         phys_part="${SEL_DISK}${p}2" ;;
        esac
        local luks_uuid
        luks_uuid=$(blkid -s UUID -o value "$phys_part")
        grub_cmdline="cryptdevice=UUID=${luks_uuid}:${LUKS_NAME} root=/dev/mapper/${LUKS_NAME}"
    fi

    if [[ "$SEL_GPU" == "nvidia" ]]; then
        grub_cmdline+=" nvidia_drm.modeset=1"
    fi

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet ${grub_cmdline}\"|" \
        "${MOUNT}/etc/default/grub"
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${grub_cmdline}\"|" \
        "${MOUNT}/etc/default/grub"

    # branding
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Mulch"/' "${MOUNT}/etc/default/grub"
    # if GRUB_DISTRIBUTOR doesn't exist, add it
    if ! grep -q '^GRUB_DISTRIBUTOR' "${MOUNT}/etc/default/grub"; then
        echo 'GRUB_DISTRIBUTOR="Mulch"' >> "${MOUNT}/etc/default/grub"
    fi

    # purple theme colors
    cat >> "${MOUNT}/etc/default/grub" <<'GRUBCOLORS'
GRUB_COLOR_NORMAL="white/black"
GRUB_COLOR_HIGHLIGHT="magenta/black"
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
GRUBCOLORS

    if [[ $IS_UEFI -eq 1 ]]; then
        arch-chroot "$MOUNT" grub-install --target=x86_64-efi \
            --efi-directory=/boot --bootloader-id=GRUB >> "$LOG" 2>&1
    else
        arch-chroot "$MOUNT" grub-install --target=i386-pc "$SEL_DISK" >> "$LOG" 2>&1
    fi
	
    # enable os-prober to suppress warning (harmless on fresh install)
    echo "GRUB_DISABLE_OS_PROBER=false" >> "${MOUNT}/etc/default/grub"
	
    arch-chroot "$MOUNT" grub-mkconfig -o /boot/grub/grub.cfg >> "$LOG" 2>&1

    log "Bootloader installed"
}

do_gaming_tweaks() {
    log "Applying gaming & performance tweaks"

    mkdir -p "${MOUNT}/etc/sysctl.d"
    cat > "${MOUNT}/etc/sysctl.d/99-gaming.conf" <<'EOF'
vm.max_map_count = 2147483642
fs.file-max = 524288
vm.swappiness = 10
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
kernel.split_lock_mitigate = 0
EOF

    mkdir -p "${MOUNT}/etc/security/limits.d"
    cat > "${MOUNT}/etc/security/limits.d/99-gaming.conf" <<'EOF'
* soft nofile 524288
* hard nofile 524288
EOF

    if [[ "$SEL_GPU" == "nvidia" ]]; then
        mkdir -p "${MOUNT}/etc/modprobe.d"
        cat > "${MOUNT}/etc/modprobe.d/nvidia.conf" <<'EOF'
options nvidia_drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_UsePageAttributeTable=1
EOF
        arch-chroot "$MOUNT" systemctl enable nvidia-suspend >> "$LOG" 2>&1 || true
        arch-chroot "$MOUNT" systemctl enable nvidia-resume  >> "$LOG" 2>&1 || true
        arch-chroot "$MOUNT" systemctl enable nvidia-hibernate >> "$LOG" 2>&1 || true
    fi

    if [[ "$SEL_SWAP" == "zram" ]]; then
        mkdir -p "${MOUNT}/etc/systemd"
        cat > "${MOUNT}/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
    fi

    mkdir -p "${MOUNT}/etc"
    cat > "${MOUNT}/etc/gamemode.ini" <<'EOF'
[general]
renice = 10
ioprio = 0
softrealtime = auto
inhibit_screensaver = 1

[gpu]
apply_gpu_optimisations = accept-responsibility
gpu_device = 0
amd_performance_level = high

[custom]
start = notify-send "GameMode" "Optimisations activated"
end = notify-send "GameMode" "Optimisations deactivated"
EOF

    log "Gaming tweaks applied"
}

do_user_config() {
    log "Setting up user configuration"
    local home="${MOUNT}/home/${SEL_USERNAME}"

    mkdir -p "${MOUNT}/etc/profile.d"
    cat > "${MOUNT}/etc/profile.d/custom-defaults.sh" <<'EOF'
export EDITOR=micro
export VISUAL=micro
export MICRO_TRUECOLOR=1
EOF

    mkdir -p "${home}/.config/micro"
    cat > "${home}/.config/micro/settings.json" <<'EOF'
{
    "colorscheme": "monokai",
    "tabsize": 4,
    "tabstospaces": true,
    "autoclose": true,
    "autoindent": true,
    "savecursor": true,
    "scrollbar": true
}
EOF

    mkdir -p "${home}/.config/autostart"
    cat > "${home}/.config/autostart/steam.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Steam
Comment=Steam gaming platform
Exec=steam -silent
Icon=steam
X-KDE-autostart-after=panel
X-KDE-autostart-phase=2
StartupNotify=false
EOF

    mkdir -p "${home}/.config/zathura"
    cat > "${home}/.config/zathura/zathurarc" <<'EOF'
set selection-clipboard clipboard
set adjust-open "best-fit"
set pages-per-row 1
set scroll-page-aware "true"
set smooth-scroll "true"
set font "monospace normal 11"
set default-bg "#1e1e2e"
set default-fg "#cdd6f4"
set recolor "true"
set recolor-lightcolor "#1e1e2e"
set recolor-darkcolor "#cdd6f4"
EOF

    mkdir -p "${home}/.config/mpv"
    cat > "${home}/.config/mpv/mpv.conf" <<'EOF'
profile=gpu-hq
vo=gpu-next
hwdec=auto-safe
keep-open=yes
save-position-on-quit=yes
osd-bar=no
border=no
EOF

    # KeePassXC browser extension for Mullvad Browser
    local mb_dist_dir=""
    for candidate in \
        "${MOUNT}/usr/lib/mullvad-browser" \
        "${MOUNT}/opt/mullvad-browser" \
        "${MOUNT}/usr/share/mullvad-browser"; do
        if [[ -d "$candidate" ]]; then
            mb_dist_dir="${candidate}/distribution"
            break
        fi
    done

    if [[ -z "$mb_dist_dir" ]]; then
        mb_dist_dir="${MOUNT}/usr/lib/mullvad-browser/distribution"
    fi

    mkdir -p "${mb_dist_dir}/extensions"

    if [[ -f "${EXT_DIR}/keepassxc-browser@keepassxc.org.xpi" ]]; then
        cp "${EXT_DIR}/keepassxc-browser@keepassxc.org.xpi" "${mb_dist_dir}/extensions/"
    fi

    cat > "${mb_dist_dir}/policies.json" <<'EOF'
{
    "policies": {
        "ExtensionSettings": {
            "keepassxc-browser@keepassxc.org": {
                "installation_mode": "normal_installed",
                "install_url": "https://addons.mozilla.org/firefox/downloads/latest/keepassxc-browser/latest.xpi"
            }
        }
    }
}
EOF

    mkdir -p "${home}/.config"
    cat > "${home}/.config/mimeapps.list" <<'EOF'
[Default Applications]
application/pdf=org.pwmt.zathura.desktop
image/png=qimgv.desktop
image/jpeg=qimgv.desktop
image/gif=qimgv.desktop
image/webp=qimgv.desktop
image/bmp=qimgv.desktop
image/svg+xml=qimgv.desktop
video/mp4=mpv.desktop
video/x-matroska=mpv.desktop
video/webm=mpv.desktop
video/avi=mpv.desktop
audio/mpeg=strawberry.desktop
audio/flac=strawberry.desktop
audio/ogg=strawberry.desktop
audio/x-wav=strawberry.desktop
text/plain=micro.desktop
EOF

    # ── taskbar setup (first login) ──────────────────────────────
    cat > "${MOUNT}/usr/local/bin/mulch-taskbar-setup" <<'TASKBAR'
#!/bin/bash
# only run for real users, not root (live ISO)
[ "$(whoami)" = "root" ] && exit 0

sleep 20

RCFILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
[ ! -f "$RCFILE" ] && exit 0

CONTAINMENT=$(grep -B3 "plugin=org.kde.plasma.icontasks" "$RCFILE" | grep -oP 'Containments\]\[\K[0-9]+' | head -1)
APPLET=$(grep -B1 "plugin=org.kde.plasma.icontasks" "$RCFILE" | grep -oP 'Applets\]\[\K[0-9]+' | head -1)

[ -z "$CONTAINMENT" ] || [ -z "$APPLET" ] && exit 0

LAUNCHERS="applications:mullvad-browser.desktop,applications:mullvad-vpn.desktop,applications:org.keepassxc.KeePassXC.desktop,applications:steam.desktop,applications:org.strawberrymusicplayer.strawberry.desktop,applications:signal.desktop,applications:lazpaint.desktop,applications:obsidian.desktop,applications:org.kde.konsole.desktop,applications:systemsettings.desktop"

kwriteconfig6 --file "$RCFILE" \
    --group "Containments" --group "$CONTAINMENT" \
    --group "Applets" --group "$APPLET" \
    --group "Configuration" --group "General" \
    --key "launchers" "$LAUNCHERS"

sed -i '/org.kde.discover/d' "$RCFILE"

qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || \
    dbus-send --session --dest=org.kde.plasmashell --type=method_call /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || \
    (kquitapp6 plasmashell 2>/dev/null; sleep 2; kstart plasmashell 2>/dev/null &)

rm -f "$HOME/.config/autostart/mulch-taskbar.desktop"
TASKBAR

    chmod +x "${MOUNT}/usr/local/bin/mulch-taskbar-setup"

    cat > "${home}/.config/autostart/mulch-taskbar.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Mulch Taskbar Setup
Exec=/usr/local/bin/mulch-taskbar-setup
X-KDE-autostart-phase=2
NoDisplay=true
EOF

    msg "  ✓ Taskbar setup script installed"

    arch-chroot "$MOUNT" chown -R "${SEL_USERNAME}:${SEL_USERNAME}" \
        "/home/${SEL_USERNAME}" >> "$LOG" 2>&1

    log "User configuration complete"
}

do_cleanup() {
    log "Final cleanup"

    # remove flatpak if somehow present
    arch-chroot "$MOUNT" pacman -Rns --noconfirm flatpak 2>/dev/null || true

    # clear package cache non-interactively
    rm -rf "${MOUNT}/var/cache/pacman/pkg/"* 2>/dev/null || true
    log "Package cache cleared"

    # sync databases now that mirrorlist exists
    arch-chroot "$MOUNT" pacman -Sy --noconfirm >> "$LOG" 2>&1 || true

    # verify yay works
    if [[ -f "${MOUNT}/usr/bin/yay" ]]; then
        arch-chroot "$MOUNT" su - "${SEL_USERNAME}" -c "yay --version" >> "$LOG" 2>&1 || true
        msg "  ✓ yay available"
    else
        warn "  yay not installed"
    fi

    sync
    log "Cleanup complete"
}

do_unmount() {
    log "Unmounting"
    [[ -n "${PART_SWAP:-}" ]] && swapoff "$PART_SWAP" 2>/dev/null || true
    umount -R "$MOUNT" 2>/dev/null || true
    [[ "$SEL_ENCRYPT" == "yes" ]] && cryptsetup close "$LUKS_NAME" 2>/dev/null || true
}

run_step() {
    local pct="$1"
    local desc="$2"
    local func="$3"

    echo "$pct" > /tmp/install-progress
    echo "$desc" > /tmp/install-step

    log "=== ${desc} ==="

    if ! $func >> "$LOG" 2>&1; then
        echo "FAILED: ${desc}" > /tmp/install-failed
        log "FAILED: ${desc}"
        return 1
    fi

    return 0
}

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run as root."
        exit 1
    fi

    : > "$LOG"
    rm -f /tmp/install-failed /tmp/install-progress /tmp/install-step
    log "Installer started"

    detect_uefi
    log "UEFI=$IS_UEFI"

    stage_welcome
    stage_keymap
    stage_disk
    stage_encrypt
    stage_filesystem
    stage_swap
    stage_hostname
    stage_user
    stage_root_pass
    stage_timezone
    stage_locale
    stage_gpu
    stage_kernel
    stage_summary

    # ── run installation steps directly (no subshell) ────────────
    clear
    echo ""
    echo "  Installing Mulch Linux…"
    echo "  Logs: ${LOG}"
    echo ""

    run_step 5  "Partitioning disk..."       do_partition  || true
    run_step 10 "Setting up encryption..."   do_encrypt    || true
    run_step 15 "Formatting partitions..."   do_format     || true
    run_step 18 "Mounting filesystems..."    do_mount

    if [[ -f /tmp/install-failed ]]; then
        err "$(cat /tmp/install-failed)"
        err "Check log: $LOG"
        echo ""
        echo "Press Enter to view log, or Ctrl+C to exit."
        read -r
        less "$LOG"
        exit 1
    fi

    echo ""
    echo "  [20%] Installing packages (this is the slow part)…"
    echo "  This can take 5-15 minutes depending on disk speed."
    echo ""

    # run pacstrap directly so we can see output
    log "=== Installing packages ==="

    # verify offline repo first
    if [[ ! -d "$OFFLINE_REPO" ]]; then
        err "Offline repo not found at ${OFFLINE_REPO}"
        log "ls /opt/:"
        ls -la /opt/ >> "$LOG" 2>&1
        echo ""
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    if [[ ! -f "$OFFLINE_REPO/mulch.db" ]]; then
        err "mulch.db not found"
        log "Contents of ${OFFLINE_REPO}:"
        ls -la "$OFFLINE_REPO"/ >> "$LOG" 2>&1
        echo ""
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    local pkg_count
    pkg_count=$(find "$OFFLINE_REPO" -name "*.pkg.tar.*" ! -name "*.sig" | wc -l)
    msg "Found ${pkg_count} packages in offline repo"

    # write pacman config
    cat > /tmp/pacman-offline.conf <<EOF
[options]
HoldPkg     = pacman glibc
Architecture = x86_64
SigLevel    = Never
ParallelDownloads = 5

[mulch]
SigLevel = Never
Server = file://${OFFLINE_REPO}
EOF

    # test it
    msg "Testing offline repo access…"
    mkdir -p /tmp/pacman-test-db
    if ! pacman -Sy --config /tmp/pacman-offline.conf --dbpath /tmp/pacman-test-db 2>&1 | tee -a "$LOG"; then
        err "pacman cannot read offline repo"
        rm -rf /tmp/pacman-test-db
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    local db_count
    db_count=$(pacman -Sl mulch --config /tmp/pacman-offline.conf --dbpath /tmp/pacman-test-db 2>/dev/null | wc -l)
    msg "Database has ${db_count} entries"
    rm -rf /tmp/pacman-test-db

    # build package list
    local cpu_ucode=""
    case "$(detect_cpu)" in
        amd)   cpu_ucode="amd-ucode" ;;
        intel) cpu_ucode="intel-ucode" ;;
    esac

    local kernel_headers="${SEL_KERNEL}-headers"

    local -a pkgs=(
        base base-devel "$SEL_KERNEL" "$kernel_headers" linux-firmware
        mkinitcpio
        grub efibootmgr os-prober
        btrfs-progs dosfstools e2fsprogs ntfs-3g exfatprogs
        networkmanager iwd openssh wget curl reflector dhcpcd
        pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
        bluez bluez-utils
        xorg-server xorg-xinit xorg-xrandr
        vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools
        dkms cryptsetup lvm2
        ufw zram-generator pacman-contrib
        git bash-completion man-db man-pages htop
        unzip unrar rsync tmux dialog terminus-font
    )

    [[ -n "$cpu_ucode" ]] && pkgs+=("$cpu_ucode")

    case "$SEL_GPU" in
        nvidia)
            pkgs+=(
                nvidia-open-dkms nvidia-utils lib32-nvidia-utils
                nvidia-settings opencl-nvidia lib32-opencl-nvidia
            )
            ;;
        amd)
            pkgs+=(
                mesa lib32-mesa
                vulkan-radeon lib32-vulkan-radeon
                xf86-video-amdgpu
            )
            ;;
        intel)
            pkgs+=(
                mesa lib32-mesa
                vulkan-intel lib32-vulkan-intel intel-media-driver
            )
            ;;
    esac

    pkgs+=(
        plasma-desktop sddm sddm-kcm
        dolphin konsole spectacle ark
        plasma-pa plasma-nm plasma-systemmonitor
        kscreen powerdevil bluedevil
        kde-gtk-config breeze-gtk breeze
        xdg-desktop-portal-kde polkit-kde-agent
    )

    pkgs+=(
        micro
        mpv strawberry qbittorrent keepassxc
        zathura zathura-pdf-mupdf
        signal-desktop
    )

    pkgs+=(
        steam
        wine-staging wine-mono wine-gecko winetricks
        gamemode lib32-gamemode
        vkd3d lib32-vkd3d
        lib32-gst-plugins-base lib32-gst-plugins-good
        lib32-libpulse lib32-openal
        lib32-libxcomposite lib32-libxinerama
        lib32-libgcrypt lib32-gnutls
        lib32-libxslt lib32-libva lib32-gtk3
        lib32-libcups lib32-ocl-icd
    )

    pkgs+=(
        ttf-liberation lib32-fontconfig
        noto-fonts noto-fonts-cjk noto-fonts-emoji
    )

    msg "Installing ${#pkgs[@]} packages via pacstrap…"

    # pacstrap with --noconfirm doesn't handle provider selection well
    # pre-answer by setting the provider explicitly based on GPU choice
    case "$SEL_GPU" in
        nvidia) pkgs+=(nvidia-utils lib32-nvidia-utils) ;;
        amd)    pkgs+=(vulkan-radeon lib32-vulkan-radeon) ;;
        intel)  pkgs+=(vulkan-intel lib32-vulkan-intel) ;;
        *)      pkgs+=(vulkan-radeon lib32-vulkan-radeon) ;;
    esac

    # run pacstrap
    if ! pacstrap -C /tmp/pacman-offline.conf "$MOUNT" "${pkgs[@]}" 2>&1 | tee -a "$LOG"; then
        err "pacstrap failed"
        echo ""
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    # verify base install
    if [[ ! -f "${MOUNT}/usr/bin/bash" ]]; then
        err "pacstrap ran but /usr/bin/bash is missing"
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    msg "Base packages installed successfully"

    msg "Installing AUR packages…"

    # mount offline repo into chroot so pacman can resolve deps
    mkdir -p "${MOUNT}/opt/offline-repo"
    mount --bind "$OFFLINE_REPO" "${MOUNT}/opt/offline-repo"

    # create temp pacman config in chroot pointing to offline repo
    cat > "${MOUNT}/etc/pacman-aur.conf" <<'AURCONF'
[options]
Architecture = x86_64
SigLevel = Never

[mulch]
SigLevel = Never
Server = file:///opt/offline-repo
AURCONF

    # sync database inside chroot
    arch-chroot "$MOUNT" pacman --config /etc/pacman-aur.conf -Sy >> "$LOG" 2>&1

    AUR_PKGS=(
        yay-bin
        mullvad-vpn-bin
        mullvad-browser-bin
        tor-browser-bin
        obsidian-bin
        qimgv-git
        lazpaint-git
    )

    for aurpkg in "${AUR_PKGS[@]}"; do
        echo "  Installing ${aurpkg}…"
        if arch-chroot "$MOUNT" pacman --config /etc/pacman-aur.conf -S --noconfirm "$aurpkg" >> "$LOG" 2>&1; then
            msg "  ✓ ${aurpkg}"
        elif arch-chroot "$MOUNT" pacman --config /etc/pacman-aur.conf -Sdd --noconfirm "$aurpkg" >> "$LOG" 2>&1; then
            msg "  ✓ ${aurpkg} (skipped broken deps)"
        else
            warn "  ✗ ${aurpkg} failed"
        fi
    done

    # cleanup
    umount "${MOUNT}/opt/offline-repo" 2>/dev/null || true
    rmdir "${MOUNT}/opt/offline-repo" 2>/dev/null || true
    rm -f "${MOUNT}/etc/pacman-aur.conf"

    msg "AUR packages done"

    # ── remaining steps ──────────────────────────────────────────
    echo "  [70%] Generating fstab…"
    do_fstab >> "$LOG" 2>&1

    echo "  [72%] Configuring system…"
    if ! do_configure >> "$LOG" 2>&1; then
        err "Configuration failed. Check log."
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    echo "  [82%] Installing bootloader…"
    if ! do_bootloader >> "$LOG" 2>&1; then
        err "Bootloader installation failed. Check log."
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    echo "  [88%] Applying gaming tweaks…"
    do_gaming_tweaks >> "$LOG" 2>&1

    echo "  [93%] Setting up user config…"
    do_user_config >> "$LOG" 2>&1

    echo "  [97%] Cleaning up…"
    do_cleanup >> "$LOG" 2>&1

    echo "  [100%] Done!"
    echo ""

    if grep -qi "error\|failed" "$LOG" 2>/dev/null; then
        echo "  Some warnings were logged."
        echo "  Press Enter to view log, or type 'skip' to continue."
        read -r answer
        if [[ "$answer" != "skip" ]]; then
            less "$LOG"
        fi
    fi

    # ── finish ───────────────────────────────────────────────────
    do_unmount
    echo ""
    echo "           Mulch Linux installed successfully!         "
    echo "                                                       "
    echo "           Username: ${SEL_USERNAME}                   "
    echo "           Hostname: ${SEL_HOSTNAME}                   "
    echo "                                                       "
    echo "           Type 'reboot' when ready.                   "
    echo ""
}

main "$@"