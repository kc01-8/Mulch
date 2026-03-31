#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="${SCRIPT_DIR}/profile"
WORK_DIR="${SCRIPT_DIR}/work"
OUT_DIR="${SCRIPT_DIR}/out"
AUR_REPO="${SCRIPT_DIR}/aur-repo"
CUSTOM_REPO="/var/tmp/mulch-custom-repo"
BUILD_PACMAN_CONF="/var/tmp/mulch-build-pacman.conf"

die() { echo "FATAL: $*" >&2; exit 1; }
msg() { echo "==> $*"; }
warn() { echo "==> WARNING: $*"; }

cleanup() {
    msg "Cleaning up build artifacts…"
    rm -rf "$CUSTOM_REPO" "$BUILD_PACMAN_CONF"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -d "$AUR_REPO" ]] || die "AUR repo not found. Run build-aur-repo.sh first."

if [[ ! -d "${PROFILE_DIR}/efiboot" ]]; then
    msg "Copying archiso releng skeleton…"
    cp -rn /usr/share/archiso/configs/releng/efiboot  "$PROFILE_DIR"/
    cp -rn /usr/share/archiso/configs/releng/grub      "$PROFILE_DIR"/ 2>/dev/null || true
    cp -rn /usr/share/archiso/configs/releng/syslinux  "$PROFILE_DIR"/ 2>/dev/null || true
fi

# use a temporary pacman.conf with multilib instead of modifying the host
cp /etc/pacman.conf "$BUILD_PACMAN_CONF"
if ! grep -q '^\[multilib\]' "$BUILD_PACMAN_CONF"; then
    msg "Enabling multilib in build pacman.conf…"
    cat >> "$BUILD_PACMAN_CONF" <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
fi

msg "Syncing package databases…"
pacman --config "$BUILD_PACMAN_CONF" -Sy

# ── set up custom repo (AUR packages) ───────────────────────────
msg "Setting up custom repo…"
rm -rf "$CUSTOM_REPO"
mkdir -p "$CUSTOM_REPO"

# copy AUR packages (skip debug)
find "$AUR_REPO" -name "*.pkg.tar.zst" ! -name "*-debug-*" -exec cp {} "$CUSTOM_REPO"/ \;

# download alternate kernels for installer choice
msg "Downloading alternate kernels…"
pacman --config "$BUILD_PACMAN_CONF" -Sw --noconfirm --cachedir "$CUSTOM_REPO" \
    linux linux-headers \
    linux-lts linux-lts-headers 2>&1 | tail -5

# build repo database
msg "Building custom repo database…"
rm -f "$CUSTOM_REPO"/custom.db* "$CUSTOM_REPO"/custom.files*

