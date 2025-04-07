#!/bin/bash
#
VM_NAME=${1:-elemental-rke2}
RAW_PATH=${2:-./disk.img}
DISK_PATH=./disk.qcow2

echo Preparing disk for ${VM_NAME}

qemu-img convert -O qcow2 ${RAW_PATH} ${DISK_PATH}
qemu-img resize ${DISK_PATH} 35G

echo Deploying ${VM_NAME} using ${RAW_PATH}

virt-install --name $VM_NAME --vcpus=4  --memory 3072 --cpu host-model \
  --os-variant=opensusetumbleweed \
  --virt-type kvm \
  --boot loader=/usr/share/qemu/ovmf-x86_64.bin \
  --disk path=${DISK_PATH},bus=scsi,size=35,format=qcow2 \
  --check disk_size=off \
  --graphics vnc \
  --serial pty \
  --console pty,target_type=virtio \
  --rng random \
  --tpm emulator,model=tpm-crb,version=2.0 \
  --autostart \
  --network bridge=vbr0
