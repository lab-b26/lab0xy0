# QEMU environment

Part of the **product** of this repository, not just a build tool. The goal is to
build the QEMU-side environment once, validate it, package it, and reuse it with
multiple fuzzers — never rebuild QEMU or recreate the VM per campaign.

```text
build QEMU-side environment once
        ↓
validate
        ↓
package  (→ artifacts/, portable bundle)
        ↓
reuse with multiple fuzzers
```

## Design principles

- **Profile-agnostic setup.** One QEMU launch wrapper serves `baseline`, `kcov`,
  `kasan`, and `debug` by selecting a prebuilt kernel image + module bundle, not by
  reconfiguring the VM. Each profile's kernel and Kbase modules come from
  `artifacts/`.
- **Repository-relative references.** No hard-coded host paths. The wrapper resolves
  artifacts relative to the repo (or an explicit artifact path passed on the
  command line), so an artifact bundle can be relocated and still run.
- **No rebuilds at fuzzing time.** QEMU itself, the rootfs, and the per-profile
  images are built once and reused. BUILD-TIME is separated from FUZZING-TIME
  (see `../README.md`).
- **KVM-aware but not KVM-dependent.** `/dev/kvm` exists on this host (VERIFIED),
  so hardware acceleration is available; the wrapper should still work (slowly)
  under TCG so a validated artifact remains usable on a host without KVM.

## Current status

```text
QEMU build:        not built from source — the host's qemu-system-x86_64 is used
QEMU package:      none (no artifact packaged yet)
boot validation:   VERIFIED for baseline + kasan — see ../../research/boot-logs/
```

Boot validation is real, not aspirational: `baseline` and `kasan` each boot to
`/init`, `insmod mali_kbase.ko` with rc=0, and drive the EL0 ioctl surface to
`passed=0x1ff failed=0x000`. Evidence and the two undocumented ioctl contracts it
uncovered are in F-19 of `../../analysis/findings.md`. Per DECISION-1 all of it is
DISCOVERY-ONLY.

Per the project spec, QEMU is **not** built or booted in this organisation phase.
This directory now contains working scripts. They consume prebuilt components and
never download or build anything themselves.

## Layout

| Path | Purpose |
|---|---|
| `README.md` | this file — goal and design |
| `scripts/` | launch/verify wrappers (repo-relative, profile-agnostic) — EXISTS, see `scripts/README.md` |
| `rootfs/` | minimal rootfs builder — EXISTS, see `rootfs/README.md` |
| `target/` | `kbase-probe.c`, the EL0 ioctl exerciser (source only; the compiled binary is a build output and is gitignored) |

## Launch flow

```bash
# select a prebuilt, packaged profile artifact and boot it
qemu/scripts/run.sh --profile <baseline|kcov|kasan|debug> [--artifact <path>]

# or assert the whole sequence and get a bitmask exit status
qemu/scripts/verify-boot.sh --profile <baseline|kcov|kasan|debug>
```

The wrapper does, in order: resolve the artifact bundle (`--artifact`, else
`artifacts/<profile>`, else `build/<profile>`); pick `bzImage` for the profile;
use the profile's `rootfs-<profile>.cpio.gz` (which already embeds that profile's
`mali_kbase.ko`); attach the serial console as the control channel; and use
`-enable-kvm` only if `/dev/kvm` is actually *usable* by this user, otherwise fall
back to TCG with `-cpu max`. No step rebuilds anything.

## Portability

The QEMU-side environment is portable only together with the rest of the
artifact. It is not considered validated until the full procedure in
`../artifacts/README.md` (portability validation) passes from a clean location
with the original build tree inaccessible.

## Still open

- Exact QEMU version to pin (must be recorded in the artifact manifest). The host
  binary is used as-is today; the pin is not yet recorded.
- Guest networking for the fuzzer control channel (serial vs virtio-net vs vsock).
  Serial is the current candidate; nothing fuzzer-facing is built yet.
- Memory/CPU sizing. Measured: `-m 2048 -smp 4` boots in ~2 s of guest time on
  KVM, which is ample for this harness.