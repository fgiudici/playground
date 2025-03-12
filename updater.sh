#!/bin/bash -x

set -e

image=${1}

# RW volumes shared across all snapshots
rw_volumes=("srv" "home" "opt" "root" "var" "boot/grub2/x86_64-efi")

# RW snapshotted subvolumes
rw_snap_volumes=("etc")

# mount upgrade image
img_mnt=$(podman image mount "${image}") || exit 1

# Create a new snapshot to apply updates
current=$(snapper --csvout list --columns number,active | grep yes | cut -d"," -f1)
id=$(snapper create --from ${current} --read-write --print-number --description "Snapshot Update of #${current}" --userdata "update-in-progress=yes")


# Create persistent snapshotted volumes
rw_snaps=()
for volpath in "${rw_snap_volumes[@]}"; do
  # Create current volume snapshot
  snapid=$(snapper -c "${volpath//\//-}" create --print-number --description "pre-update /${volpath} snapshot")

  # TODO base snapshot should be computed based on user-data instead of assuming its ID is 1
  rm -rf "/.snapshots/${id}/snapshot/${volpath}"
  btrfs subvolume snapshot "/${volpath}/.snapshots/1/snapshot" "/.snapshots/${id}/snapshot/${volpath}"
  rw_snaps+=("${snapid}")
done

# Create etc/.snapshots for the new snapshot
#rm -rf "/.snapshots/${id}/snapshot/etc/.snapshots"
#btrfs subvolume create "/.snapshots/${id}/snapshot/etc/.snapshots"


# Define exclude arguments for rsync
excludes=()
for volpath in "${rw_volumes[@]}"; do
  excludes+=("--exclude" "/${volpath}")
done
for volpath in "${rw_snap_volumes[@]}"; do
  excludes+=("--exclude" "/${volpath}/.snapshots")
done


# Synchronize new image
rsync --delete --info=progress2 --human-readable --partial --archive --xattrs --acls --filter="-x security.selinux" \
      --checksum "${excludes[@]}" --exclude /boot/efi --exclude /.snapshots "${img_mnt}/" "/.snapshots/${id}/snapshot/"

# Mount snapshots subvolume at "${workdir}/@/.snapshots/1/snapshot"
mkdir -p "/.snapshots/${id}/snapshot/.snapshots"
mount --bind "/.snapshots" "/.snapshots/${id}/snapshot/.snapshots"


# Create root snapper configuration
chroot "/.snapshots/${id}/snapshot" cp /usr/share/snapper/config-templates/default /etc/snapper/configs/root
chroot "/.snapshots/${id}/snapshot" sed -i 's|SNAPPER_CONFIGS=.*$|SNAPPER_CONFIGS="root"|g' /etc/sysconfig/snapper
chroot "/.snapshots/${id}/snapshot" snapper --no-dbus set-config "QGROUP=1/0"


# Create persistent volumes snapshots setup and stock snapshot
for volpath in "${rw_snap_volumes[@]}"; do
  chroot "/.snapshots/${id}/snapshot" rm -rf /${volpath}/.snapshots
  chroot "/.snapshots/${id}/snapshot" snapper --no-dbus -c "${volpath//\//-}" create-config --fstype btrfs "/${volpath}"
  chroot "/.snapshots/${id}/snapshot" snapper --no-dbus -c "${volpath//\//-}" create --description "stock /${volpath} contents" --userdata "stock=${volpath}"
done


# Merge current snapshotted RW snaps with new stock data
for i in "${!rw_snap_volumes[@]}"; do
  send_snap="/.snapshots/${current}/snapshot/${volpath[$i]}/.snapshots/${rw_snaps[$i]}/snapshot"
  target_snap="/.snapshots/${id}/snapshot/${volpath[$i]}"

  #parent_snap="/.snapshots/${current}/snapshot/${volpath[$i]}/.snapshots/1/snapshot"
  #btrfs send -p "${parent_snap}" "${send_snap}" | btrfs receive "${target_snap}"

  rsync --info=progress2 --human-readable --partial --archive --xattrs --acls --filter="-x security.selinux" \
        --checksum --exclude /.snapshots "${send_snap}/" "${target_snap}/"
done


# TODO consider bootloader update


# Create fstab. Should be enough updating it now rather than recreating
{

  echo "LABEL=SYSTEM / btrfs ro,defaults 0 1"
  echo "LABEL=SYSTEM /.snapshots btrfs defaults,subvol=@/.snapshots 0 0"
  for volpath in "${rw_volumes[@]}"; do
    echo "LABEL=SYSTEM /${volpath} btrfs defaults,subvol=@/${volpath} 0 0"
  done
  for volpath in "${rw_snap_volumes[@]}"; do
    echo "LABEL=SYSTEM /${volpath} btrfs defaults,subvol=@/.snapshots/${id}/snapshot/${volpath} 0 0"
  done
  echo "LABEL=EFI  /boot/efi vfat defaults 0 0"

} > "/.snapshots/${id}/snapshot/etc/fstab"


# Create persistent persistent snapshots with merged content
for volpath in "${rw_snap_volumes[@]}"; do
  chroot "/.snapshots/${id}/snapshot" snapper --no-dbus -c "${volpath//\//-}" create --description "merged /${volpath} contents"
done


# Set new default suvbolume
snapper modify --read-only --default --userdata "update-in-progress=" "${id}"

umount "/.snapshots/${id}/snapshot/.snapshots"

podman image umount "${image}"
