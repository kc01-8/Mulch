#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="${SCRIPT_DIR}/profile"
WORK_DIR="${SCRIPT_DIR}/work"
OUT_DIR="${SCRIPT_DIR}/out"
AUR_REPO="${SCRIPT_DIR}/aur-repo"
CUSTOM_REPO="/tmp/mulch-custom-repo"

die() { echo "FATAL: $*" >&2; exit 1; }
msg() { echo "==> $*"; }
warn() { echo "==> WARNING: $*"; }

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
fi

msg "Syncing package databases…"
pacman -Sy

# ── set up custom repo (AUR packages) ───────────────────────────
msg "Setting up custom repo…"
rm -rf "$CUSTOM_REPO"
mkdir -p "$CUSTOM_REPO"

# copy AUR packages (skip debug)
find "$AUR_REPO" -name "*.pkg.tar.zst" ! -name "*-debug-*" -exec cp {} "$CUSTOM_REPO"/ \;

# download alternate kernels for installer choice
msg "Downloading alternate kernels…"
pacman -Sw --noconfirm --cachedir "$CUSTOM_REPO" \
    linux linux-headers \
    linux-lts linux-lts-headers 2>&1 | tail -5

# build repo database
msg "Building custom repo database…"
rm -f "$CUSTOM_REPO"/custom.db* "$CUSTOM_REPO"/custom.files*
repo-add "$CUSTOM_REPO/custom.db.tar.gz" "$CUSTOM_REPO"/*.pkg.tar.zst 2>/dev/null || true

# also add any .pkg.tar.xz files (kernels may be .xz)
find "$CUSTOM_REPO" -name "*.pkg.tar.xz" -exec repo-add "$CUSTOM_REPO/custom.db.tar.gz" {} \; 2>/dev/null || true

# fix symlinks
for f in "$CUSTOM_REPO"/custom.db "$CUSTOM_REPO"/custom.files; do
    if [[ -L "$f" ]]; then
        _target=$(readlink -f "$f")
        rm "$f"
        cp "$_target" "$f"
    fi
done

msg "Custom repo: $(find "$CUSTOM_REPO" -name '*.pkg.tar.*' ! -name '*.sig' | wc -l) packages"

# ── place alternate kernel repo inside ISO ───────────────────────
msg "Placing kernel repo in ISO tree…"
KERNEL_REPO="${PROFILE_DIR}/airootfs/opt/kernel-repo"
rm -rf "$KERNEL_REPO"
mkdir -p "$KERNEL_REPO"

# only copy kernel packages (not AUR — those are already installed via mkarchiso)
for kpkg in linux-[0-9]* linux-headers-[0-9]* linux-lts-[0-9]* linux-lts-headers-[0-9]*; do
    [[ -f "$CUSTOM_REPO/$kpkg" ]] && cp "$CUSTOM_REPO/$kpkg" "$KERNEL_REPO"/
done
# safer glob approach
find "$CUSTOM_REPO" -name "linux-[0-9]*.pkg.tar.*" -exec cp {} "$KERNEL_REPO"/ \;
find "$CUSTOM_REPO" -name "linux-headers-*.pkg.tar.*" -exec cp {} "$KERNEL_REPO"/ \;
find "$CUSTOM_REPO" -name "linux-lts-*.pkg.tar.*" -exec cp {} "$KERNEL_REPO"/ \;
find "$CUSTOM_REPO" -name "linux-lts-headers-*.pkg.tar.*" -exec cp {} "$KERNEL_REPO"/ \;

# build kernel repo database
repo-add "$KERNEL_REPO/kernels.db.tar.gz" "$KERNEL_REPO"/*.pkg.tar.* 2>/dev/null || true

for f in "$KERNEL_REPO"/kernels.db "$KERNEL_REPO"/kernels.files; do
    if [[ -L "$f" ]]; then
        _target=$(readlink -f "$f")
        rm "$f"
        cp "$_target" "$f"
    fi
done

msg "Kernel repo: $(find "$KERNEL_REPO" -name '*.pkg.tar.*' ! -name '*.sig' | wc -l) packages"

# ── remove old offline repo if it exists ─────────────────────────
rm -rf "${PROFILE_DIR}/airootfs/opt/offline-repo"

# ── build ISO ────────────────────────────────────────────────────
msg "Building ISO (this takes a while)…"
rm -rf "$WORK_DIR"
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

# cleanup
rm -rf "$CUSTOM_REPO"

msg "Done! ISO is in ${OUT_DIR}/"