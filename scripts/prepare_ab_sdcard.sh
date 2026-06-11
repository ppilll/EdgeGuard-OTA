#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage:"
  echo "  sudo $0 /dev/sdb vendor/ebf6ull-s1-pro/u-boot-dtb.imx vendor/ebf6ull-s1-pro/zImage vendor/ebf6ull-s1-pro/imx6ull-mmc-npi.dtb"
  exit 1
fi

SD="$1"
UBOOT="$2"
KERNEL="$3"
DTB="$4"

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${PROJECT}/output/edgeguard-imx6ull"
ROOTFS_TAR="${OUT}/images/rootfs.tar"

BOOT_MNT="/mnt/edgeguard-boot"
ROOTFS_A_MNT="/mnt/edgeguard-rootfs-a"
ROOTFS_B_MNT="/mnt/edgeguard-rootfs-b"
DATA_MNT="/mnt/edgeguard-data"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: please run with sudo"
  exit 1
fi

for cmd in lsblk findmnt sfdisk partprobe udevadm wipefs mkfs.vfat mkfs.ext4 mount umount tar dd cmp sync blkid; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: command not found: $cmd"
    exit 1
  fi
done

for f in "$UBOOT" "$KERNEL" "$DTB" "$ROOTFS_TAR"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: file not found: $f"
    exit 1
  fi
done

if [ ! -b "$SD" ]; then
  echo "ERROR: block device not found: $SD"
  exit 1
fi

SD_BASE="$(basename "$SD")"

# Refuse partition paths like /dev/sdb1, /dev/mmcblk0p1, /dev/nvme0n1p1.
if [ -e "/sys/class/block/${SD_BASE}/partition" ]; then
  echo "ERROR: $SD is a partition, not a whole disk."
  echo "Please pass the whole SD card device, e.g. /dev/sdb, not /dev/sdb1."
  exit 1
fi

part_name() {
  local disk="$1"
  local idx="$2"

  if [[ "$disk" == /dev/mmcblk* || "$disk" == /dev/nvme* ]]; then
    echo "${disk}p${idx}"
  else
    echo "${disk}${idx}"
  fi
}

BOOT_PART="$(part_name "$SD" 1)"
ROOTFS_A_PART="$(part_name "$SD" 2)"
ROOTFS_B_PART="$(part_name "$SD" 3)"
DATA_PART="$(part_name "$SD" 4)"

# Refuse to operate on the system root disk.
ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
if [ -n "$ROOT_SRC" ]; then
  ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"
  if [ "$SD" = "$ROOT_DISK" ]; then
    echo "ERROR: $SD seems to be system disk. Refusing."
    exit 1
  fi
fi

unmount_sd_partitions() {
  # Unmount known partition names first.
  umount "$BOOT_PART" 2>/dev/null || true
  umount "$ROOTFS_A_PART" 2>/dev/null || true
  umount "$ROOTFS_B_PART" 2>/dev/null || true
  umount "$DATA_PART" 2>/dev/null || true

  # Unmount anything listed under the disk.
  while read -r p; do
    [ -n "$p" ] && umount "/dev/$p" 2>/dev/null || true
  done < <(lsblk -ln -o NAME "$SD" 2>/dev/null | tail -n +2 || true)

  # Unmount our mountpoints too, in case device names changed.
  umount "$BOOT_MNT" 2>/dev/null || true
  umount "$ROOTFS_A_MNT" 2>/dev/null || true
  umount "$ROOTFS_B_MNT" 2>/dev/null || true
  umount "$DATA_MNT" 2>/dev/null || true
}

reread_partitions() {
  partprobe "$SD" || true
  udevadm settle || true
  sleep 2

  if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOTFS_A_PART" ] || [ ! -b "$ROOTFS_B_PART" ] || [ ! -b "$DATA_PART" ]; then
    echo "Partition nodes are not visible yet; trying one more settle..."
    partprobe "$SD" || true
    udevadm settle || true
    sleep 3
  fi

  if [ ! -b "$BOOT_PART" ] || [ ! -b "$ROOTFS_A_PART" ] || [ ! -b "$ROOTFS_B_PART" ] || [ ! -b "$DATA_PART" ]; then
    echo "ERROR: partitions not visible:"
    lsblk "$SD" || true
    echo "Expected:"
    echo "  $BOOT_PART"
    echo "  $ROOTFS_A_PART"
    echo "  $ROOTFS_B_PART"
    echo "  $DATA_PART"
    exit 1
  fi
}

