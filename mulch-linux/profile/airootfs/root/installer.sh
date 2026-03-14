#!/usr/bin/env bash
set -uo pipefail

INSTALLER_VERSION="1.0"
LOG="/tmp/installer.log"
MOUNT="/mnt"
OFFLINE_REPO="/opt/offline-repo"
TARGET_CONFIGS="/root/target-configs"
EXT_DIR="/root/target-configs/extensions"

SEL_KEYMAP="us"
SEL_DISK=""
SEL_ENCRYPT="no"
SEL_ENCRYPT_PASS=""
SEL_FS="btrfs"
SEL_SWAP="zram"
SEL_HOSTNAME="mulchlinux"
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

R='\033[0;31m'; G='\033[0;32m'; B='\033[0;34m'; Y='\033[1;33m'; N='\033[0m'
msg()  { echo -e "${G}==>${N} $*"; }
warn() { echo -e "${Y}==> WARNING:${N} $*"; }
err()  { echo -e "${R}==> ERROR:${N} $*"; }
log()  { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

detect_uefi() {
    [[ -d /sys/firmware/efi/efivars ]] && IS_UEFI=1 || IS_UEFI=0
}

detect_gpu() {
    local gpu
    if lspci 2>/dev/null | grep -qi 'nvidia'; then
        gpu="nvidia"
    elif lspci 2>/dev/null | grep -qiE 'amd.*(radeon|rx|vega|navi|graphics)|ati'; then
        gpu="amd"
    elif lspci 2>/dev/null | grep -qiE 'intel.*(graphics|uhd|iris|xe)'; then
        gpu="intel"
    else
        gpu="none"
    fi
    echo "$gpu"
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
 • KDE Plasma (minimal)
 • Privacy tools (Mullvad, KeePassXC, Tor Browser)
 • Media & productivity apps
 • Full gaming support (native Steam)

All packages are on this ISO — no internet required.

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
        btrfs "Btrfs (windows compatible, snapshots)" \
        ext4  "ext4 (ideal, stable - recommended)" \
    ) || SEL_FS="btrfs"
}

stage_swap() {
    SEL_SWAP=$(_menu "Swap" "Select swap method:" 14 55 4 \
        zram      "zram (compressed RAM swap — recommended)" \
        partition "Swap partition (RAM-sized)" \
        none      "No swap" \
    ) || SEL_SWAP="zram"
}

stage_hostname() {
    SEL_HOSTNAME=$(_inputbox "Hostname" "Enter hostname:" 10 50 "mulchlinux") \
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
        btrfs) mkfs.btrfs -f "$PART_ROOT" >> "$LOG" 2>&1 ;;
        ext4)  mkfs.ext4 -F "$PART_ROOT"  >> "$LOG" 2>&1 ;;
    esac
}

do_mount() {
    log "Mounting filesystems"
    if [[ "$SEL_FS" == "btrfs" ]]; then
        mount "$PART_ROOT" "$MOUNT" >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@"      >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@home"  >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@log"   >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@cache" >> "$LOG" 2>&1
        btrfs subvolume create "${MOUNT}/@tmp"   >> "$LOG" 2>&1
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
}

setup_offline_pacman() {
    log "Configuring offline pacman"
    cat > /tmp/pacman-offline.conf <<EOF
[options]
HoldPkg     = pacman glibc
Architecture = x86_64
SigLevel    = Never
ParallelDownloads = 5

[offline]
SigLevel = Never
Server = file://${OFFLINE_REPO}
EOF
}

do_pacstrap() {
    log "Installing base system (pacstrap)"
    setup_offline_pacman

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
        unzip unrar p7zip rsync tmux dialog
    )

    [[ -n "$cpu_ucode" ]] && pkgs+=("$cpu_ucode")

    case "$SEL_GPU" in
        nvidia)
            pkgs+=(
                nvidia-dkms nvidia-utils lib32-nvidia-utils
                nvidia-settings opencl-nvidia lib32-opencl-nvidia
            )
            ;;
        amd)
            pkgs+=(
                mesa lib32-mesa
                vulkan-radeon lib32-vulkan-radeon
                libva-mesa-driver lib32-libva-mesa-driver
                mesa-vdpau lib32-mesa-vdpau xf86-video-amdgpu
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
        xdg-desktop-portal-kde kwallet-pam polkit-kde-agent
    )

    pkgs+=(
        micro
        mpv strawberry qbittorrent keepassxc
        zathura zathura-pdf-mupdf
    )

    pkgs+=(
        steam
        wine-staging wine-mono wine-gecko winetricks
        gamemode lib32-gamemode
        vkd3d lib32-vkd3d
        lib32-gst-plugins-base lib32-gst-plugins-good
        lib32-libpulse lib32-openal
        lib32-libxcomposite lib32-libxinerama
        lib32-sdl2 lib32-libgcrypt lib32-gnutls
        lib32-libxslt lib32-libva lib32-gtk3
        lib32-libcups lib32-ocl-icd
    )

    pkgs+=(
        ttf-liberation lib32-fontconfig
        noto-fonts noto-fonts-cjk noto-fonts-emoji
    )

    pkgs+=(
        yay-bin
        mullvad-vpn-bin mullvad-browser-bin
        tor-browser obsidian-bin signal-desktop-bin
        qimgv-git lazpaint
    )

    pacstrap -C /tmp/pacman-offline.conf "$MOUNT" "${pkgs[@]}" >> "$LOG" 2>&1
}

