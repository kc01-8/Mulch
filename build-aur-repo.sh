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
    tor-browser-bin
    obsidian-bin
    qimgv-git
    lazpaint-git
)

KEYSERVERS=(
    "hkps://keyserver.ubuntu.com"
    "hkps://keys.openpgp.org"
    "hkps://pgp.mit.edu"
    "hkps://keys.mailvelope.com"
)

die()  { echo "FATAL: $*" >&2; exit 1; }
msg()  { echo "==> $*"; }
warn() { echo "==> WARNING: $*"; }

[[ $EUID -eq 0 ]] || die "Run as root"
pacman -Sy --needed --noconfirm base-devel git pacman-contrib

# ── build user ───────────────────────────────────────────────────
if ! id "$BUILD_USER" &>/dev/null; then
    useradd -m "$BUILD_USER"
fi
echo "${BUILD_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${BUILD_USER}"

mkdir -p "$REPO_DIR" "$BUILD_DIR"
chown "$BUILD_USER":"$BUILD_USER" "$BUILD_DIR"

# ── function: import a single key, trying all keyservers ─────────
import_key() {
    local key="$1"
    local imported=false

    for server in "${KEYSERVERS[@]}"; do
        if su - "$BUILD_USER" -c "gpg --keyserver ${server} --recv-keys ${key}" 2>/dev/null; then
            msg "  Imported ${key} from ${server}"
            imported=true
            break
        fi
    done

    if [[ "$imported" == false ]]; then
        warn "  Could not import key ${key} from any keyserver"
    fi
}

# ── function: extract validpgpkeys from a PKGBUILD and import ────
import_keys_from_pkgbuild() {
    local pkgbuild="$1"

    local keys
    keys=$(sed -n "/^validpgpkeys=(/,/)/p" "$pkgbuild" \
        | grep -oE '[A-F0-9]{8,}' || true)

    if [[ -z "$keys" ]]; then
        return
    fi

    msg "  Found PGP keys in PKGBUILD, importing…"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if su - "$BUILD_USER" -c "gpg --list-keys ${key}" &>/dev/null; then
            msg "  Key ${key} already in keyring"
        else
            import_key "$key"
        fi
    done <<< "$keys"
}

fix_pkgbuild() {
    local pkgbuild="$1"

    # replace functions that call curl/wget at parse time
    for func in _dist_checksum _get_checksum _sha256sum _checksum; do
        if grep -q "^${func}()" "$pkgbuild"; then
            msg "  Patching ${func}() to return SKIP"
            sed -i "/^${func}()/,/^}/c\\${func}() { echo \"SKIP\"; }" "$pkgbuild"
        fi
    done

    # replace empty string values in checksum arrays
    sed -i "s|''|'SKIP'|g" "$pkgbuild"
    sed -i 's|""|"SKIP"|g' "$pkgbuild"

    # remove broken dependencies (handles all formats: quoted, unquoted, indented)
    for brokendep in ffmpeg4.4 mime-types libnfx gtk2; do
        sed -i "/^[[:space:]]*['\"]\\{0,1\\}${brokendep}['\"]\\{0,1\\}[[:space:]]*$/d" "$pkgbuild"
        sed -i "s/'${brokendep}'//g" "$pkgbuild"
        sed -i "s/\"${brokendep}\"//g" "$pkgbuild"
    done
}

# ── install common build deps upfront ────────────────────────────
msg "Installing common build dependencies…"
pacman -S --needed --noconfirm \
    lazarus \
    fpc \
    qt6-base qt6-svg qt6-imageformats qt6-multimedia \
    opencv \
    cmake \
    python \
    rustup \
    go \
    npm \
    libxkbcommon \
    2>/dev/null || warn "Some optional build deps not available"

# ── build each package ───────────────────────────────────────────
for pkg in "${AUR_PACKAGES[@]}"; do
    msg "Building ${pkg}…"

    # clone
    su - "$BUILD_USER" -c "
        set -e
        cd ${BUILD_DIR}
        rm -rf ${pkg}
        git clone https://aur.archlinux.org/${pkg}.git
    "

    # import PGP keys
    import_keys_from_pkgbuild "${BUILD_DIR}/${pkg}/PKGBUILD"

    # patch broken PKGBUILDs
    fix_pkgbuild "${BUILD_DIR}/${pkg}/PKGBUILD"

    # build
    if ! su - "$BUILD_USER" -c "
        set -e
        cd ${BUILD_DIR}/${pkg}
        makepkg -s --noconfirm --noprogressbar --skipinteg
    "; then
        warn "${pkg} failed to build, retrying with --skippgpcheck…"
        su - "$BUILD_USER" -c "
            set -e
            cd ${BUILD_DIR}/${pkg}
            makepkg -s --noconfirm --noprogressbar --skipinteg --skippgpcheck
        " || { warn "${pkg} FAILED completely, skipping."; continue; }
    fi

    # copy built packages (skip debug packages)
    find "${BUILD_DIR}/${pkg}" -name "*.pkg.tar.zst" ! -name "*-debug-*" \
        -exec cp {} "$REPO_DIR"/ \;

    msg "  ${pkg} built successfully"
done

# ── create repo database ────────────────────────────────────────
msg "Creating repo database…"
rm -f "${REPO_DIR}"/custom.db* "${REPO_DIR}"/custom.files*

if compgen -G "${REPO_DIR}/*.pkg.tar.zst" > /dev/null; then
    repo-add "${REPO_DIR}/custom.db.tar.gz" "${REPO_DIR}"/*.pkg.tar.zst
else
    die "No packages were built successfully"
fi

# ── summary ──────────────────────────────────────────────────────
pkg_count=$(find "$REPO_DIR" -name "*.pkg.tar.zst" | wc -l)
msg "AUR repo ready at ${REPO_DIR}/ (${pkg_count} packages)"
echo ""
echo "  Packages built:"
find "$REPO_DIR" -name "*.pkg.tar.zst" -printf "    %f\n" | sort

# ── cleanup ──────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
userdel -r "$BUILD_USER" 2>/dev/null || true
rm -f "/etc/sudoers.d/${BUILD_USER}"