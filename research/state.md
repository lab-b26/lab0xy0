# State ledger

```text
Current state: PORTABLE_ARTIFACT_VERIFIED
Updated:        2026-10-02
```

The ladder has now been formally walked, one documented transition per state,
ending at `PORTABLE_ARTIFACT_VERIFIED` on 2026-10-02 (all four bundles:
baseline, kcov, kasan, debug). `SYZKALLER_CONNECTED` and `FUZZING_STARTED` are
deliberately untouched: they require real fuzzer integration against the
packaged artifacts, which is the next phase's work, not this one's.

Note (F-41): the claim forwarded from this file's earlier revision — that Kbase
contributed zero KCOV coverage — was a harness measurement artifact, since
corrected; the verified coverage result is recorded in the
`KBASE_LOAD_VERIFIED → KCOV_VERIFIED` row and F-41.

## State ladder

Advance **one** state at a time, and only after that state's verification
checklist passes.

| State | Exit requires |
|---|---|
| `NOT_STARTED` | initial state |
| `SOURCE_INVENTORIED` | archive checksum recorded, file counts and `MALI_RELEASE_NAME` recorded |
| `KBASE_IDENTIFIED` | release id, license, build system(s) recorded |
| `PATCHES_VERIFIED` | per-patch applicability reproduced against pristine source |
| `PROGRAM_SCOPE_VERIFIED` | program page + configuration guidelines captured into `research/program-scope.md` and `research/documents/` |
| `KERNEL_COMPATIBILITY_IDENTIFIED` | gate range + ARM GUIDANCE recorded; no build yet required |
| `MINIMAL_CONFIG_DRAFTED` | provisional config fragments exist and are labelled `PROVISIONAL` |
| `BASELINE_BUILT` | baseline kernel built and its log kept |
| `KCOV_BUILT` | kcov kernel built (discovery-only) |
| `KASAN_BUILT` | kasan kernel built |
| `DEBUG_BUILT` | debug kernel built |
| `ROOTFS_BUILT` | minimal rootfs built and packaged |
| `QEMU_BOOT_VERIFIED` | QEMU boots the packaged kernel |
| `KBASE_LOAD_VERIFIED` | Kbase module loads in the guest |
| `KCOV_VERIFIED` | Kbase-side coverage actually observed |
| `PORTABLE_ARTIFACT_VERIFIED` | artifact copied to a clean location and booted with the original build tree inaccessible |
| `SYZKALLER_CONNECTED` | syzkaller reuses the packaged artifact |
| `FUZZING_STARTED` | a fuzzing campaign is running on a packaged artifact |

## Transition log

Append one row per transition. Do not edit or remove earlier rows.