verify_not_mounted() {
  if lsblk -nrpo NAME,MOUNTPOINTS "$SD" | awk 'NF >= 2 { found=1 } END { exit found ? 0 : 1 }'; then
    echo "ERROR: some partitions are still mounted:"
    lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINTS "$SD" || true
    exit 1
  fi
}

write_slot_file() {
  local root="$1"
  local slot="$2"

  mkdir -p "$root/etc"

  cat > "$root/etc/edgeguard_slot" <<SLOT_EOF
SLOT=$slot
SLOT_EOF
}

ensure_same_version_file() {
  local root_a="$1"
  local root_b="$2"

  # E1 rootfs.tar should already contain /etc/edgeguard_version from overlay.
  # E2 keeps edgeguard_version identical between A and B.
  if [ ! -f "$root_a/etc/edgeguard_version" ] && [ ! -f "$root_b/etc/edgeguard_version" ]; then
    echo "WARN: /etc/edgeguard_version missing in rootfs.tar; creating identical fallback version file."

    cat > "$root_a/etc/edgeguard_version" <<VERSION_EOF
PRODUCT=EdgeGuard OTA
BOARD=Embedfire EBF6ULL S1 PRO
CPU=NXP i.MX6ULL
STAGE=E2_AB_BOOT
ROOTFS_SOURCE=rootfs.tar
VERSION_EOF

    cp "$root_a/etc/edgeguard_version" "$root_b/etc/edgeguard_version"
  elif [ -f "$root_a/etc/edgeguard_version" ] && [ ! -f "$root_b/etc/edgeguard_version" ]; then
    cp "$root_a/etc/edgeguard_version" "$root_b/etc/edgeguard_version"
  elif [ ! -f "$root_a/etc/edgeguard_version" ] && [ -f "$root_b/etc/edgeguard_version" ]; then
    cp "$root_b/etc/edgeguard_version" "$root_a/etc/edgeguard_version"
  fi

  if cmp "$root_a/etc/edgeguard_version" "$root_b/etc/edgeguard_version"; then
    echo "OK: edgeguard_version is identical between rootfs_A and rootfs_B."
  else
    echo "ERROR: edgeguard_version differs between rootfs_A and rootfs_B."
    echo "E2 requires same edgeguard_version; only /etc/edgeguard_slot should differ."
    exit 1
  fi
}

echo "DANGER: this will ERASE $SD"
echo
echo "SD card:"
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT "$SD" || true
echo
echo "U-Boot : $UBOOT"
echo "Kernel : $KERNEL"
echo "DTB    : $DTB"
echo "Rootfs : $ROOTFS_TAR"
echo
echo "Planned layout:"
echo "  p1 BOOT     128MiB FAT32"
echo "  p2 rootfs_A 512MiB ext4"
echo "  p3 rootfs_B 512MiB ext4"
echo "  p4 data     remaining ext4"
echo
echo "Important:"
echo "  rootfs_A and rootfs_B will both be extracted from the same rootfs.tar."
echo "  Only /etc/edgeguard_slot will differ."
echo
read -r -p "Type exactly 'ERASE ${SD}' to continue: " CONFIRM

if [ "$CONFIRM" != "ERASE $SD" ]; then
  echo "Aborted."
  exit 1
fi

echo "[1/14] Unmount old partitions..."
unmount_sd_partitions
verify_not_mounted

echo "[2/14] Wipe old beginning area..."
wipefs -a "$SD" || true
dd if=/dev/zero of="$SD" bs=1M count=32 conv=fsync status=progress
sync

echo "[3/14] Create MBR A/B partitions..."
sfdisk "$SD" <<'SFDISK_EOF'
label: dos
unit: sectors

