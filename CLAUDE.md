# CLAUDE.md — Apple Silicon VM lab

> **Purpose.** Persistent project context for Claude Code working in this repo. Read this before suggesting changes or scaffolding files. This is a *fresh* repo — the first task is to lay down the skeleton described below. A sibling repo (`homelab`) already exists for the x86_64 Proxmox side; reuse the patterns from there but do not copy code blindly.

---

## What this repo is

Infrastructure-as-code for building reproducible **Ubuntu 24.04 ARM64** and **Windows 11 ARM64** VM images that run on Apple Silicon MacBooks. The output is a versioned image artifact per OS that can be launched on demand for development, testing, and throwaway experiments.

Companion to the x86_64 `homelab` repo (Proxmox cluster + Packer templates). That repo's design decisions inform this one but the architecture is different (ARM64, no shared cluster storage, no Terraform/OpenTofu layer, no per-role VM tree).

---

## Host machines

Two MacBook Pro workstations. Either can build and run images.

- **Personal M2 Max, 96 GB RAM** — primary build host; bigger memory ceiling for heavier guests.
- **Work M4 Max, 64 GB RAM** — secondary; may have MDM restrictions on hypervisor install (check before assuming Parallels or VMware Fusion is available).

Both are ARM64. Anything x86_64 will run under emulation and is out of scope.

---

## Tool decisions

These are the calls I've already made. Don't relitigate them in the scaffolding pass; surface alternatives only if you hit an actual blocker.

### Use

- **Packer** for image builds. Same shape as the `homelab` repo's `packer/*/` directories — HCL sources, an `http/` directory for installer config, a `provision/` directory for post-install scripts, an env-driven wrapper script per target.
- **Tart** (`cirruslabs/tart`) as the primary builder + runtime. ARM-native, uses Apple's Virtualization.framework, has a first-class Packer plugin (`packer-plugin-tart`). Produces versioned VM images that `tart run` launches directly. Designed for CI but works locally.
- **UTM** as the interactive/visual alternative when a guest needs a window manager and hand-driving. UTM consumes qcow2 from Packer's `qemu` builder if Tart doesn't fit a use case.

### Skip

- **OpenTofu / Terraform** — overkill for laptop VMs. No fleet, no shared storage, no networking to manage. Packer + a shell wrapper is the right size.
- **VirtualBox** — developer preview on Apple Silicon; x86_64 guests are emulated (unusable for daily work); ARM64 support is incomplete. Don't add a VBox builder.
- **Vagrant** — works but adds a layer over Packer/Tart for no win at this scale.
- **OrbStack** — great for containers and lightweight Linux VMs but not aimed at programmatic image templating.
- **Cross-arch (x86_64) builds** — explicitly out of scope. If a guest must be x86_64, use the `homelab` Proxmox cluster instead.

### Defer (mention but don't scaffold)

- **Parallels Desktop** Packer builder. Excellent Windows-on-ARM experience but requires a paid license; only add if Tart's Windows path proves rocky.
- **VMware Fusion** Packer builder. Free for personal use now; viable fallback if Tart blocks.

---

## Initial scaffolding ask

When the user kicks off scaffolding, produce the following in one pass. Stop and confirm before generating any provisioner scripts longer than ~30 lines, or before adding a second builder source per OS.

1. **`README.md`** — human-facing, GitHub landing page. Repo purpose, the two host machines, quick-start for each OS image, link to this file for deeper context. Match the depth of the `homelab` repo's README (full quick-start, prerequisites, gotchas — not a 20-line stub).
2. **`.gitignore`** — ignore `.env.*` with a `!.env.*.example` whitelist (same pattern as `homelab`); ignore `output-*/`, `*.tart`, `packer_cache/`, `.DS_Store`.
3. **`Justfile`** — top-level orchestration: `just build-ubuntu`, `just build-windows`, `just validate`, `just clean`. Mirror the homelab `Justfile` shape.
4. **`packer/ubuntu-24-04-arm64/`**
   - `ubuntu.pkr.hcl` — single `tart-cli` source targeting ARM64 Ubuntu 24.04 server ISO; provisioner pipeline parallel to the homelab Ubuntu config.
   - `http/user-data` + `http/meta-data` — cloud-init autoinstall. **Lift from the homelab repo** (`packer/ubuntu-24-04-base/http/user-data`); the autoinstall schema is arch-agnostic. Adjust only the bits that are arch-specific (kernel package names, if any).
   - `provision/` — placeholder for a single `00-baseline.sh` (qemu-guest-agent equivalent, package updates, cloud-init clean). Don't port every script from homelab; start minimal and grow on demand.
   - `variables.pkr.hcl` — ISO URL/checksum, VM specs (CPUs, RAM, disk), image output name.
   - `README.md` — quick-start, prerequisites (Tart installed, Packer + plugin installed), validation steps, image-run instructions.
5. **`packer/windows-11-arm64/`**
   - `windows.pkr.hcl` — single `tart-cli` source targeting Windows 11 ARM64. (The Microsoft Windows Insider ARM64 VHDX is the usual source; document the download step in the README — do not commit the VHDX.)
   - `Autounattend.xml` — fresh, ARM64-targeted. **Do not copy the homelab `Autounattend.xml`**; it's x86_64-specific (driver paths, SKU index, partition layout). The *philosophy* of the homelab Windows provisioners (Defender tuning, OneDrive removal, sysprep at the end) is worth carrying over once the base install works.
   - `provision/` — empty placeholder for `.ps1` provisioners; do not write them in the first pass.
   - `variables.pkr.hcl`, `README.md` — same shape as the Ubuntu directory.
