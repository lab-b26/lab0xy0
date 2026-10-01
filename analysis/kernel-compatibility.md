# Kernel compatibility — Kbase r54p0

## Headline

```text
VERIFIED OBSERVED VERSION-GATE RANGE: 3.17.0  →  6.13.0   (r54p0, 44 distinct gates)

VERIFIED BUILD RESULT:  6.12.111  compiles AND links (findings.md F-18)
VERIFIED BUILD FAILURE: 6.18.54   does not compile (findings.md F-16)
Pinned kernel:           6.12.111
```

The observed range is **not** a support statement. See "What this range does and
does not mean" below. What the two builds add is a *real* boundary, and it does
not coincide with the highest gate: the driver stops compiling at 6.17, four
versions above its own highest `KERNEL_VERSION` test, because it calls an API
that was removed without a gate around it. That is the clearest available
demonstration of the rule in `../research/methodology.md`: **a version gate is
not a ceiling, and it is not a support claim.**

## Method

Searched the entire r54p0 payload for `KERNEL_VERSION`, `LINUX_VERSION_CODE`,
`LINUX_VERSION_CODE`, and bare `LINUX_VERSION`.

| Metric | Value | Status |
|---|---|---|
| Distinct `KERNEL_VERSION(a,b,c)` conditionals | **44** | VERIFIED |
| Total `LINUX_VERSION_CODE` references | **234** | VERIFIED |
| Bare `LINUX_VERSION` (non-`_CODE`) references | **0** | VERIFIED |
| Lowest gate | `KERNEL_VERSION(3,17,0)` | VERIFIED |
| Highest gate | `KERNEL_VERSION(6,13,0)` | VERIFIED |
| Gate majors present | 3, 4, 5, 6 | VERIFIED |

> Correction: the range `3.17.0 → 6.18.0` given in the project brief is the
> **r56p0** span (48 gates). For the r54p0 primary target the verified span is
> **3.17.0 → 6.13.0**.

## Where the version gates actually live

Nearly all are concentrated in one compatibility shim, which is how the driver
supports such a wide range:

```text
include/linux/version_compat_defs.h
```

This file provides fallback `static inline` definitions for kernel APIs that do
not exist on older kernels, each wrapped in `KERNEL_VERSION` guards. Most recent
gates in r54p0 are here: `6,1,0` `6,1,25` `6,3,0` `6,4,0` `6,5,0` `6,6,0` `6,7,0`
`6,10,0` `6,12,0` `6,13,0`.

Gates elsewhere include `KERNEL_VERSION(4,13,0)` around `<linux/set_memory.h>`
inclusion (seen in `mali_kbase_csf_firmware_no_mali.c:44`, patched by 0002) and
version-conditional includes across the `csf/` and `mmu/` backends.

## Notable gates relevant to the virtual-device path

| Gate | Location | Relevance |
|---|---|---|
| `KERNEL_VERSION(4,13,0)` | `csf/mali_kbase_csf_firmware_no_mali.c:44` | guards `<linux/set_memory.h>`; No-MALI firmware stub |
| `KERNEL_VERSION(4,15,0)` | `version_compat_defs.h:566` | the guard patch **0001** changes |
| `KERNEL_VERSION(6,6,0)` | `version_compat_defs.h:558` | `of_changeset_add_prop_u32` fallback |

### Patch 0001 and the version guard

Patch 0001 rewrites the guard at `version_compat_defs.h:566` from:

```c
#if KERNEL_VERSION(4, 15, 0) <= LINUX_VERSION_CODE
```

to:

```c
#if KERNEL_VERSION(4, 1, 0) > LINUX_VERSION_CODE
```

VERIFIED: this is exactly what the patch does, and after applying all six patches
to pristine r54p0 the file contains `KERNEL_VERSION(4, 1, 0) > LINUX_VERSION_CODE`
at line 566.

Arm's rationale (guide): *"Current versions of Kbase are not designed for use on
v4.1+ kernels when devicetree is disabled (CONFIG_OF=n) … The Kernel version guard
needs to be corrected from '>= v4.15' to '< v4.1'."*

Note the direction: after 0001 the shims are active only on kernels **older than
4.1**. This implies the intended target is a kernel **at or above 4.1** with
`CONFIG_OF=n` — i.e. it is not a compatibility shim for ancient kernels, it is a
mechanism to *disable* definitions that conflict with the real kernel API.
INFERRED from the guard's polarity; the exact intent is not documented further.

## What this range does and does not mean

**It does mean** (VERIFIED): the source contains conditionals that branch across
kernel versions from 3.17.0 to 6.13.0.

**It does not mean** any of the following, none of which has been demonstrated:

- that all kernels in 3.17.0 – 6.13.0 compile Kbase;
- that any specific kernel version compiles Kbase;
- that Kbase builds on x86_64 at all.

A `#if KERNEL_VERSION()` branch is evidence of *attempted* portability, not of a
successful build. Every statement of the form "kernel X works" remains
**NOT TESTED** until a build succeeds.

## Why no kernel version has been chosen

Selecting a version requires evidence that does not exist yet:

