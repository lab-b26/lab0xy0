# Test matrix

One row per experiment actually run. Rows are appended, never rewritten — a
superseded result gets a new row that supersedes the old one.

Scope classes (`IN SCOPE` / `DISCOVERY-ONLY` / `EXCLUDED` / `UNKNOWN`) are the
**authoritative policy** in `../program-scope.md`. This matrix only records how a
given experiment was classified **at the time it was run**.

## Columns

| Column | Notes |
|---|---|
| ID | `E-001`, `E-002`, … |
| Purpose | what the experiment decides |
| Profile | `baseline` / `kcov` / `kasan` / `debug` / `n-a` |
| Kbase release | `r54p0-01eac0` etc. |
| Kernel release | `UNKNOWN` until a build picks one |
| Patch set | which patches applied |
| Config hash | hash of the config fragment; `UNKNOWN` until a real `.config` exists |
| Scope class | per `../program-scope.md` |
| Build / Boot / Kbase load / Coverage / Fuzzer / Artifact | status word each |
| Evidence | command or log that produced the result |

Status words: `NOT_STARTED`, `PASS`, `FAIL`, `PARTIAL`, `UNKNOWN`, `N/A`.

## Current rows

| ID | Purpose | Profile | Kbase | Kernel | Patches | Config hash | Scope | Build | Boot | Kbase | Cov | Fuzzer | Artifact | Evidence |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| E-001 | Confirm archive integrity + release id | n-a | r54p0-01eac0 | n-a | n-a | n-a | N/A | N/A | N/A | N/A | N/A | N/A | N/A | `sha256sum` → `3b2049aa…acc121`; `MALI_RELEASE_NAME` at `Kbuild:66`; `analysis/source-inventory.md` |
| E-002 | Reproduce per-patch applicability | n-a | r54p0 / r56p0 | n-a | 0001–0006 | n-a | N/A | N/A | N/A | N/A | N/A | N/A | N/A | `git apply --check -p1` per patch on fresh extractions; `analysis/virtual-device.md` |
| E-003 | Capture program scope + allowlist | n-a | n-a | n-a | n-a | n-a | N/A | N/A | N/A | N/A | N/A | N/A | N/A | Intigriti page + `…guidelines.pdf` (`20250623-1.0`) → `research/program-scope.md` |
| E-004 | Identify kernel-version guidance + gate range | n-a | r54p0 / r56p0 | UNKNOWN | n-a | n-a | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 44/48 gates, max 6.13.0/6.18.0; ARM GUIDANCE latest ACK/LTS; `analysis/kernel-compatibility.md` |
| E-005 | Establish NO_MALI swap surface (what stays in scope) | n-a | r54p0-01eac0 | n-a | n-a | n-a | see F-8 | N/A | N/A | N/A | N/A | N/A | N/A | `csf/Kbuild:49-56` swaps 2 objects; ioctl/MMU/mem paths remain; `analysis/findings.md` F-8 |
| E-006 | Boot 6.12.111 + `baseline`, load Kbase, exercise the EL0 ioctl surface | `baseline` | r54p0-01eac0 | 6.12.111 | vendor 0001–0006 + research 0001 (F-17) | `515ce13d…823e9` | PASS | PASS | PASS | N/A | N/A | NOT_PACKAGED | `insmod` rc=0; `GPU identified as 0x0 arch 14.8.5 r0p0` (tDRx); `/dev/mali0` 10,258; probe `passed=0x1ff failed=0x000`. Two undocumented contracts found: `SET_FLAGS` mandatory before other ioctls; `MEM_ALLOC.out.gpu_va` is a `SAME_VA` cookie requiring `mmap`. `research/boot-logs/*-baseline-BOOT.log`; `analysis/findings.md` F-19 |
| E-007 | Repeat E-006 under KASAN; does the instrumented driver run clean? | `kasan` | r54p0-01eac0 | 6.12.111 | vendor 0001–0006 + research 0001 (F-17) | `5af7eca0…aa99` | PASS | PASS | PASS | N/A | N/A | NOT_PACKAGED | `kasan: KernelAddressSanitizer initialized`; all 5 verify-boot assertions ok; probe `passed=0x1ff failed=0x000`; **zero** KASAN reports (grepped `BUG: KASAN`/`use-after-free`/`*-out-of-bounds`: none) and zero `BUG:`/`WARNING:`/`Call Trace:`. Clean run of the **probe path only** — not a fuzzing result. `research/boot-logs/20261001T090429Z-kasan-BOOT.log`; F-19 |
| E-008 | Can the baseline be packaged and booted from a clean location? | `baseline` | r54p0-01eac0 | 6.12.111 | vendor 0001–0006 + research 0001 (F-17) | `515ce13d…823e9` | PASS | PASS | PASS | N/A | N/A | **PASS (`PORTABLE_ARTIFACT_VERIFIED`)** | Bundle `artifacts/baseline` (68 MB, 16 files, id `kbase-r54p0-01eac0-6.12.111-baseline`); `sha256sum -c` 16/16 OK from a copy; booted from `/tmp` **with `build/` renamed away** → all 5 assertions ok. Surfaced a real defect: `run.sh` resolved the rootfs only from `build/rootfs/`, making relocated bundles repo-dependent; fixed. `analysis/findings.md` F-22 |
| E-009 | Does `kcov` build at all in-tree? | `kcov` | r54p0-01eac0 | 6.12.111 | vendor 0001–0006 + research 0001 (F-17) | `2b3142d9…c7b7` | PASS | NOT TESTED | NOT TESTED | NOT TESTED | N/A | NOT_PACKAGED | Build succeeded (15/15 fragment symbols, `CONFIG_KCOV=y` + `INSTRUMENT_ALL=y`); `bzImage` 17 MB, `mali_kbase.ko` 3.5 MB. **Kernel-side coverage only** — Kbase itself is still uninstrumented (F-2: `MALI_KCOV` exists only in the Android/SCons `Mconfig`, never read by an in-tree build). Not booted, so the Coverage columns stay `NOT TESTED` |

