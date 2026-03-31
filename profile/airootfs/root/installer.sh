#!/usr/bin/env bash
#  Mulch Linux Copy Based Offline Installer
set -uo pipefail

INSTALLER_VERSION="3.0"
LOG="/tmp/installer.log"
MOUNT="/mnt"
KERNEL_REPO="/opt/kernel-repo"

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
BACKTITLE="Mulch Linux Installer"

# dialog color scheme (purple background, orange text)
export DIALOGRC=/tmp/dialogrc
cat > /tmp/dialogrc <<'DIALOGRC'
use_shadow = OFF
use_colors = ON

screen_color = (WHITE,MAGENTA,ON)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (YELLOW,MAGENTA,ON)
title_color = (YELLOW,MAGENTA,ON)
border_color = (WHITE,MAGENTA,ON)
button_active_color = (BLACK,YELLOW,ON)
button_inactive_color = (WHITE,MAGENTA,ON)
button_key_active_color = (BLACK,YELLOW,ON)
button_key_inactive_color = (YELLOW,MAGENTA,ON)
button_label_active_color = (BLACK,YELLOW,ON)
button_label_inactive_color = (WHITE,MAGENTA,ON)
inputbox_color = (BLACK,WHITE,ON)
inputbox_border_color = (MAGENTA,WHITE,ON)
searchbox_color = (BLACK,WHITE,ON)
searchbox_title_color = (YELLOW,WHITE,ON)
searchbox_border_color = (MAGENTA,WHITE,ON)
position_indicator_color = (YELLOW,MAGENTA,ON)
menubox_color = (BLACK,MAGENTA,ON)
menubox_border_color = (WHITE,MAGENTA,ON)
item_color = (WHITE,MAGENTA,OFF)
item_selected_color = (BLACK,YELLOW,ON)
tag_color = (YELLOW,MAGENTA,ON)
tag_selected_color = (BLACK,YELLOW,ON)
tag_key_color = (YELLOW,MAGENTA,ON)
tag_key_selected_color = (BLACK,YELLOW,ON)
check_color = (WHITE,MAGENTA,ON)
check_selected_color = (BLACK,YELLOW,ON)
uarrow_color = (YELLOW,MAGENTA,ON)
darrow_color = (YELLOW,MAGENTA,ON)
gauge_color = (YELLOW,MAGENTA,ON)
border2_color = (YELLOW,MAGENTA,ON)
DIALOGRC

R='\033[0;31m'; G='\033[0;35m'; Y='\033[1;33m'; O='\033[38;5;208m'; P='\033[45m'; N='\033[0m'
msg()  { echo -e "${O}==>${N} $*"; }
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