do_fstab() {
    log "Generating fstab"
    genfstab -U "$MOUNT" >> "${MOUNT}/etc/fstab"
}

do_configure() {
    log "Configuring system"

    arch-chroot "$MOUNT" ln -sf "/usr/share/zoneinfo/${SEL_TIMEZONE}" /etc/localtime
    arch-chroot "$MOUNT" hwclock --systohc

    sed -i "s/^#${SEL_LOCALE}/${SEL_LOCALE}/" "${MOUNT}/etc/locale.gen"
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' "${MOUNT}/etc/locale.gen"
    arch-chroot "$MOUNT" locale-gen
    echo "LANG=${SEL_LOCALE}" > "${MOUNT}/etc/locale.conf"

    echo "KEYMAP=${SEL_KEYMAP}" > "${MOUNT}/etc/vconsole.conf"

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

    local hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck"
    fi
    sed -i "s|^HOOKS=.*|HOOKS=(${hooks})|" "${MOUNT}/etc/mkinitcpio.conf"

    if [[ "$SEL_GPU" == "nvidia" ]]; then
        sed -i 's/^MODULES=(.*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
            "${MOUNT}/etc/mkinitcpio.conf"
    fi

    arch-chroot "$MOUNT" mkinitcpio -P >> "$LOG" 2>&1

    echo "root:${SEL_ROOT_PASS}" | arch-chroot "$MOUNT" chpasswd
    arch-chroot "$MOUNT" useradd -m -G wheel,video,audio,input,gamemode \
        -s /bin/bash "$SEL_USERNAME"
    echo "${SEL_USERNAME}:${SEL_USER_PASS}" | arch-chroot "$MOUNT" chpasswd
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
        "${MOUNT}/etc/sudoers"

    arch-chroot "$MOUNT" systemctl enable sddm           >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable NetworkManager  >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable bluetooth       >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable fstrim.timer    >> "$LOG" 2>&1
    arch-chroot "$MOUNT" systemctl enable ufw             >> "$LOG" 2>&1

    if [[ -f "${MOUNT}/usr/lib/systemd/system/mullvad-daemon.service" ]]; then
        arch-chroot "$MOUNT" systemctl enable mullvad-daemon >> "$LOG" 2>&1
    fi
}

do_bootloader() {
    log "Installing bootloader"

    local root_dev="$PART_ROOT"
    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        local phys_part
        local p=""
        [[ "$SEL_DISK" == *nvme* || "$SEL_DISK" == *mmcblk* ]] && p="p"
        case "$SEL_SWAP" in
            partition) phys_part="${SEL_DISK}${p}3" ;;
            *)         phys_part="${SEL_DISK}${p}2" ;;
        esac
        local luks_uuid
        luks_uuid=$(blkid -s UUID -o value "$phys_part")
        root_dev="/dev/mapper/${LUKS_NAME}"
    fi

    local grub_cmdline=""
    if [[ "$SEL_ENCRYPT" == "yes" ]]; then
        grub_cmdline="cryptdevice=UUID=${luks_uuid}:${LUKS_NAME} root=${root_dev}"
    fi

    if [[ "$SEL_GPU" == "nvidia" ]]; then
        grub_cmdline+=" nvidia_drm.modeset=1"
    fi

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet ${grub_cmdline}\"|" \
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
        arch-chroot "$MOUNT" systemctl enable nvidia-suspend   >> "$LOG" 2>&1 || true
        arch-chroot "$MOUNT" systemctl enable nvidia-resume    >> "$LOG" 2>&1 || true
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
}

