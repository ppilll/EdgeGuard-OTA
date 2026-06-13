#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# EdgeGuard OTA E3 - Buildroot rootfs build
#
# Responsibilities:
#   1. Force the correct BR2_ROOTFS_OVERLAY into the project defconfig.
#   2. Restore the Buildroot defconfig.
#   3. Force the overlay path into the effective OUT/.config again.
#   4. Verify this is still a rootfs-only build.
#   5. Verify target RAUC is enabled.
#   6. Verify the E3 version and optional RAUC runtime configuration.
#   7. Build target RAUC first for easier error isolation.
#   8. Build the complete rootfs.
#   9. Verify target files and rootfs.tar contents.
#
# This script does not run menuconfig.
# It intentionally manages BR2_ROOTFS_OVERLAY itself because menuconfig input
# may corrupt the UTF-8 project path.
###############################################################################

DEFAULT_PROJECT="$HOME/work/EdgeGuard_OTA"

PROJECT="${PROJECT:-$DEFAULT_PROJECT}"
PROJECT="$(readlink -f "$PROJECT")"

BR="${BR:-$PROJECT/external/buildroot}"
BR="$(readlink -f "$BR")"

OUT="${OUT:-$PROJECT/output/edgeguard-imx6ull}"
DEF="${DEF:-$PROJECT/configs/buildroot_defconfig}"

OVERLAY="${OVERLAY:-$PROJECT/board/edgeguard-imx6ull/overlay}"
OVERLAY="$(readlink -f "$OVERLAY")"

VERSION_FILE="$OVERLAY/etc/edgeguard_version"
RAUC_SYSTEM_CONF="$OVERLAY/etc/rauc/system.conf"
RAUC_KEYRING="$OVERLAY/etc/rauc/keyring.pem"

EXPECTED_VERSION="${EXPECTED_VERSION:-0.3.0-e3}"
JOBS="${JOBS:-$(nproc)}"

LOG_DIR="${LOG_DIR:-$PROJECT/reports/logs}"
BR2_DL_DIR="${BR2_DL_DIR:-$HOME/buildroot-dl}"

# 1: Require system.conf/keyring in the final rootfs.
# 0: Only verify that the RAUC executable can be built.
REQUIRE_RAUC_CONFIG="${REQUIRE_RAUC_CONFIG:-1}"

# Host RAUC is useful for bundle creation but is not strictly required
# to build the target rootfs.
REQUIRE_HOST_RAUC="${REQUIRE_HOST_RAUC:-0}"

# Build target RAUC separately before the complete Buildroot build.
BUILD_RAUC_FIRST="${BUILD_RAUC_FIRST:-1}"

# Force the correct overlay path into both the saved defconfig and .config.
FORCE_OVERLAY="${FORCE_OVERLAY:-1}"

export BR2_DL_DIR

mkdir -p "$OUT" "$LOG_DIR" "$BR2_DL_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
LOG="$LOG_DIR/E3_build_rootfs_${TS}.log"

# Log all output while preserving pipeline exit codes.
exec > >(tee -a "$LOG") 2>&1

on_error() {
    local rc=$?

    echo
    echo "ERROR: E3 rootfs build failed."
    echo "  Exit code : $rc"
    echo "  Line      : ${BASH_LINENO[0]:-unknown}"
    echo "  Command   : ${BASH_COMMAND:-unknown}"
    echo "  Log       : $LOG"

    exit "$rc"
}

trap on_error ERR

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

###############################################################################
# Select and enforce a valid UTF-8 locale.
#
# The Buildroot output path contains non-ASCII characters. host-python3 runs
# Python with "-E", so PYTHONUTF8/PYTHONIOENCODING cannot be relied upon.
# LANG and LC_ALL must provide a real UTF-8 locale.
###############################################################################

select_utf8_locale() {
    local candidate
    local actual

    for candidate in \
        C.UTF-8 \
        C.utf8 \
        en_US.UTF-8 \
        en_US.utf8 \
        zh_CN.UTF-8 \
        zh_CN.utf8
    do
        actual="$(
            locale -a 2>/dev/null |
                grep -Fxi "$candidate" |
                head -n 1 ||
                true
        )"

        if [ -n "$actual" ]; then
            printf '%s\n' "$actual"
            return 0
        fi
    done

    return 1
}

if [ -z "${BUILD_LOCALE:-}" ]; then
    BUILD_LOCALE="$(select_utf8_locale || true)"
fi