#  TUI STAGES

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
        || SEL_HOSTNAME="mulch"
    if [[ ! "$SEL_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        _msgbox "Error" "Invalid hostname. Use only letters, numbers, and hyphens.\nMust start and end with a letter or number." 10 50
        stage_hostname; return
    fi
}

stage_user() {
    local reserved="root bin daemon mail ftp http nobody dbus systemd-journal-remote systemd-network systemd-oom systemd-resolve systemd-timesync systemd-coredump uuidd polkitd tss usbmux avahi colord git rtkit sddm live"

    SEL_USERNAME=$(_inputbox "User Account" "Enter username:" 10 50 "") || true
    while [[ -z "$SEL_USERNAME" ]]; do
        _msgbox "Error" "Username cannot be empty." 8 40
        SEL_USERNAME=$(_inputbox "User Account" "Enter username:" 10 50 "") || true
    done

    if [[ ! "$SEL_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
        _msgbox "Error" "Invalid username. Use lowercase letters, numbers,\nhyphens, and underscores. Must start with a letter." 10 55
        stage_user; return
    fi

    if echo " $reserved " | grep -q " $SEL_USERNAME "; then
        _msgbox "Error" "'${SEL_USERNAME}' is a reserved system name." 8 50
        stage_user; return
    fi

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

    # dynamically list all timezone regions
    local -a regions=()
    while IFS= read -r r; do
        regions+=("$r" "")
    done < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d \
        ! -name posix ! -name right ! -name Etc \
        -printf '%f\n' | sort)

    # fallback if find fails
    if [[ ${#regions[@]} -eq 0 ]]; then
        regions=(America "" Europe "" Asia "" Africa "" Australia "" Pacific "")
    fi

    region=$(_menu "Timezone" "Select region:" 20 50 12 "${regions[@]}") || region="America"

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

#  INSTALLATION ROUTINES

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

    # devices that use 'p' separator before partition number
    local p=""
    [[ "$SEL_DISK" == *nvme* || "$SEL_DISK" == *mmcblk* || "$SEL_DISK" == *loop* || "$SEL_DISK" == *nbd* ]] && p="p"

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

    if ! mountpoint -q "$MOUNT"; then
        err "Failed to mount root filesystem"
        exit 1
    fi
    log "Root mounted successfully at ${MOUNT}"
}

do_copy_system() {
    log "Copying live system to disk"

    rsync -aAXH --info=progress2 \
        --exclude='/dev/*' \
        --exclude='/proc/*' \
        --exclude='/sys/*' \
        --exclude='/tmp/*' \
        --exclude='/run/*' \
        --exclude='/mnt/*' \
        --exclude='/lost+found' \
        --exclude='/opt/kernel-repo' \
        --exclude='/root/installer.sh' \
        --exclude='/root/Desktop' \
        --exclude='/root/target-configs' \
        --exclude='/root/.config/plasma-org.kde.plasma.desktop-appletsrc' \
        --exclude='/root/.config/autostart' \
        --exclude='/etc/systemd/system/getty@tty1.service.d' \
        --exclude='/etc/systemd/system/graphical.target.wants/sddm.service' \
        --exclude='/etc/systemd/system/multi-user.target.wants/NetworkManager.service' \
        --exclude='/etc/sddm.conf.d/autologin.conf' \
        --exclude='/etc/mkinitcpio.conf' \
        --exclude='/etc/motd' \
        --exclude='/etc/issue' \
        --exclude='/etc/hostname' \
        --exclude='/etc/hosts' \
        --exclude='/etc/fstab' \
        --exclude='/etc/machine-id' \
        --exclude='/etc/pacman.d/hooks/mulch-panel-layout.hook' \
        --exclude='/var/log/*' \
        --exclude='/var/cache/pacman/pkg/*' \
        --exclude='/var/tmp/*' \
        --exclude='/usr/local/bin/install-system' \
        --exclude='/usr/local/bin/start-gui' \
        --exclude='/home/live' \
        / "${MOUNT}/" 2>&1 | tee -a "$LOG"

    if [[ ! -f "${MOUNT}/usr/bin/bash" ]]; then
        err "rsync failed — /usr/bin/bash missing on target"
        exit 1
    fi

    log "System copy complete"
}

do_cleanup_live() {
    log "Cleaning up live-ISO artifacts"

    # remove archiso-specific packages
    arch-chroot "$MOUNT" pacman -Rns --noconfirm mkinitcpio-archiso 2>> "$LOG" || true
    arch-chroot "$MOUNT" pacman -Rns --noconfirm arch-install-scripts 2>> "$LOG" || true

    # remove live-only files that slipped through
    rm -f "${MOUNT}/etc/systemd/system/systemd-firstboot.service" 2>/dev/null
    rm -rf "${MOUNT}/etc/systemd/system/systemd-firstboot.service.d" 2>/dev/null
    rm -f "${MOUNT}/etc/systemd/system/locale-gen.service" 2>/dev/null
    rm -f "${MOUNT}/usr/local/bin/mulch-taskbar-setup" 2>/dev/null
    rm -rf "${MOUNT}/etc/sddm.conf.d" 2>/dev/null

    # remove steam autostart from skel (Steam should be launched manually)
    rm -f "${MOUNT}/etc/skel/.config/autostart/steam.desktop" 2>/dev/null
    rm -f "${MOUNT}/etc/skel/.config/autostart/steam-cleanup.desktop" 2>/dev/null

    # clear machine-id so systemd generates a new one on first boot
    echo "" > "${MOUNT}/etc/machine-id"

    # clear ALL stale pacman sync databases — the installed system must do a
    # fresh sync on first boot since the ISO databases are from build time
    rm -rf "${MOUNT}/var/lib/pacman/sync/"*.db 2>/dev/null
    rm -rf "${MOUNT}/var/lib/pacman/sync/"*.files 2>/dev/null

    # clean logs and cache
    rm -rf "${MOUNT}/var/log/"* 2>/dev/null
    rm -rf "${MOUNT}/var/cache/pacman/pkg/"* 2>/dev/null

    # remove live user
    arch-chroot "$MOUNT" userdel -r live 2>> "$LOG" || true
    rm -rf "${MOUNT}/home/live" 2>/dev/null
    rm -f "${MOUNT}/etc/sudoers.d/live" 2>/dev/null
    
    # restore clean passwd/shadow/group (installer will recreate properly)
    sed -i '/^live:/d' "${MOUNT}/etc/passwd"
    sed -i '/^live:/d' "${MOUNT}/etc/shadow"  
    sed -i '/^live:/d' "${MOUNT}/etc/group"
    sed -i 's/,live//g' "${MOUNT}/etc/group"

    log "Live artifacts cleaned"
}

do_handle_kernel() {
    log "Handling kernel selection: ${SEL_KERNEL}"

    if [[ "$SEL_KERNEL" == "linux-zen" ]]; then
        # already installed in the live system, nothing to do
        log "linux-zen already installed"
        return
    fi

    # need to install alternate kernel from the kernel repo
    if [[ ! -d "$KERNEL_REPO" ]]; then
        log "WARNING: Kernel repo not found at ${KERNEL_REPO}, keeping linux-zen"
        warn "Alternate kernel repo not found. Keeping linux-zen."
        SEL_KERNEL="linux-zen"
        return
    fi

    local kernel_headers="${SEL_KERNEL}-headers"

    # create temp pacman config pointing to kernel repo
    cat > "${MOUNT}/tmp/pacman-kernel.conf" <<KERNCONF
[options]
Architecture = x86_64
SigLevel = Never

[kernels]
SigLevel = Never
Server = file:///opt/kernel-repo
KERNCONF

    # copy kernel repo into chroot
    mkdir -p "${MOUNT}/opt/kernel-repo"
    cp "$KERNEL_REPO"/* "${MOUNT}/opt/kernel-repo/" 2>/dev/null || true

    # install the chosen kernel
    msg "  Installing ${SEL_KERNEL}…"
    if arch-chroot "$MOUNT" pacman --config /tmp/pacman-kernel.conf \
        -Sy --noconfirm "$SEL_KERNEL" "$kernel_headers" >> "$LOG" 2>&1; then
        msg "  ✓ ${SEL_KERNEL} installed"
    else
        warn "Failed to install ${SEL_KERNEL}. Keeping linux-zen."
        SEL_KERNEL="linux-zen"
    fi

    # cleanup
    rm -rf "${MOUNT}/opt/kernel-repo"
    rm -f "${MOUNT}/tmp/pacman-kernel.conf"

    log "Kernel handling complete: using ${SEL_KERNEL}"
}

do_fstab() {
    log "Generating fstab"
    genfstab -U "$MOUNT" >> "${MOUNT}/etc/fstab"
}

do_configure() {
    log "Configuring system"

    if ! arch-chroot "$MOUNT" /bin/true >> "$LOG" 2>&1; then
        err "arch-chroot failed"
        exit 1
    fi

    # timezone
    arch-chroot "$MOUNT" ln -sf "/usr/share/zoneinfo/${SEL_TIMEZONE}" /etc/localtime
    arch-chroot "$MOUNT" hwclock --systohc

    # locale
    # write locale.gen fresh (rsync'd version may be wrong)
    echo "${SEL_LOCALE} UTF-8" > "${MOUNT}/etc/locale.gen"
    echo "en_US.UTF-8 UTF-8" >> "${MOUNT}/etc/locale.gen"
    
    # remove stale locale archive so locale-gen rebuilds it
    rm -f "${MOUNT}/usr/lib/locale/locale-archive" 2>/dev/null
    
    arch-chroot "$MOUNT" locale-gen >> "$LOG" 2>&1
    echo "LANG=${SEL_LOCALE}" > "${MOUNT}/etc/locale.conf"

    # keymap + console font
    echo "KEYMAP=${SEL_KEYMAP}" > "${MOUNT}/etc/vconsole.conf"
    echo "FONT=ter-v16b" >> "${MOUNT}/etc/vconsole.conf"

    # hostname
    echo "$SEL_HOSTNAME" > "${MOUNT}/etc/hostname"
    cat > "${MOUNT}/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${SEL_HOSTNAME}.localdomain ${SEL_HOSTNAME}
EOF

    # os-release
    cat > "${MOUNT}/etc/os-release" <<'OSREL'
NAME="Mulch Linux"
PRETTY_NAME="Mulch Linux"
ID=mulch
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="0;35"
HOME_URL="https://mulchlinux.org"
LOGO=mulch
OSREL

    # pacman.conf with real repos
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

    # mirrorlist
    cat > "${MOUNT}/etc/pacman.d/mirrorlist" <<'MIRRORLIST'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://mirror.leaseweb.net/archlinux/$repo/os/$arch
Server = https://archlinux.mirror.liteserver.nl/$repo/os/$arch
Server = https://mirror.f4st.host/archlinux/$repo/os/$arch
MIRRORLIST

    # mkinitcpio
    local hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
    fi

    cat > "${MOUNT}/etc/mkinitcpio.conf" <<MKINIT
MODULES=()
BINARIES=()
FILES=()
HOOKS=(${hooks})
MKINIT

    if [[ "$SEL_GPU" == "nvidia" ]]; then
        sed -i 's/^MODULES=(.*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
            "${MOUNT}/etc/mkinitcpio.conf"
    fi

    # users
    echo "root:${SEL_ROOT_PASS}" | arch-chroot "$MOUNT" chpasswd
    arch-chroot "$MOUNT" useradd -m -G wheel,video,audio,input,gamemode \
        -s /bin/bash "$SEL_USERNAME"
    echo "${SEL_USERNAME}:${SEL_USER_PASS}" | arch-chroot "$MOUNT" chpasswd
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        "${MOUNT}/etc/sudoers"

    # services
    arch-chroot "$MOUNT" systemctl enable sddm          >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable NetworkManager >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable bluetooth      >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable fstrim.timer   >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable ufw            >> "$LOG" 2>&1
	
    # initialize pacman keyring — delete the stale live-ISO keyring first,
    # then create a fresh one so the installed system can verify packages
    rm -rf "${MOUNT}/etc/pacman.d/gnupg" 2>/dev/null || true
    arch-chroot "$MOUNT" pacman-key --init >> "$LOG" 2>&1
    arch-chroot "$MOUNT" pacman-key --populate archlinux >> "$LOG" 2>&1
	
    # force enable mullvad daemon
    ln -sf /usr/lib/systemd/system/mullvad-daemon.service \
        "${MOUNT}/etc/systemd/system/multi-user.target.wants/mullvad-daemon.service" 2>/dev/null || true
    log "Mullvad daemon force-enabled"
	
	# verify mullvad daemon is enabled
    if [[ -f "${MOUNT}/usr/lib/systemd/system/mullvad-daemon.service" ]]; then
        arch-chroot "$MOUNT" systemctl enable mullvad-daemon >> "$LOG" 2>&1
        msg "  ✓ Mullvad daemon enabled"
    fi

    log "System configured successfully"
}

do_install_kernel() {
    log "Installing kernel to boot partition"

    # find the correct vmlinuz for the selected kernel
    case "$SEL_KERNEL" in
        linux-zen)
            local kdir=$(find "${MOUNT}/usr/lib/modules" -maxdepth 1 -name "*zen*" -type d | head -1)
            local kname="vmlinuz-linux-zen"
            ;;
        linux)
            local kdir=$(find "${MOUNT}/usr/lib/modules" -maxdepth 1 -name "*arch*" ! -name "*zen*" ! -name "*lts*" -type d | head -1)
            local kname="vmlinuz-linux"
            ;;
        linux-lts)
            local kdir=$(find "${MOUNT}/usr/lib/modules" -maxdepth 1 -name "*lts*" -type d | head -1)
            local kname="vmlinuz-linux-lts"
            ;;
    esac

    if [[ -n "$kdir" && -f "${kdir}/vmlinuz" ]]; then
        cp "${kdir}/vmlinuz" "${MOUNT}/boot/${kname}"
        msg "  ✓ Copied ${kname}"
    else
        warn "  ✗ Could not find vmlinuz for ${SEL_KERNEL}"
        log "Module dirs:"
        ls -la "${MOUNT}/usr/lib/modules/" >> "$LOG" 2>&1
    fi

    # microcode - copy from live ISO boot files (try multiple paths)
    local ucode_dirs=(
        "/run/archiso/bootmnt/arch/boot/x86_64"
        "/run/archiso/bootmnt/arch/boot"
        "/boot"
    )
    for ucode in amd-ucode.img intel-ucode.img; do
        if [[ -f "${MOUNT}/boot/${ucode}" ]]; then
            msg "  ✓ ${ucode} already present"
            continue
        fi
        for dir in "${ucode_dirs[@]}"; do
            if [[ -f "${dir}/${ucode}" ]]; then
                cp "${dir}/${ucode}" "${MOUNT}/boot/"
                msg "  ✓ Copied ${ucode}"
                break
            fi
        done
    done

    # generate initramfs
    msg "  Generating initramfs…"
    arch-chroot "$MOUNT" mkinitcpio -p "$SEL_KERNEL" >> "$LOG" 2>&1

    # verify
    log "Contents of ${MOUNT}/boot/:"
    ls -la "${MOUNT}/boot/" >> "$LOG" 2>&1

    if [[ -f "${MOUNT}/boot/${kname}" ]]; then
        msg "  ✓ Kernel in place"
    else
        warn "  ✗ Kernel missing from /boot"
    fi

    if ls "${MOUNT}/boot/initramfs-${SEL_KERNEL}"* &>/dev/null; then
        msg "  ✓ Initramfs generated"
    else
        warn "  ✗ Initramfs missing"
    fi

    log "Kernel installation complete"
}


do_bootloader() {
    log "Installing bootloader"

    # grub branding
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Mulch"/' "${MOUNT}/etc/default/grub"
    if ! grep -q '^GRUB_DISTRIBUTOR' "${MOUNT}/etc/default/grub"; then
        echo 'GRUB_DISTRIBUTOR="Mulch"' >> "${MOUNT}/etc/default/grub"
    fi

    cat >> "${MOUNT}/etc/default/grub" <<'GRUBEXTRA'
GRUB_COLOR_NORMAL="white/black"
GRUB_COLOR_HIGHLIGHT="magenta/black"
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
GRUB_DISABLE_OS_PROBER=false
GRUBEXTRA

    local grub_cmdline=""

    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        local phys_part p=""
        [[ "$SEL_DISK" == *nvme* || "$SEL_DISK" == *mmcblk* || "$SEL_DISK" == *loop* || "$SEL_DISK" == *nbd* ]] && p="p"
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

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet\"|" \
        "${MOUNT}/etc/default/grub"
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${grub_cmdline}\"|" \
        "${MOUNT}/etc/default/grub"

    if [[ $IS_UEFI -eq 1 ]]; then
        arch-chroot "$MOUNT" grub-install --target=x86_64-efi \
            --efi-directory=/boot --bootloader-id=GRUB >> "$LOG" 2>&1
    else
        arch-chroot "$MOUNT" grub-install --target=i386-pc "$SEL_DISK" >> "$LOG" 2>&1
    fi
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
    local config_src="/root/config"

    # ── editor defaults ──────────────────────────────────────────
    mkdir -p "${MOUNT}/etc/profile.d"
    cat > "${MOUNT}/etc/profile.d/custom-defaults.sh" <<'EOF'
export EDITOR=micro
export VISUAL=micro
export MICRO_TRUECOLOR=1
EOF

    # ── micro config ─────────────────────────────────────────────
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

    # ── KDE color schemes (system-wide) ──────────────────────────
    mkdir -p "${MOUNT}/usr/share/color-schemes"
    cp "${config_src}/color-schemes/"*.colors "${MOUNT}/usr/share/color-schemes/" 2>/dev/null || true

    # ── plasmoid widgets (system-wide) ───────────────────────────
    mkdir -p "${MOUNT}/usr/share/plasma/plasmoids"
    cp -r "${config_src}/plasma/plasmoids/org.magpie.dotted.separator" \
        "${MOUNT}/usr/share/plasma/plasmoids/" 2>/dev/null || true
    cp -r "${config_src}/plasma/plasmoids/weather.widget.plus" \
        "${MOUNT}/usr/share/plasma/plasmoids/" 2>/dev/null || true

    # ── plasma desktop theme (system-wide) ───────────────────────
    mkdir -p "${MOUNT}/usr/share/plasma/desktoptheme"
    cp -r "${config_src}/plasma/desktoptheme/We10XOS-dark" \
        "${MOUNT}/usr/share/plasma/desktoptheme/" 2>/dev/null || true

    # ── window decoration (system-wide) ──────────────────────────
    mkdir -p "${MOUNT}/usr/share/aurorae/themes"
    cp -r "${config_src}/aurorae/themes/Se7enAero" \
        "${MOUNT}/usr/share/aurorae/themes/" 2>/dev/null || true

    # ── icon theme (system-wide) ─────────────────────────────────
    mkdir -p "${MOUNT}/usr/share/icons"
    cp -r "${config_src}/icons/ExposeAir" "${MOUNT}/usr/share/icons/" 2>/dev/null || true

    # ── cursor theme (system-wide) ───────────────────────────────
    cp -r "${config_src}/cursors/Oxygen_Zion" "${MOUNT}/usr/share/icons/" 2>/dev/null || true
    # ── KDE globals (colors, theme, style) ───────────────────────
    mkdir -p "${home}/.config"
    cp "${config_src}/kdeglobals" "${home}/.config/kdeglobals" 2>/dev/null || true

    # ── kwin config (effects, tiling) ────────────────────────────
    cp "${config_src}/kwinrc" "${home}/.config/kwinrc" 2>/dev/null || true

    # ── plasma theme ─────────────────────────────────────────────
    cp "${config_src}/plasmarc" "${home}/.config/plasmarc" 2>/dev/null || true

    # ── konsole ──────────────────────────────────────────────────
    mkdir -p "${home}/.local/share/konsole"
    cp "${config_src}/konsole/Aritim Dark.colorscheme" "${home}/.local/share/konsole/" 2>/dev/null || true
    cp "${config_src}/konsole/Profile 1.profile" "${home}/.local/share/konsole/" 2>/dev/null || true
    cp "${config_src}/konsolerc" "${home}/.config/konsolerc" 2>/dev/null || true

    # ── dolphin ──────────────────────────────────────────────────
    cp "${config_src}/dolphinrc" "${home}/.config/dolphinrc" 2>/dev/null || true

    # ── disable KDE Wallet ───────────────────────────────────────
    cat > "${home}/.config/kwalletrc" <<'EOF'
[Wallet]
Enabled=false
First Use=false
EOF

    # ── disable mouse acceleration ───────────────────────────────
	cp "${config_src}/kcminputrc" "${home}/.config/kcminputrc" 2>/dev/null || true
	
    # ── configure yay (no diff prompts) ──────────────────────────
    mkdir -p "${home}/.config/yay"
    cat > "${home}/.config/yay/config.json" <<'EOF'
{
    "diffmenu": false,
    "cleanmenu": false,
    "removemake": "no",
    "provides": true,
    "pgpfetch": true,
    "cleanAfter": true
}
EOF

    # ── bashrc (yay overwrite alias) ─────────────────────────────
    cat > "${home}/.bashrc" <<'EOF'
# yay: always allow overwriting conflicting files during upgrades
alias yay='yay --overwrite "*"'
EOF

    # ── prevent Steam desktop shortcut ───────────────────────────
    mkdir -p "${home}/.local/share/Steam"
    mkdir -p "${home}/.config/autostart"
    
    # Steam checks this file to decide whether to create desktop shortcut
    touch "${home}/.local/share/Steam/.desktop-shortcut-created"

    # ── zathura config ───────────────────────────────────────────
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

    # ── mpv config ───────────────────────────────────────────────
    mkdir -p "${home}/.config/mpv"
    cat > "${home}/.config/mpv/mpv.conf" <<'EOF'
save-position-on-quit=yes
gpu-api=vulkan
gpu-context=waylandvk
hwdec=auto-copy
border=no
EOF


    # ── KeePassXC browser extension for Mullvad Browser ──────────
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

    local ext_dir="/root/target-configs/extensions"
    if [[ -f "${ext_dir}/keepassxc-browser@keepassxc.org.xpi" ]]; then
        cp "${ext_dir}/keepassxc-browser@keepassxc.org.xpi" "${mb_dist_dir}/extensions/"
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

    cp "${config_src}/plasmashellrc" "${home}/.config/plasmashellrc" 2>/dev/null || true

    # ── mullvad VPN tray ──────────────────────────────────────────
    cat > "${home}/.config/autostart/mullvad-vpn.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Mullvad VPN
Exec=mullvad-vpn
Icon=mullvad-vpn
X-KDE-autostart-phase=2
NoDisplay=true
EOF


    # ── welcome message (installed system only) ──────────────────
    cat > "${home}/.config/autostart/mulch-welcome.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Mulch Welcome
Exec=bash -c 'sleep 3 && /usr/local/bin/mulch-welcome'
X-KDE-autostart-phase=2
NoDisplay=true
EOF

    # ── file associations ────────────────────────────────────────
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

    # ── app state files (panel/toolbar visibility) ───────────────
    mkdir -p "${home}/.local/state"
    cp /etc/skel/.local/state/konsolestaterc "${home}/.local/state/" 2>/dev/null || true
    cp /etc/skel/.local/state/dolphinstaterc "${home}/.local/state/" 2>/dev/null || true

    # the welcome script is already in the ISO at /usr/local/bin/mulch-welcome
    # (deployed via profile/airootfs/usr/local/bin/mulch-welcome)
    # just ensure it's executable on the installed system
    chmod +x "${MOUNT}/usr/local/bin/mulch-welcome" 2>/dev/null || true

    # ── Mullvad GUI: start minimized to tray (must be last, read-only) ──
    mkdir -p "${home}/.config/Mullvad VPN"
    cat > "${home}/.config/Mullvad VPN/gui_settings.json" <<'EOF'
{"preferredLocale":"system","autoConnect":true,"enableSystemNotifications":true,"monochromaticIcon":false,"startMinimized":true,"unpinnedWindow":true,"browsedForSplitTunnelingApplications":[],"changelogDisplayedForVersion":"2026.1","updateDismissedForVersion":"","animateMap":true}
EOF

    # ── fix ownership ────────────────────────────────────────────
    arch-chroot "$MOUNT" chown -R "${SEL_USERNAME}:${SEL_USERNAME}" \
        "/home/${SEL_USERNAME}" >> "$LOG" 2>&1

    log "User configuration complete"
}

do_cleanup() {
    log "Final cleanup"

    # remove flatpak if present
    arch-chroot "$MOUNT" pacman -Rns --noconfirm flatpak 2>/dev/null || true

    # clear package cache
    rm -rf "${MOUNT}/var/cache/pacman/pkg/"* 2>/dev/null || true

    # remove ALL stale pacman sync databases — user's first `pacman -Sy` or `yay`
    # will fetch fresh ones from real mirrors (we can't sync here — offline install)
    rm -rf "${MOUNT}/var/lib/pacman/sync/"* 2>/dev/null || true

    # remove pacman database lock if it exists
    rm -f "${MOUNT}/var/lib/pacman/db.lck" 2>/dev/null || true

    # verify yay
    if [[ -f "${MOUNT}/usr/bin/yay" ]]; then
        msg "  ✓ yay available"
    else
        warn "  ✗ yay binary not found at /usr/bin/yay"
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

#  MAIN

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run as root."
        exit 1
    fi

    install -m 600 /dev/null "$LOG"
    log "Installer started"

    detect_uefi
    log "UEFI=$IS_UEFI"

    # ── TUI stages ───────────────────────────────────────────────
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

    # ── installation ─────────────────────────────────────────────
    clear
    echo ""
    echo "  Installing Mulch Linux…"
    echo ""
    echo ""

    echo -e "${O}  [5%]${N} Partitioning disk…"
    if ! do_partition >> "$LOG" 2>&1; then
        err "Partitioning failed. Check log: $LOG"
        exit 1
    fi

    echo -e "${O}  [10%]${N} Setting up encryption…"
    if ! do_encrypt >> "$LOG" 2>&1; then
        err "Encryption setup failed. Check log: $LOG"
        exit 1
    fi

    echo -e "${O}  [15%]${N} Formatting partitions…"
    if ! do_format >> "$LOG" 2>&1; then
        err "Formatting failed. Check log: $LOG"
        exit 1
    fi

    echo -e "${O}  [18%]${N} Mounting filesystems…"
    if ! do_mount >> "$LOG" 2>&1; then
        err "Mounting failed. Check log: $LOG"
        exit 1
    fi

    echo ""
    echo -e "${O}  [20%]${N} Copying system to disk (this takes 2-5 minutes)…"
    echo ""
    do_copy_system

    echo ""
    echo -e "${O}  [60%]${N} Cleaning live-ISO artifacts…"
    do_cleanup_live >> "$LOG" 2>&1

    echo -e "${O}  [65%]${N} Handling kernel selection…"
    do_handle_kernel >> "$LOG" 2>&1

    echo -e "${O}  [70%]${N} Generating fstab…"
    if ! do_fstab >> "$LOG" 2>&1; then
        err "fstab generation failed. Check log: $LOG"
        exit 1
    fi

    echo -e "${O}  [72%]${N} Configuring system…"
    if ! do_configure >> "$LOG" 2>&1; then
        err "Configuration failed. Check log."
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    echo -e "${O}  [78%]${N} Installing kernel to boot…"
    do_install_kernel

    echo -e "${O}  [82%]${N} Installing bootloader…"
    if ! do_bootloader >> "$LOG" 2>&1; then
        err "Bootloader installation failed. Check log."
        echo "Press Enter to view log."
        read -r
        less "$LOG"
        exit 1
    fi

    echo -e "${O}  [88%]${N} Applying gaming tweaks…"
    do_gaming_tweaks >> "$LOG" 2>&1

    echo -e "${O}  [93%]${N} Setting up user config…"
    do_user_config >> "$LOG" 2>&1

    echo -e "${O}  [97%]${N} Cleaning up…"
    do_cleanup >> "$LOG" 2>&1

    echo -e "${O}  [100%]${N} Done!"
    echo ""

    # check for real errors
    real_errors=$(grep -ciE "FATAL|ERROR:.*Failed to install|rsync failed" "$LOG" 2>/dev/null || true)
    real_errors=${real_errors:-0}
    real_errors=$((real_errors + 0))
    if [[ $real_errors -gt 0 ]]; then
        echo "  ⚠ ${real_errors} error(s) detected in log."
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
    echo "           Reboot computer when ready.                 "
    echo ""

    echo ""
    echo "  Press Enter to close the installer"
    read -r
}

main "$@"