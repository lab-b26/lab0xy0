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
artifacts produced:   0
states reached:       none (see ../research/state.md — NOT_STARTED)
```

This directory currently holds only this README. **No artifact bundle has been
produced yet.**

This is worth being explicit about, because the *components* an artifact is made of
already exist and have been verified — but a bundle is not the same as its parts:

| Component | State | Where |
|---|---|---|
| `baseline` kernel + modules | compiles, links, **boots**, module loads, EL0 ioctls respond | `build/baseline/` (gitignored) |
| `kasan` kernel + modules | same, under `CONFIG_KASAN`, zero sanitizer reports | build tree pruned; log kept |
| rootfs | built per profile (cpio, ~2.6 MB) | `build/rootfs/` (gitignored) |
| **`artifacts/<profile>/` bundle** | **NOT PACKAGED** | — |
| clean-location portability test | **NOT RUN** | — |

Runtime evidence for the components is in `../research/boot-logs/` and F-19 of
`../analysis/findings.md`. Note that a component being `TARGET_VERIFIED` says
nothing about an artifact being portable — the whole point of the procedure above
is that the bundle is tested *away from the build tree*, which has not happened.

Packaging is the remaining half of build-plan step 7 (see `../kernel/BUILD-PLAN.md`).
Until it is done, the honest status line above stays at 0.