start=2048,    size=262144,  type=c, bootable
start=264192,  size=1048576, type=83
start=1312768, size=1048576, type=83
start=2361344,              type=83
SFDISK_EOF

reread_partitions

echo "New partition layout:"
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT "$SD" || true

echo "[4/14] Unmount possible desktop automounts..."
unmount_sd_partitions
verify_not_mounted

echo "[5/14] Wipe partition signatures..."
wipefs -a "$BOOT_PART" || true
wipefs -a "$ROOTFS_A_PART" || true
wipefs -a "$ROOTFS_B_PART" || true
wipefs -a "$DATA_PART" || true
sync

echo "[6/14] Format partitions..."
mkfs.vfat -F 32 -n BOOT "$BOOT_PART"
mkfs.ext4 -F -L rootfs_A "$ROOTFS_A_PART"
mkfs.ext4 -F -L rootfs_B "$ROOTFS_B_PART"
mkfs.ext4 -F -L data "$DATA_PART"
sync

echo "[7/14] Copy kernel and dtb to BOOT partition..."
unmount_sd_partitions
reread_partitions

mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"

cp "$KERNEL" "$BOOT_MNT/zImage"
cp "$DTB" "$BOOT_MNT/edgeguard.dtb"

sync

echo "BOOT partition content:"
ls -lh "$BOOT_MNT"

umount "$BOOT_MNT"
sync

echo "[8/14] Extract same Buildroot rootfs.tar to rootfs_A..."
unmount_sd_partitions
reread_partitions

mkdir -p "$ROOTFS_A_MNT"
mount "$ROOTFS_A_PART" "$ROOTFS_A_MNT"

tar --numeric-owner -xpf "$ROOTFS_TAR" -C "$ROOTFS_A_MNT"

sync

echo "rootfs_A top level:"
ls -lh "$ROOTFS_A_MNT" | head

umount "$ROOTFS_A_MNT"
sync

echo "[9/14] Extract same Buildroot rootfs.tar to rootfs_B..."
unmount_sd_partitions
reread_partitions

mkdir -p "$ROOTFS_B_MNT"
mount "$ROOTFS_B_PART" "$ROOTFS_B_MNT"

tar --numeric-owner -xpf "$ROOTFS_TAR" -C "$ROOTFS_B_MNT"

sync

echo "rootfs_B top level:"
ls -lh "$ROOTFS_B_MNT" | head

umount "$ROOTFS_B_MNT"
sync

echo "[10/14] Write slot identity files only..."
unmount_sd_partitions
reread_partitions

mkdir -p "$ROOTFS_A_MNT" "$ROOTFS_B_MNT"
mount "$ROOTFS_A_PART" "$ROOTFS_A_MNT"
mount "$ROOTFS_B_PART" "$ROOTFS_B_MNT"

write_slot_file "$ROOTFS_A_MNT" "A"
write_slot_file "$ROOTFS_B_MNT" "B"

ensure_same_version_file "$ROOTFS_A_MNT" "$ROOTFS_B_MNT"

echo "rootfs_A slot:"
cat "$ROOTFS_A_MNT/etc/edgeguard_slot"

echo "rootfs_B slot:"
cat "$ROOTFS_B_MNT/etc/edgeguard_slot"

echo "edgeguard_version:"
cat "$ROOTFS_A_MNT/etc/edgeguard_version"

sync

umount "$ROOTFS_A_MNT"
umount "$ROOTFS_B_MNT"
sync

echo "[11/14] Verify data partition mountability..."
unmount_sd_partitions
reread_partitions

mkdir -p "$DATA_MNT"
mount "$DATA_PART" "$DATA_MNT"
echo "EdgeGuard E2 data partition placeholder" > "$DATA_MNT/README_E2_DATA.txt"
sync
ls -lh "$DATA_MNT"
umount "$DATA_MNT"
sync

echo "[12/14] Write U-Boot raw image as final step..."
unmount_sd_partitions
verify_not_mounted

# Official-style command:
# dd default block size is 512 bytes, so seek=2 means 1024-byte offset.
dd iflag=dsync oflag=dsync if="$UBOOT" of="$SD" seek=2 status=progress
sync