if [ -z "$BUILD_LOCALE" ]; then
    echo "Available locales:"
    locale -a || true

    die "no usable UTF-8 locale was found"
fi

export LANG="$BUILD_LOCALE"
export LC_ALL="$BUILD_LOCALE"
unset LANGUAGE

LOCALE_CHARMAP="$(
    locale charmap 2>/dev/null |
        tr '[:lower:]' '[:upper:]'
)"

if [ "$LOCALE_CHARMAP" != "UTF-8" ]; then
    echo "Selected locale : $BUILD_LOCALE"
    echo "Locale charmap  : $LOCALE_CHARMAP"

    die "selected build locale is not UTF-8"
fi

echo
echo "[PASS] UTF-8 build locale configured."
echo "BUILD_LOCALE         = $BUILD_LOCALE"
echo "LANG                 = $LANG"
echo "LC_ALL               = $LC_ALL"
echo "locale charmap       = $LOCALE_CHARMAP"

python3 - <<'PY'
import locale
import os
import sys

print("Host system Python encoding check:")
print(f"  filesystem encoding = {sys.getfilesystemencoding()}")
print(f"  stdout encoding     = {sys.stdout.encoding}")
print(f"  preferred encoding  = {locale.getpreferredencoding(False)}")
print(f"  cwd                 = {os.getcwd()}")

if sys.getfilesystemencoding().lower().replace("-", "") != "utf8":
    raise SystemExit("ERROR: system Python filesystem encoding is not UTF-8")
PY

config_is_y() {
    local key="$1"

    grep -qx "${key}=y" "$OUT/.config"
}

show_config_value() {
    local key="$1"

    grep -E "^${key}=|^# ${key} is not set$" \
        "$OUT/.config" || true
}

read_kconfig_string() {
    local file="$1"
    local key="$2"

    sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "$file" |
        head -n 1
}

###############################################################################
# Safely set a Kconfig string in a defconfig or .config file.
#
# This avoids using a simple sed replacement, which can be fragile when a
# value contains '/', '&', UTF-8 characters or other special characters.
###############################################################################

set_kconfig_string_file() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp

    [ -f "$file" ] ||
        die "cannot patch missing configuration file: $file"

    case "$value" in
        *$'\n'*)
            die "Kconfig string contains a newline: $key"
            ;;
        *'"'*)
            die "Kconfig string contains a double quote: $key=$value"
            ;;
    esac

    # Buildroot treats BR2_ROOTFS_OVERLAY as a space-separated list.
    # The current project path must therefore not contain spaces.
    case "$value" in
        *" "*)
            die "overlay path contains spaces, which is unsupported here: $value"
            ;;
    esac

    tmp="$(mktemp)"

    awk \
        -v key="$key" \
        -v value="$value" '
        BEGIN {
            written = 0
        }

        $0 == "# " key " is not set" {
            if (!written) {
                print key "=\"" value "\""
                written = 1
            }
            next
        }

        index($0, key "=") == 1 {
            if (!written) {
                print key "=\"" value "\""
                written = 1
            }
            next
        }

        {
            print
        }

        END {
            if (!written) {
                print key "=\"" value "\""
            }
        }
    ' "$file" > "$tmp"

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

read_edgeguard_version() {
    local file="$1"

    sed -n \
        -e 's/^EDGEGUARD_VERSION=//p' \
        -e 's/^VERSION=//p' \
        "$file" |
        head -n 1 |
        tr -d '\r"' |
        xargs
}

echo "============================================================"
echo "EdgeGuard OTA E3 Buildroot rootfs build"
echo "============================================================"
echo "PROJECT              = $PROJECT"
echo "BR                   = $BR"
echo "OUT                  = $OUT"
echo "DEF                  = $DEF"
echo "OVERLAY              = $OVERLAY"
echo "VERSION_FILE         = $VERSION_FILE"
echo "EXPECTED_VERSION     = $EXPECTED_VERSION"
echo "BR2_DL_DIR           = $BR2_DL_DIR"
echo "JOBS                 = $JOBS"
echo "REQUIRE_HOST_RAUC    = $REQUIRE_HOST_RAUC"
echo "REQUIRE_RAUC_CONFIG  = $REQUIRE_RAUC_CONFIG"
echo "BUILD_RAUC_FIRST     = $BUILD_RAUC_FIRST"
echo "FORCE_OVERLAY        = $FORCE_OVERLAY"
echo "LOG                  = $LOG"
echo "============================================================"

