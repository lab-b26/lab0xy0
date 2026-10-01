# Phase 2 build plan — steps 1–5 EXECUTED, 6+ not started

```text
STATUS:  PARTIALLY EXECUTED (2026-10-01)
STATE:   NOT_STARTED   (research/state.md) — see "Why the state did not move"
```

Steps 1–5 below have now been run on a real build host (a 4-core / 16 GB / 32 GB
Codespace). The outcome is not the happy path this plan anticipated:

- the newest LTS (6.18.54) **does not build** — r54p0 calls `__SetPageMovable`,
  removed upstream in v6.17 (**F-16**);
- the next candidate (6.12.111) compiled all of Kbase but **failed to link** on
  `__clk_is_enabled` (**F-17**), fixed by a research patch;
- with that patch, **6.12.111 builds and links successfully** (**F-18**).

Three attempts, three distinct blockers, all recorded. Steps 6+ (boot, validate,
package, instrumented profiles) have **not** run.

### Why the state did not move

`BASELINE_BUILT` requires "baseline kernel built and its log kept". A kernel
*was* built and the log was kept, but the state is deliberately left at
`NOT_STARTED` because:

1. `research/state.md` §36 requires a formal verification checklist per state,
   and that checklist has not been run and signed off.
2. A compile is not a build in the sense the project uses: nothing has been
   **loaded** or **booted**, so no claim beyond "it compiles and links" is
   supported. Claiming `BASELINE_BUILT` from a `make` exit code is exactly the
   kind of inference `research/methodology.md` forbids.

So the correct reading of the current position is: **the first hard blocker
ahead of this project has been cleared**, and the state ledger stays honest.

## What the executed steps actually cost

Measured on the build host, for planning the remaining profiles:

| Item | Measured |
|---|---|
| Linux tarball (`.tar.xz`) | 141 MB |
| Extracted source | ~1.7 GB |
| One `O=` build output | ~1.5 GB (after the build) |
| Kernel compile, 4 jobs | ~15 min |
| Peak disk during one profile | ~4.5 GB |

The 32 GB Codespace disk therefore fits **one profile at a time** with room to
spare, which matches the prune-and-rebuild strategy in `BUILD-HOST.md`. It is
*below* the 25 GB comfortable threshold, so `preflight.sh` warns (not fails)
and `codespace-setup.sh --check` reports it as a problem. Building `kasan`
next is feasible; building all four without pruning is not.

## Order of operations (do not reorder)

```text
0. clone this repo on the build host
1. kernel/scripts/codespace-setup.sh    # DONE — machine spec, deps, identity, gh
2. kernel/scripts/preflight.sh          # DONE — READY
3. fill kernel/sources/kernel.pin       # DONE — 6.12.111 (+ why not 6.18.54)
4. kernel/scripts/fetch-kernel.sh       # DONE — checksum verified
5. kernel/scripts/apply-patches.sh      # DONE — 6/6 vendor + 1 research patch
6. kernel/scripts/build.sh --profile baseline     # DONE — compiles and links (F-18)
7.   ... boot + validate + package baseline ...   # PARTIAL — boot/load/target VERIFIED (F-19); packaging NOT DONE
8. kernel/scripts/build.sh --profile kasan        # DONE — builds, boots, probe passes under KASAN, 0 reports (F-20/F-21 fixed en route)
9. kernel/scripts/build.sh --profile kcov         # IN PROGRESS
10. kernel/scripts/build.sh --profile debug
11. rootfs + QEMU + artifact packaging + clean-location test
```

**Baseline first, alone.** It answers the one question everything else depends on:
does r54p0 + the six patches + the chosen kernel compile at all? Do not build four
profiles in parallel on a 4-vCPU host, and do not start the instrumented variants
until baseline works. That question is now answered: **yes, on 6.12.111** (F-18),
after three failed attempts (F-14, F-16, F-17).

Step 7 is where compilation stopped being the only claim. It is now **partially**
done, and the split matters:

- **VERIFIED (F-19):** the module *loads* (`insmod` rc=0), a GPU target
  initialises (`arch 14.8.5` = `tDRx`), `/dev/mali0` appears, and the EL0 ioctl
  surface answers all nine probe phases (`passed=0x1ff failed=0x000`). Evidence in
  `../research/boot-logs/`. This required building tooling that did not exist:
  `qemu/rootfs/build-rootfs.sh`, `qemu/scripts/{run.sh,verify-boot.sh}`, and
  `qemu/target/kbase-probe.c`.