| Date | State | From → To | Command / test | Result | Evidence |
|---|---|---|---|---|---|
| 2026-09-30 | `NOT_STARTED` | — → `NOT_STARTED` | n/a | organisation phase; no build performed | this file, `analysis/`, `research/documents/` |
| 2026-09-30 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `kernel/scripts/preflight.sh` | `NOT READY` (exit 1): disk 3 GB, `bison` missing, pin `UNSET` — host correctly rejected for building | `kernel/BUILD-HOST.md` |
| 2026-09-30 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `bash -n` on all 4 kernel scripts | pass; `fetch-kernel.sh` refuses with exit 1 and no network call (pin `UNSET`) | `kernel/scripts/README.md` |
| 2026-09-30 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | scope reconciliation from program text (no command; documentation change) | policy bumped to v1.1; EL0-only criterion, Kbase build allowlist, dynamic-config rule captured; 3 decisions locked (DECISION-1/2/3) | `research/program-scope.md`, `analysis/findings.md` |
| 2026-09-30 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | re-read of r54p0 `Kconfig` + `mali_kbase_model_dummy.c` (grep/read only, no build) | `MALI_EXPERT` default `n` (not `y`) and `MALI_DEBUG` default `n` (not `y if DEBUG`) — two documented defaults were wrong and are fixed; latest GPU target = `tDRx` | `analysis/kconfig-dependencies.md`, `analysis/findings.md` F-4 |
| 2026-09-30 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | static review of `build.sh` + `driver/gpu/arm/{Makefile,Kbuild}` inspection (no build, no network) | `build.sh` had 4 defects, 3 of them silent (F-10); a 5th hard Kbase gate `CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND` was missing from all fragments (F-11); `.gitignore` did not exclude the 140 MB kernel tarball cache | `analysis/findings.md` F-10/F-11, `kernel/scripts/build.sh` |
| 2026-09-30 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `build.sh --profile baseline` against a **stubbed** kernel tree (fake `make` shell stub) | control flow verified: staging, kbuild-ify, wiring, merge, metadata; and all three step-5 outcomes — refuses to build on a missing symbol and on a clobbered value | `kernel/scripts/README.md` |
| 2026-09-30 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `bash -n` on all 6 then-current kernel scripts; `bootstrap.sh --check` | pass; `--check` agrees with `preflight.sh` that `bison` + `libelf-dev` are missing here | `kernel/scripts/README.md` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `codespace-setup.sh` in all modes against an **isolated repo copy** with a fake `HOME` and stubbed `apt-get`/`sudo` | machine-spec gate, repo-local git identity derived from the GitHub handle, SSH keygen + `~/.ssh/config` write, HTTPS remote switch, `gh` install, auto-stop advice, and the `preflight.sh` verdict all behave correctly; this host's real `~/.ssh` and git config confirmed untouched | `kernel/scripts/codespace-setup.sh`, `kernel/scripts/README.md` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | attempted Codespace creation from this repository (no kernel work attempted; creation failed before any build) | **FAILED to provision**: "no machine types are available" — the committed `.devcontainer/` `hostRequirements` (4 cpu / 16 gb / 64 gb) is not offered by this account, and GitHub refuses to create the codespace rather than falling back. Resolved by **removing `.devcontainer/`** (F-12); build host now comes from the default Codespaces image with machine size chosen manually | `analysis/findings.md` F-12, `kernel/BUILD-HOST.md` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `preflight.sh` on the real build host (Codespace, 4 cpu / 16 GB / 32 GB disk) | **READY** (exit 0). 18 GB free = WARN (tight, one profile at a time), not FAIL. All tools, headers, QEMU and `/dev/kvm` present; vendor + patch checksums verify. Machine is 32 GB, **not** the 64 GB `BUILD-HOST.md` prefers — enough for one profile, prune between builds | `kernel/BUILD-HOST.md` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `resolve-kernel-pin.sh --dry-run` | **FAILED** (404) — the script built `v6.18/…` from the version string, but kernel.org files the current series under `v6.x`/`v7.x`. Second bug: whitespace `read` shifted five `releases.json` fields into the wrong variables. **Fixed** (F-13), re-run selects 6.18.54 with the authoritative URL + checksum | `analysis/findings.md` F-13 |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `fetch-kernel.sh` (6.18.54) + `apply-patches.sh` | fetch: checksum **OK**, tree extracted. patches: **6/6 applied**, series hash `230c9a71…`, both spot-checks present. First network + first extraction performed in this project | `kernel/sources/kernel.pin`, `kernel/scripts/README.md` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `build.sh --profile baseline` on 6.18.54, first real build | **FAILED twice, then reached the compiler**: (1) `make defconfig` died on a C comment written into `drivers/gpu/Kconfig` — **fixed** (F-14); (2) step 5/8 rejected the mandatory `CONFIG_MALI_DEBUG=n` because it greps only `^CONFIG_X=`, while kconfig writes `# CONFIG_X is not set` — **fixed** (F-15). All three are tooling defects, exactly the F-10 class | `analysis/findings.md` F-14, F-15 |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `build.sh --profile baseline` on 6.18.54, third attempt | **BUILD FAILED — first real kernel-build result in this project.** ~2 900 objects compiled; step 5/8 passed (13/13 symbols, 0 problems) and 5 Kbase objects compiled, then `mali_kbase_mem_migrate.c:83,158`: implicit declaration of `__SetPageMovable` / `__ClearPageMovable`. VERIFIED cause: removed from `include/linux/migrate.h` in v6.17; present in v6.12–v6.16; r54p0 calls them **unguarded**. Not a config or patch problem. 6.18.54 tree and build output pruned; log kept | `analysis/findings.md` **F-16**, `research/build-logs/6.18.54-baseline-FAILED.log` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | re-pin to **6.12.111** per `kernel.pin`'s "next justified candidate" rule, then `fetch-kernel.sh` | fetch: checksum **OK**. Pin records *why* this is a step down from the newest LTS (F-16) rather than silently moving. 6.12 sits below r54p0's highest observed gate (6.13.0), so it is the conservative choice as well as the evidenced one | `kernel/sources/kernel.pin`, `analysis/kernel-compatibility.md` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `build.sh --profile baseline` on 6.12.111 | **Kbase COMPILED IN FULL** — 128 objects, all 149 sources reached, 0 errors, 0 Kbase warnings — then **modpost FAILED**: `__clk_is_enabled` undefined in `mali_kbase.ko`. VERIFIED cause: declared unconditionally in `clk-provider.h` but defined only under `CONFIG_COMMON_CLK`, which `x86_64_defconfig` leaves off; all sibling `clk_*` calls are no-op stubs, so it is the *only* undefined symbol. A link-time failure class that step 5/8 cannot see | `analysis/findings.md` **F-17**, `research/build-logs/6.12.111-baseline-FAILED-modpost.log` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | wrote `kernel/patches/0001-kbase-guard-clk-is-enabled-behind-COMMON_CLK.patch`; extended `apply-patches.sh` to apply research patches after the vendor series with a separate series hash | patch **applies** (1/1) after 6/6 vendor patches. Chosen over `CONFIG_COMMON_CLK=y` because that would be a §5 config delta outside the allowlist; the patch keeps plain `x86_64_defconfig` and introduces **no** config delta. Labelled a **build fix, not a behaviour change**, with the equivalence argued for both settings of `CONFIG_COMMON_CLK` | `kernel/patches/0001-*.patch`, `kernel/patches/README.md`, `analysis/findings.md` F-17 |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `build.sh --profile baseline` on 6.12.111 with the F-17 research patch | **BUILD SUCCEEDED** — 3 063 objects, 0 errors, 0 undefined symbols, ~15 min on 4 cores. `mali_kbase.ko` (2.4 MB, 3 627 symbols) + `bzImage` (13.6 MB) + 10 modules. Verified beyond exit 0: `modinfo` shows `r54p0-01eac0 (UK version 1.36)`, `intree: Y`, `vermagic 6.12.111`; the `vexpress` backend and the `tDRx` target are really in the binary; `MALI_DEBUG=n` honoured (no `kbase_dbg_*`). **Still `NOT_STARTED`**: this is a COMPILE result only — the module has not been loaded | `analysis/findings.md` **F-18**, `build/baseline/build-metadata.txt` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | QEMU boot + `insmod mali_kbase.ko` + custom EL0 probe (`qemu/target/kbase-probe.c`) from a cpio rootfs (`qemu/rootfs/build-rootfs.sh` + `qemu/scripts/{run.sh,verify-boot.sh}`) | **VERIFIED (F-19):** module loads (rc=0), `mali mali.0: Kernel DDK version r54p0-01eac0`, `/dev/mali0` created (10,258), `GPU identified as 0x0 arch 14.8.5 r0p0` (tDRx). EL0 ioctl surface: passed=0x1ff failed=0x000 across all phases (open, VERSION_CHECK negotiated 1.36, SET_FLAGS, GET_GPUPROPS 773 bytes, MEM_ALLOC returned cookie gpu_va=0x41000, mmap bound region, MEM_QUERY, munmap). Two undocumented contracts recorded: SET_FLAGS required before other ioctls; SAME_VA cookie must be mmap()ed (not used as a pointer). `research/state.md` remains `NOT_STARTED` by design (ladder requires one-at-a-time formal transitions); boot/load/target is DISCOVERY-ONLY (DECISION-1). | `research/boot-logs/*`, `qemu/target/kbase-probe.c`, `analysis/findings.md` **F-19**, `build/baseline/*` (where present) |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | kasan profile: build.sh fragment merge fix (F-20) + `kasan.config` choice resolved to NO_MALI=y + tDRx (F-21); `build.sh --profile kasan` completed | **BUILD SUCCEEDED:** fragment merge now preserves `# CONFIG_X is not set` and deduplicates symbols; step 5/8 verified all 16 fragment symbols took effect (including `CONFIG_MALI_NO_MALI=y`, `# CONFIG_MALI_REAL_HW is not set`, `MALI_NO_MALI_DEFAULT_GPU="tDRx"`, `MALI_PLATFORM_NAME="vexpress"`). `CONFIG_KASAN=y`/`GENERIC`/`INLINE` confirmed in the effective `.config`; `mali_kbase.ko` 2.4 MB → 5.1 MB, consistent with instrumentation | `analysis/findings.md` **F-20,F-21**, `build/kasan/build-metadata.txt`, `kernel/scripts/build.sh`, `kernel/configs/kasan.config` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `build-rootfs.sh --profile kasan` + `verify-boot.sh --profile kasan` | **VERDICT: PASS** — all 5 assertions ok. `kasan: KernelAddressSanitizer initialized` in guest; Kbase loads and the EL0 probe passes `passed=0x1ff failed=0x000`. **Zero KASAN reports** (grepped for `BUG: KASAN`/`use-after-free`/`out-of-bounds`: no hits; zero `BUG:`/`WARNING:`/`Call Trace:`). This is a clean instrumented run of the probe path only — **NOT** a fuzzing result, and NOT a conformance claim (DECISION-1: DISCOVERY-ONLY) | `research/boot-logs/20261001T090429Z-kasan-BOOT.log`, `analysis/findings.md` **F-19** |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `build.sh --profile kcov` (15/15 fragment symbols, incl. `CONFIG_KCOV`+`INSTRUMENT_ALL`) | **BUILD SUCCEEDED** — config sha `2b3142d9…c7b7`, `bzImage` 17 MB, `mali_kbase.ko` 3.5 MB. Independent confirmation of the F-20 merge fix on a second fragment. **Not yet booted.** | `build/kcov/build-metadata.txt`, `kernel/configs/kcov.config` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | new `qemu/scripts/package-artifact.sh`; package `baseline`; `verify-boot.sh --artifact` from `/tmp` **with `build/` renamed away**; `sha256sum -c` | **VERIFIED (F-22): `artifacts/baseline` = `PORTABLE_ARTIFACT_VERIFIED`** (68 MB, 16 files, identity `kbase-r54p0-01eac0-6.12.111-baseline`, integrity 16/16 OK). All 5 assertions pass from a relocated copy with no build tree present, so self-containment is demonstrated, not assumed. **Defect found and fixed by doing it:** `run.sh` resolved `bzImage` from the artifact but the **rootfs only from `build/rootfs/`**, so a relocated bundle stayed repo-dependent — rootfs now uses the same artifact-first candidate order. Scope class recorded separately as `DISCOVERY-ONLY` so portability is never misread as conformance | `analysis/findings.md` **F-22**, `artifacts/baseline/metadata/manifest.json`, `qemu/scripts/package-artifact.sh`, `research/boot-logs/20261001T093246Z-baseline-BOOT.log` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `verify-boot.sh --profile kcov`, after teaching the rootfs KCOV's real ioctl+mmap protocol | **VERDICT: PASS** — all 5 assertions. First **quantitative coverage** in the project: `records=14495 distinct_pcs=2882` (range `0xffffffff8103d11d`–`0xffffffff812da9f5`, not truncated). **F-23: every PC is inside vmlinux's own text segment, so Kbase contributed ZERO coverage** — `mali_kbase.ko` is a module at `0xffffffffc0000000`+, ~2.4 GB above the highest PC seen. This closes F-2 by *measurement*: a coverage-guided fuzzer here would optimise kernel paths and score every Kbase input identically while appearing healthy. Four silent-failure traps in KCOV's userspace API are recorded in F-23 (ioctl not write; `INIT_TRACE` takes the size as the argument; one fd for the whole cycle; counters via mmap as a PC **list**, not a bitset — popcounting it gave a meaningless `656023`). Scope: DISCOVERY-ONLY | `analysis/findings.md` **F-23**, `research/boot-logs/20261001T102818Z-kcov-BOOT.log`, `qemu/rootfs/build-rootfs.sh` |
| 2026-10-01 | `NOT_STARTED` | `NOT_STARTED` → `NOT_STARTED` | `package-artifact.sh --profile kcov`; `sha256sum -c` | **PACKAGED (not portable-tested):** `artifacts/kcov`, 80 MB, 16 files, integrity 16/16 OK, state `TARGET_VERIFIED`, scope `DISCOVERY-ONLY`. The clean-location test was run for `baseline` only | `artifacts/kcov/metadata/manifest.json` |
| 2026-10-02 | `NOT_STARTED` | `NOT_STARTED` → `SOURCE_INVENTORIED` | formal checklist replay of `analysis/source-inventory.md` | PASS — archive checksum recorded (`vendor/arm/SHA256SUMS`), 441 files, `MALI_RELEASE_NAME` at `Kbuild:66`; release id r54p0-01eac0 | `analysis/source-inventory.md`, test-matrix E-001 |
| 2026-10-02 | `SOURCE_INVENTORIED` | `SOURCE_INVENTORIED` → `KBASE_IDENTIFIED` | checklist replay of `analysis/kbase-version.md` | PASS — release id, licence (GPL-2.0), build systems (in-tree Kbuild / Android SCons) recorded | `analysis/kbase-version.md` |
| 2026-10-02 | `KBASE_IDENTIFIED` | `KBASE_IDENTIFIED` → `PATCHES_VERIFIED` | checklist replay of `analysis/virtual-device.md` | PASS — per-patch applicability reproduced against pristine r54p0 (6/6, matrix); `apply-patches.sh` re-verified on 2026-10-02 run | `analysis/virtual-device.md`, test-matrix E-002 |
| 2026-10-02 | `PATCHES_VERIFIED` | `PATCHES_VERIFIED` → `PROGRAM_SCOPE_VERIFIED` | checklist replay of `research/program-scope.md` + `research/documents/` | PASS — program page, configuration guidelines (v20250623-1.0), Kbase config and insmod allowlists captured; policy v1.1 | `research/program-scope.md`, test-matrix E-003 |
| 2026-10-02 | `PROGRAM_SCOPE_VERIFIED` | `PROGRAM_SCOPE_VERIFIED` → `KERNEL_COMPATIBILITY_IDENTIFIED` | checklist replay of `analysis/kernel-compatibility.md` | PASS — gate range recorded (44/48 gates, max 6.13.0/6.18.0); Arm "latest ACK/LTS" guidance recorded; pin decided by build evidence (F-16/F-17/F-18) = 6.12.111 | `analysis/kernel-compatibility.md`, `kernel/sources/kernel.pin` |
| 2026-10-02 | `KERNEL_COMPATIBILITY_IDENTIFIED` | `KERNEL_COMPATIBILITY_IDENTIFIED` → `MINIMAL_CONFIG_DRAFTED` | four profile fragments exist and have since been driven to built+verified | PASS — `kernel/configs/{baseline,kasan,kcov,debug}.config` | `kernel/configs/` |
| 2026-10-02 | `MINIMAL_CONFIG_DRAFTED` | `MINIMAL_CONFIG_DRAFTED` → `BASELINE_BUILT` | `build.sh --profile baseline` (log kept) | PASS — 3,063 objects, `mali_kbase.ko` 2.4 MB + `bzImage` 13.6 MB, vermagic 6.12.111 (F-18) | `analysis/findings.md` F-18, `research/build-logs/` |
| 2026-10-02 | `BASELINE_BUILT` | `BASELINE_BUILT` → `KCOV_BUILT` | `build.sh --profile kcov` | PASS — 16/16 fragment symbols (incl. `CONFIG_KCOV_ENABLE_COMPARISONS=y`, F-33 fix), `bzImage` 19.5 MB, `mali_kbase.ko` 4.0 MB | `build/kcov/build-metadata.txt` |
| 2026-10-02 | `KCOV_BUILT` | `KCOV_BUILT` → `KASAN_BUILT` | `build.sh --profile kasan` (F-20/F-21 merge fixes applied) | PASS — `CONFIG_KASAN=y/GENERIC/INLINE` in effective config; `mali_kbase.ko` 5.1 MB | `build/logs/kasan.log`, test-matrix E-007 |
| 2026-10-02 | `KASAN_BUILT` | `KASAN_BUILT` → `DEBUG_BUILT` | `build.sh --profile debug` | PASS — 16/16 fragment symbols, DWARF5 verified in the image via `readelf` (F-24 fix) | `build/logs/debug.log`, TODO P3 |
| 2026-10-02 | `DEBUG_BUILT` | `DEBUG_BUILT` → `ROOTFS_BUILT` | `build-rootfs.sh` for all four profiles | PASS — `build/rootfs/rootfs-{baseline,kcov,kasan,debug}.cpio.gz` produced, contents verified by the boots below | `build/rootfs/` |
| 2026-10-02 | `ROOTFS_BUILT` | `ROOTFS_BUILT` → `QEMU_BOOT_VERIFIED` | `verify-boot.sh` (7 assertions incl. negargs battery) for all four profiles | PASS — serial logs committed | `research/boot-logs/` |
| 2026-10-02 | `QEMU_BOOT_VERIFIED` | `QEMU_BOOT_VERIFIED` → `KBASE_LOAD_VERIFIED` | `insmod mali_kbase.ko` rc=0; `Probed as mali0`; EL0 probe `passed=0x1ff failed=0x000` (F-19) | PASS | `analysis/findings.md` F-19, `research/boot-logs/*-baseline-BOOT.log` |
| 2026-10-02 | `KBASE_LOAD_VERIFIED` | `KBASE_LOAD_VERIFIED` → `KCOV_VERIFIED` | `kcov-ctl --inline-probe`, module-range counting corrected for KASLR canonicalization | **PASS — `KCOV module_pcs=1678` distinct module PCs (records=596,005) from the 9-phase probe; windowed open+read independently shows module hits.** F-23's "module contributes zero" superseded by F-41 (harness measurement-defect chain F-33/F-36) | `analysis/findings.md` F-41, `qemu/target/kcov-ctl.c`, `research/boot-logs/20261002T055951Z-kcov-BOOT.log` |
| 2026-10-02 | `KCOV_VERIFIED` | `KCOV_VERIFIED` → `PORTABLE_ARTIFACT_VERIFIED` | all four bundles re-packaged and relocation-booted with `--strict-artifact` from a clean location with the build tree inaccessible | PASS — 4× `PORTABLE_ARTIFACT_VERIFIED` (F-22 for baseline on 2026-10-01; kcov/kasan/debug on 2026-10-02; tiers B/C held throughout) | `artifacts/*/metadata/manifest.json`, `research/boot-logs/20261002T0435*Z-*-PORTABLE.log` |

