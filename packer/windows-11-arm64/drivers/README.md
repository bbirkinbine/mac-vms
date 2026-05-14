# drivers/

Populated at build time by `scripts/build-windows.sh`. The wrapper mounts
`virtio-win.iso` (path from `VIRTIO_WIN_ISO_PATH`) and copies the ARM64
WinPE-critical drivers into `drivers/staging/<driver>/`:

```
drivers/
  README.md         (this file)
  .gitkeep          (so the directory exists at packer-validate time)
  staging/
    viostor/        virtio-blk storage driver
    vioscsi/        virtio-scsi storage driver (covers future bus changes)
    NetKVM/         virtio-net network driver (FirstLogonCommands needs this)
```

The `windows.pkr.hcl` `cd_files` list includes `./drivers/`, so the staging
tree is packed into the same auto-built CD that carries `Autounattend.xml`.
WinPE assigns that CD a drive letter dynamically; `Autounattend.xml`'s
`Microsoft-Windows-PnpCustomizationsWinPE` block lists multiple candidate
drive letters so the injection resolves regardless of enumeration order.

The staging directory contents are gitignored (`drivers/staging/`).
