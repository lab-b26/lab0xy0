# Portable artifacts

The **product** of this repository. Everything upstream exists to produce these:
a validated, self-contained, relocatable environment that a fuzzer can start
without rebuilding Linux, Kbase, or the rootfs.

```text
build once → validate → package → reuse many times → fuzz
```

## Artifact layout

```text
artifact/
├── kernel/
│   ├── bzImage              # bootable image for the profile
│   ├── vmlinux              # with symbols (for KCOV / crash triage)
│   └── config               # the exact .config used
├── modules/
│   └── ...                  # Kbase .ko (+ deps) for this profile
├── rootfs/                  # minimal rootfs (see qemu/rootfs/)
├── qemu/                    # launch wrapper + version pin (if packaged)
├── metadata/
│   ├── manifest.json        # structured identity (below)
│   └── SHA256SUMS           # integrity of every packaged file
└── README.md                # how to run this artifact
```

The exact structure may evolve. What is fixed is the principle: **an artifact is
self-contained.** It must not reference a build tree, a source checkout, or a host
path.

## Manifest — every artifact records

`metadata/manifest.json` must capture, per profile artifact:

```text
artifact ID              unique name, e.g. kbase-r54p0-<kernelver>-<profile>
Kbase release            r54p0-01eac0
kernel release           exact kernel version + source SHA-256
kernel config hash       hash of the .config used
patch-set identity       which patches (vendor + research) and their SHA-256s
rootfs identity          build id / checksum
QEMU version             pinned version used to boot it
build date               ISO-8601
source checksums         vendor archive SHA-256(s)
validation status        one of the states below
scope class              IN SCOPE / DISCOVERY-ONLY / EXCLUDED / UNKNOWN
```

The `scope class` is not cosmetic: a `kcov` artifact is `DISCOVERY-ONLY` and must
not be represented as an Arm-conforming validation kernel
(`../research/program-scope.md` §5–§6, `../analysis/findings.md` F-9).

## Validation states

An artifact is labelled with how far it has actually been validated:

| State | Meaning |
|---|---|
| `BUILT` | compiled; nothing else claimed |
| `BOOT_VERIFIED` | boots under QEMU |
| `KBASE_LOAD_VERIFIED` | Kbase module loads in the guest |
| `TARGET_VERIFIED` | the target interface (e.g. `/dev/mali0` ioctls) responds |
| `PORTABLE_ARTIFACT_VERIFIED` | passed the full portability procedure below |

An artifact is **not** called portable merely because it can be archived.

## Portability validation procedure

```text
build
  ↓
package
  ↓
copy artifact to a clean location
  ↓
remove/restrict access to the original build tree
  ↓
launch using only the packaged contents
  ↓
boot QEMU
  ↓
load Kbase
  ↓
exercise the target interface
  ↓
validate the fuzzer-facing interface
```

Only after this sequence passes does the artifact become
`PORTABLE_ARTIFACT_VERIFIED`.

## One source tree / many builds

The four profiles come from **one** Linux source tree with separate outputs, not
four source trees:

```text
linux/                     # one source tree
build/
├── baseline/              # make O=build/baseline
├── kcov/
├── kasan/
└── debug/
```

Each `build/<profile>` produces one artifact as above. This is what makes
build-once/reuse-many affordable on a ~3.9 GB-free host
(`../analysis/findings.md` F-6): build a profile, package it, record its checksum,
then reclaim the build tree before the next — never keeping four full trees.

## Consumers

A validated artifact is consumed by one or more fuzzers **without rebuilding**:

```text
artifact/  →  fuzzer A
artifact/  →  fuzzer B
artifact/  →  (a future campaign)
```

See `../syzkaller/README.md` for the intended first consumer, and note the artifact
is kept fuzzer-agnostic.

## Current status

```text
artifacts produced:   4
  baseline            PORTABLE_ARTIFACT_VERIFIED   (DISCOVERY-ONLY, DECISION-1)
  kcov                PORTABLE_ARTIFACT_VERIFIED   (DISCOVERY-ONLY, DECISION-1)
  debug               PORTABLE_ARTIFACT_VERIFIED   (DISCOVERY-ONLY, DECISION-1)
  kasan               PORTABLE_ARTIFACT_VERIFIED   (DISCOVERY-ONLY, DECISION-1)
program state:        NOT_STARTED (see ../research/state.md)
```

Every bundle now carries a `clean_location_log` in its manifest naming the exact
boot log that earned the state (the `*-<profile>-PORTABLE.log` files), and every
bundle's `SHA256SUMS` covers `README.md` itself (the F-28 hole is closed for all
four, via `--promote-to` regenerating the sums AFTER the README is written).

### `artifacts/baseline` — the first artifact

```text
identity      kbase-r54p0-01eac0-6.12.111-baseline
size          68 MB, 16 files
validation    PORTABLE_ARTIFACT_VERIFIED
scope class   DISCOVERY-ONLY
```

