#!/usr/bin/env bash
#
# build-rootfs.sh --profile <baseline|kasan|kcov|debug> [--artifact DIR] [--out FILE]
#
# Build the minimal guest rootfs (cpio initramfs) used to boot and exercise a
# profile artifact. One script, all profiles: the rootfs is profile-AGNOSTIC in
# content except for which Kbase module is dropped in, which is exactly the
# reusability property qemu/rootfs/README.md claims.
#
# Contents, and why each thing is here:
#   busybox (static)      sh + mount + insmod + dmesg, for debugging and for init
#   mali_kbase.ko         the module for the requested profile
#   kbase-probe           the EL0 target-interface exerciser (see target/)
#   /init                 a non-interactive init that loads the module and runs
#                         the probe, then powers off. There is no getty: this is
#                         a test image, and an interactive shell would only make
#                         automated runs hang waiting on input.
#
# Why a cpio initramfs and not a disk image (qemu/rootfs/README.md called this
# UNKNOWN): the whole image is ~2 MB, it needs no partition table, no loop mount
# and no root privileges on the host, and it is trivially reproducible with
# `find | cpio`. A writable ext4 image would add host-side loop device
# privileges and gain nothing for fuzzing, where the guest is disposable.
#
# This script BUILDS nothing kernel-side. It consumes an already-built artifact.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build"
ARTIFACT_DEFAULT="$REPO_ROOT/artifacts"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

PROFILE=""; ARTIFACT=""; OUT=""
usage() {
    cat <<'EOF'
Usage: qemu/rootfs/build-rootfs.sh --profile <name> [--artifact DIR] [--out FILE]

  --profile <name>   baseline | kasan | kcov | debug   (required)
  --artifact DIR     artifact bundle to read the module from
                     (default: artifacts/<profile>, falling back to build/<profile>)
  --out FILE         output cpio.gz (default: build/rootfs/rootfs-<profile>.cpio.gz)

Input resolution, in order:
  1. <artifact>/modules/mali_kbase.ko
  2. <artifact>/modules/gpu/arm/midgard/mali_kbase.ko
  3. build/<profile>/drivers/gpu/arm/midgard/mali_kbase.ko   (unpackaged build)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --artifact) ARTIFACT="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
done

case "$PROFILE" in
    baseline|kasan|kcov|debug) ;;
    *) [ -n "$PROFILE" ] || die "--profile is required"; die "unknown profile: $PROFILE" ;;
esac

# --- locate the module, preferring a packaged artifact -------------------
[ -n "$ARTIFACT" ] || ARTIFACT="$ARTIFACT_DEFAULT/$PROFILE"
MODULE=""
for cand in \
    "$ARTIFACT/modules/mali_kbase.ko" \
    "$ARTIFACT/modules/gpu/arm/midgard/mali_kbase.ko" \
    "$BUILD_ROOT/$PROFILE/drivers/gpu/arm/midgard/mali_kbase.ko"
do
    if [ -f "$cand" ]; then MODULE="$cand"; break; fi
done
[ -n "$MODULE" ] || die "no mali_kbase.ko found for profile '$PROFILE'.
Looked in:
  $ARTIFACT/modules/mali_kbase.ko
  $ARTIFACT/modules/gpu/arm/midgard/mali_kbase.ko
  $BUILD_ROOT/$PROFILE/drivers/gpu/arm/midgard/mali_kbase.ko
Build it first:  kernel/scripts/build.sh --profile $PROFILE
Or point --artifact at a packaged bundle."

# --- locate the host tools the image is built from ------------------------
BUSYBOX="${BUSYBOX:-}"
if [ -z "$BUSYBOX" ]; then
    for c in /usr/bin/busybox /bin/busybox "$(command -v busybox 2>/dev/null || true)"; do
        [ -n "$c" ] && [ -x "$c" ] && BUSYBOX="$c" && break
    done
fi
[ -n "$BUSYBOX" ] || die "busybox not found. Install it, or set BUSYBOX=/path/to/busybox.
The image needs a STATIC busybox so the guest needs no shared libraries."

