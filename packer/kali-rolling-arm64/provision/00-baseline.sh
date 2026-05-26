#!/usr/bin/env bash
# 00-baseline.sh — minimal post-install baseline for the Kali base image.
#
# Runs once after the d-i preseed install completes and the VM reboots
# into the freshly-installed OS. Responsibilities: wait for the install's
# own first-boot cloud-init to finish, wait for any apt/dpkg locks to
# clear, then run a single apt update/upgrade. Image sealing (cloud-init
# clean, machine-id wipe, SSH host key wipe, deferred packer-user
# removal, etc.) all live in 99-cleanup.sh.
#
# Anything role-specific belongs downstream (cloud-init at clone time,
# Ansible, or per-VM provisioners), not here.
#
# Lifted with no behavioural change from this repo's
# packer/ubuntu-24-04-arm64/provision/00-baseline.sh — Debian-derived
# plumbing is identical.

set -euo pipefail

echo "==> waiting for cloud-init to finish"
cloud-init status --wait || true

# Even after cloud-init reports done, apt's unattended-upgrades timer
# may still be ramping up. If apt-get below races it, we deadlock on
# dpkg's lock. Sleep briefly to let the timer fire if it's going to,
# then poll the actual lock files until they're free. fuser is what
# apt itself uses to detect contention — no false positives from
# orphan parent shells, no false negatives from systemd-run wrappers.
sleep 15
LOCKS=(
  /var/lib/dpkg/lock-frontend
  /var/lib/dpkg/lock
  /var/lib/apt/lists/lock
)
TIMEOUT=600
for i in $(seq 1 "$TIMEOUT"); do
  busy=0
  for lock in "${LOCKS[@]}"; do
    if [ -e "$lock" ] && fuser "$lock" >/dev/null 2>&1; then
      busy=1
      break
    fi
  done
  if [ "$busy" -eq 0 ]; then
    echo "==> apt/dpkg locks free after ${i}s"
    break
  fi
  sleep 1
done
if [ "$busy" -ne 0 ]; then
  echo "WARN: apt/dpkg locks still held after ${TIMEOUT}s; dumping holders before continuing."
  for lock in "${LOCKS[@]}"; do
    [ -e "$lock" ] || continue
    echo "  $lock:"
    fuser -v "$lock" 2>&1 | sed 's/^/    /' || true
  done
fi

echo "==> apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# Plain `upgrade`, not `full-upgrade` / `dist-upgrade`. Repo policy:
# full-upgrade can remove packages on an unattended build (kali-rolling
# is a moving target, so this risk is real here in a way it isn't on
# Ubuntu LTS).
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "==> cleaning apt caches"
apt-get autoremove -y
apt-get clean

echo "==> baseline complete"
