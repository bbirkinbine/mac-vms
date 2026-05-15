# Tart `tart ip` doesn't discover Ubuntu 24.04 clones

## Symptom

After cloning a Tart VM from the Ubuntu 24.04 ARM64 base image (with or
without a cidata seed), `tart ip <vm>` returns:

```
no IP address found
```

…even though the VM has fully booted, run cloud-init successfully, acquired
a DHCP lease, and is reachable via SSH from the host.

## Diagnosis

macOS's `bootpd` (the vmnet DHCP server) records DHCP leases in
`/var/db/dhcpd_leases`. Each entry's `hw_address` is the DHCP **client
identifier** (DHCP option 61) the guest sent — *not* always the guest's MAC.

Ubuntu 24.04's `systemd-networkd` defaults to a DUID-based client identifier
per RFC 4361. The lease record then looks like:

```
{
    name=null
    ip_address=192.168.64.16
    hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:d2:26:7:2c:9e:a4:c1:1e
    identifier=ff,f1:f5:dd:7f:0:2:0:0:ab:11:d2:26:7:2c:9e:a4:c1:1e
    lease=0x6a0745b8
}
```

That `hw_address` is 17 bytes (1-byte type `ff,` indicating RFC 3315 DUID +
16-byte DUID). It does **not** contain the VM's MAC. The macOS bridge ARP
table separately maps the VM's MAC to the IP:

```
% arp -an | grep bridge100
? (192.168.64.16) at fe:cf:55:da:65:8f on bridge100 ifscope [bridge]
```

Tart's `tart ip` looks up the VM's MAC (`fe:cf:55:da:65:8f`) against
`hw_address` in `dhcpd_leases`. Since the lease uses the DUID form, no match.

Older Ubuntu releases (22.04 and earlier) and many other distros default to
the simpler form `hw_address=1,<6-byte-MAC>`, which Tart handles. That's
why the issue is new with the 24.04-based image.

## Workarounds

### 1. Read the lease file directly

```bash
grep -B1 -A3 "name=<vm-name>" /var/db/dhcpd_leases | \
  awk -F= '/ip_address/ {print $2}'
```

If multiple leases share a hostname (e.g. several `null` clones over time),
the most recent block in the file wins.

### 2. Look it up via the bridge ARP table

```bash
arp -an | grep bridge100 | grep -v 'ff:ff:ff:ff:ff:ff'
```

You'll see one line per running VM. Match the VM's MAC if you know it.

### 3. Once you know the IP, SSH directly

```bash
ssh <user-from-seed>@<ip>
```

If the seed provided an SSH key, this works immediately.

## Possible permanent fixes (not currently applied)

Two paths exist. Neither is applied because each has tradeoffs:

1. **Configure systemd-networkd in the Packer base image to use the
   MAC-based client identifier.** Drop a file like
   `/etc/systemd/network/10-mac-client-id.network` setting
   `[DHCPv4] ClientIdentifier=mac`. After this, leases use the
   `1,<MAC>` form Tart already understands. Tradeoff: loses RFC 4361's
   IP-stable-across-MAC-change property (which matters if you ever change
   the VM's MAC but want the same lease back — uncommon for our use case).

2. **File an upstream issue with Tart** to teach the lease-lookup code
   about RFC 4361 DUID-form `hw_address` values. Tart would have to walk
   the DUID encoding, extract the LL/LLT-shaped MAC if present, and match.
   Out of our hands but the cleaner long-term fix.

Until either lands, treat the workarounds above as the supported path.
