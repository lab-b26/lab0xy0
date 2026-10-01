# QEMU scripts

Launch and verification wrappers for the QEMU environment. These **exist and
work**; they consume prebuilt components and never invoke a kernel build.

## Scripts

| Script | Purpose | Status |
|---|---|---|
| `run.sh` | launch a prebuilt, packaged profile artifact (profile-agnostic) | EXISTS, used |
| `verify-boot.sh` | boot the artifact and assert Kbase loads + target interface responds | EXISTS, used |
| `package-artifact.sh` | bundle one profile's components into a self-contained artifact | EXISTS, used |
| `build-env.sh` | build/package the QEMU-side environment once | SUPERSEDED by `package-artifact.sh` + `../rootfs/build-rootfs.sh` + `../../kernel/scripts/build.sh` |

## `package-artifact.sh`

```text
qemu/scripts/package-artifact.sh --profile <name> [--out DIR] --validation-state STATE
```

Collects `kernel/{bzImage,vmlinux,config}`, `modules/` (all `.ko`, in-tree paths
preserved), this profile's rootfs, and writes `metadata/manifest.json`,
`metadata/SHA256SUMS`, and a runnable `README.md`.

Three deliberate constraints:

- **It never builds.** A missing component is a hard error, not a silent omission —
  an artifact missing its kernel fails later and further away than this check does.
  It also requires the *profile-specific* rootfs (`rootfs-<profile>.cpio.gz`),
  because a rootfs built for another profile would embed the wrong `.ko` and
  produce a plausible-looking wrong artifact.
- **`--validation-state` is a required claim and is validated against the
  allowlist** in `artifacts/README.md`, so `PORTABLE_ARTIFACT_VERIFIED` cannot be
  asserted by accident. It records reproducibility, never conformance.
- **It fails loudly if a host path could leak in.** The generated manifest and
  README carry no absolute paths, so a bundle is genuinely relocatable.

### The portability defect this found

Packaging `baseline` exposed a bug that "it boots" would never have caught:
`run.sh` resolved `bzImage` from the artifact but the **rootfs only from
`build/rootfs/`**. Every relocated bundle would therefore have depended on the
repo's build tree, quietly defeating the purpose of the artifact. The rootfs now
uses the same artifact-first candidate order as the kernel. Recorded as F-22.

The general lesson, and why the clean-location test is written the way it is:
**self-containment can only be tested by removing the thing you claim not to
depend on.** `verify-boot.sh` was run with the whole `build/` directory renamed
away, not merely from a different working directory.

The project spec deliberately does **not** ask for
`build-baseline.sh` / `build-kcov.sh` / `build-kasan.sh` / `build-debug.sh` here or
in `kernel/scripts/`; a single `build.sh --profile ...` design is used instead.

## `run.sh`

```text
qemu/scripts/run.sh --profile <baseline|kcov|kasan|debug> [options] [-- extra qemu args]
```

Resolves, in order: an explicit `--artifact DIR`, else `artifacts/<profile>`, else
`build/<profile>` as a fallback for pre-packaging use. **Both** the kernel and the
rootfs resolve artifact-first; `--rootfs` overrides the initramfs, `--serial FILE`
captures the console, `--accel` forces `kvm`/`tcg`/`auto`, `--interactive` keeps
the guest alive on stdin instead of powering off.

Two environment realities are handled explicitly:

- **KVM present is not KVM usable.** `/dev/kvm` here is mode `0660 root:kvm` and
  the Codespaces user is not in group `kvm`. The script *tests usability*, and
  only then uses `sudo -n` (or `SUDO=1`); otherwise it falls back to TCG.
- **TCG needs `-cpu max`.** Without it, an x86_64 guest under TCG does not expose
  the features this kernel wants. The KVM and TCG paths therefore differ in more
  than one flag.

## `verify-boot.sh`

```text
qemu/scripts/verify-boot.sh --profile <name>
```

Boots a profile and asserts, from the serial console:

| Bit | Assertion |
|---|---|
| 1 | kernel booted and ran `/init` |
| 2 | `mali_kbase.ko` loaded, rc=0, with default parameters |
| 4 | Kbase probed a device (`Probed as mali0`) |
| 8 | module present in `lsmod` and self-identified (`Kernel DDK version`) |
| 16 | EL0 target interface fully exercised (`passed=0x1ff failed=0x000`) |

**Exit status is a bitmask of failed assertions**, so a partial failure is still
diagnosable — but a single non-zero exit is not "total failure", and a caller
must not read it as such. Full success is `0`.

Assertions parse `BOOTMARK` markers and the `PROBE summary` line rather than
guest exit codes, because guest stdout interleaves with kernel log lines on the
same serial console and can split a line mid-token.

Every run writes its serial log to `../../research/boot-logs/<UTC>-<profile>-BOOT.log`,
which is the project's runtime evidence (see F-19 in
`../../analysis/findings.md`).

## Requirements these scripts satisfy

- **Repository-relative paths only** — the artifact bundle is resolved relative to
  the repo or an explicit `--artifact` path, so a packaged artifact can be
  relocated and still run. No host path is baked in.
- **No rebuild at fuzzing time.** They consume prebuilt components (`kernel/`
  images + `modules/` + `rootfs/`) and refuse to build.
- **Profile-agnostic.** One launch path serves all four profiles by selecting the
  right prebuilt components — not by reconfiguring the VM per profile.
- **KVM-aware, TCG-capable** (see above).
- **Repo-relative fuzzer interface.** The serial console is the control channel
  today.

## Control channel

The guest exposes its channel on the serial console (`console=ttyS0`, logged to
file). This is what lets a single VM artifact serve multiple fuzzers. The exact
transport (serial vs virtio-net vs vsock) is still open — `../README.md` records
the alternatives, and serial remains the current candidate. A fuzzer-facing
transport is **not** built yet.