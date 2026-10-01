# Boot logs — runtime evidence

Serial-console captures from QEMU boots. These are the project's **runtime**
evidence, as distinct from `../build-logs/` (compile evidence).

Every log here was produced by `qemu/scripts/verify-boot.sh --profile <name>`,
which writes one file per run and prints a bitmask verdict. Filenames are
`<UTC timestamp>-<profile>-BOOT.log`, so they sort chronologically.

## What a log proves

A log is evidence for exactly the claims its markers support, in this order:

| Marker / line | Supports |
|---|---|
| kernel banner, `BOOTMARK userspace-up` | the kernel booted and ran `/init` |
| `BOOTMARK insmod-start` … `insmod-rc 0` | the module loaded with **default** parameters |
| `mali mali.0: Kernel DDK version r54p0-01eac0` | the loaded module is the expected build |
| `mali mali.0: GPU identified as … arch 14.8.5 …` | a GPU target initialised; `14.8.5` == `tDRx` (DECISION-2) |
| `mali mali.0: Probed as mali0` | `/dev/mali0` was created |
| `PROBE summary passed=0x1ff failed=0x000` | the EL0 target interface answered every phase |
| `PROBE summary … failed=0x0NN` | a **partial** pass — read the per-phase lines, do not call it success |

## Reading them correctly

- **Guest output interleaves with kernel log lines on the same console.** A
  `PROBE …` line can be split mid-token by a `[ 1.234567]` timestamp. Parse the
  `BOOTMARK` markers and the `PROBE summary` line, not raw line offsets — which
  is why `verify-boot.sh` asserts on markers rather than guest exit codes.
- **The probe's exit status is a pass bitmask, not a success flag.** `probe-rc
  255` in the logs means all nine phase bits passed (0x1ff). A failure is encoded
  separately in `failed=` (bit<<16) precisely so that full success stays
  distinguishable from partial failure. Do not read a non-zero probe rc as an error.
- **Absence of a sanitizer report is a claim that needs checking, not an
  assumption.** For the `kasan` log, "no KASAN reports" was established by
  grepping for `BUG: KASAN`, `use-after-free`, and `*-out-of-bounds` — all absent —
  and by confirming KASAN was actually active (`kasan: KernelAddressSanitizer
  initialized`).
- **Expected noise on this host.** `No OPPs found in device tree!`, `Clock not
  available for devfreq` / `Continuing without devfreq`, `OPP table not found
  (-19)`, and `Dummy model register access: … unsupported register` are all normal
  for x86_64 + `MALI_NO_MALI` and are recorded so they are not later mistaken for
  defects.

## Scope limit

Per **DECISION-1** the x86_64 + `MALI_NO_MALI` harness is **INVESTIGATION-ONLY**.
Nothing in this directory may be cited as Arm-conforming validation evidence, no
matter how clean the run. A clean boot means "the driver works on the simulator",
never "the driver is correct on hardware".

## Current contents

| Profile | Result | Notes |
|---|---|---|
| `baseline` | PASS ×7 | includes two **clean-location** runs booted from `/tmp` with `build/` renamed away (F-22) |
| `kasan` | PASS | `kasan: KernelAddressSanitizer initialized`; zero sanitizer reports |
| `kcov` | PASS | **2882 distinct PCs** collected; none of them Kbase (F-23) |
| `debug` | PASS | `MALI_KUTF` off (F-27); DWARF5 confirmed in `vmlinux`, not just the config |

### The `kcov` logs are a debugging record, not a single result

Eight `kcov` logs are retained rather than trimmed to the last one, because the
sequence *is* the evidence for F-23's second half. Read in order they show a tool
that reported plausible success while being wrong three separate times:

| Log | What it shows |
|---|---|
| `…T093940Z` | first run: **no KCOV output at all** — `/init` never mounted `debugfs`, so `/sys/kernel/debug/kcov` did not exist |
| `…T094138Z`, `…T094236Z` | same, after the `debugfs` mount was added |
| `…T100901Z` | `KCOV_INIT_TRACE: Invalid argument` — the size was passed as a *pointer*; the ioctl wants the size **as the argument** |
| `…T100931Z` | probe ran under KCOV, but `count`/`disable` were silently skipped — `run` consumed the rest of `argv` |
| `…T101042Z` | `read /sys/kernel/debug/kcov: Invalid argument` — kcov has no `.read` handler at all |
| `…T102417Z` | counters read, but `covered_pcs=656023` — a **popcount of a PC list**, meaningless |
| `…T102818Z` | correct: `records=14495 distinct_pcs=2882`, `pc_range` entirely inside vmlinux text |

Each failure was found by reading the reported errno, never by guessing. The
final line to trust is the `PROBE summary`; for `kcov` also assert on
`KCOV records=… distinct_pcs=…` and check the `pc_range` against vmlinux's own
executable segment.