6. **`scripts/`**
   - `build-ubuntu.sh` — env-driven wrapper that sources `.env.local`, validates Tart + Packer are installed, runs `packer init` / `validate` / `build`. Same shape as homelab's `build-pve.sh`: fail loud, validate preconditions up front, no branching dispatcher.
   - `build-windows.sh` — sibling script. Separate file, not a dispatcher.
7. **`.env.local.example`** — empty template for any env vars the wrappers expect.
8. **`docs/`** — empty for now; the README handles first-time setup. Add docs as components grow.

---

## What to lift from the `homelab` repo

The user keeps `homelab` checked out alongside this repo. Direct lifts (with minor tweaks):

- `packer/ubuntu-24-04-base/http/user-data` — autoinstall config; arch-agnostic.
- The wrapper-script shape from `packer/ubuntu-24-04-base/build-pve.sh` — env validation, fail-fast preconditions, no branching.
- The `Justfile` orchestration pattern.
- The validation-gate habit from `homelab/CLAUDE.md` — run `packer init/fmt/validate`, `bash -n` on shell scripts, `xmllint --noout` on any unattend XML before claiming a change is ready.
- The `.gitignore` `.env.*` + `!.env.*.example` whitelist.

Do **not** lift:

- Anything Proxmox-API-shaped (token plumbing, `proxmox-iso` source, `pve` env vars).
- `packer/windows-11-base/Autounattend.xml` — x86_64-specific in load-bearing ways.
- `modules/proxmox-vm/` or any OpenTofu — out of scope here.
- Per-role `vms/*/` structure — this repo produces base images, not per-role VMs.

---

## Secrets and public-repo hygiene

This will be a public GitHub repo. Treat it accordingly.

- Never commit `.env.*` (gitignored — verify before staging).
- No real passwords in `Autounattend.xml`. A build-only password like `packer-build-only-Win11!` is fine; it gets rotated by sysprep.
- The user's secret store is **KeePassXC unlocked with a YubiKey** (backup YubiKey enrolled). When suggesting credential flows, default to "read from `.env.local` at invocation time" or "fetch from KeePassXC at run time." Don't default to 1Password CLI, Vault, or SOPS — those are options, not the current shape.
- Any Packer variable that takes a secret must use `sensitive = true` and be passed via `PKR_VAR_*` env vars from the wrapper script.

---

## Style preferences

Match the homelab repo's tone.

- Substantive comments where *why* is non-obvious. Terse where it's obvious.
- One-line summary at the top of every `.ps1` / `.sh` provisioner saying what it does.
- HCL gets `//` comments on non-obvious lines (why these CPU/RAM defaults, why this specific Tart base image, why two separate wrapper scripts).
- READMEs are full quick-start + prerequisites + validation + gotchas. No 20-line stubs.
- Avoid emojis in repo files.
- Avoid the words *genuinely*, *straightforward*, *actually* in prose.
- Direct, technical tone.

---

## Validation gates before claiming done

```bash
# Packer
packer init .
packer fmt -check .
packer validate .

# Shell
bash -n scripts/*.sh
shellcheck scripts/*.sh   # if installed

# XML
xmllint --noout packer/windows-11-arm64/Autounattend.xml
```

Don't claim a build is "ready" without at least:

1. A clean `packer validate` for the affected source.
2. A clean `bash -n` on every shell script touched.
3. An updated README if the change affects how the build runs.

The user validates reproducibility by re-running the build themselves on a clean clone. Treat "the code parses" as table stakes, not as proof of working.

---

## Decision history (read this before touching the Windows pipeline)

The Windows pipeline has been through several pivots that ruled out the obvious-looking approaches. Before making changes there, read [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md) — it captures:

- Why Tart can't host Win11 (no TPM 2.0 / Secure Boot exposed by Apple Virtualization.framework).
- Why the Tart `vm_base_name` shortcut doesn't apply (no prebuilt Windows base from cirruslabs).
- Why UTM is documented as the active Windows path despite being interactive-only.
- Six QEMU/macOS plumbing gotchas already resolved (don't relive them).
- The remaining wall — Win11 24H2 ARM64 WinPE has no in-box driver matching any QEMU storage controller, and 24H2 Setup ignores `Microsoft-Windows-PnpCustomizationsWinPE` driver injection per the homelab x86 build's findings.
- The one viable continuation path — custom-rolled install ISO with virtio drivers pre-injected into `boot.wim` / `install.wim` via DISM or wimlib — and what to verify early if anyone takes it on.

The Ubuntu side has no equivalent decision-history doc because it works end-to-end with no significant pivots.

---

## Out of scope

Don't add these without being asked first:

- x86_64 guests (use the `homelab` Proxmox cluster).
- macOS guests (licensing constraints; not the goal here).
- Kubernetes / k3s manifests.
- CI/CD pipelines. The lab is small enough that `just build-ubuntu` from a laptop is the loop.
- Public-cloud infrastructure.
- A second hypervisor backend (VMware Fusion, Parallels) until Tart proves insufficient.
- Application code. This repo produces base images; downstream use is out of scope.

If a task seems to want any of the above, surface it and ask before adding files.
