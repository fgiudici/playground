#!/bin/bash -x

set -e

echo "linux" | passwd root --stdin

systemctl enable NetworkManager.service
