#!/usr/bin/env bash
# 99-cleanup.sh — final pass before the image is sealed.
#
# Two responsibilities:
#   1. Lay down config files clones will need on first boot (cloud-init
#      datasource lock, systemd-networkd-wait-online timeout drop-in).
#   2. Seal the image: wipe identity (machine-id, SSH host keys, logs,
#      shell histories, cloud-init cache, DHCP leases) and arrange for
#      the build user `packer` to be removed on first boot of any clone.
#
# Inline deletion of the build user would tear down Packer's own SSH
# session mid-script, so it's deferred to a systemd one-shot. The unit
# is ordered Before=cloud-init-local.service so the build user is gone
# before any clone's network/sshd come up — eliminates the "known-
# password sudoer briefly reachable on a clone" window.
#
# Lifted with light edits from
# homelab/packer/ubuntu-24-04-base/provision/99-cleanup.sh.

set -euo pipefail

echo "==> bound systemd-networkd-wait-online to 30s"
# Ubuntu 24.04 ships this unit with no timeout. If a clone's interface
# fails to come online on first boot (transient bridge issues, or the
# cidata seed taking a moment to attach), boot stalls indefinitely.
# --any succeeds as soon as ANY managed link is online; --timeout=30
# fails the unit instead of hanging forever. Empty ExecStart= clears
# the inherited one so the second ExecStart= fully replaces it
# (drop-ins append by default).
install -d -m 0755 /etc/systemd/system/systemd-networkd-wait-online.service.d
install -m 0644 /dev/stdin /etc/systemd/system/systemd-networkd-wait-online.service.d/timeout.conf <<'WAIT_EOF'
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=30
WAIT_EOF

echo "==> lock cloud-init datasource to NoCloud"
# Without this, cloud-init probes EC2/OpenStack/etc. metadata endpoints
# on every boot (~90-120s wasted) before falling back. Tart clones
# receive identity via a NoCloud cidata ISO attached at clone time (see
# docs/cloning-and-cloud-init.md); ConfigDrive isn't used here, so the
# list is [NoCloud, None] — homelab's [NoCloud, ConfigDrive, None] is
# Proxmox-specific. None terminates the search instead of falling
# through to network sources. manage_etc_hosts + preserve_hostname=false
# let the seed's hostname directive land in /etc/hosts on first boot.
install -m 0644 /dev/stdin /etc/cloud/cloud.cfg.d/99-mac-vms-datasource.cfg <<'DS_EOF'
datasource_list: [ NoCloud, None ]
manage_etc_hosts: true
preserve_hostname: false
DS_EOF

echo "==> set DHCP client identifier to MAC (so 'tart ip' can find the lease)"
# Ubuntu 24.04's systemd-networkd defaults to an RFC 4361 DUID-based DHCP
# client identifier. macOS's bootpd writes that DUID into the lease file's
# hw_address= field (in addition to identifier=), but Tart's `tart ip`
# matches against the VM's 6-byte MAC, so the lookup fails and `tart ip`
# returns "no IP address found" despite the VM being networked.
#
# Tart's maintainers documented the same quirk and shipped the fix in
# their own Linux base images:
#   https://github.com/cirruslabs/tart/issues/912
#   https://github.com/cirruslabs/linux-image-templates/pull/39
# Their cure is `dhcp-identifier: mac` in netplan, applied via a
# cloud.cfg.d snippet so it survives every boot (not just first boot).
# Match: cloud-init's default `network` config under NoCloud is "DHCP on
# the first matching interface"; we override the identifier and leave
# everything else default. A clone that ships its own network-config in
# the cidata seed still wins (cloud-init merges; later sources override).
install -m 0644 /dev/stdin /etc/cloud/cloud.cfg.d/99-mac-vms-dhcp.cfg <<'DHCP_EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp-identifier: mac
DHCP_EOF

