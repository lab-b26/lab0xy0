#!/usr/bin/env bash
#
# run.sh --profile <baseline|kasan|kcov|debug> [--artifact DIR] [--serial FILE]
#          [--accel kvm|tcg|auto] [--rootfs FILE] [--] [extra QEMU args...]
#
# Launch a prebuilt profile artifact under QEMU with a serial control channel.
#
# This wrapper BUILDS NOTHING. It consumes an already-built kernel image, an
# already-built Kbase module bundle and an already-built rootfs. If any of them
# is missing it says so and stops, rather than quietly rebuilding: BUILD-TIME
# and FUZZING-TIME are separated on purpose (see ../../artifacts/README.md).
#
# It is profile-agnostic: the profile selects which prebuilt components to use,
# it does not change how the VM is configured. One code path serves all four.
#
# Paths are resolved relative to the repo, or from an explicit --artifact, so a
# packaged artifact can be moved elsewhere and still boot. No host path is baked
# in.
#
# KVM-aware but not KVM-dependent: /dev/kvm is used when it is actually usable by
# this user, otherwise QEMU falls back to TCG. Note that on some hosts /dev/kvm
# exists but is root-only (mode 0660, group kvm); "present" is not "accessible",
# and treating them as the same produces a confusing accelerator failure.
#
# When TCG is selected, the guest is given -cpu max. That is required because the
# TCG emulator does not implement the full default CPU model set and will refuse
# to start an x86-64 guest without an explicit CPU.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build"
ARTIFACT_DEFAULT="$REPO_ROOT/artifacts"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

PROFILE=""; ARTIFACT=""; SERIAL=""; ACCEL="auto"; ROOTFS=""; MEM=2048; CPUS=4
EXTRA=()
usage() {
    cat <<'EOF'
Usage: qemu/scripts/run.sh --profile <name> [options] [-- extra qemu args]

  --profile <name>   baseline | kasan | kcov | debug   (required)
  --artifact DIR     artifact bundle (default: artifacts/<profile>, falling back
                     to build/<profile>)
  --rootfs FILE      initramfs to boot (default: build/rootfs/rootfs-<profile>.cpio.gz)
  --serial FILE      write the serial console here (default: stdout only)
  --accel MODE       kvm | tcg | auto   (default: auto)
  --strict-artifact  forbid the build/<profile> fallback: every component must
                     come from the bundle. REQUIRED by the portability test --
                     without it a missing bundle file is silently replaced by
                     the build tree and an incomplete bundle looks portable.
  --mem MB           guest RAM (default: 2048)
  --cpus N           guest vCPUs (default: 4)
  --interactive      keep the guest alive on stdin instead of powering off
  --                 everything after this is passed verbatim to QEMU

Environment:
  QEMU             qemu binary (default: qemu-system-x86_64)
  SUDO             set to 1 to run QEMU via `sudo -n` (for KVM where /dev/kvm
                   is root-only); default: only if KVM is wanted and unusable
EOF
}

INTERACTIVE=0
STRICT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --artifact) ARTIFACT="${2:-}"; shift 2 ;;
        --rootfs) ROOTFS="${2:-}"; shift 2 ;;
        --serial) SERIAL="${2:-}"; shift 2 ;;
        --accel) ACCEL="${2:-}"; shift 2 ;;
        --strict-artifact) STRICT=1; shift ;;
        --mem) MEM="${2:-}"; shift 2 ;;
        --cpus) CPUS="${2:-}"; shift 2 ;;
        --interactive) INTERACTIVE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA=("$@"); break ;;
        *) die "unknown argument: $1 (use -- to pass QEMU args)" ;;
    esac
done

case "$PROFILE" in
    baseline|kasan|kcov|debug) ;;
    *) [ -n "$PROFILE" ] || die "--profile is required"; die "unknown profile: $PROFILE" ;;
esac

QEMU="${QEMU:-qemu-system-x86_64}"
command -v "$QEMU" >/dev/null 2>&1 || die "qemu binary not found: $QEMU"

# --- resolve the prebuilt components (never build) ------------------------
[ -n "$ARTIFACT" ] || ARTIFACT="$ARTIFACT_DEFAULT/$PROFILE"

# The build-tree fallback below exists for convenience BEFORE a bundle is
# packaged. But it is also the exact way a non-self-contained bundle gets mistaken
# for a portable one: if artifacts/<p>/kernel/bzImage went missing, the boot would
# silently succeed from build/<p>/ and nothing would notice the bundle is
# incomplete. That is F-22's failure mode recurring through the back door. So
# --strict-artifact forbids the fallback entirely, and the portability test uses
# it: a missing component becomes a hard error naming the bundle, never a silent
# substitution.
# resolve_from_artifact <label> <fallback> <candidate> [candidate...]
#
# The fallback is a SEPARATE positional parameter, deliberately. An earlier version
# took it as the last element of the candidate list and shifted once -- so `shift`
# left the fallback still inside "$@", the candidate loop matched it directly, and
# --strict-artifact was never consulted at all. The flag appeared to work (STRICT=1
# was plainly visible in the trace) while the boot silently used build/ anyway.
# That is the worst possible shape of bug here: a portability check that always
# passes. Found by testing the flag's negative case, not by reading the code.
resolve_from_artifact() {
    _label="$1"; _fallback="$2"; _hit=""
    shift 2
    for cand in "$@"; do
        if [ -f "$cand" ]; then _hit="$cand"; break; fi
    done
    if [ -z "$_hit" ] && [ -n "$_fallback" ] && [ "$STRICT" -eq 0 ] && [ -f "$_fallback" ]; then
        echo "note: $_label resolved from the build tree, not the bundle:" >&2
        echo "      $_fallback" >&2
        echo "      (pass --strict-artifact to forbid this)" >&2
        _hit="$_fallback"
    fi
    [ -n "$_hit" ] || return 1
    printf '%s' "$_hit"
}