###############################################################################
# 1. Input validation
###############################################################################

[ -f "$BR/Makefile" ] ||
    die "Buildroot Makefile not found: $BR/Makefile"

[ -f "$DEF" ] ||
    die "Buildroot defconfig not found: $DEF"

[ -d "$OVERLAY" ] ||
    die "rootfs overlay directory not found: $OVERLAY"

[ -f "$VERSION_FILE" ] ||
    die "version file not found: $VERSION_FILE"

if [ "$REQUIRE_RAUC_CONFIG" = "1" ]; then
    [ -f "$RAUC_SYSTEM_CONF" ] ||
        die "RAUC system.conf not found: $RAUC_SYSTEM_CONF"

    [ -s "$RAUC_KEYRING" ] ||
        die "RAUC keyring missing or empty: $RAUC_KEYRING"
fi

SOURCE_VERSION="$(read_edgeguard_version "$VERSION_FILE")"

[ -n "$SOURCE_VERSION" ] ||
    die "Neither EDGEGUARD_VERSION nor VERSION was found in $VERSION_FILE"

if [ "$SOURCE_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "Current version file:"
    cat "$VERSION_FILE"

    die "expected version '$EXPECTED_VERSION', got '$SOURCE_VERSION'"
fi

echo
echo "[PASS] Overlay source directory exists."
echo "[PASS] Overlay version: $SOURCE_VERSION"

###############################################################################
# 2. Force the correct overlay into the saved defconfig
###############################################################################

echo
echo "============================================================"
echo "[1/8] Force BR2_ROOTFS_OVERLAY into saved defconfig"
echo "============================================================"

DEF_OVERLAY_BEFORE="$(read_kconfig_string "$DEF" BR2_ROOTFS_OVERLAY || true)"

echo "Saved defconfig overlay before patch:"
echo "  ${DEF_OVERLAY_BEFORE:-<not set>}"

if [ "$FORCE_OVERLAY" = "1" ]; then
    if [ "$DEF_OVERLAY_BEFORE" != "$OVERLAY" ]; then
        DEF_BACKUP="${DEF}.before-overlay-fix-${TS}"

        cp -a "$DEF" "$DEF_BACKUP"

        echo "Incorrect defconfig overlay detected."
        echo "Backup created:"
        echo "  $DEF_BACKUP"
    fi

    set_kconfig_string_file \
        "$DEF" \
        BR2_ROOTFS_OVERLAY \
        "$OVERLAY"
fi

DEF_OVERLAY_AFTER="$(read_kconfig_string "$DEF" BR2_ROOTFS_OVERLAY || true)"

echo "Saved defconfig overlay after patch:"
echo "  ${DEF_OVERLAY_AFTER:-<not set>}"

[ "$DEF_OVERLAY_AFTER" = "$OVERLAY" ] ||
    die "failed to set BR2_ROOTFS_OVERLAY in $DEF"

echo "[PASS] Saved defconfig contains the correct overlay."

###############################################################################
# 3. Restore the saved Buildroot configuration
###############################################################################

echo
echo "============================================================"
echo "[2/8] Restore Buildroot defconfig"
echo "============================================================"

make -C "$BR" \
    O="$OUT" \
    BR2_DEFCONFIG="$DEF" \
    defconfig

CONFIG="$OUT/.config"

[ -f "$CONFIG" ] ||
    die "Buildroot .config was not generated: $CONFIG"

###############################################################################
# 4. Force the correct overlay into effective .config
###############################################################################

echo
echo "============================================================"
echo "[3/8] Force BR2_ROOTFS_OVERLAY into effective .config"
echo "============================================================"

CONFIG_OVERLAY_BEFORE="$(
    read_kconfig_string "$CONFIG" BR2_ROOTFS_OVERLAY || true
)"

echo "Effective overlay before patch:"
echo "  ${CONFIG_OVERLAY_BEFORE:-<not set>}"

if [ "$FORCE_OVERLAY" = "1" ]; then
    set_kconfig_string_file \
        "$CONFIG" \
        BR2_ROOTFS_OVERLAY \
        "$OVERLAY"

    # Let Buildroot/Kconfig normalize all dependencies after the direct edit.
    make -C "$BR" \
        O="$OUT" \
        olddefconfig
fi

CONFIG_OVERLAY="$(
    read_kconfig_string "$CONFIG" BR2_ROOTFS_OVERLAY || true
)"

