# CLAUDE.md — Apple Silicon VM lab

> **Purpose.** Persistent project context for Claude Code working in this repo. Read this before suggesting structural changes. A sibling repo (`homelab`) already exists for the x86_64 Proxmox side; the patterns there inform this one, but the architecture is ARM-native and the Windows pipeline diverges significantly (see [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md)).

---

## What this repo is

Infrastructure-as-code for building reproducible **Ubuntu 24.04 ARM64** and **Windows 11 ARM64** VM images that run on Apple Silicon MacBooks. The output is a versioned image artifact per OS that can be launched on demand for development, testing, and throwaway experiments.

Companion to the x86_64 `homelab` repo (Proxmox cluster + Packer templates). That repo's design decisions inform this one but the architecture is different (ARM64, no shared cluster storage, no Terraform/OpenTofu layer, no per-role VM tree).

---

## Host machine

Built and verified on a MacBook Pro M2 Max with 96 GB RAM. Apple Silicon (ARM64) is required for both pipelines — Tart relies on Apple Virtualization.framework, and the Windows build uses QEMU's `hvf` accelerator which is Apple-Silicon-only on macOS. Anything x86_64 will run under emulation and is out of scope.

---

## Tool decisions

These are the calls I've already made. Don't relitigate them in the scaffolding pass; surface alternatives only if you hit an actual blocker.

### Use

- **Packer** for image builds. Same shape as the `homelab` repo's `packer/*/` directories — HCL sources, a `provision/` directory for post-install scripts, an env-driven wrapper script per target.
- **Tart** (`cirruslabs/tart`) as the Ubuntu builder + runtime. ARM-native, uses Apple's Virtualization.framework, has a first-class Packer plugin (`packer-plugin-tart`). Produces versioned VM images that `tart run` launches directly. Designed for CI but works locally.
- **Packer's `qemu` source + `qemu-system-aarch64` + `swtpm`** as the Windows builder. Tart can't host Windows — not just because of TPM/Secure Boot (the original blocker) but also because Apple Virtualization.framework only exposes virtio buses to non-macOS guests and ARM Win11 WinPE has no in-box virtio-blk driver, so the install can't read the boot media. QEMU sidesteps both via `swtpm` for TPM 2.0, `edk2` for UEFI, and a wrapper script that rewrites `media=cdrom` drives to `usb-storage` form so WinPE's in-box xHCI stack can read them. Output is a qcow2; see [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md) for the full diagnostic history.
- **UTM** as the interactive front-end for the Windows qcow2 the Packer build produces. UTM ships TPM 2.0 and Secure Boot natively and is the right tool for snapshot/clone management of an installed Windows VM.

### Skip

- **OpenTofu / Terraform** — overkill for laptop VMs. No fleet, no shared storage, no networking to manage. Packer + a shell wrapper is the right size.
- **VirtualBox** — developer preview on Apple Silicon; x86_64 guests are emulated (unusable for daily work); ARM64 support is incomplete. Don't add a VBox builder.
- **Vagrant** — works but adds a layer over Packer/Tart for no win at this scale.
- **OrbStack** — great for containers and lightweight Linux VMs but not aimed at programmatic image templating.
- **Cross-arch (x86_64) builds** — explicitly out of scope. If a guest must be x86_64, use the `homelab` Proxmox cluster instead.

### Defer (mention but don't scaffold)

