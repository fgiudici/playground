ARG OS_IMAGE=registry.opensuse.org/opensuse/tumbleweed
ARG OS_VERSION=latest


FROM ${OS_IMAGE}:${OS_VERSION} AS os

RUN zypper --non-interactive removerepo repo-update && zypper ref
RUN zypper --non-interactive --gpg-auto-import-keys install --no-recommends -- \
      patterns-base-base \
      aaa_base-extras \
      acl \
      chrony \
      dracut \
      fipscheck \
      pam_pwquality \
      iputils \
      issue-generator \
      vim-small \
      haveged \
      less \
      parted \
      gptfdisk \
      iproute2 \
      openssh \
      rsync \
      dosfstools \
      lsof \
      live-add-yast-repos \
      zypper-needs-restarting \
      combustion \
      grub2 \
      grub2-branding-openSUSE \
      grub2-x86_64-efi \
      shim \
      kernel-default-base \
      btrfsprogs \
      btrfsmaintenance \
      snapper \
      firewalld \
      podman \
      git \
      NetworkManager && \
    zypper clean --all

# Set default parameters for grub2
RUN echo 'GRUB_GFXMODE=auto'                  >> /etc/default/grub && \
    echo 'GRUB_TERMINAL_INPUT="console"'      >> /etc/default/grub && \
    echo 'GRUB_TERMINAL_OUTPUT="gfxterm"'     >> /etc/default/grub

RUN source /etc/os-release && \
    rm -rf /boot/* && rm -rf /boot/.* && \
    kernel_version=$(ls /usr/lib/modules | head -n1) && \
    mkdir -p /boot/${ID}/${kernel_version} && \
    dracut -f --no-hostonly "/boot/${ID}/${kernel_version}/initrd" "${kernel_version}"  && \
    cp "/usr/lib/modules/${kernel_version}/vmlinuz" "/boot/${ID}/${kernel_version}/vmlinuz" && \
    grub2-editenv /boot/grubenv set entries="active snap_1 snap_2" && \
    mkdir -p /boot/loader/entries && \
    grub2-editenv /boot/loader/entries/active.conf set display_name="openSUSE Tumbleweed" linux="/${ID}/${kernel_version}/vmlinuz" initrd="/${ID}/${kernel_version}/initrd" cmdline="root=LABEL=SYSTEM rw" && \
    grub2-editenv /boot/loader/entries/snap_1.conf set display_name="Snapshot 1 - Read Only" linux="/${ID}/${kernel_version}/vmlinuz" initrd="/${ID}/${kernel_version}/initrd" cmdline="root=LABEL=SYSTEM ro" && \
    grub2-editenv /boot/loader/entries/snap_2.conf set display_name="Snapshot 2 - break pre-pivot" linux="/${ID}/${kernel_version}/vmlinuz" initrd="/${ID}/${kernel_version}/initrd" cmdline="root=LABEL=SYSTEM ro rd.shell rd.break=pre-pivot" && \
    mkdir -p /boot/EFI/BOOT && \
    cp /usr/share/efi/x86_64/MokManager.efi /boot/EFI/BOOT/ && \
    cp /usr/share/efi/x86_64/shim.efi /boot/EFI/BOOT/bootx64.efi && \
    cp /usr/share/grub2/x86_64-efi/grub.efi /boot/EFI/BOOT/


COPY grub.cfg /boot/EFI/BOOT/grub.cfg

# Copying it to /root as this is a RW volume, handy for debugging and hacking
COPY updater.sh /root/updater.sh

CMD ["/bin/bash"]
