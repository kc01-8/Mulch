#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="${SCRIPT_DIR}/profile"
WORK_DIR="${SCRIPT_DIR}/work"
OUT_DIR="${SCRIPT_DIR}/out"
AUR_REPO="${SCRIPT_DIR}/aur-repo"
PKG_CACHE="${SCRIPT_DIR}/pkg-cache"

die() { echo "FATAL: $*" >&2; exit 1; }
msg() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -d "$AUR_REPO" ]] || die "AUR repo not found. Run build-aur-repo.sh first."

if [[ ! -d "${PROFILE_DIR}/efiboot" ]]; then
    msg "Copying archiso releng skeleton…"
    cp -rn /usr/share/archiso/configs/releng/efiboot  "$PROFILE_DIR"/
    cp -rn /usr/share/archiso/configs/releng/grub      "$PROFILE_DIR"/ 2>/dev/null || true
    cp -rn /usr/share/archiso/configs/releng/syslinux  "$PROFILE_DIR"/ 2>/dev/null || true
fi

if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    msg "Enabling multilib on build host…"
    cat >> /etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    pacman -Sy
fi

msg "Downloading all packages for offline repo…"
mkdir -p "$PKG_CACHE"

mapfile -t PKGLIST < <(grep -v '^#\|^$' "${PROFILE_DIR}/packages.x86_64")

pacman -Syw --noconfirm --cachedir "$PKG_CACHE" "${PKGLIST[@]}" || true

msg "Merging AUR packages…"
cp -u "${AUR_REPO}"/*.pkg.tar.zst "$PKG_CACHE"/

msg "Building offline repo database…"
rm -f "${PKG_CACHE}"/offline.db* "${PKG_CACHE}"/offline.files*
repo-add "${PKG_CACHE}/offline.db.tar.gz" "${PKG_CACHE}"/*.pkg.tar.zst

ISO_REPO="${PROFILE_DIR}/airootfs/opt/offline-repo"
rm -rf "$ISO_REPO"
mkdir -p "$ISO_REPO"
ln -sf "$PKG_CACHE"/* "$ISO_REPO"/ 2>/dev/null \
    || cp -al "$PKG_CACHE"/* "$ISO_REPO"/

msg "Building ISO (this takes a while)…"
rm -rf "$WORK_DIR"
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

msg "Done! ISO is in ${OUT_DIR}/"
