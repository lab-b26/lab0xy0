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
| `kcov` | not yet | builds (E-009); not booted |
| `debug` | not started | |
