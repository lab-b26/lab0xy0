# TODO.md — the ordered plan, and what each step is allowed to claim

**This file is the repository's live task list.** It is not a wish list: every
`DONE` line carries an `Evidence:` line, and `check/check-all.sh` check **A12**
verifies that the cited evidence actually exists. A step cannot be marked done by
assertion.

**Scope class: DISCOVERY-ONLY** (DECISION-1). The x86_64 + `MALI_NO_MALI` harness is
INVESTIGATION-ONLY. Nothing here can produce an Arm-conforming validation result,
and no step below may be described as if it could. A clean boot in this repository
is a statement about a simulator build, never about real hardware.

---

## The rule that shapes everything here

> A compile is not a loaded driver. A boot is not a packaged artifact.
> A packaged artifact is not a portable one.

Three of the four profiles have already earned their way up that ladder, and each
step below is one rung. The validation ladder for a bundle is:

```
BUILT → TARGET_VERIFIED → QEMU_BOOT_VERIFIED → KBASE_LOAD_VERIFIED
      → KCOV_VERIFIED → PORTABLE_ARTIFACT_VERIFIED
```

`SYZKALLER_CONNECTED` and `FUZZING_STARTED` sit above these and are **not
reachable** until F-2 closes, because coverage of Kbase itself does not yet exist
(P6). The project ladder in `research/state.md` stops at
`PORTABLE_ARTIFACT_VERIFIED` and does not pretend otherwise.

---

## Status vocabulary

| Status | Means |
|---|---|
| `DONE` | the work happened and the `Evidence:` line points at it |
| `IN PROGRESS` | started, not finished; no completion claim is made |
| `NOT STARTED` | not begun |
| `BLOCKED` | cannot proceed until a named thing changes |

`IN PROGRESS` is not a polite word for `DONE`. Several steps below are partly
finished and say so.

---

## P1 — Unblock the `debug` profile (F-24)

Status: DONE
Evidence: `analysis/findings.md` F-24; `kernel/configs/debug.config`;
`check/check-all.sh` A2; `check/selftest.sh` case F-24
Checks: A2, A11, A7

`debug.config` asked for `CONFIG_DEBUG_INFO=y`. That symbol exists at
`lib/Kconfig.debug:227` but is a **prompt-less derived `bool`** `select`ed by the
"Debug information" `choice`, so the line was unsatisfiable and did nothing. It is
now `CONFIG_DEBUG_INFO_DWARF5=y`. `DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT` was
deliberately rejected: it would make the artifact's debug-info format depend on the
host gcc, which is a reproducibility hole.