if compgen -G "$CUSTOM_REPO"/*.pkg.tar.zst > /dev/null; then
    repo-add "$CUSTOM_REPO/custom.db.tar.gz" "$CUSTOM_REPO"/*.pkg.tar.zst
else
    warn "No .pkg.tar.zst files found in custom repo"
fi

# also add any .pkg.tar.xz files (kernels may be .xz)
find "$CUSTOM_REPO" -name "*.pkg.tar.xz" -exec repo-add "$CUSTOM_REPO/custom.db.tar.gz" {} + 2>/dev/null || true

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
find "$CUSTOM_REPO" \( \
    -name "linux-[0-9]*.pkg.tar.*" -o \
    -name "linux-headers-[0-9]*.pkg.tar.*" -o \
    -name "linux-lts-[0-9]*.pkg.tar.*" -o \
    -name "linux-lts-headers-[0-9]*.pkg.tar.*" \
    \) ! -name "*.sig" -exec cp {} "$KERNEL_REPO"/ \;

# build kernel repo database
if compgen -G "$KERNEL_REPO"/*.pkg.tar.* > /dev/null; then
    repo-add "$KERNEL_REPO/kernels.db.tar.gz" "$KERNEL_REPO"/*.pkg.tar.*
else
    warn "No kernel packages found for kernel repo"
fi

for f in "$KERNEL_REPO"/kernels.db "$KERNEL_REPO"/kernels.files; do
    if [[ -L "$f" ]]; then
        _target=$(readlink -f "$f")
        rm "$f"
        cp "$_target" "$f"
    fi
done

msg "Kernel repo: $(find "$KERNEL_REPO" -name '*.pkg.tar.*' ! -name '*.sig' | wc -l) packages"

# ── install KDE themes and widgets into live ISO ─────────────────
msg "Installing KDE configs into live ISO…"

# color schemes
mkdir -p "${PROFILE_DIR}/airootfs/usr/share/color-schemes"
cp "${SCRIPT_DIR}/config/color-schemes/"*.colors \
    "${PROFILE_DIR}/airootfs/usr/share/color-schemes/" || warn "No color schemes found"

# plasma desktop theme
mkdir -p "${PROFILE_DIR}/airootfs/usr/share/plasma/desktoptheme"
cp -r "${SCRIPT_DIR}/config/plasma/desktoptheme/We10XOS-dark" \
    "${PROFILE_DIR}/airootfs/usr/share/plasma/desktoptheme/" || warn "Plasma theme not found"

# plasmoid widgets
mkdir -p "${PROFILE_DIR}/airootfs/usr/share/plasma/plasmoids"
cp -r "${SCRIPT_DIR}/config/plasma/plasmoids/org.magpie.dotted.separator" \
    "${PROFILE_DIR}/airootfs/usr/share/plasma/plasmoids/" || warn "Separator widget not found"
cp -r "${SCRIPT_DIR}/config/plasma/plasmoids/weather.widget.plus" \
    "${PROFILE_DIR}/airootfs/usr/share/plasma/plasmoids/" || warn "Weather widget not found"

# window decoration
mkdir -p "${PROFILE_DIR}/airootfs/usr/share/aurorae/themes"
cp -r "${SCRIPT_DIR}/config/aurorae/themes/Se7enAero" \
    "${PROFILE_DIR}/airootfs/usr/share/aurorae/themes/" || warn "Aurorae theme not found"

# icon theme
mkdir -p "${PROFILE_DIR}/airootfs/usr/share/icons"
cp -r "${SCRIPT_DIR}/config/icons/ExposeAir" \
    "${PROFILE_DIR}/airootfs/usr/share/icons/" || warn "Icon theme not found"

# cursor theme
cp -r "${SCRIPT_DIR}/config/cursors/Oxygen_Zion" \
    "${PROFILE_DIR}/airootfs/usr/share/icons/" || warn "Cursor theme not found"
	
# ── copy config files into ISO tree ──────────────────────────────
msg "Copying config files into ISO tree…"
cp -r "${SCRIPT_DIR}/config" "${PROFILE_DIR}/airootfs/root/"

# ── sync config/ to skel/ so live user and installed user match ──
msg "Syncing config files to skel…"
SKEL_DIR="${PROFILE_DIR}/airootfs/etc/skel"
mkdir -p "${SKEL_DIR}/.config" "${SKEL_DIR}/.local/share/konsole"
for cfg in dolphinrc kdeglobals konsolerc kwinrc kcminputrc plasmashellrc plasmarc; do
    [[ -f "${SCRIPT_DIR}/config/${cfg}" ]] && \
        cp "${SCRIPT_DIR}/config/${cfg}" "${SKEL_DIR}/.config/${cfg}"
done
# konsole color scheme and profile
cp "${SCRIPT_DIR}/config/konsole/"*.colorscheme "${SKEL_DIR}/.local/share/konsole/" 2>/dev/null || true
cp "${SCRIPT_DIR}/config/konsole/"*.profile "${SKEL_DIR}/.local/share/konsole/" 2>/dev/null || true

# ── remove old offline repo if it exists ─────────────────────────
rm -rf "${PROFILE_DIR}/airootfs/opt/offline-repo"

# ── sync AUR packages into host pacman cache so mkarchiso finds them ──
# mkarchiso uses /var/cache/pacman/pkg/ — stale cached versions cause
# checksum mismatches against the freshly-built repo database
msg "Syncing custom repo packages to pacman cache…"
# force-overwrite: stale cached versions cause checksum mismatches with the fresh repo db
cp -f "$CUSTOM_REPO"/*.pkg.tar.* /var/cache/pacman/pkg/ 2>/dev/null || true

# ── build ISO ────────────────────────────────────────────────────
msg "Building ISO (this takes a while)…"
rm -rf "$WORK_DIR"
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

msg "Done! ISO is in ${OUT_DIR}/"