do_user_config() {
    log "Setting up user configuration"
    local home="${MOUNT}/home/${SEL_USERNAME}"

    mkdir -p "${MOUNT}/etc/profile.d"
    cat > "${MOUNT}/etc/profile.d/mulch-defaults.sh" <<'EOF'
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

    local mb_dist_dir=""
    local mb_ext_dir=""

    for candidate in \
        "${MOUNT}/usr/lib/mullvad-browser" \
        "${MOUNT}/opt/mullvad-browser" \
        "${MOUNT}/usr/share/mullvad-browser"; do
        if [[ -d "$candidate" ]]; then
            mb_dist_dir="${candidate}/distribution"
            mb_ext_dir="${mb_dist_dir}/extensions"
            break
        fi
    done

    if [[ -z "$mb_dist_dir" ]]; then
        mb_dist_dir="${MOUNT}/usr/lib/mullvad-browser/distribution"
        mb_ext_dir="${mb_dist_dir}/extensions"
    fi

    mkdir -p "$mb_ext_dir"

    if [[ -f "${EXT_DIR}/keepassxc-browser@keepassxc.org.xpi" ]]; then
        cp "${EXT_DIR}/keepassxc-browser@keepassxc.org.xpi" "$mb_ext_dir"/
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

    arch-chroot "$MOUNT" chown -R "${SEL_USERNAME}:${SEL_USERNAME}" \
        "/home/${SEL_USERNAME}" >> "$LOG" 2>&1
}

do_cleanup() {
    log "Final cleanup"

    arch-chroot "$MOUNT" pacman -Rns --noconfirm flatpak 2>/dev/null || true
    arch-chroot "$MOUNT" pacman -Rns --noconfirm xdg-desktop-portal-gnome 2>/dev/null || true
    arch-chroot "$MOUNT" pacman -Scc --noconfirm >> "$LOG" 2>&1 || true
    arch-chroot "$MOUNT" bash -c \
        "su - ${SEL_USERNAME} -c 'yay --version'" >> "$LOG" 2>&1 || true

    sync
}

do_unmount() {
    log "Unmounting"
    [[ -n "${PART_SWAP:-}" ]] && swapoff "$PART_SWAP" 2>/dev/null || true
    umount -R "$MOUNT" 2>/dev/null || true
    [[ "$SEL_ENCRYPT" == "yes" ]] && cryptsetup close "$LUKS_NAME" 2>/dev/null || true
}

stage_finish() {
    _msgbox "Installation Complete" \
"Mulch Linux has been installed successfully!

You may now reboot into your new system.

Default editor:  micro
Steam will autostart on login.

Username: ${SEL_USERNAME}
Hostname: ${SEL_HOSTNAME}

Enjoy!" 18 55

    do_unmount
    clear
    echo ""
    echo "  Installation complete.  Type 'reboot' when ready."
    echo ""
}

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run as root."
        exit 1
    fi

    : > "$LOG"
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

    (
        echo "XXX"; echo 5;  echo "Partitioning disk...";        echo "XXX"
        do_partition >> "$LOG" 2>&1

        echo "XXX"; echo 10; echo "Setting up encryption...";    echo "XXX"
        do_encrypt >> "$LOG" 2>&1

        echo "XXX"; echo 15; echo "Formatting partitions...";    echo "XXX"
        do_format >> "$LOG" 2>&1

        echo "XXX"; echo 18; echo "Mounting filesystems...";     echo "XXX"
        do_mount >> "$LOG" 2>&1

        echo "XXX"; echo 20; echo "Installing packages (this takes a while)..."; echo "XXX"
        do_pacstrap >> "$LOG" 2>&1

        echo "XXX"; echo 70; echo "Generating fstab...";         echo "XXX"
        do_fstab >> "$LOG" 2>&1

        echo "XXX"; echo 72; echo "Configuring system...";       echo "XXX"
        do_configure >> "$LOG" 2>&1

        echo "XXX"; echo 82; echo "Installing bootloader...";    echo "XXX"
        do_bootloader >> "$LOG" 2>&1

        echo "XXX"; echo 88; echo "Applying gaming tweaks...";   echo "XXX"
        do_gaming_tweaks >> "$LOG" 2>&1

        echo "XXX"; echo 93; echo "Setting up user config...";   echo "XXX"
        do_user_config >> "$LOG" 2>&1

        echo "XXX"; echo 97; echo "Cleaning up...";              echo "XXX"
        do_cleanup >> "$LOG" 2>&1

        echo "XXX"; echo 100; echo "Done!";                      echo "XXX"
        sleep 1
    ) | dialog --backtitle "$BACKTITLE" --title "Installing" --gauge "" 8 70 0

    if grep -qi "error\|fatal\|failed" "$LOG" 2>/dev/null; then
        _yesno "Warnings" \
            "Some warnings/errors were logged.\nView the log?" 8 50 \
            && dialog --backtitle "$BACKTITLE" --title "Install Log" \
                --textbox "$LOG" 25 78
    fi

    stage_finish
}

main "$@"
