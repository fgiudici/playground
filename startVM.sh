#!/bin/sh

DISKIMG="${DISKIMG:-disk.img}"

sudo virt-install \
    -n "elemental-rke2" --osinfo=slem5.4 --memory="4092" --vcpus="2" \
    --boot uefi \
    --disk path="${DISKIMG}",bus=virtio --import \
    --graphics "spice" \
    --network "default" \
    --autoconsole "text"
