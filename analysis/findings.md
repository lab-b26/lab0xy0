# Findings

Findings recorded during repository organisation and source analysis, and since
the first real builds. Every entry is labelled by evidence strength.

**F-1 … F-12 have not been validated by a build.** F-13 … F-15 are defects in
this repository's own tooling, found by *executing* it on the build host; each
is fixed and verified. **F-16 is the first result of an actual kernel build**,
and it is negative: r54p0 does not build on Linux 6.17 or newer.

Severity convention used in this repository: a **build-system defect is not a
security vulnerability**, and a **virtual-device behaviour is not a
production-device vulnerability**. Those require independent evidence.

## Scope policy reference

```text
Scope reference:        research/program-scope.md  (authoritative; do not
                        duplicate policy here)
Scope assessment date:  2026-09-30
Scope status:           see authoritative policy
```

Each finding below may carry an `Assessment:` line (`IN SCOPE` /
`DISCOVERY-ONLY` / `EXCLUDED` / `UNKNOWN`). Such a line is a **point-in-time
assessment**, not a second policy source, and never overrides
`research/program-scope.md`. This file does **not** restate the program scope,
allowlist, or exclusions — read those from the policy document.

---

## F-1 — VERIFIED BUILD-SYSTEM FINDING: dangling `../arbitration/` reference

**Classification:** build-system defect. Security classification: **NOT
ESTABLISHED**. Not a vulnerability on the evidence available.

**Assessment:** EXCLUDED as a security finding. This is a build-system defect
only; per `research/program-scope.md` it has no attacker-reachable surface, and
the supplied patches that touch this path are themselves listed as out of scope.

### The problem

`drivers/gpu/arm/midgard/Kbuild:133` (r54p0, pristine):

```make
obj-$(CONFIG_MALI_MIDGARD) += mali_kbase.o
obj-$(CONFIG_MALI_HAS_VIRTUALIZATION) += ../arbitration/
obj-$(CONFIG_MALI_KUTF)    += tests/
```

Referenced path: `drivers/gpu/arm/arbitration/`

Actual path that exists: `drivers/gpu/arm/midgard/arbiter/`

### Evidence — VERIFIED

```bash
$ ls drivers/gpu/arm/arbitration
ls: cannot access 'drivers/gpu/arm/arbitration': No such file or directory

$ ls drivers/gpu/arm/
BUILD.bazel  Kbuild  Kconfig  Makefile  midgard
```

The `arbiter/` directory does exist and contains a real implementation:

```text
drivers/gpu/arm/midgard/arbiter/
├── Kbuild
├── mali_kbase_arbif.c / .h
├── mali_kbase_arbiter_defs.h
└── mali_kbase_arbiter_pm.c / .h
```

and it is wired into the build unconditionally through a *different* mechanism
(`midgard/Kbuild:183-184`):

```make
INCLUDE_SUBDIR = \
    $(src)/arbiter/Kbuild \
    ...
```

`midgard/arbiter/Kbuild` then adds the objects:

```make
mali_kbase-y += \
    arbiter/mali_kbase_arbif.o \
    arbiter/mali_kbase_arbiter_pm.o
```

So the arbiter code is built from `arbiter/`, while a **second, stale reference**
to `../arbitration/` remains on line 133.

### Second reference — VERIFIED

`drivers/gpu/arm/midgard/Makefile:190`:

```make
-include $(THIS_DIR)/../arbitration/Makefile
```

Note the leading `-` on `-include`: a missing file is silently tolerated. This
Makefile is the SCons/Android path, so it is not expected to break an in-tree
build, but it points at the same non-existent directory.

### The enabling symbol — VERIFIED

`CONFIG_MALI_HAS_VIRTUALIZATION` is **defined nowhere** in r54p0:

```bash
$ grep -RIn "MALI_HAS_VIRTUALIZATION" <r54p0 payload>
midgard/Kbuild:133:obj-$(CONFIG_MALI_HAS_VIRTUALIZATION) += ../arbitration/
```

The only occurrence is this use site — it is never `config`'d in any `Kconfig` or
`Mconfig`. It therefore cannot be enabled through normal configuration, and
expands to the empty string.

### Effect

`obj-` with an empty variable expands to nothing, so the line contributes no
object normally. The breakage arises in Kbuild's directory traversal /
cleaning logic, which is exactly what patch 0006 addresses:

```make
ifneq ($(CONFIG_MALI_HAS_VIRTUALIZATION),)
obj-$(CONFIG_MALI_HAS_VIRTUALIZATION) += ../arbitration/
endif
```

