#!/bin/bash -x

set -e

SCRIPT="$(realpath -s "${0}")"
SCRIPT_PATH="$(dirname "${SCRIPT}")"

image=$1

img_mnt=$(podman image mount "${image}") || exit 1

qemu-img create -f raw disk.img 10G
loopdev=$(losetup -f --show disk.img)
sgdisk -og "${loopdev}"
sgdisk -n 1:2048:4194303 -c 1:"EFI System Partition" -t 1:ef00 "${loopdev}"
sgdisk -n 2:4194304:+0 -c 2:"Root System Partition" -t 2:8300 "${loopdev}"
partx -u "${loopdev}"
mkfs.vfat -F 16 -n EFI "${loopdev}p1"
mkfs.btrfs -L SYSTEM "${loopdev}p2" -f
partx -u "${loopdev}"

workdir=/mnt/root
srcdir="${img_mnt}"

mkdir -p "${workdir}"
mount "${loopdev}p2" "${workdir}"

# Set root subvolume and quota
btrfs quota enable "${workdir}"
btrfs subvolume create "${workdir}/@"
btrfs qgroup create 1/0 "${workdir}"

btrfs subvolume create "${workdir}/@/.snapshots"

mkdir -p "${workdir}/@/.snapshots/1"
btrfs subvolume snapshot "${workdir}/@" "${workdir}/@/.snapshots/1/snapshot"

# Set default root to snapshot 1
volid=$(btrfs subvolume list --sort path "${workdir}" | grep "1/snapshot" | cut -d" " -f2)
btrfs subvolume set-default "${volid}" "${workdir}"

# Create snapshot 1 info
date=$(date +'%Y-%m-%d %H:%M:%S')
cat << EOF > "${workdir}/@/.snapshots/1/info.xml"
<?xml version="1.0"?>
<snapshot>
  <type>single</type>
  <num>1</num>
  <date>${date}</date>
  <description>first root filesystem</description>
</snapshot>
EOF


# RW volumes shared across all snapshots
rw_volumes=("srv" "home" "opt" "root" "var" "boot/grub2/x86_64-efi")

# RW snapshotted subvolumes
rw_snap_volumes=("etc")

# Create persistent volumes
# This script is not safe for nested subvolumes, there isn't any sorting logic
for volpath in "${rw_volumes[@]}"; do
  mkdir -p $(dirname "${workdir}/@/${volpath}")
  btrfs subvolume create "${workdir}/@/${volpath}"
done


# Create persistent snapshotted volumes
for volpath in "${rw_snap_volumes[@]}"; do
  mkdir -p $(dirname "${workdir}/@/.snapshots/1/snapshot/${volpath}")
  btrfs subvolume create "${workdir}/@/.snapshots/1/snapshot/${volpath}"
done


# Bind mount persistent subvolume and EFI partition at "${workdir}/@/.snapshots/1/snapshot"
mkdir -p "${workdir}/@/.snapshots/1/snapshot/boot/efi"
mount -t vfat "${loopdev}p1" "${workdir}/@/.snapshots/1/snapshot/boot/efi"

for volpath in "${rw_volumes[@]}"; do
  mkdir -p "${workdir}/@/.snapshots/1/snapshot/${volpath}"
  mount --bind "${workdir}/@/${volpath}" "${workdir}/@/.snapshots/1/snapshot/${volpath}"
done

# Feed data
rsync --info=progress2 --human-readable --partial --archive --xattrs --acls --filter="-x security.selinux" "${srcdir}/" "${workdir}/@/.snapshots/1/snapshot/"


# Mount snapshots subvolume at "${workdir}/@/.snapshots/1/snapshot"
mkdir -p "${workdir}/@/.snapshots/1/snapshot/.snapshots"
mount -t btrfs -o defaults,subvol=/@/.snapshots "${loopdev}p2"  "${workdir}/@/.snapshots/1/snapshot/.snapshots"


# Create root snapper configuration
chroot "${workdir}/@/.snapshots/1/snapshot" cp /usr/share/snapper/config-templates/default /etc/snapper/configs/root
chroot "${workdir}/@/.snapshots/1/snapshot" sed -i 's|SNAPPER_CONFIGS=.*$|SNAPPER_CONFIGS="root"|g' /etc/sysconfig/snapper
chroot "${workdir}/@/.snapshots/1/snapshot" snapper --no-dbus set-config "QGROUP=1/0"


# Create persistent volumes snapshots setup and stock snapshot
for volpath in "${rw_snap_volumes[@]}"; do
  chroot "${workdir}/@/.snapshots/1/snapshot" snapper --no-dbus -c "${volpath//\//-}" create-config --fstype btrfs "/${volpath}"
  chroot "${workdir}/@/.snapshots/1/snapshot" snapper --no-dbus -c "${volpath//\//-}" create --description "stock /${volpath} contents" --userdata "stock=${volpath}"
done


# TODO consider bootloader install


# Create fstab
{

  echo "LABEL=SYSTEM / btrfs ro,defaults 0 1"
  echo "LABEL=SYSTEM /.snapshots btrfs defaults,subvol=@/.snapshots 0 0"
  for volpath in "${rw_volumes[@]}"; do
    echo "LABEL=SYSTEM /${volpath} btrfs defaults,subvol=@/${volpath} 0 0"
  done
  for volpath in "${rw_snap_volumes[@]}"; do
    echo "LABEL=SYSTEM /${volpath} btrfs defaults,subvol=@/.snapshots/1/snapshot/${volpath} 0 0"
  done
  echo "LABEL=EFI  /boot/efi vfat defaults 0 0"

} > "${workdir}/@/.snapshots/1/snapshot/etc/fstab"


# set first snapshot as readonly
btrfs property set "${workdir}/@/.snapshots/1/snapshot" ro true


# Run chrooted configuration script at "${workdir}/@/.snapshots/1/snapshot"
if [ -f "${SCRIPT_PATH}/config.sh" ]; then
  mkdir -p "${workdir}/@/.snapshots/1/snapshot/var/tmp-builder-config"
  cp "${SCRIPT_PATH}/config.sh" "${workdir}/@/.snapshots/1/snapshot/var/tmp-builder-config"
  mount -t proc /proc "${workdir}/@/.snapshots/1/snapshot/proc"
  mount -t sysfs /sys "${workdir}/@/.snapshots/1/snapshot/sys"
  mount --bind /dev "${workdir}/@/.snapshots/1/snapshot/dev"
  mount --bind /dev/pts "${workdir}/@/.snapshots/1/snapshot/dev/pts"
  chroot "${workdir}/@/.snapshots/1/snapshot" /var/tmp-builder-config/config.sh
  umount "${workdir}/@/.snapshots/1/snapshot/dev/pts"
  umount "${workdir}/@/.snapshots/1/snapshot/dev"
  umount "${workdir}/@/.snapshots/1/snapshot/sys"
  umount "${workdir}/@/.snapshots/1/snapshot/proc"
  rm -rf "${workdir}/@/.snapshots/1/snapshot/var/tmp-builder-config"
fi


# Umount everything
umount "${workdir}/@/.snapshots/1/snapshot/boot/efi"
umount "${workdir}/@/.snapshots/1/snapshot/.snapshots"
for volpath in "${rw_volumes[@]}"; do
  umount "${workdir}/@/.snapshots/1/snapshot/${volpath}"
done
umount "${workdir}"


# TODO: Run configuration final script for final tweaks


losetup -d "${loopdev}"

podman image umount "${image}"