`build.sh` step 5 now classifies a symbol as `absent` / `invisible` / `settable` and
prints the matching remedy, because the old single message ("symbol not in the
Kconfig") sent the reader hunting for a line that exists.

---

## P1b — Findings F-25, F-26, F-27

Status: DONE
Evidence: `analysis/findings.md` F-25, F-26, F-27;
`kernel/configs/{kasan,kcov,debug}.config`
Checks: A2, A7, A11

- **F-25** — a fragment header was rewritten to "BUILT + BOOTED" for a profile that
  had not been built. Self-caught, reverted, and now check A7 compares every
  header claim against the filesystem.
- **F-26** — `CONFIG_DMA_SHARED_BUFFER=y` in all four fragments is **causally
  inert**: prompt-less at `drivers/base/Kconfig:200`, and `y` only because Kbase's
  own `midgard/Kconfig:23` selects it. Step 5 reported `[ ok ]` because it verifies
  the result, not the cause. The lines are annotated `# INERT:` and check A11
  refuses an annotation on a symbol that is actually settable.
- **F-27** — `MALI_DEBUG=y` silently opts into Kbase's unit-test framework
  (`tests/Kconfig:21`, `default y if MALI_DEBUG`), and `kutf_kprobe.c:139` uses
  `ri->rph`, which cannot exist when `CONFIG_KRETPROBE_ON_RETHOOK=y` (`def_bool y`
  on x86_64, `arch/Kconfig:208`). A config-dependent API break, not a version
  break. Fixed with `# CONFIG_MALI_KUTF is not set`.

A7 also found that `kasan.config` and `kcov.config` still claimed **NOT BUILT**
after both had in fact been built and booted. Stale in the *understating*
direction, which is just as wrong. Both headers now state the real result.

---

## P2 — Test harness: `check/check-all.sh`

Status: DONE
Evidence: `check/check-all.sh`, `check/selftest.sh`, `check/README.md`,
`kernel/scripts/build.sh`, `qemu/scripts/run.sh`, `qemu/scripts/verify-boot.sh`
Checks: A1–A12, B1–B5, C1, D1–D3

Tiers, chosen so the cheap ones need no toolchain and no QEMU:

| Tier | Needs | What it does |
|---|---|---|
| A | nothing | static: scripts parse, fragments vs real Kconfig, scope guard, pin agreement, vendor patches, findings numbering, header honesty, cited logs, no stray binaries, TODO evidence |
| B | `artifacts/` | bundle checksums, manifest shape and ladder state, PORTABLE claims backed by logs, no absolute build paths, scope class |
| C | QEMU | boots each packaged artifact through `verify-boot.sh` (7 assertions) **with `--strict-artifact`**, so a bundle cannot silently borrow from `build/` |
| D | nothing | `research/state.md` ledger consistency, and per-ledger state validation (D2 project, D3 artifact) |

Current result: **24 passed, 0 failed, 0 skipped** (`--all`, including four real
QEMU boots).

The checks have earned their keep by finding things, which is the only reason to
believe them:

| Found by | What |
|---|---|
| A2 | F-24's unsatisfiable symbol, F-26's causally inert line |
| A7 | `kasan.config` + `kcov.config` still claiming `NOT BUILT` after both had been built **and booted** — stale in the *understating* direction |
| B2 | two bugs in itself (wrong manifest key `validation_state` vs `validation_status`; a `fi` imbalance) before it ever ran green |
| B3 | `SHA256SUMS` covers payload but **not** the bundle's `README.md` (F-28) |
| D2/D3 | two ladders sharing four identical names (F-30); a check firing on a *true* claim because it compared across them |
| F-31 | `--strict-artifact` was a **no-op** — the portability check could only ever pass |

---

## P2b — Prove the checks are not vacuous

Status: DONE
Evidence: `check/selftest.sh`, `check/README.md`
Checks: A2, A3, A5, A6, A7, A8, A11, B1, C1

A checker that never fails is indistinguishable from no checker. `selftest.sh`
re-injects each historical defect and asserts the named check goes **red**: F-24
twice (prompt-less symbol, and a symbol the kernel does not have), F-26 abuse
(annotating a settable symbol inert), F-21 (scope escape), F-25 (header overclaim),
F-25b (documented count vs disk), A8 (phantom log citation), A6 (findings gap), A5
(edited vendor patch), B1 (corrupted covered bundle file), F-31 (strict mode must
refuse a missing bundle file), and four A12 cases (a dangling check ID, a range
spanning two ladders, a `DONE` task with no evidence, a missing path on a wrapped
evidence line).

**Current result: 23 proven, 0 not-proven, 4 clean-tree positive controls.**

Three design points that are load-bearing:

- **Positive controls run first.** On the clean tree each of those checks must stay
  *silent*. A check that fires on a correct repository fails the run, so the suite
  cannot be satisfied by checks that fail everything.
- **`NOT PROVEN` is a real outcome.** A case that cannot be made to fail is
  reported as unproven, never as passing. Two of the first run's four failures were
  "not proven" — and the cause was a bug in the *test* (F-29: the fragments had no
  trailing newline, so the mutation landed inside a comment where no check could see
  it), not in the checks.
- **The tree is restored and then verified.** `cmp` against a backup of every
  touched file, because a selftest that leaves the repository modified is itself a
  defect.

---

## P3 — `debug`: build, boot, package

Status: DONE
Evidence: `research/boot-logs/20261001T111658Z-debug-BOOT.log`; `build/logs/debug.log`;
`kernel/configs/debug.config`; `artifacts/debug/metadata/manifest.json`
Checks: A2, A7, B1–B5

- [x] build — 16/16 fragment symbols, `CONFIG_MALI_KUTF` unset (F-27), merged
      `.config` sha256 `67405d143d94c32524ca1c352dae75c527cb9f71d58e26036d2216bc182a3610`,
      `mali_kbase.ko` 53 MB, `bzImage` 13.6 MB.
- [x] `build-rootfs.sh --profile debug` → 19 MB cpio
- [x] `verify-boot.sh --profile debug` → **5/5**, `PROBE summary passed=0x1ff failed=0x000`
- [x] **DWARF5 confirmed in the image, not just the config.** `vmlinux` carries
      `.debug_info`, `.debug_line_str`, `.debug_rnglists`, `.debug_loclists` and
      `readelf --debug-dump=info` reports `Version: 5`. Without this the profile
      would compile "successfully" while producing no debug info at all — which is
      exactly what F-24's unsatisfiable `CONFIG_DEBUG_INFO=y` would have done.
- [x] packaged as `TARGET_VERIFIED` (460 MB)
- [ ] clean-location test → `PORTABLE_ARTIFACT_VERIFIED` (this is P5)

The 460 MB is expected: this profile ships `vmlinux` with full DWARF5. That size is
the profile working, not misconfiguration.

---

## P4 — `kasan`: rebuild, boot, package

Status: DONE
Evidence: `build/logs/kasan-rebuild.log`; `research/boot-logs/20261001T173049Z-kasan-BOOT.log`;
`artifacts/kasan/metadata/manifest.json`
Checks: A2, A7, B1–B5, C1

- [x] `build/baseline` pruned *after* confirming its bundle still passed tier B —
      the choreography's ordering rule kept
- [x] rebuild — 16/16 fragment symbols, merged `.config` sha
      `5af7eca01b287e883fd0ca51fe301b6782105f38b085821e2e2ae03db707aa99` —
      bit-identical to the first kasan build's config, so the rebuild reproduced it
- [x] rootfs (3.0 MB), boot 5/5, `PROBE summary passed=0x1ff failed=0x000`
- [x] **KASAN proved active in the log, not assumed**: `kasan:
      KernelAddressSanitizer initialized` present; zero `BUG: KASAN`/`use-after-free`
      lines. The DWARF5 lesson from P3 applies to every profile: a boot without
      the profile's one job verified is not that profile's boot.
- [x] packaged 134 MB, then relocated and promoted (P5)

---

## P5 — Clean-location test: all four bundles

Status: DONE
Evidence: `check/portable-test.sh`; `research/boot-logs/20261001T184229Z-baseline-PORTABLE.log`
and the other three `*-PORTABLE.log`; the `clean_location_log` field in each
`artifacts/*/metadata/manifest.json`
Checks: B1–B5, C1

The procedure in `artifacts/README.md` is now a script. For each bundle:
`sha256sum -c` on the standing bundle, copy to `/tmp/portable-test-<p>/`, rename
the repository's `build/` away (restored by trap even on failure), boot the copy
with `--strict-artifact`, require `passed=0x1ff`, append `CLEAN-LOCATION: <p>` to
the log, then re-verify the original bundle still matches its sums. Promotion then
goes through `--promote-to PORTABLE_ARTIFACT_VERIFIED --evidence <log>`, which
refuses without a marked, passing log. **All four bundles are now
`PORTABLE_ARTIFACT_VERIFIED`.**

Two latent defects surfaced while landing this and are worth their own mention:

- **B3 was vacuous.** It searched all of `research/boot-logs/` for the words
  "clean-location" and found them in that directory's own README — so any bundle
  could have claimed PORTABLE and passed. Now it requires the manifest's
  `clean_location_log` field, the log's existence, the PROBE signature, and the
  per-profile marker. (F-32.)
- **B1 caught a real half-promoted state.** The first promote run edited three
  manifests and then died on a scripting error (`write_bundle_readme: command not
  found`), leaving their SHA256SUMS stale. B1 went red on exactly the changed
  file. That is the integrity suite working, and it is also the data point for why
  promotion regenerates sums *last*.

The one baseline wrinkle: its original PORTABLE claim (F-22) rested on a README
sentence, not a named log. With `build/baseline` now pruned, the relocation test
was re-run against the bundle alone in the most literal sense possible — no tree
existed to accidentally borrow from.

---

## P6 — F-2: coverage of Kbase itself

Status: DONE — **coverage of Kbase verified by measurement** (2026-10-02)
Evidence: `analysis/findings.md` F-33/F-36/F-39/F-41 (and F-38 for the interim
mystery); `qemu/target/kcov-ctl.c`; `research/boot-logs/20261002T055951Z-kcov-BOOT.log`
and later kcov boots; `artifacts/kcov` (PORTABLE_ARTIFACT_VERIFIED)
Checks: A2, A6

**What was true at BLOCKED time, and what turned out to be the real chain.**
The original P6 diagnosis ("module not instrumented; needs a Kbuild patch plus
CONFIG_KCOV_ENABLE_COMPARISONS") was wrong about the *primary* defect:
`CONFIG_KCOV_INSTRUMENT_ALL=y` had instrumented mali_kbase from the start
(`is-kernel-object` covers module objects, `scripts/Makefile.lib`). What
actually produced "zero Kbase PCs" was a chain of harness measurement defects
(F-33 stale `.config` swallowing the fragment edit; F-36 kcov-ctl forking the
workload out of the traced task; F-41 the KASLR-canonicalization masking of
module PCs behind fixed address ranges), with F-38 recording the interim
"executes but not recorded" contradiction faithfully.

**Resolution (all landed and verified):**
1. `kernel/configs/kcov.config`: `CONFIG_KCOV_ENABLE_COMPARISONS=y` — now
   actually merged (F-33's fragment-drift fix in `build.sh` step 4 makes step 5
   meaningful again).
2. `kernel/patches/0002-kbase-kbuild-kcov-instrument-modules.patch` — retained;
   inert-but-explicit under `INSTRUMENT_ALL=y`, and the correct mechanism for a
   future targeted-instrumentation profile. Note: it only reached the build
   after the staging fixes F-39 (step-1 re-stage on payload drift, step-2
   kbuild-ify Makefile refresh).
3. `kcov-ctl` rewritten (`qemu/target/kcov-ctl.c`): in-process probe (no fork),
   counters frozen before counting, slide-aware module-range bucketing.
   Acceptance is now asserted by the tool itself (`KCOV module_pcs=` counts
   distinct canonical PCs inside the KASLR-adjusted module text range).

**Verification (kcov profile, booted from the build tree):**

```text
KCOV window records=595177 in_mali_window=540920    (probe: 91% in mali_kbase)
KCOV records=596005 distinct_pcs=5878
KCOV module_pcs=1678 (module text covered)          <- the P6 metric, now correct
control (open+read of /dev/mali0): in_mali_window=22 region pcs
VERDICT: PASS (verify-boot, 7 assertions incl. negargs battery)
```

Repro: `qemu/scripts/verify-boot.sh --profile kcov`, read the `KCOV *` lines in
`research/boot-logs/<ts>-kcov-BOOT.log`.

**Superseded acceptance criterion:** the original "pc_range must contain
addresses >= 0xffffffffc0000000" test is invalid under KASLR (canonicalize_ip
subtracts the slide from module PCs; see F-41). Kept here so nobody
"un-fails" a green run by re-applying it.

**Policy:** unchanged — Kbase-side coverage remains DISCOVERY-ONLY by
construction (§5 allows no KCOV options; §8.3 mandates `MALI_DEBUG=n`).
Coverage is a discovery aid only; nothing in this P6 alters validation scope.

---

## P7 — Walk the state ladder, one transition at a time

Status: DONE
Evidence: `research/state.md` (table rows 2026-10-02, one documented transition
per state, NOT_STARTED → PORTABLE_ARTIFACT_VERIFIED); Checks D1/D2 green
Checks: D1, D2

Walked formally on 2026-10-02 (this required reconciling the pre-walk trace text
in the file's tail against the walked table, removing the stale "pin is still
UNSET" paragraph). Stopped exactly at `PORTABLE_ARTIFACT_VERIFIED`;
`SYZKALLER_CONNECTED` / `FUZZING_STARTED` were NOT entered because the kcov
bundle is a discovery target, not a fuzzing result (scope doc §5/§8, DECISION-1).

---

## P8 — Bracket F-16's kernel ceiling (measure only)

Status: NOT STARTED
Evidence: `analysis/findings.md` F-16; `kernel/sources/kernel.pin`
Checks: A4

Build 6.13–6.16 to find where r54p0 stops building, since `__SetPageMovable` was
removed in v6.17. **This measures; it does not re-pin.** The pin stays 6.12.111
and any rejected candidate gets recorded with the reason it was rejected.

---

## P9 — Known-CVE audit + negative-argument battery

Status: DONE
Evidence: `analysis/known-vulns.md`; `analysis/findings.md` F-36, F-37, F-38;
`qemu/target/kbase-negargs.c`; the `unexpected=0` lines in every current
`*-BOOT.log`/`*-PORTABLE.log`
Checks: A2, A7, tier C (now 7 assertions, incl. the negargs battery and the
no-kernel-BUG serial scan)

Requested as: deep source-grounded analysis driven by publicly known Mali kbase
vulnerabilities. Methodological result, recorded in detail in
`analysis/known-vulns.md`:

- The 22-driver-CVE catalog is one class (improper GPU memory ops → UAF /
  write-to-RO / OOB-write) and none is known-applicable to r54p0 by version. So
  the round's raw output is *negative*: no new defect was found by reading.
- Every classic seam was audited line-by-line in the current tree and found
  hardened — with line references, so a future reviewer can re-verify rather
  than trust.
- The harness now *mechanically* tests the audit's rejection envelope at every
  boot. If draining a malformed ioctl ever stops producing ESPIPE/EINVAL/EPERM
  classes — i.e. an early-return gate or a padding check regresses — the battery
  fails the gate, which is exactly what "test check for completed tasks" means
  for a security audit.
- Coverage-guided fuzzing of Kbase remains gated on F-2; the kprobe control
  (F-38) confirmed the fix is compile-instrumentation, not a workload change.

---

## Disk choreography

32 GB disk, ~14 GB free. One profile tree at a time.

| Order | Action | Why |
|---|---|---|
| 1 | ~~prune `build/baseline` (~875 M)~~ **done** | was already packaged + portable-verified; the bundle was then re-tested post-prune, proving the tree was redundant |
| 2 | ~~rebuild `kasan`, boot, package~~ **done** | rebuilt (identical config sha), 134 MB bundle |
| 3 | keep `build/kcov` (~1.1 G) | P6 needs it |
| 4 | keep `build/debug` (~1.2 G) and `build/kasan` (~0.8 G) | keep until P7's ledger walk cites them; bundles no longer need them |
| 5 | prune any tree only after its bundle passes tiers B/C *and* promotion | rule kept |

Pruning a tree does not delete a bundle. Bundles are self-contained and gitignored
along with `kernel/sources/` and `build/`.

---

## Definition of done

Every one of these, or the work is not done:

- [x] `check/check-all.sh` — all tiers green (**26 passed, 0 failed**, incl. 4 boots;
      tier C now asserts 7 artefacts per boot)
- [x] `check/selftest.sh` — every check proven to catch its defect (**23 proven, 0
      not-proven**), tree restored byte-identical
- [x] all four profiles built, booted, packaged; each bundle carries the
      negative-argument battery in its rootfs
- [x] all four bundles relocated-tested and at `PORTABLE_ARTIFACT_VERIFIED`,
      each naming its own evidence log in its manifest
- [x] known-CVE audit of r54p0 landed with a runtime rejection battery (F-37),
      and the F-2 mechanism confirmed by the kprobe control (F-38)
- [x] F-2 closed by measurement (module coverage of Kbase verified: `KCOV
      module_pcs=1678`; harness fixes F-33/F-36/F-39 + criterion correction F-41;
      evidence in TODO P6)
- [x] F-2 closed by measurement (module coverage of Kbase verified: `KCOV
      module_pcs=1678`; harness fixes F-33/F-36/F-39 + criterion correction F-41;
      evidence in TODO P6)
- [x] `research/state.md` walked formally to `PORTABLE_ARTIFACT_VERIFIED`, one
      documented transition per state (2026-10-02)
- [x] no document claims a state the evidence does not support — **including this
      file** (A7/A12 enforce the parts that can be enforced mechanically)

All eight are ticked. What remains open by design, not by omission: entering
`SYZKALLER_CONNECTED` / `FUZZING_STARTED` (real fuzzer integration against the
packaged kcov bundle is the *next phase*, and the scope doc caps what this
discovery harness may claim either way), and P8's optional F-16 ceiling bracket.