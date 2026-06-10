#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-$HOME/桌面/project/EdgeGuard_OTA}"
OUT="${OUT:-$PROJECT/output/edgeguard-imx6ull}"
CONFIG="$OUT/.config"

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: .config not found: $CONFIG"
  exit 1
fi

set_config_string() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$CONFIG"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG"
  else
    echo "${key}=\"${value}\"" >> "$CONFIG"
  fi
}

set_config_y() {
  local key="$1"
  sed -i "/^# ${key} is not set/d" "$CONFIG"
  if grep -q "^${key}=" "$CONFIG"; then
    sed -i "s|^${key}=.*|${key}=y|" "$CONFIG"
  else
    echo "${key}=y" >> "$CONFIG"
  fi
}

set_config_unset() {
  local key="$1"
  sed -i "/^${key}=/d" "$CONFIG"
  sed -i "/^# ${key} is not set/d" "$CONFIG"
  echo "# ${key} is not set" >> "$CONFIG"
}

set_config_unset BR2_LINUX_KERNEL
set_config_unset BR2_TARGET_UBOOT

set_config_string BR2_TARGET_GENERIC_GETTY_PORT "ttymxc0"
set_config_string BR2_TARGET_GENERIC_GETTY_BAUDRATE "115200"
set_config_string BR2_TARGET_GENERIC_HOSTNAME "edgeguard-imx6ull"
set_config_string BR2_TARGET_GENERIC_ISSUE "Welcome to EdgeGuard OTA E1"

set_config_string BR2_ROOTFS_OVERLAY "$PROJECT/board/edgeguard-imx6ull/overlay"

set_config_y BR2_TARGET_ROOTFS_TAR
set_config_y BR2_TARGET_ROOTFS_EXT2
set_config_y BR2_TARGET_ROOTFS_EXT2_4
set_config_string BR2_TARGET_ROOTFS_EXT2_LABEL "rootfs"
set_config_string BR2_TARGET_ROOTFS_EXT2_SIZE "256M"

echo "E1 Buildroot config patched."