echo "Effective overlay after patch:"
echo "  ${CONFIG_OVERLAY:-<not set>}"

[ -n "$CONFIG_OVERLAY" ] ||
    die "BR2_ROOTFS_OVERLAY is empty in the effective configuration"

[ "$CONFIG_OVERLAY" = "$OVERLAY" ] || {
    echo "Configured overlay:"
    echo "  $CONFIG_OVERLAY"
    echo "Expected overlay:"
    echo "  $OVERLAY"

    die "failed to force the correct BR2_ROOTFS_OVERLAY"
}

echo "[PASS] Effective Buildroot overlay is correct."

###############################################################################
# 5. Validate effective Buildroot configuration
###############################################################################

echo
echo "============================================================"
echo "[4/8] Validate effective Buildroot configuration"
echo "============================================================"

echo
echo "Relevant effective configuration:"

for key in \
    BR2_PACKAGE_RAUC \
    BR2_PACKAGE_HOST_RAUC \
    BR2_USE_MMU \
    BR2_USE_WCHAR \
    BR2_TOOLCHAIN_HAS_THREADS \
    BR2_LINUX_KERNEL \
    BR2_TARGET_UBOOT \
    BR2_ROOTFS_OVERLAY \
    BR2_TARGET_ROOTFS_TAR \
    BR2_TARGET_ROOTFS_EXT2
do
    show_config_value "$key"
done

# Target RAUC is mandatory for the E3 target rootfs.
if ! config_is_y BR2_PACKAGE_RAUC; then
    echo

    if config_is_y BR2_PACKAGE_HOST_RAUC; then
        echo "BR2_PACKAGE_HOST_RAUC=y is enabled, but this only builds:"
        echo "  $OUT/host/bin/rauc"
        echo
        echo "It does not install RAUC into the target rootfs."
    fi

    echo
    echo "Target RAUC dependencies:"

    show_config_value BR2_USE_MMU
    show_config_value BR2_USE_WCHAR
    show_config_value BR2_TOOLCHAIN_HAS_THREADS

    echo
    echo "Open menuconfig and select:"
    echo "  Target packages -> System tools -> rauc"
    echo
    echo "Command:"
    echo "  make -C \"$BR\" O=\"$OUT\" menuconfig"

    die "BR2_PACKAGE_RAUC=y is not enabled in the effective configuration"
fi

echo "[PASS] Target RAUC is enabled."

# Host RAUC is useful for creating bundles, but not mandatory for rootfs build.
if config_is_y BR2_PACKAGE_HOST_RAUC; then
    echo "[PASS] Host RAUC is enabled."
else
    if [ "$REQUIRE_HOST_RAUC" = "1" ]; then
        die "BR2_PACKAGE_HOST_RAUC=y is required but not enabled"
    fi

    warn "Host RAUC is not enabled. The target rootfs can still build."
fi

# E1/E2/E3 route: Buildroot only builds rootfs.
if config_is_y BR2_LINUX_KERNEL; then
    die "BR2_LINUX_KERNEL=y is enabled; E3 must use the vendor kernel"
fi

if config_is_y BR2_TARGET_UBOOT; then
    die "BR2_TARGET_UBOOT=y is enabled; E3 must use the vendor U-Boot"
fi

echo "[PASS] Buildroot kernel is disabled."
echo "[PASS] Buildroot U-Boot is disabled."

# E3 primary payload requires rootfs.tar.
if ! config_is_y BR2_TARGET_ROOTFS_TAR; then
    die "BR2_TARGET_ROOTFS_TAR=y is not enabled"
fi

echo "[PASS] rootfs.tar output is enabled."
echo "[PASS] EdgeGuard overlay is active."

###############################################################################
# 6. Build target RAUC first
###############################################################################

if [ "$BUILD_RAUC_FIRST" = "1" ]; then
    echo
    echo "============================================================"
    echo "[5/8] Build target RAUC first"
    echo "============================================================"

    make -C "$BR" \
        O="$OUT" \
        -j"$JOBS" \
        rauc
else
    echo
    echo "============================================================"
    echo "[5/8] Skip standalone RAUC build"
    echo "============================================================"
fi

###############################################################################
# 7. Build complete rootfs
###############################################################################

echo
echo "============================================================"
echo "[6/8] Build complete Buildroot rootfs"
echo "============================================================"

make -C "$BR" \
    O="$OUT" \
    -j"$JOBS"

###############################################################################
# 8. Verify target directory
###############################################################################

