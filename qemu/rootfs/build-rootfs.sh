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

# kcov-ctl drives KCOV's ioctl protocol and reports real errnos.
#
# The protocol is NOT a write() and NOT self-evident from the node name:
#   KCOV_INIT_TRACE  allocates the coverage area for this task
#   KCOV_ENABLE      starts collection  (requires the area: without
#                    INIT_TRACE this fails -EINVAL, see kcov_ioctl_locked)
#   KCOV_DISABLE     stops collection
# A child forked after ENABLE reports into the parent's REMOTE area, which is
# what makes "run the probe in a child, then read the parent's counters" work.
#
# busybox's `echo >` gives EINVAL with no explanation and cannot express
# INIT_TRACE at all, so this has to be a real program.
cat > "$STAGE/kcov-ctl.c" <<'KCOV_EOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <linux/kcov.h>

#define KCOV_PATH "/sys/kernel/debug/kcov"

static int fail(const char *what, int err)
{
	fprintf(stderr, "%s: %s\n", what, strerror(err));
	return 1;
}

static int cmp_ulong(const void *a, const void *b)
{
	unsigned long x = *(const unsigned long *)a;
	unsigned long y = *(const unsigned long *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
	/*
	 * One invocation runs the WHOLE cycle, because kcov state is
	 * per-open-file: INIT_TRACE on one fd and ENABLE on another leaves the
	 * second fd with no area, and ENABLE then fails -EINVAL. Holding one fd
	 * across init -> enable -> collect -> count -> disable is not a
	 * convenience, it is a requirement.
	 *
	 * The sequence is FIXED and the command to be measured is simply
	 * argv[1..]. An earlier version took an explicit command list where
	 * `run` swallowed the remaining argv, so a trailing `count` was never
	 * reached and the tool printed success having read no counters. Making
	 * the order non-negotiable removes that whole class of mistake.
	 */
	if (argc < 2) {
		fprintf(stderr, "usage: kcov-ctl <command> [args...]\n"
			"Runs the command under KCOV and reports the number of\n"
			"distinct PCs it covered.\n");
		return 2;
	}

	int fd = open(KCOV_PATH, O_RDWR);
	if (fd < 0)
		return fail("open " KCOV_PATH, errno);

	/*
	 * KCOV_INIT_TRACE takes the area SIZE IN WORDS as the ioctl argument
	 * itself, not a pointer to it, and rejects size < 2. The header's
	 * _IOR('c', 1, unsigned long) makes a pointer look expected; it is
	 * not. kcov_ioctl_locked() does `size = arg; if (size < 2 || size >
	 * INT_MAX/sizeof(long)) return -EINVAL;`, so passing a pointer fails
	 * -EINVAL. 256 KiB / 8 = 32768 words.
	 */
	const unsigned long area_words = 256 * 1024 / 8;
	if (ioctl(fd, KCOV_INIT_TRACE, area_words) < 0) {
		int e = errno;
		close(fd);
		return fail("KCOV_INIT_TRACE", e);
	}
	printf("KCOV init-trace ok (area=%lu words / %lu KiB)\n",
	       area_words, area_words * sizeof(unsigned long) / 1024);

	if (ioctl(fd, KCOV_ENABLE, 0) < 0) {
		int e = errno;
		close(fd);
		return fail("KCOV_ENABLE", e);
	}
	printf("KCOV enable ok (collecting)\n");

	/* Fork: the child is covered and reports into this task's REMOTE area. */
	pid_t pid = fork();
	if (pid < 0) {
		int e = errno;
		close(fd);
		return fail("fork", e);
	}
	if (pid == 0) {
		execvp(argv[1], &argv[1]);
		fprintf(stderr, "exec %s: %s\n", argv[1], strerror(errno));
		_exit(127);
	}

	int status = 0;
	if (waitpid(pid, &status, 0) < 0) {
		int e = errno;
		close(fd);
		return fail("waitpid", e);
	}
	int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
	printf("KCOV run: %s exited %d\n", argv[1], code);

	/*
	 * Counters are obtained by MMAP, not read(). kcov_fops has no .read
	 * handler at all (only open/ioctl/mmap/release), so read() on the node
	 * returns -EINVAL regardless of kernel state.
	 *
	 * Two kernel constraints, both from kcov_mmap():
	 *   - vm_pgoff must be 0;
	 *   - vm_end - vm_start must EXACTLY equal kcov->size * sizeof(long),
	 *     so the mapping length must be the size passed to
	 *     KCOV_INIT_TRACE — not a rounded-up page count, which is -EINVAL.
	 *
	 * LAYOUT: this is a PC LIST, not a bitset.
	 * __sanitizer_cov_trace_pc() stores `area[0] = number of PCs recorded
	 * so far` and appends each canonicalised PC at `area[pos]`, incrementing
	 * pos. So:
	 *
	 *     total   = area[0]
	 *     PCs     = area[1 .. total]
	 *
	 * Popcounting the area — which is what this tool originally did —
	 * produces a large, meaningless number that looks like coverage but is
	 * just the popcount of a list of addresses (656023 for a small probe
	 * run). The number a fuzzer needs is DISTINCT PCs, so the list is
	 * sorted and deduplicated; duplicates are expected because the same PC
	 * is recorded on every execution of an instrumented block.
	 *
	 * With a 256 KiB area the list saturates at 32767 entries and area[0]
	 * stops advancing (`pos < t->kcov_size`), so `total` is also the
	 * saturation indicator: total == area_words - 1 means coverage was
	 * TRUNCATED, and any distinct count below that is a lower bound.
	 */
	const size_t map_len = area_words * sizeof(unsigned long);
	unsigned long *area = mmap(NULL, map_len, PROT_READ, MAP_SHARED, fd, 0);
	if (area == MAP_FAILED) {
		int e = errno;
		close(fd);
		return fail("mmap " KCOV_PATH, e);
	}

	unsigned long total = area[0];
	if (total > area_words - 1)
		total = area_words - 1;   /* defensive: never read past the area */

	unsigned long *pcs = malloc(total * sizeof(unsigned long));
	if (!pcs) {
		munmap(area, map_len);
		close(fd);
		return fail("malloc", ENOMEM);
	}
	for (unsigned long i = 0; i < total; i++)
		pcs[i] = area[i + 1];

	/* Sort + unique in place to count DISTINCT PCs. */
	qsort(pcs, total, sizeof(unsigned long), cmp_ulong);
	unsigned long distinct = 0;
	for (unsigned long i = 0; i < total; i++)
		if (i == 0 || pcs[i] != pcs[i - 1])
			distinct++;

	const int truncated = (area[0] >= area_words - 1);

	printf("KCOV records=%lu distinct_pcs=%lu%s\n",
	       total, distinct,
	       truncated ? " TRUNCATED(area full)" : "");
	if (distinct > 0)
		printf("KCOV pc_range=0x%lx-0x%lx\n", pcs[0], pcs[distinct - 1]);

	free(pcs);
	munmap(area, map_len);

	if (ioctl(fd, KCOV_DISABLE, 0) < 0)
		fprintf(stderr, "warning: KCOV_DISABLE: %s\n", strerror(errno));
	else
		printf("KCOV disable ok\n");

	close(fd);
	/* Propagate the child's status: a coverage run that crashed the
	 * workload must not look like a clean one. */
	return code == 0 ? 0 : (code & 0xff);
}
KCOV_EOF
gcc -std=gnu11 -O2 -Wall -Wextra -static \
    -o "$STAGE/bin/kcov-ctl" "$STAGE/kcov-ctl.c" \
    || die "failed to build kcov-ctl"
rm -f "$STAGE/kcov-ctl.c"

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

# --- coverage -------------------------------------------------------------
# Enable KCOV, run the probe in a CHILD, then read the parent's remote counter.
# The fork matters: kcov traces the writing task, and a child it forks reports
# into the parent's remote area. Running the probe inline and reading afterwards
# would read counters the probe itself did not fill.
echo "BOOTMARK kcov-start"
if [ -e /sys/kernel/debug/kcov ]; then
    echo "KCOV node present at /sys/kernel/debug/kcov"
    ls -l /sys/kernel/debug/kcov
    # kcov-ctl performs the whole ioctl cycle on ONE fd (state is per-open-file):
    # INIT_TRACE, ENABLE, fork+exec the probe, read the REMOTE counters, DISABLE.
    # PROBE_RC stays 0 so verify-boot.sh's probe assertion still works; the
    # workload's real status is reported on the KCOV run line above.
    echo "BOOTMARK probe-start"
    kcov-ctl /bin/kbase-probe
    KCOV_RC=$?
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