To record a transition:

```text
Date:
State:
From -> To:
Command/test:
Result:
Evidence:
```

## Notes on currently-satisfiable states

Nothing left open below `PORTABLE_ARTIFACT_VERIFIED`: every state through it
now has a signed-off transition row (2026-10-02) with its evidence. The next
states — `SYZKALLER_CONNECTED`, `FUZZING_STARTED` — are unexplored territory by
design: they are the fuzzing phase, not the organisation phase.

## Resource constraints on future states

The build states are **not** being attempted on the machine that organised this
repository. Measured here (VERIFIED): 3.8 GB free disk (96% used), 7.4 GB RAM total
but only ~1.6–2.0 GB available, 4 vCPU, `/dev/kvm` present, and **`bison` missing**
(plus libelf headers missing and no `qemu-system-x86_64`). A kernel build here
would fail for environment reasons before it tested anything about Kbase.

The build is therefore **deferred by decision** to a separate build host with
25–40+ GB free disk and 8–16 GB RAM (`kernel/BUILD-HOST.md`). What was delivered
instead is the tooling to make that run reproducible elsewhere: `preflight.sh`
(ran here read-only and correctly reported `NOT READY`), a pinned checksum-verified
`fetch-kernel.sh`, `apply-patches.sh`, a shared `build.sh`, and `kernel/BUILD-PLAN.md`.