- **Parallels Desktop** Packer builder. Excellent Windows-on-ARM experience but requires a paid license; only add if the QEMU+swtpm path regresses (it works as of 2026-05-13).
- **VMware Fusion** Packer builder. Free for personal use; viable fallback for the same scenario.

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
   - `windows.pkr.hcl` — single `qemu` source (not `tart-cli` — Tart can't host Windows; see the "Decision history" section below). Targets the public Win11 24H2 ARM64 ISO from Microsoft. `qemu_binary` points at a wrapper script (`scripts/qemu-with-tpm.sh`) that injects TPM + ramfb + USB + usb-storage CD rewrites.
   - `Autounattend.xml` — fresh, ARM64-targeted. **Do not copy the homelab `Autounattend.xml`**; it's x86_64-specific (driver paths, SKU index, partition layout). The *philosophy* of the homelab Windows provisioners (Defender tuning, OneDrive removal, sysprep at the end) carries over.
   - `drivers/` — populated at build time by the wrapper from `virtio-win.iso`. Staging tree is gitignored; `.gitkeep` + `README.md` are tracked.
   - `provision/` — five PowerShell scripts (00 wait-for-winrm, 15 cleanup, 20 harden [stub], 30 cloudbase-init [stub], 99 sysprep).
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

**This is a public GitHub repo** ([github.com/bbirkinbine/mac-vms](https://github.com/bbirkinbine/mac-vms)). Everything you write here is world-readable — file contents, commit messages, branch names, PR descriptions, and issue comments. Treat it accordingly.

- Never commit `.env.*` (gitignored — verify before staging).
- No real passwords in `Autounattend.xml`. A build-only password like `packer-build-only-Win11!` is fine; it gets rotated by sysprep.
- Credential flow defaults to "read from `.env.local` at invocation time" — `.env.local` is gitignored and assumed to come from your local secret manager. Don't default to 1Password CLI, Vault, or SOPS; those are options, not the current shape.
- Any Packer variable that takes a secret must use `sensitive = true` and be passed via `PKR_VAR_*` env vars from the wrapper script.
- **Commit messages, branch names, and PR/issue text are public too.** Don't reference internal hostnames, coworker names, ticket IDs from private trackers, or path fragments from unrelated private repos. If a diagnostic detail is load-bearing for the commit, scrub identifying bits before writing the message.
- No internal URLs, Slack links, private Linear/Jira IDs, or paths under `~/` that leak user/org structure in code comments or docs either — same surface, same rules.

---

## Git commit conventions

- **No `Co-Authored-By:` trailers.** Do not add a Claude / Anthropic / AI co-author trailer to commit messages in this repo, even though the Claude Code default tells you to. The user is the sole author; AI assistance is acknowledged in the README and doesn't need per-commit attribution on a public repo. This overrides the default `Co-Authored-By: Claude ... <noreply@anthropic.com>` footer.
- **No "Generated with Claude Code" footer** in commit messages or PR bodies for the same reason. Acknowledgement lives in [`README.md`](README.md), not on every commit.
- Match the existing log style: lowercase, terse, scope-then-summary (`README/CLAUDE: ...`, `add run-windows probe; fix UTM Virtualize→Emulate`). No conventional-commits prefixes (`feat:`, `fix:`, `chore:`) — they're not the style here.
- Body paragraphs are fine when the *why* is non-obvious; skip them when the subject line is self-explanatory.

---

## Style preferences

Match the homelab repo's tone.

- Substantive comments where *why* is non-obvious. Terse where it's obvious.
- One-line summary at the top of every `.ps1` / `.sh` provisioner saying what it does.
- HCL gets `//` comments on non-obvious lines (why these CPU/RAM defaults, why this specific Tart base image for Ubuntu, why the qemu wrapper script approach for Windows).
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

The Windows pipeline went through several pivots before reaching the
current working shape. Before making changes there, read
[`docs/windows-build-attempts.md`](docs/windows-build-attempts.md) — it
captures, in chronological order:

- Why Tart can't host Win11 — three layered blockers (no Windows VM configuration in Tart's source, no TPM in Apple Virtualization.framework, AVF only exposes virtio buses to non-macOS guests and ARM WinPE has no in-box viostor).
- Why the Tart `vm_base_name` shortcut doesn't apply (no prebuilt Windows base from cirruslabs).
- Why UTM is the recommended interactive consumption path for the Packer-built qcow2.
- Six original QEMU/macOS plumbing gotchas resolved (the cheat-sheet table).
- The "CD-ROM bus problem" — ARM `virt` has no IDE/SATA controller, so the qemu wrapper rewrites every `media=cdrom` drive to `usb-storage` form; otherwise WinPE can't read the install ISO or the unattend CD pre-injection.
- USB enumeration order — the install ISO's usb-storage device must precede virtio-win.iso's so EDK2 auto-boots the right device.
- The five-wall closing diagnostic (2026-05-13): CD-ROM bus → USB enum order → Win11 hardware-requirements check (LabConfig bypass in unattend) → NetBIOS computer-name 15-char cap → sysprep WinRM-disconnect exit code 16001.

Build is verified end-to-end as of 2026-05-13: ~16 min wall-clock on M2 Max producing a sysprep'd qcow2 in `packer/windows-11-arm64/output-windows-11-arm64/`. The Ubuntu side has no equivalent decision-history doc because it works end-to-end with no significant pivots.

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