echo "==> apt clean (caches, lists, and pkgcache index)"
# apt-get clean only removes downloaded .deb files in
# /var/cache/apt/archives/. The parsed pkgcache.bin / srcpkgcache.bin
# (the binary index ansible's apt module stat()s to decide cache age)
# survive with a recent mtime from the build's apt update. Leaving
# them lets ansible's cache_valid_time check on a fresh clone declare
# "cache is fresh — skip apt update", and the subsequent apt install
# fails because /var/lib/apt/lists/ is empty.
export DEBIAN_FRONTEND=noninteractive
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin

echo "==> truncate logs"
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.[0-9]" -delete
find /var/log -type f -exec truncate -s 0 {} \; || true

echo "==> wipe machine-id (systemd regenerates on first boot)"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "==> wipe SSH host keys (sshd regenerates on first boot)"
rm -f /etc/ssh/ssh_host_*

echo "==> wipe shell histories"
rm -f /root/.bash_history
rm -f /home/*/.bash_history
history -c || true

echo "==> wipe cloud-init seed cache"
cloud-init clean --logs --seed || true
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance

echo "==> wipe netplan installer config from autoinstall"
# Subiquity drops a 50-cloud-init.yaml with build-time NIC config.
# Clones get their network identity from their own cloud-init seed,
# not from this file.
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/netplan/00-installer-config.yaml

echo "==> install deferred packer-user removal as a systemd one-shot"
# The one-shot self-destructs after running, so it fires exactly once
# on the first boot of any clone (and on the base image itself if you
# ever `tart run` it directly — the base isn't a login target).
#
# Critical: DefaultDependencies=no + WantedBy=sysinit.target. Without
# DefaultDependencies=no, systemd auto-adds After=basic.target to the
# unit (the default for service units). basic.target sits between
# sysinit and multi-user, so pairing that auto-added After=basic.target
# with our explicit Before=cloud-init-local.service (a sysinit-phase
# unit) creates an ordering cycle through sysinit.target. systemd
# resolves the cycle by silently deleting cloud-init-local.service
# from the boot graph ("Job cloud-init-local.service/start deleted to
# break ordering cycle" in journalctl). Result on every fresh clone:
# NoCloud is never probed, DataSourceNone fallback is selected, no
# hostname/user/netplan/SSH-key from the seed. Homelab's team hit this
# in production on 2026-05-15; the directives below are the fix.
# Conflicts=shutdown.target is the standard sibling that ensures the
# unit doesn't try to start during shutdown.

install -m 0755 /dev/stdin /usr/local/sbin/packer-cleanup.sh <<'CLEANUP_EOF'
#!/bin/bash
# Installed by packer-ubuntu-24-04-arm64/provision/99-cleanup.sh.
# One-shot: removes the build-time packer user on first boot, then
# unregisters and deletes itself.
set -e
userdel -r -f packer 2>/dev/null || true
rm -f /etc/sudoers.d/99-packer-build
systemctl disable packer-cleanup.service
rm -f /etc/systemd/system/packer-cleanup.service
rm -f /usr/local/sbin/packer-cleanup.sh
systemctl daemon-reload
CLEANUP_EOF

install -m 0644 /dev/stdin /etc/systemd/system/packer-cleanup.service <<'UNIT_EOF'
[Unit]
Description=Remove packer build user from cloned image (one-shot on first boot)
DefaultDependencies=no
After=local-fs.target
Before=cloud-init-local.service
Conflicts=shutdown.target
ConditionPathExists=/usr/local/sbin/packer-cleanup.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/packer-cleanup.sh

[Install]
WantedBy=sysinit.target
UNIT_EOF

systemctl enable packer-cleanup.service

echo "==> wipe DHCP leases"
rm -f /var/lib/dhcp/*.leases
rm -f /var/lib/NetworkManager/*.lease 2>/dev/null || true

echo "==> trim free space back to the host"
# Tart-on-AVF presents disks as sparse files; fstrim's UNMAP requests
# propagate through to the host filesystem and release blocks. Costs
# nothing if the host doesn't honor it.
fstrim -av || true
sync

echo "==> cleanup done"