The build-host deferral above was **resolved on 2026-10-01** by standing up a
32 GB Codespace with `codespace-setup.sh` (kernel/BUILD-HOST.md; F-12), after
which the entire ladder below was walked state-by-state (table above). The text
in this section predates the walk and is kept because the scope constraints it
states are still binding; the stale operational claims it used to carry
("`fetch-kernel.sh` has performed no download", "the pin is still UNSET") have
been removed rather than left to contradict the table.

## Scope constraints that shape every future state

Recorded here because they change what a future state may *claim* (details and
sources in `research/program-scope.md` §8):

- The x86 `MALI_NO_MALI` / `vexpress` environment is **INVESTIGATION/DISCOVERY-ONLY**
  (DECISION-1). It needs `MALI_PLATFORM_NAME` and a GPU target, neither on the
  program allowlist, so **no** state above `KBASE_LOAD_VERIFIED` that relies on the
  virtual harness can be a *validation* environment. This caps what QEMU-based
  states can prove.
- `CONFIG_MALI_DEBUG=n` is mandatory, so any Kbase coverage work (F-2) forces a
  non-conforming build — the `KCOV_VERIFIED` state is therefore a discovery
  milestone only.
- Only **EL0 / unprivileged-syscall** exposure is in scope (§8.2).
- Dynamic configuration must use default module parameters; the permitted `insmod`
  override list is **truncated** in the available program text (UNKNOWN).

These constraints remain binding at `PORTABLE_ARTIFACT_VERIFIED` and are exactly
why `SYZKALLER_CONNECTED` and `FUZZING_STARTED` were not entered: both would be
discovery-phase milestones over this harness, and they have not been reached.

On the build host, expect to build one profile, package it, record its checksum,
then delete the build tree before the next — the `one source tree / many O=
outputs` design in `artifacts/README.md` exists to make this tractable.