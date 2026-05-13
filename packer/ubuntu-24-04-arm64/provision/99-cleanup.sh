#!/usr/bin/env bash
# 99-cleanup.sh — final pass before the image is sealed.
#
# Goal: clones come up with a known-good blank slate and the cloud-init seam
# is the *only* way to land a usable login. Specifically:
#   - SSH host keys are removed so each clone regenerates unique ones on
#     first boot (no fingerprint collisions across VMs).
#   - The netplan config subiquity wrote at install time is removed —
#     clones get their networking from cloud-init (or the default DHCP
#     fallback), not from a build-time artifact.
#   - The build-time `packer` user removal is *deferred* to a systemd
#     one-shot that fires on first boot of any clone, ordered
#     Before=cloud-init-local.service so the user is gone before any
#     clone's network/sshd comes up. Inline deletion would tear down
#     Packer's own SSH session mid-script.
#
# Lifted with light edits from
# homelab/packer/ubuntu-24-04-base/provision/99-cleanup.sh; same
# rationale documented there.

set -euo pipefail

echo "==> wipe SSH host keys (sshd regenerates on first boot)"
rm -f /etc/ssh/ssh_host_*

echo "==> wipe netplan installer config from autoinstall"
# Subiquity drops a 50-cloud-init.yaml with build-time NIC config. Clones
# should get their network identity from their own cloud-init seed, not
# from this file.
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/netplan/00-installer-config.yaml

echo "==> install deferred packer-user removal as a systemd one-shot"
# The one-shot self-destructs after running, so it fires exactly once on
# the first boot of any clone (and on the base image itself if you ever
# `tart run` it directly — which is fine, the base isn't a login target).

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
After=local-fs.target
Before=cloud-init-local.service
ConditionPathExists=/usr/local/sbin/packer-cleanup.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/packer-cleanup.sh

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl enable packer-cleanup.service

echo "==> cleanup done"
