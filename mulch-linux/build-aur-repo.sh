#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/aur-repo"
BUILD_DIR="/tmp/aur-build"
BUILD_USER="aurbuilder"

AUR_PACKAGES=(
    yay-bin
    mullvad-vpn-bin
    mullvad-browser-bin
    tor-browser
    obsidian-bin
    signal-desktop-bin
    qimgv-git
    lazpaint
)

die() { echo "FATAL: $*" >&2; exit 1; }
msg() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "Run as root"
pacman -Sy --needed --noconfirm base-devel git

if ! id "$BUILD_USER" &>/dev/null; then
    useradd -m "$BUILD_USER"
    echo "${BUILD_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${BUILD_USER}"
fi

mkdir -p "$REPO_DIR" "$BUILD_DIR"
chown "$BUILD_USER":"$BUILD_USER" "$BUILD_DIR"

for pkg in "${AUR_PACKAGES[@]}"; do
    msg "Building ${pkg}…"
    su - "$BUILD_USER" -c "
        set -e
        cd ${BUILD_DIR}
        rm -rf ${pkg}
        git clone https://aur.archlinux.org/${pkg}.git
        cd ${pkg}
        makepkg -s --noconfirm --noprogressbar
    "
    cp "${BUILD_DIR}/${pkg}"/*.pkg.tar.zst "$REPO_DIR"/
done

msg "Creating repo database…"
repo-add "${REPO_DIR}/custom.db.tar.gz" "${REPO_DIR}"/*.pkg.tar.zst

rm -rf "$BUILD_DIR"
userdel -r "$BUILD_USER" 2>/dev/null || true
rm -f "/etc/sudoers.d/${BUILD_USER}"

msg "AUR repo ready at ${REPO_DIR}/"