Notes on the rows above:

- **Scope class for all of these is DISCOVERY-ONLY** (DECISION-1). The x86_64 +
  `MALI_NO_MALI` harness cannot produce Arm-conforming validation evidence
  regardless of how clean the run is. `PORTABLE_ARTIFACT_VERIFIED` in E-008 is a
  *reproducibility* result, not a conformance one.
- **`NOT_PACKAGED` is accurate** for E-006/E-007: those runs predate packaging.
  Only `baseline` has a bundle today.
- **E-009 is a build result only.** It records that `kcov` compiles; the coverage
  columns stay `NOT TESTED` until it is actually booted, and Kbase-level coverage
  stays blocked on F-2 regardless.
- **Kernel release 6.12.111** because 6.18.54 does not build (F-16). Coverage
  (`KCOV`) columns stay `N/A` until a `kcov` profile is built and booted.
- E-007 required fixing the fragment merge first: the old `build.sh` deleted
  every `# CONFIG_X is not set` line, so the Kbase backend choice silently
  resolved to `MALI_REAL_HW=y` (F-20), and `kasan.config` named no choice member
  at all (F-21). Both fragments now merge deterministically.

No build had been performed when rows E-001–E-005 were recorded; their Build/Boot/
Kbase/Coverage/Fuzzer/Artifact columns are `N/A` for that reason. Rows are
appended as work proceeds.

## Scope-class guidance for planned rows

| Planned experiment | Expected class | Why |
|---|---|---|
| Boot baseline, load Kbase, run a PoC on a conforming kernel | `IN SCOPE` | default config, per §5 |
| ASAN/UBSAN crash on a conforming config | `IN SCOPE` | `CONFIG_KASAN*`/`CONFIG_UBSAN*` allowed, per §5 |
| Anything in the x86 `MALI_NO_MALI` / `vexpress` harness | `DISCOVERY-ONLY` | `MALI_PLATFORM_NAME` + GPU target are outside the §8.3 Kbase allowlist (DECISION-1) |
| Coverage-guided triage under KCOV | `DISCOVERY-ONLY` | KCOV not on allowlist (§5) **and** Kbase-side coverage requires `MALI_DEBUG=y` (§8.3, `Mconfig:204`) |
| Behaviour seen only under instrumentation | `EXCLUDED` | per §6 |
| Crash only reachable via debugfs | `EXCLUDED` | program exclusion |
| Crash only reachable via `MALI_KUTF` TEST config | `EXCLUDED` | program exclusion |
| Crash in the `MALI_NO_MALI` dummy model | `EXCLUDED` | program exclusion ("dummy model"); see F-8 |
| Crash requiring privilege above EL0 (kernel-mode, or only after an in-kernel foothold) | `EXCLUDED` | EL0-only criterion, §8.2 |
| Any Linux-kernel-side bug | `EXCLUDED` | program exclusion |
| Crash in the supplied virtual-device patches | `EXCLUDED` | program exclusion |

Two scope criteria apply to **every** row, regardless of environment:

1. **EL0 only** — the impact must be reachable through unprivileged syscalls
   (§8.2). Anything needing privileged execution is out of scope even if the code
   path is real.
2. **Dynamic config must be default** — findings are produced with default module
   parameters (§8.4). The permitted `insmod` override list is **truncated** in the
   available program text (UNKNOWN), so an experiment that depends on an override
   cannot currently be classified.

The boundary that matters for planning: the harness necessarily contains excluded
code, but the in-scope Kbase ioctl/MMU/memory paths remain reachable under
`MALI_NO_MALI=y` (F-8). So the discovery surface is legitimately large; only
triaged findings need the scope filter, and that filter is applied **after**
discovery, per `../program-scope.md` §6. GPU target for all such experiments is
`tDRx` (DECISION-2).