# Must be static: the initramfs carries no loader and no libc.
if ldd "$BUSYBOX" >/dev/null 2>&1; then
    die "busybox at $BUSYBOX is dynamically linked; a static build is required."
fi

PROBE_SRC="$REPO_ROOT/qemu/target/kbase-probe.c"
[ -f "$PROBE_SRC" ] || die "probe source missing: $PROBE_SRC"
UAPI_INCLUDE="$REPO_ROOT/work/kbase-patched/driver/product/kernel/include"
[ -d "$UAPI_INCLUDE" ] || die "Kbase UAPI headers not found at $UAPI_INCLUDE
Run kernel/scripts/apply-patches.sh first (it produces work/kbase-patched)."

command -v cpio >/dev/null 2>&1 || die "cpio not found (package: cpio)"
command -v gcc  >/dev/null 2>&1 || die "gcc not found; it builds the static probe"

[ -n "$OUT" ] || OUT="$BUILD_ROOT/rootfs/rootfs-$PROFILE.cpio.gz"
mkdir -p "$(dirname "$OUT")"

echo "=============================================================="
echo " build-rootfs.sh -- profile $PROFILE"
echo "=============================================================="
echo "module:   $MODULE"
echo "busybox:  $BUSYBOX"
echo "probe:    $PROBE_SRC"
echo "output:   $OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE"/{bin,dev,proc,sys,tmp,lib/modules}

cp "$BUSYBOX" "$STAGE/bin/busybox"
for a in sh ash mount umount insmod rmmod lsmod ls cat dmesg echo printf \
         poweroff halt mkdir mknod cp mv rm uname id free grep sed head tail \
         sync date sleep; do
    ln -sf busybox "$STAGE/bin/$a"
done

# Cross-compile check: the guest is the same architecture as the build host for
# this x86 harness, so a host static build is correct. If that ever stops being
# true the image will fail to exec rather than silently misbehave.
gcc -std=gnu11 -O2 -Wall -Wextra -static -I "$UAPI_INCLUDE" \
    -o "$STAGE/bin/kbase-probe" "$PROBE_SRC" \
    || die "failed to build kbase-probe"

cp "$MODULE" "$STAGE/lib/modules/mali_kbase.ko"

# The init is written to the TARGET as a copy, not symlinked, so the cpio has no
# dangling entries if the script is interrupted.
cat > "$STAGE/init" <<'INIT_EOF'
#!/bin/sh
# Non-interactive init for the Kbase boot test.
#
# Everything here is deliberately observable on the serial console: the run is
# evidence, so the guest prints what it did and why. If any step fails the guest
# still powers off cleanly (so QEMU exits 0) but the output says which step, and
# qemu/scripts/verify-boot.sh parses for the markers rather than relying on the
# exit code alone.
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t tmpfs tmpfs /tmp

echo "BOOTMARK userspace-up"
uname -a

echo "BOOTMARK insmod-start"
insmod /lib/modules/mali_kbase.ko
INSMOD_RC=$?
echo "BOOTMARK insmod-rc $INSMOD_RC"

lsmod

echo "BOOTMARK probe-start"
kbase-probe
PROBE_RC=$?
echo "BOOTMARK probe-rc $PROBE_RC"

echo "BOOTMARK dmesg-start"
dmesg | grep -iE 'kbase|mali|gpu' || echo "(no kbase lines)"
echo "BOOTMARK dmesg-end"

sync
echo "BOOTMARK poweroff"
poweroff -f
INIT_EOF
chmod +x "$STAGE/init"

# newc is the only cpio format the x86 kernel initramfs parser accepts.
# --quiet keeps the file list out of the log; the contents are summarised above.
( cd "$STAGE" && find . -print0 | LC_ALL=C sort -z | \
  cpio --null --create --format=newc --quiet --owner=0:0 ) | gzip -1 > "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
echo
echo "initramfs: $OUT ($SIZE)"
echo "sha256:    $(sha256sum "$OUT" | awk '{print $1}')"
echo "DONE. Boot it with: qemu/scripts/run.sh --profile $PROFILE"
exit 0