It passed the full procedure above — twice, in fact: once when it was packaged
(F-22), and again after its build tree was pruned to reclaim disk, when the same
test was re-run end-to-end through the now-automated `../../check/portable-test.sh`.
Re-running after the prune is the interesting half: it proves the *bundle only* is
sufficient, with no tree at all behind it (`sha256sum -c` clean before and after;
`20261001T184229Z-baseline-PORTABLE.log`).

Rebuild it with:

```bash
qemu/scripts/package-artifact.sh --profile baseline \
    --validation-state PORTABLE_ARTIFACT_VERIFIED
```

`--validation-state` is a required claim about *this bundle*; the script refuses
states outside the table above so "portable" can never be asserted by accident.

### `artifacts/kcov`

```text
identity      kbase-r54p0-01eac0-6.12.111-kcov
size          ~80 MB
validation    PORTABLE_ARTIFACT_VERIFIED
scope class   DISCOVERY-ONLY
```

Clean-location booted and promoted (`clean_location_log` in its manifest names the
attesting log). **This bundle's purpose is still only partly served:** KCOV works
(2882 distinct PCs collected in F-23), but none of that coverage is Kbase — every
PC lies inside vmlinux and Kbase contributed zero. A consumer using this bundle for
coverage guidance is optimising kernel paths, not the driver. Closing that gap is
F-2 (P6 in `../TODO.md`) and remains **open**.

### Per-profile status of the other two

| Profile | Built | Booted + probed | Bundle |
|---|---|---|---|
| `kasan` | yes | yes — `passed=0x1ff failed=0x000`; `KernelAddressSanitizer initialized`; **zero** KASAN reports | `PORTABLE_ARTIFACT_VERIFIED`, 134 MB (module 2.4 → 5.1 MB under instrumentation) |
| `debug` | yes | yes — `passed=0x1ff failed=0x000`; DWARF5 confirmed in `vmlinux` (`.debug_rnglists` et al, `Version: 5`) | `PORTABLE_ARTIFACT_VERIFIED`, 460 MB |

`debug`'s bundle is large because it ships `vmlinux` with full DWARF5 debug info —
which is the entire reason the profile exists. `mali_kbase.ko` alone is 53 MB there
against 2.4 MB in `baseline`, for the same reason. Do not read the size as
misconfiguration.

### Verified by `check/check-all.sh` before you trust a bundle

`check/check-all.sh --tier B` re-derives, for every bundle on disk:
`SHA256SUMS` still matches (B1); the manifest has every required field and names a
state that is actually in the ladder (B2); a `PORTABLE_ARTIFACT_VERIFIED` claim is
backed by *its own named evidence* — the manifest must carry a `clean_location_log`
field, the named log must exist, contain the full PROBE pass, and carry a
`CLEAN-LOCATION: <profile>` marker for THAT profile (B3); no file references an
absolute `build/` path (B4); and the scope class is `DISCOVERY-ONLY` (B5).
`check/selftest.sh` proves each of those checks goes red when its defect is
re-injected, so a green run is not merely a checker that has never been tested.

The first B3 was vacuous: it searched all of `research/boot-logs/` for the words
"clean-location" and found them in that directory's own README, so any bundle could
have claimed PORTABLE and passed. The per-bundle evidence requirement is what makes
the claim falsifiable.

**F-28 is closed.** `SHA256SUMS` used to be written *before* `README.md` existed —
not a policy choice, an ordering accident — so the one file stating
`validation_status` and `scope_class` sat outside the integrity set. The packaging
and promotion paths now both write the sums last, and all four bundles' sums cover
`README.md`. The earlier reason to leave it open (re-packaging would reset
baseline's earned state) is gone: `--promote-to` exists precisely so a claim can be
raised — or, here, the integrity boundary widened — without tearing the state down
and rebuilding.

### The portability test must use `--strict-artifact`

`run.sh` resolves components **artifact-first with a `build/` fallback**, which is
convenient before a bundle exists — and is also precisely how a non-self-contained
bundle gets mistaken for a portable one. Delete `artifacts/<p>/kernel/bzImage` and a
non-strict boot quietly succeeds from `build/<p>/`.

```sh
qemu/scripts/verify-boot.sh --profile <p> --artifact artifacts/<p> \
        --strict-artifact --log /tmp/portable-<p>.log
```

With the flag, a missing component is a hard error naming the bundle. `run.sh` also
prints the `kernel=` and `rootfs=` it resolved on every boot, so a fallback is visible
in the log instead of looking like an artifact boot. Tier C always uses the flag.

The first implementation of that flag was a **no-op** — a `shift` left the fallback
inside the candidate list, so the `STRICT` gate was never evaluated and the boot used
`build/` while the trace cheerfully showed `STRICT=1` (F-31). A portability check
that cannot fail is worse than none, because it converts *unverified* into
*verified*. `check/selftest.sh` now asserts the negative case.

A profile being *built* is not an artifact, and a profile's components being
verified is not the profile's bundle being portable. The bundle is what a fuzzer
consumes; only the bundle goes through the procedure above.

**All bundles are `DISCOVERY-ONLY`.** Portability is a reproducibility property and
carries no conformance meaning: nothing here is Arm-conforming validation evidence
(DECISION-1, F-9).