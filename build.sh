#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="${SCRIPT_DIR}/profile"
WORK_DIR="${SCRIPT_DIR}/work"
OUT_DIR="${SCRIPT_DIR}/out"
AUR_REPO="${SCRIPT_DIR}/aur-repo"
PKG_CACHE="${SCRIPT_DIR}/pkg-cache"
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

# ── read package list ────────────────────────────────────────────
mapfile -t PKGLIST < <(grep -v '^#\|^$' "${PROFILE_DIR}/packages.x86_64")
EXTRA_PKGS=(intel-ucode amd-ucode)

# ── download official packages with empty db to get all deps ─────
msg "Downloading all official packages + dependencies…"
mkdir -p "$PKG_CACHE"

FAKE_DB="/tmp/pacman-fake-db"
rm -rf "$FAKE_DB"
mkdir -p "$FAKE_DB/local"

cat > /tmp/pacman-download.conf <<DLEOF
[options]
HoldPkg     = pacman glibc
Architecture = x86_64
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
DLEOF

pacman -Sy --config /tmp/pacman-download.conf --dbpath "$FAKE_DB" --noconfirm 2>&1 | tail -3

# filter to only official packages (skip AUR names)
AUR_NAMES=(yay-bin mullvad-vpn-bin mullvad-browser-bin tor-browser-bin obsidian-bin qimgv-git lazpaint-git)
OFFICIAL_PKGS=()
for pkg in "${PKGLIST[@]}" "${EXTRA_PKGS[@]}"; do
    skip=false
    for aur in "${AUR_NAMES[@]}"; do
        [[ "$pkg" == "$aur" ]] && skip=true && break
    done
    if [[ "$skip" == false ]]; then
        if pacman -Si "$pkg" --config /tmp/pacman-download.conf --dbpath "$FAKE_DB" &>/dev/null; then
            OFFICIAL_PKGS+=("$pkg")
        else
            warn "Package not in repos: ${pkg}"
        fi
    fi
done

msg "Downloading ${#OFFICIAL_PKGS[@]} official packages + all deps…"
pacman -Syw --noconfirm \
    --config /tmp/pacman-download.conf \
    --dbpath "$FAKE_DB" \
    --cachedir "$PKG_CACHE" \
    "${OFFICIAL_PKGS[@]}" 2>&1 | tail -10

rm -rf "$FAKE_DB" /tmp/pacman-download.conf

# ── download AUR package dependencies ────────────────────────────
msg "Downloading AUR package dependencies…"
for aurpkg in "$AUR_REPO"/*.pkg.tar.zst; do
    [[ -f "$aurpkg" ]] || continue
    [[ "$aurpkg" == *-debug-* ]] && continue

    pkgname=$(basename "$aurpkg" | sed 's/-[0-9].*//')

    deps=$(tar xf "$aurpkg" .PKGINFO -O 2>/dev/null \
        | grep "^depend = " \
        | sed 's/^depend = //' \
        | sed 's/[>=<].*//' \
        | sort -u) || true

    missing_deps=()
    for dep in $deps; do
        if find "$PKG_CACHE" -name "${dep}-[0-9]*.pkg.tar.*" ! -name "*.sig" 2>/dev/null | grep -q .; then
            continue
        fi
        if find "$AUR_REPO" -name "${dep}-[0-9]*.pkg.tar.*" 2>/dev/null | grep -q .; then
            continue
        fi
        if pacman -Si "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        msg "  ${pkgname}: downloading ${#missing_deps[@]} deps…"
        pacman -Syw --noconfirm --cachedir "$PKG_CACHE" "${missing_deps[@]}" >> /tmp/download.log 2>&1 || true
    fi
done

total_official=$(find "$PKG_CACHE" -name "*.pkg.tar.*" ! -name "*.sig" | wc -l)
total_aur=$(find "$AUR_REPO" -name "*.pkg.tar.*" ! -name "*.sig" | wc -l)
msg "Downloaded: ${total_official} official + ${total_aur} AUR = $((total_official + total_aur)) total"

# ── set up custom repo for mkarchiso (AUR packages) ─────────────
msg "Setting up custom repo for live ISO build…"
rm -rf "$CUSTOM_REPO"
mkdir -p "$CUSTOM_REPO"

# copy AUR packages (skip debug)
find "$AUR_REPO" -name "*.pkg.tar.zst" ! -name "*-debug-*" -exec cp {} "$CUSTOM_REPO"/ \;

# build repo database once
msg "Building custom repo database…"
rm -f "$CUSTOM_REPO"/custom.db* "$CUSTOM_REPO"/custom.files*
repo-add "$CUSTOM_REPO/custom.db.tar.gz" "$CUSTOM_REPO"/*.pkg.tar.zst 2>/dev/null

# replace symlinks with real files
for f in "$CUSTOM_REPO"/custom.db "$CUSTOM_REPO"/custom.files; do
    if [[ -L "$f" ]]; then
        _target=$(readlink -f "$f")
        rm "$f"
        cp "$_target" "$f"
    fi
done

msg "Custom repo: $(find "$CUSTOM_REPO" -name '*.pkg.tar.zst' | wc -l) packages"

# ── also prepare offline repo for the installer ──────────────────
ISO_REPO="${PROFILE_DIR}/airootfs/opt/offline-repo"
rm -rf "$ISO_REPO"
mkdir -p "$ISO_REPO"

msg "Copying all packages into offline repo for installer…"
find "$PKG_CACHE" -name "*.pkg.tar.*" ! -name "*.sig" -exec cp {} "$ISO_REPO"/ \;
find "$CUSTOM_REPO" -name "*.pkg.tar.zst" -exec cp {} "$ISO_REPO"/ \;

msg "Building offline repo database…"
find "$ISO_REPO" -name "*.pkg.tar.*" -print0 \
    | xargs -0 repo-add -q "$ISO_REPO/mulch.db.tar.gz" 2>/dev/null || true

for f in "$ISO_REPO"/mulch.db "$ISO_REPO"/mulch.files; do
    if [[ -L "$f" ]]; then
        _target=$(readlink -f "$f")
        rm "$f"
        cp "$_target" "$f"
    fi
done

pkg_in_repo=$(find "$ISO_REPO" -name "*.pkg.tar.*" ! -name "*.sig" | wc -l)
msg "Offline repo: ${pkg_in_repo} packages"

# ── build ISO ────────────────────────────────────────────────────
msg "Building ISO (this takes a while)…"
rm -rf "$WORK_DIR"
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

# cleanup
rm -rf "$CUSTOM_REPO"

msg "Done! ISO is in ${OUT_DIR}/"