- **NOT DONE:** artifact packaging and the clean-location portability test. No
  `artifacts/<profile>/` bundle exists — `../artifacts/README.md` still reads
  "artifacts produced: 0" — so `PORTABLE_ARTIFACT_VERIFIED` is **not** reached and
  must not be claimed. Step 11 remains the real step 7 remainder.

Per DECISION-1 all of the above is **DISCOVERY-ONLY**, and `../research/state.md`
stays `NOT_STARTED`: the state ladder requires formal one-at-a-time checklist
transitions, which this phase has not run.

## Step 2 — choosing the kernel version — RESOLVED, with a caveat

**Resolved on 2026-10-01: Linux 6.12.111** (`sources/kernel.pin`). The rule
below selected 6.18.54, the newest LTS, and that turned out not to build (F-16),
so the pin was moved to the newest LTS that r54p0 can actually build. The pin
file records both candidates and the reason, so the deviation is auditable
rather than silent.

The practical consequence for the remaining profiles: **the newest LTS is not
available**, so "newest suitable LTS" is now constrained by r54p0's real
compatibility rather than by policy. A 6.13–6.16 build is the obvious next
experiment — that is the range r54p0's own highest `KERNEL_VERSION` gate
(6.13.0) was written for, and it is the most relevant to real hardware.

### The original rule (kept, because it is still the rule)

Arm guidance (VERIFIED, `../research/program-scope.md` §4): for a new virtual test
environment, use the **latest Android Common Kernel or the latest Linux Kernel
stable/longterm release**.

So the policy is *newest suitable LTS*, not a guessed number. Concretely:

1. On the build host, query authoritative release metadata and checksums:
   ```bash
   curl -s https://www.kernel.org/releases.json
   curl -s https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc
   ```
2. Select the newest **longterm (LTS)** release.
3. Write `version=`, `url=`, `sha256=` into `kernel/sources/kernel.pin`.
4. Record the decision in `../analysis/kernel-compatibility.md` using the required
   fields:

   ```text
   Candidate:
   Source:            (authoritative URL consulted)
   Reason:
   r54p0 compatibility evidence:
   Status:
   ```

Constraints on the choice:

- Do **not** assume 4.19, 6.12, or 6.18 is correct merely because it is convenient.
- r54p0's highest observed `KERNEL_VERSION` gate is **6.13.0**, but a gate is
  **not** a proven ceiling (`../analysis/kernel-compatibility.md`). A kernel newer
  than 6.13.0 may be fine; only a successful build/boot/load proves it.
- Do not silently downgrade. If the newest LTS fails, record the exact first
  meaningful error (see *Failure handling*), diagnose the category, and only then
  try the next justified candidate.
- Do not call a kernel "supported" until build + boot + Kbase-load all pass.

## Step 5 — baseline configuration

**Do not hand-write a tiny `.config`.** The baseline is:

```text
kernel defconfig (x86_64)
        +
minimum required Kbase / virtual-device dependencies
```

The minimum set is derived from r54p0 source, not guessed. Already established
(`../analysis/kconfig-dependencies.md`):

| Requirement | Source of truth |
|---|---|
| `MALI_MIDGARD` (`=m`, tristate) | `midgard/Kconfig`; selects DMA_SHARED_BUFFER, PM_DEVFREQ, DEVFREQ_THERMAL, FW_LOADER |
| `MALI_CSF_SUPPORT=y` | r54p0 default is `n`, so it must be set explicitly |
| `MALI_EXPERT=y` | r54p0 default is **`n`** (`Kconfig:156`), so this must be set explicitly; it gates `MALI_NO_MALI`, `MALI_DEBUG`, `LARGE_PAGE_SUPPORT` |
| `MALI_DEBUG=n` | **mandatory** per program policy (`../research/program-scope.md` §8.3) and the r54p0 default (`Kconfig:197`) |
| `MALI_NO_MALI=y` | no real GPU; requires `MALI_EXPERT` |
| `MALI_NO_MALI_DEFAULT_GPU="tDRx"` | latest GPU target defined by r54p0 (DECISION-2); Arm's guide uses the older `tKRx` |
| `MALI_PLATFORM_NAME="vexpress"` | selects the Simulated Platform Device; **not** on the §8.3 allowlist |
| `DMA_SHARED_BUFFER`, `PM_DEVFREQ`, `DEVFREQ_THERMAL` | `Kbuild:29-39` raises `$(error …)`; set explicitly because the `=n` test misses unset symbols (F-3) |
| virtio / serial / initramfs | needed for boot + control channel |

