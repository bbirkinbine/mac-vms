#!/usr/bin/env bash
# 00-baseline.sh — minimal post-install baseline for the Ubuntu base image.
#
# Runs once after the autoinstall completes and the VM reboots into the
# freshly-installed OS. Keep this short — anything role-specific belongs
# downstream (cloud-init at clone time, Ansible, or per-VM provisioners).

set -euo pipefail

echo "==> waiting for cloud-init to finish"
cloud-init status --wait

echo "==> apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "==> cleaning apt caches"
apt-get autoremove -y
apt-get clean

echo "==> cleaning cloud-init state so the next boot is treated as first boot"
cloud-init clean --logs --seed

echo "==> truncating machine-id so clones get a unique id on first boot"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "==> baseline complete"