echo
echo "============================================================"
echo "[7/8] Verify target rootfs"
echo "============================================================"

TARGET_RAUC="$OUT/target/usr/bin/rauc"
TARGET_VERSION="$OUT/target/etc/edgeguard_version"
TARGET_SYSTEM_CONF="$OUT/target/etc/rauc/system.conf"
TARGET_KEYRING="$OUT/target/etc/rauc/keyring.pem"

[ -x "$TARGET_RAUC" ] ||
    die "target RAUC binary not found or not executable: $TARGET_RAUC"

echo "Target RAUC binary:"
ls -lh "$TARGET_RAUC"
file "$TARGET_RAUC"

[ -f "$TARGET_VERSION" ] ||
    die "target version file not found: $TARGET_VERSION"

TARGET_VERSION_VALUE="$(
    read_edgeguard_version "$TARGET_VERSION"
)"

if [ "$TARGET_VERSION_VALUE" != "$EXPECTED_VERSION" ]; then
    echo "Target version file:"
    cat "$TARGET_VERSION"

    die "target version is '$TARGET_VERSION_VALUE', expected '$EXPECTED_VERSION'"
fi

echo
echo "Target E3 version:"
cat "$TARGET_VERSION"

if [ "$REQUIRE_RAUC_CONFIG" = "1" ]; then
    [ -f "$TARGET_SYSTEM_CONF" ] ||
        die "system.conf was not copied into target rootfs"

    [ -s "$TARGET_KEYRING" ] ||
        die "keyring.pem was not copied into target rootfs"

    echo
    echo "Target RAUC configuration:"
    cat "$TARGET_SYSTEM_CONF"

    echo
    echo "Target RAUC keyring:"
    ls -lh "$TARGET_KEYRING"
fi

###############################################################################
# 9. Verify host RAUC
###############################################################################

echo
echo "Host RAUC verification:"

HOST_RAUC="$OUT/host/bin/rauc"

if config_is_y BR2_PACKAGE_HOST_RAUC; then
    [ -x "$HOST_RAUC" ] ||
        die "BR2_PACKAGE_HOST_RAUC=y, but host RAUC was not generated: $HOST_RAUC"

    "$HOST_RAUC" --version
else
    echo "Host RAUC was not selected; skip host tool verification."
fi

###############################################################################
# 10. Verify generated rootfs.tar
###############################################################################

echo
echo "============================================================"
echo "[8/8] Verify generated rootfs.tar"
echo "============================================================"

ROOTFS_TAR="$OUT/images/rootfs.tar"

[ -s "$ROOTFS_TAR" ] ||
    die "rootfs.tar not found or empty: $ROOTFS_TAR"

TAR_LIST="$(mktemp)"

cleanup() {
    rm -f "$TAR_LIST"
}

trap cleanup EXIT

tar -tf "$ROOTFS_TAR" |
    sed 's#^\./##' > "$TAR_LIST"

tar_must_contain() {
    local path="$1"

    if ! grep -Fxq "$path" "$TAR_LIST"; then
        die "rootfs.tar does not contain: $path"
    fi

    echo "[PASS] rootfs.tar contains $path"
}

tar_must_contain "usr/bin/rauc"
tar_must_contain "etc/edgeguard_version"

if [ "$REQUIRE_RAUC_CONFIG" = "1" ]; then
    tar_must_contain "etc/rauc/system.conf"
    tar_must_contain "etc/rauc/keyring.pem"
fi

echo
echo "Generated images:"

find "$OUT/images" \
    -maxdepth 1 \
    \( -type f -o -type l \) \
    -printf '%p -> %l\n' |
    sort

echo
echo "rootfs.tar:"

ls -lh "$ROOTFS_TAR"
sha256sum "$ROOTFS_TAR"

echo
echo "Final effective configuration:"

grep -E \
    '^(BR2_PACKAGE_RAUC|BR2_PACKAGE_HOST_RAUC|BR2_ROOTFS_OVERLAY|BR2_TARGET_ROOTFS_TAR)=' \
    "$CONFIG"

echo
echo "============================================================"
echo "E3 rootfs build completed successfully"
echo "============================================================"
echo "Target RAUC : $TARGET_RAUC"
echo "Host RAUC   : $HOST_RAUC"
echo "Rootfs tar  : $ROOTFS_TAR"
echo "Overlay     : $CONFIG_OVERLAY"
echo "Version     : $TARGET_VERSION_VALUE"
echo "Log         : $LOG"