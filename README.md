# Playground

This repository is just a playground to experiment with immutable linux installation and upgrade from OCI container images.

This repository contains two scripts, `builder.sh` and `updater.sh`. The builder builds a RAW disk image from an OCI container.
It assumes bootloader setup to be already prepared and configured at `/boot` and it also assumes `/boot/efi` represents the EFI partition contents.
The updater scripts updates from an OCI container with the same assumptions of the builder script, but adding a podman requirement as part of the
target OS.

The builder script checks for the existence of a `config.sh` which is executed in a chroot environment after creating the first snapshot. This can
be used to configure the system and preload data. Note the chroot enviroment is meant to reproduce the immutable system, hence `/` is read-only.

The immutability is based on btrfs snapshots which are managed by snapper, hence both tools are required in the host and in the target OS.

Both scripts require a unique paramter which is the image reference of the local podman storage. None of the scripts cover OCI image extraction
they just relay on `podman image mount`.

The repository also includes two different Dockerfiles to build images to test upgrades. The `Dockerfile` includes a generic TW based OS and the
`Dockerfile.update` includes the same TW OS definition with few differences on the packages list and configs. Those are essentially meant to build
a couple of images to exercise the `builder.sh` and `updater.sh`.

## Immutable concept

As immutable linux it is assumed `/` is a read-only filesystem. However to make the system usable there are certain paths which are read-write.
The root `/` filesystem is snapshotted, meaning each update represents an independent bucket for `/`. RW areas can be of two different types, they
can be snapshotted (meaning snapshots across updates are kept and tied with its particular root `/` snapshot) or, alternatively, they can be
simple RW buckets aside shared across all `/` snapshots.

This experiment does not consider ephemeral areas.

### Snapper based implementation

Each `/` root-tree is stored from an OCI image into a particular btrfs snapshot following snapper criteria (subvolume `/@/.snapshots/1/snapshot`). Each
snapshotted path (e.g. /etc) represents an snapshotted subvolume nested to its particular snapshot (subvolume `/@/.snapshots/1/snapshot/etc` with additional
snapper subvolumes `/@/.snapshots/1/snapshot/etc/.snapshots` and `/@/.snapshots/1/snapshot/etc/.snapshots/1/snapshot`).


#### Benefits of this approach

* Mounting the default subvolume already includes a RO view of its snapshotted RW paths (e.g. /etc). This prevents needing special initrd logic to
  mount them.
* While being in each root (`/`) snapshot it is easy to list system wide snapshots and particular RW snapshots associated to the root (`/`) snapshot:
```bash
# List `/` snapshots
snapper list

# List `/etc` snapshots
snapper -c etc list
```
* We keep track of stock RW content for snapshotted contents (origianl /etc is kept for each update) which allows to consider multiple merging strategies.
* If `/etc` is a RW snapshotted area it does not require specific treatment, we can snapshot `/etc` and any other path we consider (`/root`, `/home`, etc.).
* Easy rollback, in order to roll back to a previous snapshot we can just run `snapper modify --default <snapID>` and reboot.

#### Caveats of this approach

* So far I could not find how to fully use snapper in a nested fashion, this implies automatic cleanup is not functional.
  Deleting a root (`/`) snapshot fails due to the nested subvolumes. So far a snapshot can be deleted as:
```bash
snapper modify --read-write <snapID>
btrfs subvolume delete -c -R /.snapshots/<snapID>/snapshot
rm -rf /.snapshot/<snapID>
```
* RW snapshotted paths are likely to be innefficient at disk. Stock data gets updated by user config on Snap 1. Stock data in Snap 2 is snapshot of stock data in 1 plus the diff from
  stock data of the new img. Then stock data in Snap 2 is merged with user additions done at config time, I'd assume this second delta is duplicated at disk.
* In the current logic of this example any changes to RW snapshotted areas after upgrading and before rebooting are lost. This is by desing and it could be considered a feature too.
* Requires fstab generation/maintenace for each OS upgrade (there is an explicit reference to the default repo snapshot). It should not be a big deal though, we have to generate
  it in any case for the installation phase.
* Rolling back the nested RW snapshots can't be done with `snapper rollback` for this the actual nested subvolume would require to be a snapshot itself. I did not consider this
  option because then the default mount of root `/` would not include nested volumes at the right location. In any case rolling back /etc without rolling back the full root `/` is
  not something that should not happen, it could be handy for trouble shooting, but not as an automated regular operation as part of a fallback or upgrade OS mechanism.

## Running a test (validated on TW only)

**WARNING: this procedure requires root privileges, use it at your own risk. Ideally this should be all executed in VM or equivalent isolated system.**

Non development environment run:
```bash
# Move to the root folder of the git checkout
cd playground

podman build . -t image:test
./builder image:test

# Run the generated disk
qemu-kvm -m 2048 -hda disk.img -bios /usr/share/qemu/ovmf-x86_64.bin
```

Login in the VM (default root password is `linux`) and run:
```
# Create user to validate changes in /etc are kept
useradd -m alice
passwd alice

# Check the we use kernel-default-base
rpm -qa | grep kernel

# Build the image to upgrade to
git clone https://gitub.com/davidcassany/playground
cd playground
podman build -f Dockerfile.update -t image:update

# Upgrade
./updater.sh image:update

# Reboot
shutdown -r now
```

On the rebooted syste, login as root:
```bash
# Check the we use kernel-default, no base version.
rpm -qa | grep kernel
```

Exit and verify we can login as `Alice`.

## A potential installation definition in a yaml form

This is an example of how we could define a potential installation in a yaml form.

```yaml
# The OS image to install
imageSource: registry.org/my/image:latest

# Building RAW images requires supporting variable sector size 
# as we might need to adapt to target device constraints. Should
# be auto detected during baremetal installation.
sectorSize: 512

# partitions list with the disk order
partitions:
- label: EFI

  # We could assume Megabytes
  size: 1024
  
  # We could imagine several partition types based on purpose (boot, root, recovery, storage, etc.)
  # The defined purpose could automatically assume certain details (filesystem, gpt type, etc.)
  purpose: boot
  
  # Any ARM image is likely to require pretty specific setup
  startSector: 2048
  
- lable: RECOVERY

  # Size zero could imply size it according to contents
  size: 0
  
  # This could imply a ext4 with a nested OEM squashfs image or a similar approach
  purpose: recovery
  
- label: SYSTEM
  size: 20480 
  filesystem: btrfs
  
  # root purpose implies snapshotted root
  purpose: root
  
  # RW volumes
  volumes:
  - path: /etc
    # mountpoint would used to feed the contents and generate fstab
    mountpoint: /etc
    
    # /etc would be a nested subvolume of the root snapshot
    # and set snapper to snapshot it
    snapshotted: true 
    
  - path: /var
    mountpoint: /var
  - ...
  
# Any extra partition would also be defined
- label: data
  # It could mean all available space, only valid for the last partition
  size: -1
  filesystem: btrfs
  
  # this purpose could assume no snapshotted RW volumes are supported, just plain filesystem and its RW mountpoint
  purpose: data
  mountpoint: /data
  
# Any data related to the bootloader should be also part of the installer (e.g. kernel args)
bootloader: # TBD
```

Only `boot` and `root` partitions should be mandatory in all cases.