- Affects: **`make clean`** (per patch title and Arm's troubleshooting section).
- Compilation: not demonstrated to be affected; Arm's guide reports the driver
  *builds* successfully and only `make clean` fails.
- Scope: build-system behaviour only.

### Is the `arbiter/` absence intentional? — UNKNOWN

It is not established whether:
- the reference is a vendor bug (directory renamed `arbitration` → `arbiter`
  without updating `Kbuild:133`), or
- an internal vendor-only component was stripped from this public archive.

Both are consistent with the evidence. Not resolved in this phase.

### Relationship to r56p0 — VERIFIED

r56p0 contains **neither** `midgard/arbiter/` nor any
`CONFIG_MALI_HAS_VIRTUALIZATION` reference. Consistent with the same upstream
cleanup having been completed there, but that is an INFERENCE, not a documented
statement.

### Patch that addresses it

`patches/virtual-device/0006-Fix-make-clean-when-no-arbitration-code-present.patch`
— VERIFIED to apply to pristine r54p0.

### Why this is not a security finding

The consequence is a failing `make clean` in the vendor build system. It does not
affect the code compiled into the module, does not create a memory-safety issue,
and has no privilege or input-reachability dimension. Reporting it as a
vulnerability would be wrong.

---

## F-2 — HIGH RISK: `MALI_KCOV` is unreachable in an in-tree build

**Status: VERIFIED source fact; consequences INFERRED; not yet built.**

### Evidence — VERIFIED

| Check | Result |
|---|---|
| `MALI_KCOV` in `midgard/Kconfig` | **absent** |
| `MALI_KCOV` in `midgard/Mconfig` | present (line 202) |
| `MALI_KCOV` in `midgard/Kbuild` | **absent — 0 occurrences** |
| Its flags in `midgard/Makefile:283` (SCons/Android) | present |
| Its flags in `drivers/base/arm/Makefile:103` (SCons/Android) | present |
| `drivers/gpu/arm/Kconfig` sources `Mconfig`? | **no** — sources only `midgard/Kconfig` |

The flags in question:

```make
ifeq ($(CONFIG_MALI_KCOV),y)
    CFLAGS_MODULE += $(call cc-option, -fsanitize-coverage=trace-cmp)
    EXTRA_CFLAGS += -DKCOV=1
    EXTRA_CFLAGS += -DKCOV_ENABLE_COMPARISONS=1
endif
```

`MALI_KCOV` is a **compile-time instrumentation switch for Kbase objects**. It is
distinct from Linux's `CONFIG_KCOV`, which is the runtime coverage subsystem.
`MALI_KCOV` makes Kbase emit trace-cmp coverage; `CONFIG_KCOV` collects it.

Dependency (VERIFIED, `midgard/Mconfig:204`):

```text
MALI_KCOV  depends on  MALI_MIDGARD && MALI_DEBUG
```

### Consequence — INFERRED, not built

Because the in-tree Kbuild path never reads the `Makefile` that carries those
flags, and the symbol is absent from the `Kconfig` the kernel parses, an in-tree
x86_64 build of r54p0 will very likely produce **a module with no Kbase-side
coverage instrumentation**, regardless of `CONFIG_MALI_KCOV`.

This directly threatens the `kcov` profile, which is the primary coverage-guided
fuzzing kernel.

### Mitigation — PLANNED

A research-authored patch in `kernel/patches/` adding a `Kbuild` condition that
appends `-fsanitize-coverage=trace-cmp` for the coverage profile. Preferred over
editing vendor source, which is forbidden. Must be validated by build in the
build phase — until then this remains an INFERENCE.

### Same situation in r56p0 — VERIFIED

r56p0 has the identical `Kconfig`/`Kbuild` gap. Switching to r56p0 does **not**
solve it.

---

## F-3 — Hard build gates can be silently satisfied

**Status: VERIFIED source fact.**

`midgard/Kbuild:29-39` uses `ifeq ($(CONFIG_X),n)` rather than testing for
emptiness:

```make
ifeq ($(CONFIG_PM_DEVFREQ),n)
    $(error CONFIG_PM_DEVFREQ must be set in Kernel configuration)
endif
```

Consequence (INFERRED): an **unset** symbol expands to the empty string, which is
not equal to `n`, so the guard would not fire. The intended safety net may
therefore not engage for a symbol that is absent rather than explicitly disabled.

Mitigation for our own configs (PLANNED): set these symbols explicitly, and assert
their presence in the build script rather than relying on Kbuild to complain.

---

## F-4 — RESOLVED: `NO_MALI_DEFAULT_GPU` target

**Status: VERIFIED (source) / NOT_TESTED (runtime).** Superseded the earlier
"UNKNOWN / NEEDS RECONCILIATION" entry after the program's "target the latest GPU"
guidance and a full read of r54p0's GPU table (DECISION-2).

| Source | Value | Note |
|---|---|---|
| `midgard/Kconfig:72` default (r54p0) | `"tMIx"` | the **oldest** GPU; the table's fallback |
| Arm virtual-platform guide, x86 config | `"tKRx"` | valid, but the **second-newest** |
| r54p0 `all_control_reg_values[]` latest | **`"tDRx"`** | arch 14.8.5; the true latest |

Resolution: the release defines 18 GPU targets, ordered oldest→newest in
`backend/gpu/mali_kbase_model_dummy.c:161-442`. The last/highest is `tDRx`
(`GPU_ID2_MAKE(14, 8, 5, …)`). "Target the latest GPU when compiling" therefore
means `CONFIG_MALI_NO_MALI_DEFAULT_GPU="tDRx"`, not the guide's older `tKRx`. Full
evidence table and DECISION-2 record in `kconfig-dependencies.md`.

`tDRx` is supported in the virtual path (hardware feature/issue tables, product id,
product name, IPA model, and the CSF `_no_mali` arch gate all reference arch 14),
but this is a **source-level** result — no build or boot has confirmed it
(NOT_TESTED).

The value remains a module parameter (`mali_kbase_model_dummy.c:527-529`), but the
program's dynamic-config policy says default module parameters must be used and
does **not** list `no_mali_gpu` among the permitted overrides, so the GPU target is
set at compile time, not by `insmod` (DECISION-1/2; `research/program-scope.md`
§8.4).

Related minor discrepancy (still open): Arm's how-to guide shows sample DDK output
`r54p0-00eac0`, while the source identifier is `r54p0-01eac0`.

---

## F-5 — VERIFIED: patch series targets r54p0, not r56p0

**Status: VERIFIED by reproduction.** See `virtual-device.md` for the matrix.

Method: fresh extraction of each archive; `git apply --check -p1` from the `driver/`
directory; corroborated by blob-hash pre-image comparison (9/10 hashes match r54p0).

This is the reason r54p0 is the primary target and the reason the project brief's
`454 files` and `3.17.0 → 6.18.0` figures — both r56p0 values — were corrected.

---

## F-6 — RESOLVED: resource constraint (build-phase blocker)

**Status: RESOLVED 2026-10-01 — the constraint was real and it was worked
around, exactly as predicted below.** The measurements are kept unedited because
they are what justified the codespace build host; the note records what actually
happened.

The blocker was solved by building on a different machine, not by shrinking the
build. `baseline` then compiled and linked on Linux 6.12.111 in a 4-core /
16 GB / **32 GB**-disk Codespace (F-18). The 32 GB disk is *below* the 256 GB
ideal and below the 25 GB "comfortable" threshold in `../kernel/BUILD-HOST.md`,
so `preflight.sh` warns and one profile at a time is required (~4.5 GB peak,
prune between). The original measurements below are retained verbatim.

| Resource | This host | Arm's documented tested baseline |
|---|---|---|
| Architecture | x86_64 | — |
| vCPU | 4 | 4+ |
| RAM | 7.4 GB (≈3.4 GB available at measurement) | **16 GB** |
| Free disk | 3.8 GB (96% used on `/`) | **256 GB** |

Missing host tooling at time of writing (VERIFIED):
`qemu-system-x86_64`, `bison`, `libelf`. Present: `gcc` 15.3.0, `make` 4.4.1,
`flex`, `bc`, `openssl`, `cpio`, `zstd`, `socat`, `git`, `curl`, `wget`.
`/dev/kvm` **is** present, so KVM acceleration is available.

Consequences, stated without pessimism:

- Disk, not CPU, is the binding constraint. Four full kernel build trees plus four
  rootfs images would not fit.
- This is a direct argument for the repository's **one-source / many-`O=`-dirs /
  portable-artifact** design, and for deleting build trees after packaging.
- It is not evidence that the project cannot work.

---

## F-7 — Scope note: an unexpected third variant

`VX504X08X-SW-99002-r56p0-19eac0/` (release `r56p0-19eac0`, 489 files) appeared in
the working directory during this phase. **NOT ANALYSED, NOT VENDORED, NOT
TESTED.** Recorded so a later session does not mistake it for r56p0-18eac0 or
assume it was considered.

---

## F-8 — Harness contains excluded code by construction (scope hazard)

**Status: VERIFIED source fact.** Scope: see `research/program-scope.md` (§9
excludes "dummy model" code; §9 excludes bugs only reachable via debugfs or TEST
config options). This finding exists so future researchers do not confuse the
virtual harness's own scaffolding with the reportable Kbase attack surface.

The `MALI_NO_MALI` virtual harness necessarily includes code that the program
excludes. But `NO_MALI` swaps **only two objects**, so the majority of Kbase —
including the in-scope ioctl / MMU / memory paths — remains present and reachable.

### VERIFIED: the NO_MALI swap surface is minimal

`drivers/gpu/arm/midgard/csf/Kbuild:49-56`:

```make
ifeq ($(CONFIG_MALI_NO_MALI),y)
mali_kbase-y += csf/mali_kbase_csf_firmware_no_mali.o
mali_kbase-y += csf/mali_kbase_csf_fw_io_no_mali.o
else
mali_kbase-y += csf/mali_kbase_csf_firmware.o
mali_kbase-y += csf/mali_kbase_csf_fw_io.o
endif
```

Exactly **two** firmware-interface objects are replaced. Everything else is
compiled as usual, including:

| Kbase area | Under `MALI_NO_MALI=y` | Evidence |
|---|---|---|
| ioctl dispatch (`mali_kbase_io.c`) | compiled; debugfs-only ioctls `#if`'d out | `mali_kbase_io.c:102` `#if defined(CONFIG_DEBUG_FS) && !IS_ENABLED(CONFIG_MALI_NO_MALI)` |
| memory management (`mali_kbase_mem_linux.c`) | compiled; uses dummy page when no GPU | `mali_kbase_mem_linux.c:3306,3674` |
| MMU direct (`mmu/mali_kbase_mmu_hw_direct.c`) | compiled; small regions `#if`'d | `mali_kbase_mmu_hw_direct.c:229,525` |
| model layer (`mali_kbase_model_dummy.c`) | compiled **in** | `backend/gpu/Kbuild:43` `mali_kbase-$(CONFIG_MALI_NO_MALI) += …mali_kbase_model_dummy.o` |

### Operational consequence

- The reportable surface is **large**: production ioctl handling, MMU mapping, and
  memory-allocation code all run in the virtual environment.
- A finding is only out of scope if it is **specific to** the dummy-model object or
  the two `_no_mali` firmware objects. A generic ioctl/MMU/memory bug reached
  *through* the harness is still a Kbase bug, subject to the discovery-vs-
  validation rule (`research/program-scope.md` §6).
- Do **not** report the harness scaffolding itself (the dummy model) or the
  supplied virtual-device patches — both are listed exclusions.

**Assessment:** mixed. Individual findings are classified per
`research/program-scope.md`; this entry records the surface, it does not grant or
deny scope.

---

## F-9 — KCOV / debug configurations are non-conforming for validation

**Status: VERIFIED, and broadened.** Scope: `DISCOVERY-ONLY` per
`research/program-scope.md` §5–§6, and additionally per the Kbase build allowlist in
§8.3.

Two allowlists now apply, and BOTH must hold for a validation environment:

1. the **kernel** allowlist (`research/program-scope.md` §5): only `CONFIG_COMPAT`,
   the ARM64 page-size pair, `CONFIG_KASAN*` (except `*_TEST`), `CONFIG_UBSAN*`
   (except `CONFIG_TEST_UBSAN`);
2. the **Kbase** allowlist (`research/program-scope.md` §8.3): default KConfig plus
   `CONFIG_MALI_DEBUG=n` (mandatory) and at most `MALI_CSF_SUPPORT`, `MALI_EXPERT`,
   `LARGE_PAGE_SUPPORT`, `MALI_TRACE_POWER_GPU_WORK_PERIOD`, `MALI_NO_MALI`.

Measured against both:

| Profile | Non-allowlisted kernel options | Non-default/other Kbase options | Use | Validation-eligible? |
|---|---|---|---|---|
| `baseline` | none intended | `MALI_NO_MALI=y` (allowed); `MALI_PLATFORM_NAME="vexpress"` + `MALI_NO_MALI_DEFAULT_GPU` (**not** on §8.3 list) | control / reproduction | **no** in the x86 harness — it is the x86 virtual env, hence investigation-only (DECISION-1). It defines the intended conforming config shape for real HW. |
| `kasan` | none — all changes are `CONFIG_KASAN*` | previously `MALI_DEBUG=y` (**now removed**) | discovery **and** validation | **potentially yes** once `MALI_DEBUG=y` is dropped and the savedefconfig diff is clean |
| `kcov` | `CONFIG_KCOV`, `CONFIG_KCOV_INSTRUMENT_ALL` | `MALI_NO_MALI` path; `vexpress`; GPU target | discovery / coverage triage | **no** |
| `debug` | `CONFIG_DEBUG_KERNEL`, `CONFIG_DEBUG_INFO` | `MALI_DEBUG=y` (mandatory-`n` violation) | crash / root-cause | **no** |

Key correction: the program **mandates `CONFIG_MALI_DEBUG=n`** and does not list
`MALI_DEBUG` among the changeable options. Any `MALI_DEBUG=y` profile is therefore
non-conforming. The earlier `kasan.config` claim that `MALI_DEBUG=y` is needed "for
ASAN interaction" was **INFERRED and is now withdrawn**; `kasan.config` sets
`MALI_DEBUG=n`.

DECISION-1 consequence: because the x86_64 NO_MALI harness needs
`MALI_PLATFORM_NAME="vexpress"` (and a GPU target), which are outside the §8.3
allowlist, **the entire x86 virtual environment is INVESTIGATION/DISCOVERY-ONLY**.
No profile built in it is a validation environment, including `baseline`.

Consequences, recorded explicitly:

```text
Discovery use:   intentional and expected for the whole x86 virtual environment
Validation use:  requires BOTH allowlists (kernel §5 + Kbase §8.3) on real HW;
                 findings from the virtual harness are re-confirmed before counting
Eligibility:     a crash under an instrumented kernel or a non-conforming Kbase
                 config does NOT by itself make a finding eligible
```

This compounds F-2: the Kbase-side coverage gap is a *build* problem, and even once
a research patch closes it, the resulting KCOV kernel remains a discovery-only,
non-conforming environment.

**Assessment:** DISCOVERY-ONLY for the x86 virtual harness as a whole (DECISION-1);
`kasan` is the only profile that can *theoretically* approach a conforming config,
and only on real hardware and only after `MALI_DEBUG=n` + a clean savedefconfig diff.

---

## F-10 — `build.sh` could not have built Kbase (found by static review)

**Status: FIXED. Not reproduced at runtime** — no kernel has been compiled on any
host, so this is a defect found by reading the script and by testing its control
flow against a stubbed tree, not an observed build failure. Category:
`build-system issue`.

The first `build.sh` (committed as `a7e0d72`) had four independent defects. Any one
of them would have produced a wrong or missing build, and three of them would have
failed *silently*:

| # | Defect | Consequence |
|---|---|---|
| 1 | Staging used `cp -a "$KBASE_TREE/." "$KERNEL_SRC/drivers/gpu/arm/"` | The payload root contains `drivers/`, `include/`, `Documentation/`, so this created `drivers/gpu/arm/drivers/gpu/arm/midgard/…`. Kbase would not have been built at all. |
| 2 | `.config` was seeded at step 1, but Kbase's `Kconfig` was only staged at step 3 | The `MALI_*` symbols did not exist when `scripts/config` set them. |
| 3 | Those failures were swallowed by `2>/dev/null \|\| true` | The build continued with a `.config` containing **no MALI options** and still exited 0. Worst case: a "successful" kernel with no Kbase. |
| 4 | `scripts/config --set-str` was used for every `CONFIG_*` line | `--set-str` quotes the value, so booleans became `CONFIG_KASAN="y"` — invalid `.config` syntax. `--set-val` is correct for bool/tristate. |

Plus two lesser ones: the staged copy was never removed from the pinned source
tree, and there was no verification that the config merge worked.

Fixes applied:

- stage the **payload root into the kernel tree root** (defect 1);
- stage *before* seeding the config (defect 2);
- replace the `scripts/config` loop with `append fragment` + `make olddefconfig`,
  then **verify every fragment symbol took effect**, and exit non-zero listing the
  ones that did not (defect 3, and the new safety net);
- verification covers three outcomes — all set / symbol absent / value clobbered —
  and all three were exercised against a stubbed tree.

Verification of the fix is a control-flow test only: `build.sh` was run against a
fake kernel tree whose `make` is a shell stub. It confirms the staging, wiring,
merge and refusal logic; it proves nothing about whether Kbase compiles.

## F-11 — In-tree integration requirements, and one hard gate my analysis missed

**Status: VERIFIED by source inspection. NOT_TESTED at build time.** Category:
`build-system issue` + correction to F-3.

Reading `drivers/gpu/arm/{Makefile,Kbuild}` and `midgard/{Makefile,Kbuild}` in the
pristine r54p0 extract turned up two things the analysis had wrong or absent.

**(a) A hard gate was missing.** F-3 listed three unconditional `$(error)` gates.
There are **five**:

| Symbol | midgard/Kbuild | Was it in the fragments? |
|---|---|---|
| `CONFIG_DMA_SHARED_BUFFER` | 29-30 | yes |
| `CONFIG_PM_DEVFREQ` | 33-34 | yes |
| `CONFIG_DEVFREQ_THERMAL` | 37-38 | yes |
| **`CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND`** | **41-42** | **NO — added to all four fragments** |
| `CONFIG_FW_LOADER` | 45-46 | no (satisfied — `MALI_MIDGARD` selects it) |

Two further gates are conditional and only fire if `MALI_PRFCNT_SET_SELECT_VIA_DEBUG_FS`
(Kbuild:49-51, needs `CONFIG_DEBUG_FS`) or `MALI_FENCE_DEBUG` (55-57, needs
`CONFIG_SYNC_FILE`) are enabled. No profile enables either.

**(b) `Makefile` shadows `Kbuild`.** Kbase ships *both* files in every directory it
owns, and kbuild prefers `Makefile`. The `Makefile`s are the Android/out-of-tree
ones — `midgard/Makefile` starts with `KERNEL_SRC ?= /lib/modules/$(uname -r)/build`
and `KDIR ?= $(KERNEL_SRC)`. So a plain copy never reaches
`obj-$(CONFIG_MALI_MIDGARD) += midgard/` at all. `build.sh` now sets the Android
`Makefile` aside and installs `Kbuild` in its place, inside the disposable fetched
tree only.

Minimal integration therefore requires: payload root merged into the kernel tree
root; `drivers/gpu/arm` + `drivers/gpu/arm/midgard` kbuild-ified;
`source "drivers/gpu/arm/Kconfig"` added to `drivers/gpu/Kconfig`; and
`obj-$(CONFIG_MALI_MIDGARD) += arm/` added to `drivers/gpu/Makefile`.

Deliberately **not** wired: `drivers/base/arm/` and
`drivers/hwtracing/coresight/mali/`. They are gated on
`CONFIG_MALI_MEMORY_GROUP_MANAGER`, `CONFIG_MALI_PROTECTED_MEMORY_ALLOCATOR`,
`CONFIG_DMA_SHARED_BUFFER_TEST_EXPORTER` and Arm64 coresight — none of which are on
the program allowlist (§8.3) or enabled by any profile. Wiring them would add
nothing and widen the config delta.

**A latent vendor bug, recorded but not worked around:**
`drivers/gpu/arm/Kbuild:21` and `drivers/base/arm/Kbuild:21` contain

```make
ifeq ($(MALI_CSF_SUPPORT),n)
    $(error [GPUBUILD-2005] Only CSF builds are supported on this branch)
endif
```

`MALI_CSF_SUPPORT` (without the `CONFIG_` prefix) is **never assigned** anywhere in
the tree — only `CONFIG_MALI_CSF_SUPPORT` is. The variable expands to empty, so
`ifeq (,n)` is false and the gate never fires. The build will not spuriously fail,
but this "only CSF builds" guard is currently dead code. It does not change our
profile choice: `CONFIG_MALI_CSF_SUPPORT=y` is set anyway, per the FAQ and Arm's
own x86 config. Recorded so nobody later "fixes" it by passing `MALI_CSF_SUPPORT=n`.

## F-12 — `.devcontainer/` blocked Codespace creation; removed

**Status: FIXED by removal.** Category: `build-host / CI configuration`.

A `.devcontainer/devcontainer.json` (Ubuntu 24.04 image, with
`hostRequirements` of 4 cpu / 16 gb / 64 gb) was committed in `b348b58`. Attempting
to create a Codespace from this repository failed:

```text
A codespace cannot be created because no machine types are available.
You may need to select a different branch, modify your container
configuration, or adjust your organization's policy settings.
```

This is a **Codespace provisioning failure**, not a defect in any kernel script.
The declared `hostRequirements` combination is not offered by this account, and
GitHub fails closed: rather than falling back to a smaller machine, it refuses to
create the codespace at all. A devcontainer cannot fix a machine-availability or
org-policy problem — declaring the requirements only converted "too small machine"
into "no codespace at all".

Resolved by **deleting `.devcontainer/`** (commit after `b348b58`). Codespaces
works without one: create the codespace from the default Codespaces image and pick
**4 cores / 16 GB / 64 GB** manually in the UI.

Consequences, and why this is not a regression:

- Nothing in the repository needed the devcontainer. It was convenience only.
- The toolchain install it performed in `onCreateCommand` is now done by
  `kernel/scripts/codespace-setup.sh`, which is the documented first command on a
  fresh host and covers strictly more (toolchain **plus** machine-spec check, git
  identity, GitHub access, `gh`, preflight verdict).
- The machine-spec check that `hostRequirements` used to automate is now performed
  by `codespace-setup.sh`, which fails loudly *before* a build instead of
  preventing the codespace from existing.
- Do not re-add `hostRequirements`. If automatic machine selection is wanted
  again, it must be validated against the account's actual available machine types
  first — an unmatchable requirement blocks the entire build host.

## F-13 — `resolve-kernel-pin.sh` constructed URLs kernel.org does not serve

**Status: FIXED.** Category: `build tooling`. Found on the first real
execution of the script, on the build host.

The script derived the tarball directory by string surgery on the version:

```bash
MAJMIN=$(printf '%s' "$VER" | cut -d- -f1 | cut -d. -f1,2)
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJMIN}/${TARBALL}"
```

For `6.18.54` that yields `.../v6.18/linux-6.18.54.tar.xz`. kernel.org returns
**404**: the current series is not filed per-point-version.

```text
error: could not fetch https://cdn.kernel.org/pub/linux/kernel/v6.18/sha256sums.asc
```

Verified layout (2026-10-01, live):

| Release | Actual directory |
|---|---|
| 6.18.54 (newest LTS) | `v6.x` |
| 6.12.111 | `v6.x` |
| 5.15.221 | `v5.x` |
| 7.2.8 | `v7.x` |
| `v6.18/`, `v6.12/`, `v6.6/` | **404 — do not exist** |

So the per-point `v<major>.<minor>` layout the script assumed no longer exists
at all; the old directories that do exist are `v1.0` … `v5.x`, `v6.x`, `v7.x`.

A second, quieter bug in the same block: the five values parsed out of
`releases.json` were read with whitespace-separated `read -r`, and the script
looked for a top-level `isodate` key that does not exist (the date is at
`released.isodate`). The empty field collapsed, so `source` was silently
assigned to the `released` variable. The URL was wrong *and* the provenance
line would have been wrong, without any error.

Fix: use the `source` URL kernel.org publishes in `releases.json` (it is
authoritative and already correct), then fall back to `v<major>.<minor>` and
`v<major>.x`; a candidate directory is accepted **only if its `sha256sums.asc`
actually lists the tarball**, so a layout change fails loudly here instead of
writing a wrong pin. Fields are now `|`-delimited so an empty value cannot
shift its neighbours. See `kernel/scripts/resolve-kernel-pin.sh`.

## F-14 — `build.sh` injected a C comment into a Kconfig file

**Status: FIXED.** Category: `build tooling`. Found on the first real build.

The wiring marker was written in C comment syntax:

```bash
WIRE_TAG="/* Kbase integration added by kernel/scripts/build.sh -- do not edit */"
```

and appended to **both** `drivers/gpu/Makefile` and `drivers/gpu/Kconfig`.
`/* */` is a valid Makefile comment but is a hard syntax error in Kconfig, so
the very first `make defconfig` died:

```text
drivers/gpu/Kconfig:15: syntax error
drivers/gpu/Kconfig:15: unknown statement "Kbase"
make[3]: *** [.../scripts/kconfig/Makefile:95: defconfig] Error 1
```

Fix: `#` is a comment in both languages, so the tag is now `#`-prefixed. The
already-staged tree was repaired in place; both files verified. See
`kernel/scripts/build.sh`.

This is exactly the class of defect F-10 predicted: `build.sh` was
syntax-checked, never executed against a real kernel, and the failure surfaced
on the first real run.

## F-15 — `build.sh` step 5 mis-read every `=n` line in a fragment

**Status: FIXED.** Category: `build tooling`. Found on the first real build.

Step 5 is the safety net that refuses to compile a kernel missing Kbase. It
looked a symbol up with `grep "^${sym}=" .config` only. But kconfig **never**
writes `CONFIG_X=n`: an `n`-valued symbol is written as the line
`# CONFIG_X is not set`. So every fragment line that *disables* a symbol was
reported as missing, including the mandatory `CONFIG_MALI_DEBUG=n` (§8.3):

```text
[ MISSING  ] CONFIG_MALI_DEBUG   wanted n — symbol not in the Kconfig
```

The symbol was present and correctly `n` (`midgard/Kconfig:194`, `default n`).
The safety net was not merely wrong, it was **wrong in the fail-closed
direction**: it would have blocked a conforming build, and the obvious
"fix" — deleting the line from the fragment — would have dropped a mandatory
option. Fix: when the wanted value is `n`, accept either spelling, and report
MISSING only when the symbol is absent from the Kconfig entirely.

## F-16 — r54p0 does not build on Linux 6.17+ (`__SetPageMovable` removed)

**Status: OPEN, build-blocking.** Category: `r54p0 vs kernel API`. The first
**real** build result in this project, and the first evidence for consolidated
unknown #1 and #2.

Attempt: `baseline` profile, Linux **6.18.54** (newest LTS, chosen by
`resolve-kernel-pin.sh` per Arm's "latest stable/longterm" guidance), all six
vendor patches applied, `gcc 13.3.0`, x86_64.

Result — **FAILED** after ~2 900 objects:

```text
drivers/gpu/arm/midgard/mali_kbase_mem_migrate.c:83:9: error:
    implicit declaration of function '__SetPageMovable'
drivers/gpu/arm/midgard/mali_kbase_mem_migrate.c:158:25: error:
    implicit declaration of function '__ClearPageMovable'
cc1: all warnings being treated as errors
```

Full log: `research/build-logs/6.18.54-baseline-FAILED.log`
(errors extracted: `…-FAILED.errors.txt`).

Cause — **VERIFIED**: r54p0 calls `__SetPageMovable`/`__ClearPageMovable`
**unguarded**, with no `KERNEL_VERSION` gate, and the declarations vanished
from `include/linux/migrate.h`:

| Tag | `__SetPageMovable` declared? |
|---|---|
| v6.12, v6.13, v6.14, v6.15, v6.16 | **yes** |
| v6.17, v6.18, v7.0, v7.1, v7.2 | **no** |

(checked against `raw.githubusercontent.com/torvalds/linux/<tag>/include/linux/migrate.h`)

Consequences, stated precisely:

- This is **not** a configuration problem. All 13 fragment symbols verified
  (step 5/8 passed with 0 problems), and no Kbase warning preceded the error.
  No amount of Kconfig work fixes it.
- It **is** not a patch-application problem either: all 6/6 vendor patches
  applied cleanly.
- It is an upstream API removal, so **r54p0 cannot build on 6.17 or newer
  without a research patch** in `kernel/patches/`. That patch is not written.
- It refines, and partially answers, consolidated unknowns #1/#2: r54p0 does
  *not* compile on every kernel in its 3.17→6.13 gate range, nor on the newest
  LTS. The gate range is about `KERNEL_VERSION` branches; it says nothing
  about unguarded API calls, which is precisely the forbidden inference
  `research/methodology.md` warns about (a version gate → a support claim).

Action taken — **6.12.111** is now pinned: the newest `longterm` release that
still exports these symbols (verified present in the v6.12 and v6.12.111
tags). This is a deliberate, recorded step down from the newest LTS, forced by
evidence rather than convenience, and `kernel/sources/kernel.pin` records both
candidates and the reason. 6.12 also sits below r54p0's highest observed gate
(6.13.0), so it is the conservative choice as well as the evidenced one.

Two further `__SetPageMovable` call sites exist at lines 241 and 330 of the
same file, inside the same unguarded region, so expect the fix — whatever form
it takes — to be needed in more than one place. INFERRED, not yet observed.

What this finding is **not**: not a vulnerability, not a Kbase defect, and not
a statement that 6.17+ is a bad kernel. It is a source/API mismatch that this
project hit by building.

## F-17 — r54p0 calls `__clk_is_enabled`, which x86_64 defconfig never builds

**Status: OPEN, build-blocking (link stage).** Category: `r54p0 vs kernel config`.
Found on the 6.12.111 build, after the F-16 obstacle was removed.

Attempt: `baseline` profile, Linux **6.12.111** (newest LTS at or below the
verified 6.16 API boundary), all six vendor patches, gcc 13.3.0, x86_64.

Result: **compilation of Kbase succeeded in full** (128 Kbase objects, all 149
sources reached, 0 compile errors) and the build then failed in **modpost**:

```text
ERROR: modpost: "__clk_is_enabled" [drivers/gpu/arm/midgard/mali_kbase.ko] undefined!
make[3]: *** [.../scripts/Makefile.modpost:145: Module.symvers] Error 1
```

Cause — **VERIFIED**, and it is a *configuration* problem, unlike F-16:

- `__clk_is_enabled` **is** `EXPORT_SYMBOL_GPL`'d in 6.12.111
  (`drivers/clk/clk.c:630`), so the API exists and is exported.
- But the whole clock core is built only when `CONFIG_COMMON_CLK` is set
  (`drivers/clk/Makefile:4` — `obj-$(CONFIG_COMMON_CLK) += clk.o`), and
  `# CONFIG_COMMON_CLK is not set` in the merged `.config`.
- `x86_64_defconfig` does not enable it: it is an ARM/SoC-centric option with no
  x86 consumer, so an in-tree x86 build simply never emits the symbol.
- r54p0 calls it **unguarded** at `mali_kbase_core_linux.c:3292` and `:3329`,
  and `#include <linux/clk-provider.h>` is unconditional at line 95 — the
  *declaration* is visible (it is not `#ifdef`-guarded in the header), which is
  exactly why this compiles cleanly and only fails at link time.

So this is the mirror image of F-16: there the symbol was **removed upstream**;
here the symbol is **present but never built** for this architecture. A third
call site exists in the devicetree and meson platform backends
(`platform/devicetree/mali_kbase_runtime_pm.c`,
`platform/meson/mali_kbase_runtime_pm.c`), though those are not compiled in this
`MALI_NO_MALI` configuration.

Two candidate fixes existed:

1. **Enable `CONFIG_COMMON_CLK`** in the profile fragment. One line, no source
   change — but it is a kernel config delta **outside** the §5 allowlist
   (`../research/program-scope.md` §5), which would make `baseline`
   non-conforming as the intended control profile.
2. **Guard the call sites** in a research patch (`kernel/patches/`), behind
   `IS_ENABLED(CONFIG_COMMON_CLK)`.

**Decision: option 2, chosen and written** as
`kernel/patches/0001-kbase-guard-clk-is-enabled-behind-COMMON_CLK.patch`. The
deciding reason is scope, not convenience: it keeps the configuration at plain
`x86_64_defconfig` and therefore introduces **no configuration delta at all**,
so §5 compliance is preserved by construction rather than by argument.

The patch is a **build fix, not a behaviour change**, and that claim is
checkable in both directions:

- `CONFIG_COMMON_CLK=y` → the `__clk_is_enabled` test is still performed, so the
  real-hardware behaviour is untouched.
- `CONFIG_COMMON_CLK=n` → `clk_disable_unprepare()` is a no-op stub
  (`include/linux/clk.h:1155`, and `clk_disable`/`clk_put` likewise at
  `:1075`/`:1056`), and `kbdev->clocks[]` can never be populated because
  `clk_get()` is a stub returning NULL, so the loop body is unreachable.

It is now applied automatically by `apply-patches.sh` after the six vendor
patches, and carries its own series hash so a build using it can never be
attributed to pristine vendor source. This is the first entry in this
directory; see `../kernel/patches/README.md`.

An important secondary observation: this class of failure — a symbol that
*compiles* but does not *link* — cannot be caught by `build.sh` step 5/8, which
only inspects `.config`. It is a genuinely new failure category, and the
repository's "a version gate is not a support claim" rule (F-16) applies here
too: r54p0 compiling cleanly proves nothing about the module linking.

## F-18 — VERIFIED: r54p0 **builds and links** as a module on Linux 6.12.111

**Status: RESOLVED POSITIVE (compile+link only).** Category: `build result`.
This is the first **successful** Kbase build in this project, and the first
positive evidence for consolidated unknowns #1 and #2.

```text
profile      baseline
kernel       6.12.111 (x86_64_defconfig + kernel/configs/baseline.config)
kbase        r54p0-01eac0 + 6 vendor patches + 1 research patch (F-17)
compiler     gcc 13.3.0, Ubuntu 24.04
result       SUCCESS — 3 063 objects, 0 errors, 0 undefined symbols
modules      10 .ko, including drivers/gpu/arm/midgard/mali_kbase.ko (2.4 MB)
             3 627 external+local symbols in the Kbase module
kernel image arch/x86/boot/bzImage (13.6 MB)
config       sha256 515ce13d9fcdfb4d4d4dbbe8885f38b8850dd8deedbde018d5c2eecbcdb823e9
metadata     build/baseline/build-metadata.txt
```

Independently checked, beyond "make exited 0":

- `modinfo` reports `version: r54p0-01eac0 (UK version 1.36)`, `license: GPL`,
  `intree: Y`, `vermagic: 6.12.111` — the module is the expected one and
  matches the running kernel.
- The `MALI_PLATFORM_NAME="vexpress"` backend is genuinely compiled in
  (`mali_kbase_config_vexpress.c` present in the module), so
  `CONFIG_MALI_PLATFORM_NAME` really reached the build rather than being
  accepted and ignored.
- `MALI_NO_MALI_DEFAULT_GPU="tDRx"` is baked in (the literal `tDRx` is
  present), confirming F-4/DECISION-2 reached the binary.
- `CONFIG_MALI_DEBUG=n` is honoured: no `kbase_dbg_*` symbol is emitted.

**What this does and does not prove.** It proves r54p0 compiles and links as an
in-tree module on 6.12.111 with the recorded patch set. It does **not** prove:

- that the module **loads** (state `KBASE_LOAD_VERIFIED` is a separate state,
  and `insmod` is where most real defects appear);
- that the `NO_MALI` harness initialises a GPU, or that `tDRx` does anything
  (consolidated unknown #12 — still `NOT_TESTED`);
- that 6.16 works. F-17 was fixed for the newest-LTS-below-6.17 kernel; whether
  the **top** of the supported range (6.13–6.16) also builds is untested, and
  the upper end is the more interesting one for real-hardware relevance;
- anything about behaviour, security, or conformance. Per DECISION-1 this
  x86 environment is **INVESTIGATION-ONLY** regardless of the build outcome.

F-16 and F-17 are what stood between this project and a build; both are now
resolved *for 6.12.111 specifically*, not for r54p0 in general.

## F-19 — VERIFIED: r54p0 **loads** under QEMU and the EL0 target interface responds

**Status: RESOLVED POSITIVE (boot + load + target interface).** Category:
`runtime result`. This is the first evidence that the Kbase module is not merely
compilable but *functional as a userspace-facing device*.

Serial-log evidence, `research/boot-logs/20261001T062348Z-baseline-BOOT.log`
(four independent boots are committed; all four are identical in substance):

```text
kernel       6.12.111 bzImage + cpio initramfs, QEMU -machine q35 -no-reboot
cmdline      console=ttyS0 panic=-1 rdinit=/init loglevel=7
boot cost    ~2 s guest time (KVM, -m 2048 -smp 4)
insmod       rc=0
             mali mali.0: Kernel DDK version r54p0-01eac0
             mali mali.0: Using Dummy Model
             mali mali.0: GPU identified as 0x0 arch 14.8.5 r0p0 status 0
             mali mali.0: Probed as mali0          -> /dev/mali0 created
EL0 probe    passed=0x1ff  failed=0x000           (all 9 phases PASS)
```

The probe (`qemu/target/kbase-probe.c`) exercises, in order: `open`,
`VERSION_CHECK` (negotiated 1.36), `SET_FLAGS`, `GET_GPUPROPS`, `MEM_ALLOC`,
`mmap`, `MEM_QUERY`, `munmap`. Selected observed values:

```text
gpuprops     773 bytes; product_id=0x0006 version_status=0xe850 major=9 minor=0
             gpu_id=0x0000000000000100  num_exec_engines=15
gpu arch     0x000e0805 == 14.8.5  == tDRx  -> DECISION-2 target confirmed live
mem_alloc    gpu_va=0x41000 out_flags=0x200f
```

Consolidated unknown #12 is therefore **answered YES**: `tDRx` does initialise in
the `MALI_NO_MALI` path on x86_64. This is the first *runtime* confirmation of
F-4/DECISION-2, which until now rested on source reading only.

### Two undocumented contracts discovered (both would silently break a fuzzer)

**1. `SET_FLAGS` is mandatory between handshake and everything else.**
`kbase_api_handshake()` deliberately does **not** create a `kctx` when
`mali_kbase_supports_cap(1.36, MALI_KBASE_CAP_SYSTEM_MONITOR)` is true. Until a
`KBASE_IOCTL_SET_FLAGS` arrives, every other ioctl fails with `-EPERM`, raised by
`kbase_file_get_kctx_if_setup_complete()` returning `NULL`
(`mali_kbase_core_linux.c:1688`). This ordering requirement appears nowhere in the
uapi headers, and the failure mode is a bare `-EPERM` rather than a diagnostic.

**2. `MEM_ALLOC`'s `out.gpu_va` is a cookie, not a GPU VA.**
For non-compat 64-bit clients `BASE_MEM_SAME_VA` is forced
(`mali_kbase_core_linux.c:879`), so `alloc.out.gpu_va` is a cookie keyed on
`BASE_MEM_COOKIE_BASE` (`64 << 12` = `0x40000`; observed `0x41000`). Consequences:

- `MEM_QUERY` on the cookie returns `-EINVAL` — the cookie is not a region handle;
- the region must be bound with `mmap(fd, ..., offset=cookie)`, which yields the
  real GPU VA (== the CPU address for `SAME_VA`);
- `MEM_FREE` is **rejected** on `SAME_VA` regions; release with `munmap`.

A fuzzer that trusted `out.gpu_va` as a pointer would read/write near address 0.

### Scope of this finding

VERIFIED: the module loads, the device node appears, and the ioctl surface
responds end-to-end under `MALI_NO_MALI` on x86_64. **NOT** claimed:

- that real hardware behaves this way (per DECISION-1 this environment is
  **INVESTIGATION-ONLY**; all of the above is `DISCOVERY-ONLY`);
- that CSF paths are reached — `num_exec_engines=15` is reported, but the probe
  does not yet open a CSF stream (consolidated unknown #6 still open);
- any security or conformance conclusion.

Expected, harmless dmesg noise on this host, recorded so it is not later
mistaken for a defect: `No OPPs found in device tree!`, `Clock not available for
devfreq`, and `Dummy model register access: ... unsupported register`.

## F-20 — `build.sh` silently deleted every "must be off" line from a fragment

**Status: RESOLVED (fixed and re-verified).** Category: `tooling defect`.
Found while building the `kasan` profile; it had been latent since the fragment
merge was written.

Step 4 merged a profile fragment into `.config` with `grep -v '^#'`. That drops
every `# CONFIG_X is not set` line — which is the **only** kconfig encoding for
"this symbol must be off". A fragment therefore could not express "off" at all.

The failure is silent in the worst way: a Kconfig `choice` with no member
selected does not stay unset, it resolves to its kconfig `default`. The `Mali HW
backend` choice in `drivers/gpu/arm/midgard/Kconfig` has `default MALI_REAL_HW`,
so the kasan fragment's `# CONFIG_MALI_REAL_HW is not set` became
`CONFIG_MALI_REAL_HW=y` — the opposite of what the fragment said.

**Reproduced deterministically** (6.12.111, `x86_64_defconfig` + kasan fragment):

```text
CASE A  fragment appended verbatim      -> MALI_REAL_HW unset, MALI_NO_MALI=y
                                           (correct, but only by accident:
                                            deselecting the default member makes
                                            kconfig fall through to the other)
CASE B  grep -v '^#'  (the old build.sh) -> CONFIG_MALI_REAL_HW=y
                                           MALI_NO_MALI unset
```

Note that CASE A's correctness is itself a trap: it depends on kconfig falling
through to the non-default member, which is not a documented guarantee and would
not survive a third member being added to the choice.

The **step 5/8 safety net caught it**, which is the point of those checks — the
defect was in the merge, not in the verification. Fix: preserve both symbol forms
(`CONFIG_X=value` and `# CONFIG_X is not set`), drop only prose comments, and
delete any pre-existing `.config` line for a symbol the fragment mentions so the
fragment is the single authority and no duplicate can win by position (kconfig
honours the *first* occurrence, so ordering was previously load-bearing in a way
nobody had written down).

This is the same class as F-14 (a comment-style mistake kconfig handles
differently than the author expected) and adjacent to F-15 (a `=n` line mis-read).
The recurring lesson: **kconfig is not text.** Every fragment merge has now been
verified against the real symbol semantics.

## F-21 — `kasan.config` named no choice member, so it meant the opposite of what it said

**Status: RESOLVED (fragment corrected).** Category: `config defect`. This is the
fragment-side half of F-20; recording separately because the two fixes are
independent and either alone would have left the profile wrong.

`kernel/configs/kasan.config` asserted `# CONFIG_MALI_REAL_HW is not set` *and*
deferred the choice with a comment:

```text
# CONFIG_MALI_REAL_HW is not set
# MALI_NO_MALI choice is DEFERRED for this profile: memory-safety hunting wants
# the real code paths, not the No-MALI stub. Which reaches the interesting code
# is UNKNOWN and must be settled by experiment.
# CONFIG_MALI_NO_MALI=y      <- deferred
```

That is an un-honourable configuration: it names no member of a mandatory choice.
Note the last line is also not valid kconfig at all — `# CONFIG_MALI_NO_MALI=y
<- deferred` has trailing text, so kconfig ignores it silently. Combined with
F-20 the result was `MALI_REAL_HW=y`.

**The deferred experiment is now answered, by F-19.** `MALI_NO_MALI` is the only
backend that yields a loadable module and a reachable `/dev/mali0` on this host —
VERIFIED. Whether `MALI_REAL_HW` would *also* probe under the fake `vexpress`
platform device is **UNKNOWN / NOT_TESTED**, and is deliberately not claimed in
either direction; it was not built, so no statement about it is made.

Resolution: kasan now selects `CONFIG_MALI_NO_MALI=y` with
`CONFIG_MALI_NO_MALI_DEFAULT_GPU="tDRx"` and `MALI_PLATFORM_NAME="vexpress"` —
identical to baseline/kcov/debug, and consistent with DECISION-2. This is a
**harness requirement, not a conformance claim**: per DECISION-1 the profile
remains DISCOVERY-ONLY, while `CONFIG_KASAN*` itself stays allowlisted (§5).

## F-22 — VERIFIED: the baseline artifact is `PORTABLE_ARTIFACT_VERIFIED`

**Status: RESOLVED POSITIVE.** Category: `artifact`. The first artifact in the
project, and the first state in `artifacts/README.md`'s ladder that required the
*bundle* — not its parts — to be tested.

```text
artifact      artifacts/baseline  (68 MB, 16 files)
identity      kbase-r54p0-01eac0-6.12.111-baseline
contents      kernel/{bzImage,vmlinux,config}, modules/ (10 .ko),
              rootfs/rootfs-baseline.cpio.gz, metadata/{manifest.json,SHA256SUMS}
integrity     sha256sum -c metadata/SHA256SUMS -> 16/16 OK (from a copy)
portability   booted from /tmp/... (outside the repo) with the build tree
              RENAMED AWAY -> all 5 assertions PASS
validation    PORTABLE_ARTIFACT_VERIFIED
scope class   DISCOVERY-ONLY (DECISION-1)
```

The clean-location test was run **twice**, and the second run is the one that
counts: the whole `build/` directory was `mv`'d out of the repo before booting, so
any hidden dependency on the build tree would have failed loudly rather than
quietly resolving. `run.sh` resolves `bzImage` *and* the rootfs from inside the
bundle.

### One real portability defect found and fixed by doing this

`run.sh` resolved the kernel from the artifact but the **rootfs only from
`build/rootfs/`**. A relocated bundle would therefore still have depended on the
repo's build tree — exactly the thing the artifact is supposed to eliminate, and
exactly the kind of flaw that stays invisible until someone actually tries to
relocate the bundle. Fixed by giving the rootfs the same
artifact-first/build-tree-fallback candidate order as the kernel.

The lesson generalises: **self-containment is a property you can only test by
removing the thing you are supposed to depend on.** "It boots" was never the test;
"it boots with the build tree gone" is.

### Scope limit

`PORTABLE_ARTIFACT_VERIFIED` means *reproducible and relocatable*. It does **not**
mean conforming, safe, or hardware-validated. The bundle is `MALI_NO_MALI` on
x86_64, so it is `DISCOVERY-ONLY` per DECISION-1, and no result from it is
Arm-conforming evidence. The manifest records both fields separately so the
portability result cannot be misread as a conformance result.

## F-23 — VERIFIED: the `kcov` profile collects coverage, and that coverage **excludes Kbase** (F-2 confirmed empirically)

**Status: F-2 CONFIRMED BY MEASUREMENT (not by Kconfig reading alone).** Category:
`coverage result`. This is the first *quantitative* coverage number in the project,
and it simultaneously proves the harness works and that the instrumentation misses
the target.

```text
guest          kcov profile, 6.12.111, CONFIG_KCOV=y + KCOV_INSTRUMENT_ALL=y
KCOV cycle     KCOV_INIT_TRACE(32768 words) -> KCOV_ENABLE -> fork+exec
               kbase-probe -> read area -> KCOV_DISABLE, all on ONE fd
records        14495 recorded PCs
distinct PCs   2882            <-- the number a fuzzer would use as "new coverage"
PC range       0xffffffff8103d11d - 0xffffffff812da9f5
truncated      no (14495 << 32767)
```

**Kbase contributed zero of those 2882 PCs.** vmlinux's executable segment is
`0xffffffff81000000–0xffffffff82dfffff` (from `readelf -lW`), and *every* observed
PC falls inside it. `mali_kbase.ko` is a loadable module, so its text lives in the
module/vmalloc region (`0xffffffffc0000000`+) — roughly 2.4 GB above the highest
PC seen. No PC in that range appears, so not one instrumented Kbase instruction was
recorded.

This is F-2 (`MALI_KCOV` exists only in the Android/SCons `Mconfig`, never read by
an in-tree build) confirmed by *behaviour* rather than by reading a Kconfig file. A
coverage-guided fuzzer pointed at this kernel would optimise kernel-side paths and
would treat every Kbase input as producing identical coverage — the worst possible
failure mode, because the fuzzer would look healthy while making no progress on the
actual target. Closing F-2 with a research patch is therefore a prerequisite for
`kcov` being useful at all, not a nice-to-have.

### KCOV's userspace protocol is genuinely counter-intuitive

Four separate mistakes were made and caught only because each step reported its
real errno. Worth recording, because every one of them fails *silently* or
misreports:

1. **KCOV is driven by `ioctl`, not `write`.** `echo 1 > /sys/kernel/debug/kcov`
   is the intuitive thing to try and it is wrong — kcov's `file_operations` has
   **no `.read` and no `.write` handler at all**, only `open`/`ioctl`/`mmap`/
   `release`.
2. **`KCOV_INIT_TRACE` takes the area size *as the ioctl argument*, not a pointer
   to it.** The header's `_IOR('c', 1, unsigned long)` strongly implies a pointer.
   `kcov_ioctl_locked()` does `size = arg; if (size < 2 || …) return -EINVAL;`, so
   passing a pointer fails `-EINVAL`. It also rejects `size < 2`.
3. **The whole cycle must share one fd.** kcov state hangs off the open file, so
   `INIT_TRACE` on one fd and `ENABLE` on another leaves the second fd with no area
   and `ENABLE` returns `-EINVAL`.
4. **Counters are read by `mmap`, and the area is a PC *list*, not a bitset.**
   `__sanitizer_cov_trace_pc()` stores the running count in `area[0]` and appends
   each canonicalised PC at `area[pos]`. Popcounting the area — the obvious
   approach — yields `656023` for this run: a large, entirely meaningless number
   that reads like great coverage. The real figures are `records=14495`,
   `distinct_pcs=2882`. `mmap` must additionally use exactly
   `kcov->size * sizeof(long)` bytes at offset 0, or it returns `-EINVAL`.

The lesson generalises past KCOV: **a coverage tool that returns a plausible wrong
number is more dangerous than one that crashes.** Every stage here reports the real
errno, so a misconfiguration names itself instead of producing a confident lie.

Scope: DISCOVERY-ONLY per DECISION-1, as always. The number describes this
simulator build and is not a statement about real hardware.

## Consolidated unknowns

1. ~~Whether r54p0 + all six patches compiles on any x86_64 Linux kernel.~~
   **VERIFIED YES for 6.12.111** (F-18), and **VERIFIED NO for 6.17+** (F-16).
   So the answer is version-dependent, and the supported range is now
   bracketed: it builds on 6.12.111, it does not build on 6.17+, and the exact
   upper bound (6.13–6.16) is still open.
2. ~~Which exact kernel version to select.~~ **Answered: 6.12.111** — the newest
   LTS at or below the verified 6.16 API boundary (F-16), now confirmed to
   build (F-18). Re-open if a research patch lifts the 6.17 ceiling; the
   6.13–6.16 range is the next thing worth testing, since it is the part of
   the range r54p0's own gates were written for.
3. The exact minimal upstream kernel configuration.
4. ~~Why `NO_MALI_DEFAULT_GPU` differs between Arm's guide (`tKRx`) and the source
   default (`tMIx`).~~ **Resolved by F-4 / DECISION-2**: neither is the latest;
   r54p0's latest target is `tDRx`. Why Arm documented `tKRx` is still UNKNOWN.
5. Whether the `MALI_KCOV` gap (F-2) can be closed without touching vendor source.
6. Whether the virtual configuration reaches the CSF code paths a fuzzer needs.
7. Whether any virtual-only behaviour is relevant to a real production Kbase
   target — and, separately, which findings survive the discovery-vs-validation
   rule on conforming hardware (F-9).
8. Whether `make clean` actually fails pre-patch 0006 (the patch title asserts it;
   not reproduced here).
9. Whether targeting `tDRx` (vs `tKRx`) changes the NO_MALI dummy model's
   behaviour enough to matter for F-8's reportable surface (NOT_TESTED).
10. Whether a `kasan` build can be made fully conforming (all deltas within both
    the §5 kernel and §8.3 Kbase allowlists) so it can serve as the validation
    environment for discoveries. Note the x86 harness itself is investigation-only
    (DECISION-1), so this can only be settled on real hardware.
11. The complete list of permitted `insmod` module parameters — the supplied text
    is truncated (UNKNOWN; `research/program-scope.md` §8.4).
12. ~~Whether `tDRx` actually initialises in the `MALI_NO_MALI` path on
    x86_64.~~ **Answered YES (F-19):** the module loads, `Using Dummy Model`,
    `GPU identified as 0x0 arch 14.8.5 r0p0`, and the EL0 probe passes all nine
    phases (`passed=0x1ff failed=0x000`). This is the first *runtime* — not
    source-level — confirmation of DECISION-2's target choice.
13. Whether an r54p0 ioctl harness can be driven to completion without
    undocumented ordering/cookie contracts. **Partly answered (F-19):** it can,
    but only after discovering two contracts absent from the uapi headers —
    `SET_FLAGS` is mandatory before any other ioctl (`-EPERM` otherwise), and
    `MEM_ALLOC.out.gpu_va` is a `SAME_VA` cookie that must be `mmap`ed, not used
    as a pointer. A *complete* harness (CSF streams, job/command submission) is
    still unbuilt.
14. ~~Whether the minimal in-tree integration in F-11 is *sufficient*.~~
    **VERIFIED sufficient for 6.12.111** (F-18): staging, kbuild-ify, and
    `drivers/gpu` wiring all worked as designed, with no further integration
    work needed. It remains unverified for other kernel versions.
15. ~~Whether the newest LTS kernel pairs cleanly with the compiler on the build
    host.~~ **Answered, negatively, for 6.18.54** (F-16: the blocker was an
    upstream API removal, not the compiler), and **affirmatively for 6.12.111**
    with gcc 13.3.0 (F-18). No `-Werror` churn was encountered either way.
16. Which Codespace machine types this account actually offers. F-12 shows the
    consequence of assuming: an unmatchable `hostRequirements` made the codespace
    uncreatable. Machine size must be chosen in the UI and confirmed by
    `codespace-setup.sh` before any build.
