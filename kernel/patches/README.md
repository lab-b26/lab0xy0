# Research-authored kernel patches

This directory is for patches **this project writes**. It is not for vendor
material.

```text
patches/virtual-device/   = the six supplied Arm virtual-device patches
                             (third-party; VERIFIED to apply to r54p0)

kernel/patches/            = future research-authored Linux-kernel patches
                             (ours; written and justified in this project)
```

Never mix the two. Vendor patches are preserved byte-for-byte and are never
edited, reformatted, or "cleaned up"; research patches live here and are
versioned with their own rationale.

## Current contents

| Patch | Problem it fixes | Category | Validated on |
|---|---|---|---|
| `0001-kbase-guard-clk-is-enabled-behind-COMMON_CLK.patch` | `__clk_is_enabled` is declared unconditionally but defined only under `CONFIG_COMMON_CLK`, so the module compiles and then fails to link on x86_64 (F-17) | **build fix** (not a behaviour change) | Linux 6.12.111, x86_64, gcc 13.3.0 |
| `0002-kbase-kbuild-kcov-instrument-modules.patch` | `MALI_KCOV` exists only in the Android/SCons `Mconfig`/`Makefile`, so the SCons coverage flags never reached in-tree builds (F-2). Measured: `INSTRUMENT_ALL` already covers modules (F-41), so the patch is retained as belt-and-braces for targeted-instrumentation configs (`INSTRUMENT_ALL=n`); requires `CONFIG_KCOV_ENABLE_COMPARISONS=y` in the kcov fragment | **instrumentation** (discovery-profile only; not a behaviour change) | applied on r54p0 + six vendor patches + 0001; Kbase coverage VERIFIED (`KCOV module_pcs=1678`, F-41) |

`apply-patches.sh` applies these automatically, **after** the six vendor
patches, from `driver/` with `patch -p1` — the same mechanism and the same
base directory as the vendor series. Vendor patches are applied first because
each research patch is written against vendor-patched source.

The two series are identified separately and the identity is kept separate on
purpose:

```text
work/kbase-patched/.patch-series.sha256            = the six Arm patches ONLY
work/kbase-patched/.research-patch-series.sha256   = our patches ONLY
```

Both appear in `build/<profile>/build-metadata.txt`. A build that used a
research patch can therefore never be mistaken for a pristine-vendor build —
which matters, because a research patch is a build fix and not something Arm
shipped or verified.

### Why the F-17 patch exists rather than `CONFIG_COMMON_CLK=y`

Both were available. The patch was chosen because enabling
`CONFIG_COMMON_CLK` in a profile fragment is a **kernel configuration delta
outside the `research/program-scope.md` §5 allowlist**, which would make the
`baseline` profile non-conforming as the intended control. The patch keeps the
configuration at plain `x86_64_defconfig` and introduces no delta at all.

The trade-off is explicit: this modifies driver *source*, so the resulting
module is not bit-identical to what Arm's release produces. That is acceptable
for an investigation-only harness (DECISION-1) and is why the patch is
labelled a build fix — it changes no behaviour in either configuration:

- `CONFIG_COMMON_CLK=y`: the `__clk_is_enabled` test is still performed;
- `CONFIG_COMMON_CLK=n`: `clk_disable_unprepare()` is a no-op stub and
  `kbdev->clocks[]` is never populated, so the guarded and unguarded forms are
  equivalent.

## The Kbase-side KCOV instrumentation patch (0002)

**Status: applied in staged builds (F-39 fixed the staging so it actually
reaches the compiler); effect measured — coverage of Kbase is VERIFIED. The
patch turned out to be belt-and-braces, not the load-bearing piece:**
`CONFIG_KCOV_INSTRUMENT_ALL=y` already instruments module objects
(`scripts/Makefile.lib`: `is-kernel-object` includes modules), so the module
carried sancov callbacks in every kcov-profile build. The "no Kbase coverage"
outcome was a chain of harness measurement defects (F-33/F-36/F-41), not a
build property. The patch is retained deliberately: it pins
`KCOV_INSTRUMENT := y` for midgard under `CONFIG_KCOV`, which is what a future
targeted-instrumentation profile (`INSTRUMENT_ALL=n`) would need.

`MALI_KCOV` exists only in `midgard/Mconfig` (the Android/SCons path), not in
`midgard/Kconfig`, and its `-fsanitize-coverage=trace-cmp` flags live only in
the SCons/Android `Makefile` an in-tree build never reads (F-2 — the static
observation remains true). Its feared consequence (no Kbase coverage) is
disproven by measurement (F-41).

The kcov fragment must set `CONFIG_KCOV_ENABLE_COMPARISONS=y`, or objects
compiled with `-fsanitize-coverage=trace-cmp` reference
`__sanitizer_cov_trace_cmp*` symbols that `kernel/kcov.c` compiles out — a
modpost `undefined!` failure. That invariant is now enforced by build.sh's
step-5 fragment verification.

## Requirements for any patch added here

Each research patch must be accompanied by, or reference:

- the problem it solves, and the `VERIFIED` evidence for that problem;
- the target kernel version(s) it was validated against;
- whether it changes the Arm configuration-allowlist status of a profile
  (`../../research/program-scope.md` §5);
- a recorded application order relative to `patches/virtual-device/`;
- its own SHA-256 entry, so the applied patch-set is identifiable.

A patch that only makes a build succeed is still valuable, but it must be
labelled as a build fix, not a behaviour change.