KERNEL=$(resolve_from_artifact "bzImage" \
    "$BUILD_ROOT/$PROFILE/arch/x86/boot/bzImage" \
    "$ARTIFACT/kernel/bzImage") || die "no bzImage for profile '$PROFILE'.
Looked in:
  $ARTIFACT/kernel/bzImage
  $BUILD_ROOT/$PROFILE/arch/x86/boot/bzImage
Build it first:  kernel/scripts/build.sh --profile $PROFILE"

# The rootfs must resolve from the artifact too, not just from build/rootfs/.
# A bundle that could only boot while the repo's build tree was still present
# would not be self-contained, which is the whole point of packaging one
# (see ../../artifacts/README.md). Same candidate order as the kernel: artifact
# first, build tree only as a pre-packaging fallback.
ROOTFS=$(resolve_from_artifact "rootfs" \
    "$BUILD_ROOT/rootfs/rootfs-$PROFILE.cpio.gz" \
    "$ARTIFACT/rootfs/rootfs-$PROFILE.cpio.gz" \
    "$ARTIFACT/rootfs/rootfs.cpio.gz") || die "no rootfs for profile '$PROFILE'.
Looked in:
  $ARTIFACT/rootfs/rootfs-$PROFILE.cpio.gz
  $ARTIFACT/rootfs/rootfs.cpio.gz
  $BUILD_ROOT/rootfs/rootfs-$PROFILE.cpio.gz
Build it first:  qemu/rootfs/build-rootfs.sh --profile $PROFILE"

# Report what was actually used, so the log records which tree answered. Silence
# here would let a fallback boot masquerade as an artifact boot -- the reviewer
# reading a PASS has no way to tell the two apart otherwise.
echo "run.sh: profile=$PROFILE strict=$STRICT" >&2
echo "run.sh:   kernel=$KERNEL" >&2
echo "run.sh:   rootfs=$ROOTFS" >&2

# --- accelerator selection -------------------------------------------------
# "KVM present" is not "KVM usable": the device node can be root-only.
kvm_usable() { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }
have_sudo() { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

SUDO_PREFIX=()
case "$ACCEL" in
    auto|kvm)
        if kvm_usable; then
            ACCEL=kvm
        elif have_sudo && [ -e /dev/kvm ]; then
            ACCEL=kvm
            SUDO_PREFIX=(sudo -n)
            echo "note: /dev/kvm is not accessible to $(id -un) (mode $(stat -c %a /dev/kvm 2>/dev/null || echo '?')); using sudo -n for KVM" >&2
        elif [ "$ACCEL" = kvm ]; then
            die "--accel kvm requested but /dev/kvm is not accessible (and sudo -n is unavailable)"
        else
            ACCEL=tcg
            echo "note: /dev/kvm unavailable; falling back to TCG (slower, but identical guest behaviour)" >&2
        fi
        ;;
    tcg) ACCEL=tcg ;;
    *) die "--accel must be auto, kvm or tcg (got: $ACCEL)" ;;
esac

QEMU_ARGS=(
    -machine q35
    -m "$MEM"
    -smp "$CPUS"
    -no-reboot
    -kernel "$KERNEL"
    -initrd "$ROOTFS"
    -append "console=ttyS0 panic=-1 rdinit=/init loglevel=7"
)
if [ "$ACCEL" = kvm ]; then
    QEMU_ARGS+=( -accel kvm )
else
    # TCG cannot emulate the default CPU model set for x86_64; max is required.
    QEMU_ARGS+=( -accel tcg -cpu max )
fi
[ "$INTERACTIVE" = 1 ] && QEMU_ARGS+=( -serial mon:stdio )

[ ${#EXTRA[@]} -gt 0 ] && QEMU_ARGS+=( "${EXTRA[@]}" )

echo "=============================================================="
echo " run.sh -- profile $PROFILE"
echo "=============================================================="
echo "kernel:    $KERNEL"
echo "rootfs:    $ROOTFS"
echo "accel:     $ACCEL${SUDO_PREFIX:+ (via sudo)}"
echo "qemu:      $("$QEMU" --version 2>/dev/null | head -1)"
if [ -n "$SERIAL" ]; then
    mkdir -p "$(dirname "$SERIAL")"
    echo "serial:    $SERIAL"
    set +e
    "${SUDO_PREFIX[@]}" "$QEMU" "${QEMU_ARGS[@]}" -nographic -serial "file:$SERIAL" >/dev/null 2>&1
    RC=$?
    set -e
    echo
    echo "--- serial output ---"
    cat "$SERIAL"
    echo "--- end serial output ---"
    exit $RC
fi

exec "${SUDO_PREFIX[@]}" "$QEMU" "${QEMU_ARGS[@]}" -nographic