echo "[13/14] Verify U-Boot raw area, BOOT files, and slot files..."
reread_partitions

UBOOT_SIZE="$(stat -c%s "$UBOOT")"
UBOOT_BLOCKS=$(( (UBOOT_SIZE + 511) / 512 ))

dd if="$SD" of=/tmp/edgeguard-uboot-from-sd.imx bs=512 skip=2 count="$UBOOT_BLOCKS" status=none

if cmp -n "$UBOOT_SIZE" "$UBOOT" /tmp/edgeguard-uboot-from-sd.imx; then
  echo "OK: U-Boot raw area matches."
else
  echo "ERROR: U-Boot raw area does not match!"
  exit 1
fi

unmount_sd_partitions
mkdir -p "$BOOT_MNT"
mount "$BOOT_PART" "$BOOT_MNT"

echo "BOOT partition content after U-Boot write:"
ls -lh "$BOOT_MNT"

if cmp "$KERNEL" "$BOOT_MNT/zImage"; then
  echo "OK: zImage matches."
else
  echo "ERROR: zImage mismatch or missing!"
  umount "$BOOT_MNT" || true
  exit 1
fi

if cmp "$DTB" "$BOOT_MNT/edgeguard.dtb"; then
  echo "OK: DTB matches."
else
  echo "ERROR: DTB mismatch or missing!"
  umount "$BOOT_MNT" || true
  exit 1
fi

umount "$BOOT_MNT"
sync

mkdir -p "$ROOTFS_A_MNT" "$ROOTFS_B_MNT"
mount "$ROOTFS_A_PART" "$ROOTFS_A_MNT"
mount "$ROOTFS_B_PART" "$ROOTFS_B_MNT"

if grep -qx "SLOT=A" "$ROOTFS_A_MNT/etc/edgeguard_slot"; then
  echo "OK: rootfs_A slot marker matches."
else
  echo "ERROR: rootfs_A slot marker mismatch."
  exit 1
fi

if grep -qx "SLOT=B" "$ROOTFS_B_MNT/etc/edgeguard_slot"; then
  echo "OK: rootfs_B slot marker matches."
else
  echo "ERROR: rootfs_B slot marker mismatch."
  exit 1
fi

if cmp "$ROOTFS_A_MNT/etc/edgeguard_version" "$ROOTFS_B_MNT/etc/edgeguard_version"; then
  echo "OK: edgeguard_version remains identical."
else
  echo "ERROR: edgeguard_version differs."
  exit 1
fi

umount "$ROOTFS_A_MNT"
umount "$ROOTFS_B_MNT"
sync

echo "[14/14] Final sync and layout..."
unmount_sd_partitions
sync

lsblk -f "$SD" || true
fdisk -l "$SD" || true

echo
echo "SD card ready."
echo "Boot partition   : $BOOT_PART"
echo "Rootfs A partition: $ROOTFS_A_PART"
echo "Rootfs B partition: $ROOTFS_B_PART"
echo "Data partition   : $DATA_PART"
echo
echo "Manual U-Boot commands for A:"
echo "  mmc dev 0"
echo "  mmc rescan"
echo "  fatls mmc 0:1"
echo "  ext4ls mmc 0:2 /"
echo "  fatload mmc 0:1 0x80800000 zImage"
echo "  fatload mmc 0:1 0x83000000 edgeguard.dtb"
echo "  setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw rootfstype=ext4'"
echo "  bootz 0x80800000 - 0x83000000"
echo
echo "Manual U-Boot commands for B:"
echo "  mmc dev 0"
echo "  mmc rescan"
echo "  fatls mmc 0:1"
echo "  ext4ls mmc 0:3 /"
echo "  fatload mmc 0:1 0x80800000 zImage"
echo "  fatload mmc 0:1 0x83000000 edgeguard.dtb"
echo "  setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p3 rootwait rw rootfstype=ext4'"
echo "  bootz 0x80800000 - 0x83000000"
echo
echo "Before removing the SD card, recommended:"
echo "  sudo udisksctl power-off -b $SD"
echo "If udisksctl is unavailable, wait a few seconds after sync before unplugging."
