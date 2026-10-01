# State ledger

```text
Current state: NOT_STARTED
Updated:        2026-10-01
```

A build is running on the build host right now (`baseline`, Linux 6.12.111,
with `kernel/patches/0001-*`). `NOT_STARTED` is still correct until that
succeeds *and* its verification checklist is run: three separate builds have
now been attempted and three distinct blockers found (F-14, F-16, F-17). The
`NOT_STARTED` label is being earned, not assumed.

`NOT_STARTED` is correct for this phase. This repository is in the
**organisation + source-analysis + scope-evidence** phase: nothing has been built,
booted, loaded, or fuzzed. Evidence gathered so far (source inventory, patch
applicability, program scope, kernel-version analysis) is real, but it does not
satisfy any of the build states below — those each require an executed command
whose output is recorded.

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

The evidence gathered in this phase would appear to justify
`SOURCE_INVENTORIED`, `KBASE_IDENTIFIED`, `PATCHES_VERIFIED`,
`PROGRAM_SCOPE_VERIFIED`, and `KERNEL_COMPATIBILITY_IDENTIFIED`. They are **not
marked reached** because §36 of the project spec requires a formal verification
checklist per state, and this phase explicitly forbids the building/booting that
the later states need. The evidence itself is recorded in `analysis/` and
`research/`; promoting these states is a one-line change once the checklists are
run and signed off, and is left to the next phase rather than assumed here.

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

**None of those scripts has run a build, and `fetch-kernel.sh` has performed no
download** — the pin is still `UNSET`, so it refuses before any network call.

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

None of this changes `NOT_STARTED`; it constrains how these states may be entered.

On the build host, expect to build one profile, package it, record its checksum,
then delete the build tree before the next — the `one source tree / many O=
outputs` design in `artifacts/README.md` exists to make this tractable.