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
artifacts produced:   3
  baseline            PORTABLE_ARTIFACT_VERIFIED   (DISCOVERY-ONLY, DECISION-1)
  kcov                TARGET_VERIFIED               (DISCOVERY-ONLY, DECISION-1)
  debug               TARGET_VERIFIED               (DISCOVERY-ONLY, DECISION-1)
  kasan               built + booted (logs kept); bundle NOT packaged
program state:        NOT_STARTED (see ../research/state.md)
```

### `artifacts/baseline` — the first artifact

```text
identity      kbase-r54p0-01eac0-6.12.111-baseline
size          68 MB, 16 files
validation    PORTABLE_ARTIFACT_VERIFIED
scope class   DISCOVERY-ONLY
```

It passed the full procedure above: packaged, copied to a location outside the
repository, and booted **with the entire `build/` tree renamed away**, so the
result cannot be an accident of the build tree still being present. All five
`verify-boot.sh` assertions passed from that clean location, and
`sha256sum -c metadata/SHA256SUMS` reports 16/16 OK. Evidence and the one real
portability defect this surfaced (the rootfs was still resolved from `build/`)
are in F-22 of `../analysis/findings.md`.

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
size          80 MB, 16 files
validation    TARGET_VERIFIED
scope class   DISCOVERY-ONLY
integrity     16/16 OK
```

Packaged and integrity-checked, but **not** clean-location tested, so it is not
`PORTABLE_ARTIFACT_VERIFIED`. Note also that this artifact is
`TARGET_VERIFIED` while its *purpose* — coverage — is only partly served: KCOV
works (2882 distinct PCs), but none of that coverage is Kbase (F-23). A consumer
must not read `TARGET_VERIFIED` as "coverage-guided fuzzing is ready here".

### Per-profile status of the other two

| Profile | Built | Booted + probed | Bundle |
|---|---|---|---|
| `kasan` | yes | yes — `passed=0x1ff failed=0x000`, **zero** KASAN reports | not packaged (build tree pruned to save disk) |
| `debug` | yes | yes — `passed=0x1ff failed=0x000`; DWARF5 confirmed in `vmlinux` | `TARGET_VERIFIED`, 460 MB |

`debug`'s bundle is large because it ships `vmlinux` with full DWARF5 debug info —
which is the entire reason the profile exists. `mali_kbase.ko` alone is 53 MB there
against 2.4 MB in `baseline`, for the same reason. Do not read the size as
misconfiguration.

### Verified by `check/check-all.sh` before you trust a bundle

`check/check-all.sh --tier B` re-derives, for every bundle on disk:
`SHA256SUMS` still matches (B1); the manifest has every required field and names a
state that is actually in the ladder (B2); a `PORTABLE_ARTIFACT_VERIFIED` claim is
backed by a clean-location log (B3); no file references an absolute `build/` path
(B4); and the scope class is `DISCOVERY-ONLY` (B5). `check/selftest.sh` proves each
of those checks goes red when its defect is re-injected, so a green run is not
merely a checker that has never been tested.

**Known gap (F-28):** `SHA256SUMS` covers every payload file but **not** the
bundle's own `README.md` — which is where the bundle states its `validation_status`
and `scope_class`. So `sha256sum -c` would pass on a bundle whose README described
different contents. Left open deliberately: covering it means re-packaging every
bundle, which resets `artifacts/baseline` from `PORTABLE_ARTIFACT_VERIFIED` and
requires its clean-location boot again. Trading an earned state for a
documentation-integrity nicety is a bad trade.

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