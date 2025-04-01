#!/bin/bash -x

set -e

echo "linux" | passwd root --stdin

systemctl enable NetworkManager.service

cat <<- END > /etc/ssh/sshd_config.d/permit_root_login.conf
PermitRootLogin yes
END

systemctl enable sshd

cat <<- END > /etc/systemd/system/ensure-sysext.service
[Unit]
BindsTo=systemd-sysext.service
After=systemd-sysext.service
DefaultDependencies=no
# Keep in sync with systemd-sysext.service
ConditionDirectoryNotEmpty=|/etc/extensions
ConditionDirectoryNotEmpty=|/run/extensions
ConditionDirectoryNotEmpty=|/var/lib/extensions
ConditionDirectoryNotEmpty=|/usr/local/lib/extensions
ConditionDirectoryNotEmpty=|/usr/lib/extensions
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/systemctl daemon-reload
ExecStart=/usr/bin/systemctl restart --no-block sockets.target timers.target multi-user.target
[Install]
WantedBy=sysinit.target
END

mkdir /etc/extensions
curl --output-dir /etc/extensions/ -LO https://download.opensuse.org/repositories/home:/fgiudici:/UC/sysext/rke2-6.1.x86-64.raw

systemctl enable systemd-sysext
systemctl enable ensure-sysext
ln -s /usr/lib/systemd/system/rke2-server.service /etc/systemd/system/multi-user.target.wants/rke2-server.service
