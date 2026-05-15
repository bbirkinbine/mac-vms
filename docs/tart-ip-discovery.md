# `tart ip` discovery on Ubuntu 24.04 clones

## Background

Ubuntu 24.04's `systemd-networkd` defaults to sending an RFC 4361 DUID-based
DHCP client identifier (option 61). macOS's `bootpd` (the vmnet DHCP server)
records each lease in `/var/db/dhcpd_leases` with a `hw_address` field that's
supposed to be the guest's MAC, but in practice macOS puts the DHCP client
identifier verbatim into both `identifier=` *and* `hw_address=`. With a
DUID-shaped identifier, `hw_address` becomes a 17-byte string like
`ff,f1:f5:dd:7f:0:2:0:0:ab:11:...` — which doesn't contain the guest's
6-byte MAC anywhere.

Tart's `tart ip <vm>` looks up the VM's MAC in `hw_address`. No match, so
`tart ip` returns:

```text
no IP address found
```

…even though the VM has booted cleanly and is reachable via SSH.

This is documented upstream: see
[cirruslabs/tart#912](https://github.com/cirruslabs/tart/issues/912) for the
diagnosis and
[cirruslabs/linux-image-templates#39](https://github.com/cirruslabs/linux-image-templates/pull/39)
for Tart's own fix in their official Linux base images.

## What this repo does about it

[`packer/ubuntu-24-04-arm64/provision/99-cleanup.sh`](../packer/ubuntu-24-04-arm64/provision/99-cleanup.sh)
installs `/etc/cloud/cloud.cfg.d/99-mac-vms-dhcp.cfg` into the base image:

```yaml
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp-identifier: mac
```

That tells `systemd-networkd` (via netplan) to send the guest's MAC as the
DHCP client identifier instead of a DUID. macOS's `bootpd` then records a
lease whose `hw_address` is a normal 6-byte MAC (`1,<mac>` form), and Tart's
lease lookup matches it. `tart ip <vm>` works.

This is the same shape as Tart's upstream fix, just packaged into our
Packer base image rather than pulled from `ghcr.io/cirruslabs/ubuntu`.

A clone is free to override this — anything supplying a `network-config`
on the cidata seed merges later in cloud-init's network-config resolution,
so a per-VM network override (custom interface name, static IP, IPv6
preferences, etc.) still wins.

## If you hit `no IP address found` anyway

Most likely cause now: the image predates this fix. Rebuild:

```bash
just clean && just build-ubuntu
```

…or if you're consuming a base image you didn't build yourself (e.g. a
`tart pull` from a registry that didn't apply this), drop the same file
manually into the running VM:

```bash
ssh <user>@<vm> "sudo tee /etc/cloud/cloud.cfg.d/99-mac-vms-dhcp.cfg <<'EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: \"en*\"
      dhcp4: true
      dhcp-identifier: mac
EOF
sudo cloud-init clean --logs
sudo reboot"
```

After reboot, macOS will register a new lease keyed on the MAC and `tart ip`
will start working.

## Falling back without the fix

If you can't or won't apply the cloud-init override, two read-only paths to
the IP from the host:

```bash
# Lease database — match on the cloud-init-set hostname (from your seed yaml).
awk -v RS='}' -v ORS='}\n' '/name=<vm-name>/' /var/db/dhcpd_leases \
  | awk -F= '/ip_address/ {print $2}'

# ARP table on the vmnet bridge.
arp -an | grep bridge100 | grep -v 'ff:ff:ff:ff:ff:ff'
```

Then `ssh <user>@<ip>` directly. Both methods read state macOS already has;
neither requires Tart cooperation.
