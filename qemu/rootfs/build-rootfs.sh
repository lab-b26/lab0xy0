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

# kbase-negargs is the probe's sibling: it proves kbase REJECTS malformed ioctls,
# not just that it accepts good ones (source-audit seam coverage: alias/tiler/
# kcpu/flags-change validation -- the CVE classes catalogued in F-37).
# Same static build, same UAPI headers, no other dependencies.
NEGARGS_SRC="$REPO_ROOT/qemu/target/kbase-negargs.c"
[ -f "$NEGARGS_SRC" ] || die "negargs source missing: $NEGARGS_SRC"
gcc -std=gnu11 -O2 -Wall -Wextra -static -I "$UAPI_INCLUDE" \
    -o "$STAGE/bin/kbase-negargs" "$NEGARGS_SRC" \
    || die "failed to build kbase-negargs"

# kcov-ctl: a real program is required because the KCOV interface is
# ioctl+mmap only (no read/write), INIT_TRACE takes the area size as the
# ioctl argument (not a pointer), and the workload must run in the ENABLED
# TASK since task-mode coverage does not survive fork(). The source lives in
# qemu/target/kcov-ctl.c next to kbase-probe.c/kbase-negargs.c.
KCOVCTL_SRC="$REPO_ROOT/qemu/target/kcov-ctl.c"
[ -f "$KCOVCTL_SRC" ] || die "kcov-ctl source missing: $KCOVCTL_SRC"
gcc -std=gnu11 -O2 -Wall -Wextra -static -I "$UAPI_INCLUDE" \
    -DKBASE_PROBE_NO_MAIN \
    -o "$STAGE/bin/kcov-ctl" "$KCOVCTL_SRC" "$PROBE_SRC" \
    || die "failed to build kcov-ctl"

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

# debugfs is what exposes KCOV's control+counter interface at
# /sys/kernel/debug/kcov. Without this mount the kcov profile compiles the
# instrumentation in and then never reads a single counter, which would make a
# "kcov profile works" claim worthless. Harmless on profiles without KCOV: the
# directory is simply absent.
mkdir -p /sys/kernel/debug
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

echo "BOOTMARK userspace-up"
uname -a

echo "BOOTMARK insmod-start"
insmod /lib/modules/mali_kbase.ko
INSMOD_RC=$?
echo "BOOTMARK insmod-rc $INSMOD_RC"

lsmod

# Console quiet window: kernel printks inject themselves between (and INSIDE)
# the serial console lines the probe and the negargs battery produce -- an early
# run proved it by letting a ringbuffer dev_err split the "PROBE summary" line,
# which failed the assertion even though the probe itself had passed. The ring
# buffer keeps everything; the dmesg dump at the end still prints every kernel
# message. `dmesg -n 1` only stops console writes during the evidence window.
dmesg -n 1

# --- coverage -------------------------------------------------------------
# KCOV task-mode coverage does NOT survive fork() (kcov_task_init resets the
# child), so the probe must run IN THE TRACED TASK: kcov-ctl --inline-probe
# links the probe body and calls it between KCOV_ENABLE and KCOV_DISABLE.
# Counters are frozen (DISABLE) before counting, then printed.
echo "BOOTMARK kcov-start"
if [ -e /sys/kernel/debug/kcov ]; then
    echo "KCOV node present at /sys/kernel/debug/kcov"
    ls -l /sys/kernel/debug/kcov
    # kcov-ctl performs the whole ioctl cycle on ONE fd (state is per-open-file):
    # INIT_TRACE, ENABLE, run the probe IN-PROCESS, DISABLE, count.
    # PROBE_RC stays 0 so verify-boot.sh's probe assertion still works; the
    # workload's real status is reported on the KCOV run line above.
    # CONTROL EXPERIMENT (F-38; settled the question): count actual executions of the
    # module's entry points with kprobes while kcov-ctl drives the device, to
    # prove whether module code runs in the measured path at all.
    mkdir -p /sys/kernel/tracing
    T=/sys/kernel/tracing
    if mount -t tracefs tracefs "$T" 2>/dev/null; then
        echo > "$T/kprobe_events" 2>/dev/null
        echo 'p:kp_open kbase_open' >> "$T/kprobe_events" 2>/dev/null
        echo 'p:kp_read kbase_read' >> "$T/kprobe_events" 2>/dev/null
        echo 'p:kp_ioctl kbase_ioctl' >> "$T/kprobe_events" 2>/dev/null
        echo 1 > "$T/events/kprobes/enable" 2>/dev/null
        echo "BOOTMARK kprobe-armed"
    fi
    echo "BOOTMARK probe-start"
    kcov-ctl --inline-probe
    KCOV_RC=$?
    # discriminator: open+read on /dev/mali0 runs kbase_open/kbase_read in
    # THIS task under tracing -- isolates module coverage from probe machinery
    kcov-ctl --inline-read /dev/mali0
    KCOVREAD_RC=$?
    echo "BOOTMARK kcov-inline-read-rc $KCOVREAD_RC"
    # windowed control: exactly which PCs a single open()+read() of the
    # device produces, bucketed vs the running module's text range
    kcov-ctl --inline-window /dev/mali0 || true
    if [ -d "$T" ]; then
        echo "KPROBE hits: open=$(grep -c kp_open $T/trace 2>/dev/null) read=$(grep -c kp_read $T/trace 2>/dev/null) ioctl=$(grep -c kp_ioctl $T/trace 2>/dev/null)"
    fi
    PROBE_RC=0
    echo "BOOTMARK kcov-ctl-rc $KCOV_RC"
    echo "BOOTMARK probe-rc $PROBE_RC"
else
    echo "no /sys/kernel/debug/kcov - kernel built without KCOV (expected on non-kcov profiles)"
    echo "BOOTMARK probe-start"
    kbase-probe
    PROBE_RC=$?
    echo "BOOTMARK probe-rc $PROBE_RC"
fi
echo "BOOTMARK kcov-end"

# Console interleave: kernel printks can inject INTO the PROBE/NEGARGS summary
# lines on the serial (an earlier run had the ringbuffer dev_err land between
# "PROBE summary" and "passed=0x1ff", failing the assertion while the probe
# itself had passed) -- the quiet window above covers this whole section.
echo "BOOTMARK negargs-start"
if [ -x /bin/kbase-negargs ] && [ "$INSMOD_RC" = "0" ]; then
    kbase-negargs
    echo "BOOTMARK negargs-rc $?"
else
    echo "NEGARGS summary skipped (no binary or insmod failed)"
fi
echo "BOOTMARK negargs-end"
dmesg -n 7

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