1. Whether the six patches apply to the kernel's own headers/APIs — they only
   touch Kbase, but their correctness assumes a particular `asm/` and `linux/`
   API surface (patch 0004 for instance defines `dmb(opt) mb()`, which requires
   `mb()` to exist — it does, as `include/asm-generic/barrier.h`).
2. Whether `mali_kbase_time.c`'s timestamp arithmetic behaves on a given
   architecture (it assumes Arm counter semantics by default; patches 0002/0003
   substitute `USEC_PER_SEC` on non-Arm).
3. Whether the required Kconfig symbols exist and are selectable.

Linux 4.19 was suggested at some point in this project's history. **It is not
adopted.** No evidence supports it; adopting it now would be choosing a version
for convenience rather than evidence, which this repository's evidence policy
forbids.

## Kernel-selection policy — VERIFIED ARM GUIDANCE

From `research/documents/arm_gpu_bug_bounty_device_configuration_guidelines.pdf`
(version `20250623-1.0`):

> "If you are configuring a new virtual environment for testing, we recommend you
> always use the latest Android Common Kernel or the latest Linux Kernel stable
> or longterm release before testing."

Status: **VERIFIED ARM GUIDANCE**. This resolves the earlier "no guidance"
uncertainty. It constrains the *policy* but does not name a specific version, so:

```text
Kernel-selection policy:
Use the latest suitable Linux stable/LTS release for the build phase, subject to
actual compatibility with the primary r54p0 source. The exact version remains
experimentally determined until a build succeeds.
```

Do **not** choose 4.19. Do not prematurely choose another version. A candidate
must be tested against r54p0, and the first candidate that builds with all six
patches applied wins. Note the tension to verify rather than assume: ARM guidance
favours the *latest* LTS, while r54p0's highest observed gate is 6.13.0 — gates are
not ceilings, so a newer kernel may work, but this must be shown by a build.

## Configuration allowlist — VERIFIED ARM GUIDANCE (64-bit only)

The same guidelines document require the default kernel configuration wherever
possible, permitting changes only to: `CONFIG_COMPAT`; one of
`CONFIG_ARM64_4K_PAGES` / `CONFIG_ARM64_16K_PAGES`; any `CONFIG_KASAN*` (except
`*_TEST` = n); and any `CONFIG_UBSAN*` (except `CONFIG_TEST_UBSAN` = n).

They also state: **"The Arm Mali Kernel Driver only supports 64-bit kernels"** —
so the intended guest architecture is `x86_64` and a 32-bit test kernel must not
be constructed. `CONFIG_COMPAT` is the one explicitly permitted 32-bit-related
option.

Full allowlist and the discovery-vs-validation distinction: see
`research/program-scope.md` §5–§6. This document references that policy; it does
not restate it.

## Candidate-selection approach for the build phase — PLANNED

Not yet executed. Sketch only:

1. Choose a candidate with a stable, widely-available x86_64 build configuration
   (per the guidance above — latest stable/LTS).
2. Extract Kbase, apply the six patches (VERIFIED to apply on r54p0).
3. Attempt an in-tree build; record the first hard failure.
4. Iterate on candidate version and on research patches in `kernel/patches/`.
5. Run the mandatory `savedefconfig`-diff and classify every delta against the
   allowlist (`research/program-scope.md` §5).
6. Record the configuration that actually builds as `VERIFIED`.

## RESOLVED by build — 6.12.111 (2026-10-01)

The version question above is now **decided by evidence, not by argument**:

```text
6.18.54  (newest LTS)  FAILS   r54p0 calls __SetPageMovable, removed in v6.17
6.12.111               BUILDS  compiles AND links; see findings.md F-18
```

So the answer to "which exact kernel version" is **6.12.111**, pinned with a
checksum in `../kernel/sources/kernel.pin`, and both the accepted and the
rejected candidate are recorded there.

The compatibility picture is now bracketed rather than open-ended:

| Range | Status |
|---|---|
| 3.17 – 6.12 | **VERIFIED to compile and link** (6.12.111) |
| 6.13 – 6.16 | **UNKNOWN** — the symbols F-16 needs still exist (v6.16 is the last release that has them) |
| 6.17 + | **VERIFIED NOT to compile** (F-16) |

The 6.13–6.16 gap is the interesting one, and it is the range r54p0's own
highest gate (6.13.0) was written for. Testing it would tell us whether F-16 is
a hard API ceiling or something a research patch can lift — which determines
whether a modern LTS is reachable at all for this driver. That is the obvious
next kernel experiment, and it is a one-line pin change plus a rebuild.

## Not yet verified

- Whether 6.13–6.16 builds (see above). The tested kernels are 6.12.111 (yes)
  and 6.18.54 (no); the range between them is untested.
- Whether the module **loads**, and whether the `NO_MALI` harness initialises at
  all. Compilation is not initialisation (F-18).
- Whether the 4.1 polarity change in patch 0001 is safe for the eventual target
  kernel (UNKNOWN until a build exists).
- Maximum supported kernel version — 6.13.0 is merely the **highest gate present**
  for r54p0, which usually indicates "at least this new", not "no newer than
  this". A kernel newer than 6.13.0 may well work; that is UNKNOWN. (6.18.0 is the
  corresponding highest gate in r56p0, the comparison release.)
