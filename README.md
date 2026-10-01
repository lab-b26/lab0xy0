# lab0xy0

A **build-once, reuse-many-times portable fuzzing laboratory** for the Arm Mali
GPU Kernel Driver (**Kbase**).

The primary deliverable is **validated, reusable environments** — not merely
documentation. The documentation exists to make those environments
**reproducible, auditable, and portable**.

## The goal

Build the required Linux kernel variants, the Kbase driver environment, a minimal
root filesystem, and the QEMU environment **once**; validate them; package them
as reusable portable artifacts; and hand them to fuzzers later **without
rebuilding the kernel or recreating the VM** for every campaign.

```text
Vendor source (r54p0 Kbase)
        ↓
Virtual-device patch set (6 Arm patches)
        ↓
Linux kernel profiles (baseline · kcov · kasan · debug)
        ↓
Kbase module
        ↓
Minimal rootfs
        ↓
QEMU/KVM environment
        ↓
Validated VM  →  portable artifact bundle
        ↓
   ┌──────────┴──────────┐
   ▼                     ▼
fuzzer A              fuzzer B        (same built target)
```

## Build-time is separate from fuzzing-time

This separation is the whole design:

```text
BUILD-TIME    compile once · validate · package · record checksums
FUZZING-TIME  unpack · boot · fuzz · repeat        (never rebuilds)
```

A fuzzing campaign must not trigger a Linux, Kbase, rootfs, or QEMU rebuild. If it
does, the artifact model in `artifacts/` has been bypassed.

## Current phase

This repository has moved past the **organisation + source-analysis** phase.
The `baseline` profile **compiles and links successfully** against
**Linux 6.12.111**: r54p0 + the six Arm patches + one research patch produce
`mali_kbase.ko` and a `bzImage`. **Nothing has been booted, loaded, or
fuzzed**, and no artifact exists. Current state is still `NOT_STARTED`
(`research/state.md`) — deliberately, because a compile is not a loaded driver
and the state checklist has not been signed off.

Getting there took three builds and three real blockers, all recorded:

| Attempt | Result | Cause |
|---|---|---|
| 6.18.54 (newest LTS) | FAILED to compile | `__SetPageMovable` removed upstream in v6.17; r54p0 calls it unguarded (**F-16**) |
| 6.12.111 | Kbase compiled, FAILED to link | `__clk_is_enabled` is only built under `CONFIG_COMMON_CLK`, which `x86_64_defconfig` leaves off (**F-17**) |
| 6.12.111 + research patch | **SUCCESS** | — (**F-18**) |

Two of the three blockers were defects in this repository's **own tooling**,
found only by executing it against a real kernel: `resolve-kernel-pin.sh` built
404 URLs from the kernel.org layout (**F-13**), and `build.sh` wrote a C comment
into a Kconfig file and then mis-read every `=n` config line (**F-14**, **F-15**).
Syntax-checking the scripts had passed on all of them.

The build ran on a GitHub Codespace used as the build host. There is deliberately
no `.devcontainer/` (F-12): create the codespace from the default image and pick
the machine size yourself. **4 cores / 16 GB** is the working configuration;
32 GB of disk is enough for one profile at a time, which is how it was run.
See `kernel/BUILD-HOST.md` and `kernel/BUILD-PLAN.md`.

Quick start on the build host:

```bash
./kernel/scripts/codespace-setup.sh --yes  # machine spec, deps, git identity,
                                           # GitHub access, gh; then preflight.sh
./kernel/scripts/resolve-kernel-pin.sh     # newest LTS from kernel.org, pin it
#   commit the pin, so the kernel choice is reproducible
./kernel/scripts/fetch-kernel.sh
./kernel/scripts/apply-patches.sh
./kernel/scripts/build.sh --profile baseline
```

`build.sh` refuses to compile unless every `CONFIG_*` in the profile fragment
actually took effect in the merged `.config` — a kernel that quietly lacks Kbase is
worse than no kernel. That check is what proves the config is honest; it cannot
see link-time failures, which is a separate class (F-17).

What *is* established (see `analysis/` and `research/`):

- **r54p0 builds and links as a module on Linux 6.12.111** (F-18) — the first
  real build in this project. Compile and link only; not loaded, not booted.
- r54p0 **cannot** build on Linux 6.17 or newer, for a specific verified API
  reason (F-16). The usable ceiling is therefore below the newest LTS, and
  6.12.111 is the newest LTS that works.
- r54p0-01eac0 inventoried and verified (441 files, GPL-2.0); the six supplied
  virtual-device patches VERIFIED to apply to it (matrix in
  `analysis/virtual-device.md`).
- Arm program scope, configuration allowlist, and discovery-vs-validation rule
  captured in `research/program-scope.md`.
- Kernel-compatibility analysis and Arm's "latest stable/LTS" guidance recorded
  (`analysis/kernel-compatibility.md`); the version is now **decided by build
  evidence** — the newest LTS does not work, and 6.12.111 does.
- Findings F-1 … F-18 in `analysis/findings.md`, including the three
  build-blocking issues and the first positive build result.

## Layout

| Path | Contents |
|---|---|
| `vendor/arm/` | primary r54p0 archive, checksums, provenance |
| `patches/virtual-device/` | the six supplied Arm patches (byte-preserved) |
| `analysis/` | source inventory, version, kernel-compat, Kconfig deps, findings |
| `research/` | program scope, methodology, test matrix, state, Arm documents |
| `kernel/` | build plan, build-host requirements, config fragments, pin file, build scripts |
| `qemu/` | QEMU environment design (scripts + minimal rootfs) |
| `syzkaller/` | planned fuzzer integration (independent of the artifact) |
| `artifacts/` | portable artifact model and validation states |
| `tools/scripts/` | shared integrity / config-delta helpers |

## Evidence discipline

Every technical statement is labelled `VERIFIED`, `INFERRED`, `UNKNOWN`,
`NOT_TESTED`, `FAILED`, `PLANNED`, or `DISCOVERY-ONLY`. Source-level compatibility
is not proven build support; a version gate is not a support claim; a
virtual-device result is not a production-device result; a build-system defect is
not a security vulnerability; and an instrumented-harness crash is not an eligible
finding. See `research/methodology.md`.

## Scope

This project targets **Kbase only** (Intigriti Tier 3, $500–$10,000). The CSF
firmware (`CSFFW`, Tier 2) is not a target here because no firmware blob is
present. The authoritative, date-stamped program scope — including the kernel
configuration allowlist, the 64-bit requirement, and the excluded surfaces — is
`research/program-scope.md`; other documents reference it rather than restate it.

## Licence and vendor material

This project's own documentation and tooling are GPL-2.0 (`LICENSE`), matching the
GPL-2.0 Kbase source. Arm's archives, PDFs, and supplied patches are Arm's
copyright, preserved byte-for-byte, held for research/reference only, and not
redistributed outside this repository.