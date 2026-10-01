# Root filesystem

The rootfs is **minimal** and is itself a **reusable artifact**. It is built by
`build-rootfs.sh`.

## Purpose

The rootfs exists only to enable the guest to do what fuzzing needs:

```text
boot
Kbase module load
device interaction with /dev/mali0
debugging (serial console, logs)
coverage consumption (KCOV)
fuzzer communication (control channel)
```

It is not a general-purpose userland. A full desktop or server distribution would
waste the disk and boot time this host cannot afford, and would add attack surface
irrelevant to the Kbase target.

## Contents (planned)

Only what the above requires:

- a tiny init (`/init` or equivalent) and a shell for interactive debugging;
- `/dev/mali0` handling and the ioctl surface Kbase exposes;
- tools to load the Kbase module and read dmesg/serial output;
- whatever the fuzzer needs on the control channel;
- CA certificates / static binaries only if the fuzzer requires them.

Everything else (package managers, compilers, desktop, docs) is deliberately
omitted.

## Reusability

One rootfs *template* serves **all** kernel profiles. The rootfs does not depend
on the kernel configuration; only the kernel image and the Kbase module bundle
change per profile. `build-rootfs.sh` therefore takes `--profile` and embeds that
profile's `mali_kbase.ko`, producing one small file per profile
(`rootfs-<profile>.cpio.gz`) from identical content otherwise. The alternative —
build once and inject the module at boot — needs writable guest storage, which the
cpio format deliberately does not provide.

## Format: **cpio initramfs** (RESOLVED)

| Option | Pros | Cons |
|---|---|---|
| cpio initramfs | simple, self-contained, no partition table | rebuilt if contents change; whole image in RAM |
| small disk image (ext4) | writable, standard tooling | needs image creation + loop mount; more disk |

**Decided: cpio initramfs.** Reasons, in the order that actually mattered here:

1. **No host privileges.** An ext4 image needs `mount -o loop`, i.e. root or
   `CAP_SYS_ADMIN` on the build host. A Codespaces user is not root, and this
   project already hit exactly this class of wall with `/dev/kvm` (F-19 tooling
   notes: KVM *present* is not KVM *usable*). cpio needs none.
2. **Size.** The whole guest is ~2.6 MB compressed. A partitioned ext4 image
   cannot be smaller than its filesystem overhead, and this host has 32 GB total
   (see `../kernel/BUILD-HOST.md`), so every avoidable megabyte is contested.
3. **Reproducibility.** It is `find | cpio | gzip`. No image tool, no filesystem
   UUID, no mount step, nothing to go stale.
4. **The guest never needs to write.** The guest's only jobs are: load a module,
   open a device, run a probe, print to serial, power off. Nothing persists.

The accepted cost is that changing guest contents means a rebuild — ~2 seconds,
which is not a real constraint.

## Building

```text
qemu/rootfs/build-rootfs.sh --profile <baseline|kcov|kasan|debug>
```

Output: `build/rootfs/rootfs-<profile>.cpio.gz`, plus the sha256 that identifies
it in an artifact manifest.

Contents actually built:

- `/init` — a busybox shell script that mounts `/proc` and `/sys`, `insmod`s the
  module, runs the probe, dumps dmesg, then powers off. It echoes `BOOTMARK`
  markers at each stage so an assertion script can parse the serial log without
  depending on exit codes (guest output interleaves with kernel log lines).
- `/bin/busybox` (+ symlinks) — the shell and the handful of utilities needed.
- `/lib/modules/…/mali_kbase.ko` — this profile's module.
- `/bin/kbase-probe` — the EL0 ioctl exerciser (`../target/kbase-probe.c`),
  compiled **statically** at build time with gcc against the Kbase uapi headers.

## Portability

The rootfs ships inside the portable artifact (`../../artifacts/`) and is part of
what must boot from a clean location before the artifact is marked
`PORTABLE_ARTIFACT_VERIFIED`.

## Verified

`baseline` and `kasan` rootfs have each been booted under QEMU and driven through
the full load-and-probe sequence; see `../../research/boot-logs/` and F-19 in
`../../analysis/findings.md`.

## Portability

The rootfs ships inside the portable artifact (`../artifacts/`) and is part of what
must boot from a clean location before the artifact is marked
`PORTABLE_ARTIFACT_VERIFIED`.