Two of the rows above (`MALI_NO_MALI_DEFAULT_GPU`, `MALI_PLATFORM_NAME`) are outside
the program's Kbase build allowlist. That is precisely why the whole x86 virtual
environment is INVESTIGATION/DISCOVERY-ONLY (DECISION-1, §8.5): it is a
discovery harness, not a validation environment.

`kernel/configs/baseline.config` is the **starting fragment**, not a finished
config. `build.sh` seeds `build/<profile>/.config` from the kernel default and
merges the fragment.

## Step 5b — config-delta validation (mandatory before calling anything conforming)

For each profile:

1. Generate the effective config.
2. `make savedefconfig` to get a minimal representation.
3. Diff it against the approved baseline.
4. Classify **every** delta using exactly these classes:

   ```text
   NO-OP                    (already the default; setting it changed nothing)
   ALLOWLISTED              (per Arm allowlist: COMPAT / ARM64 page size /
                             KASAN* / UBSAN*)
   KCONFIG-AUTO-DEPENDENCY  (pulled in by a select; not a user policy change)
   REQUIRED                 (genuinely needed, e.g. a Kbase hard gate)
   NON-CONFORMING           (outside the allowlist)
   UNKNOWN                  (not yet understood — never silently accept)
   ```

A profile is **not** called Arm-conforming until every user-visible delta is
classified and no unexplained `NON-CONFORMING` remains.

Scope consequences already established (`../research/program-scope.md` §5–§6):

| Profile | Likely status |
|---|---|
| `baseline` | conforming if all deltas are `NO-OP` / `REQUIRED` |
| `kasan` | potentially conforming — `CONFIG_KASAN*` is allowlisted |
| `kcov` | `CONFIG_KCOV*` is **not** allowlisted → **DISCOVERY-ONLY** |
| `debug` | `DEBUG_KERNEL` / `DEBUG_INFO` not allowlisted → **DISCOVERY-ONLY** |

## Failure handling

When a build fails, record before changing anything:

```text
kernel version · Kbase release · patch state · config
exact command · compiler version
first meaningful error · dependency involved
```

Then classify the cause as one of: `Kbase/kernel API mismatch`,
`missing Kconfig dependency`, `architecture issue`, `compiler issue`,
`patch mismatch`, `vendor source issue`, `resource exhaustion`,
`build-system issue`, `configuration-policy issue`.

Failed experiments are recorded, never hidden (see `../research/methodology.md`).

## Known risks to expect

| Risk | Reference | Note |
|---|---|---|
| Kbase-side coverage instrumentation absent in an in-tree build | `MALI_KCOV` in `Mconfig` only (F-2) | needs a research patch in `kernel/patches/`; until then `kcov` yields an uninstrumented module |
| Any Kbase coverage instrumentation also forces `MALI_DEBUG=y` | `Mconfig:204` vs mandatory `MALI_DEBUG=n` (§8.3) | closing F-2 can only ever produce a non-conforming `kcov` profile — by policy, not just practice |
| New compiler vs old kernel | gcc 15.x is very new | if the pinned kernel predates it, expect `-Werror` / API churn; record it as a `compiler issue` |
| Dangling `../arbitration/` reference | F-1 | patch 0006 addresses it; confirm `make clean` behaviour |
| `tDRx` is NEWER than what Arm's guide documents (`tKRx`) | F-4 / DECISION-2 | may hit an incompletely-exercised dummy-model path; if `tDRx` fails to initialise, fall back to `tKRx` and record the deviation |
| The x86 harness is outside the §8.3 allowlist | DECISION-1 / §8.5 | `vexpress` + GPU target are unavoidable here, so **no** build in this environment can be a validation build; do not spend the build budget trying to make one |

## State discipline

Advance `../research/state.md` only after real verification:

```text
KERNEL_COMPATIBILITY_IDENTIFIED → BASELINE_BUILT → … → QEMU_BOOT_VERIFIED
→ KBASE_LOAD_VERIFIED → PORTABLE_ARTIFACT_VERIFIED
```

A `make` that returned once is not proof; module install and required
post-processing must also pass. Nothing advances until then.