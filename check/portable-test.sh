#!/usr/bin/env bash
#
# portable-test.sh <profile> -- prove a bundle is self-contained, not just
# bootable.
#
# A bundle can PASS every boot assertion and still be repo-dependent: as long as
# build/<profile>/ exists, run.sh's fallback resolution can silently borrow from
# it, and nothing notices the bundle is incomplete (F-22). This test removes the
# question:
#
#   1. integrity-check the bundle as it stands     (sha256sum -c)
#   2. copy it to /tmp/portable-test-<profile>/    (the "clean location")
#   3. rename the repository's build/ tree away    (the repo is now unreachable
#      for component resolution; RESTORED BY TRAP on EXIT/INT/TERM)
#   4. boot the copy with --strict-artifact        (no fallback even allowed)
#   5. require the full PROBE pass signature and append a
#      "CLEAN-LOCATION: <profile>" marker to the log
#
# The marker is not decoration: package-artifact.sh --promote-to
# PORTABLE_ARTIFACT_VERIFIED refuses a log without it, and check/check-all.sh B3
# re-verifies it later. A promotion claim without a marker, a marker without a
# passing boot, or a passing boot that used the build tree -- all rejected.
#
# F-31 note: --strict-artifact ALONE is not sufficient to conclude portability,
# because it only constrains run.sh's resolution. Renaming build/ away is still
# what proves nothing ELSE reachable the tree (manifest checks, future readers
# of vmlinux paths, etc.). Both halves are kept.
#
# SCOPE: DISCOVERY-ONLY (DECISION-1). A pass here says the simulator bundle is
# portable, never that the driver conforms on real hardware.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

PROFILE="${1:-}"
[ -n "$PROFILE" ] || die "usage: check/portable-test.sh <baseline|kasan|kcov|debug>"

SRC="artifacts/$PROFILE"
DST="/tmp/portable-test-$PROFILE"
LOG_DIR="research/boot-logs"
LOG="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$PROFILE-PORTABLE.log"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

[ -d "$SRC" ] || die "no bundle at $SRC"
[ -f "$SRC/metadata/SHA256SUMS" ] || die "bundle has no metadata/SHA256SUMS"
[ -d "$REPO_ROOT/build" ] || die "no build/ tree to rename away -- the test needs it present to prove independence from it"

BUILD_RENAMED=0
cleanup() {
    if [ -d "$REPO_ROOT/build.off" ]; then
        mv "$REPO_ROOT/build.off" "$REPO_ROOT/build"
        echo "restored: build.off -> build" >&2
    else
        # Hit before rename: nothing to do. If the rename happened and restore
        # failed, that is catastrophic -- make noise rather than claim order.
        [ "$BUILD_RENAMED" -eq 1 ] && \
            echo "FATAL: build/ was renamed and could not be restored; restore $REPO_ROOT/build*.off manually" >&2
    fi
    rm -rf "$DST"
    rmdir "/tmp/portable-test-$PROFILE-cpio" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=============================================================="
echo " portable-test.sh -- $PROFILE"
echo "=============================================================="
echo "bundle:     $SRC"
echo "clean site: $DST"
echo "log:        $LOG"

# 1. The bundle under test must first be flawless as it stands.
echo "--- 1/5  integrity of the bundle under test"
( cd "$SRC" && sha256sum -c metadata/SHA256SUMS | grep -v ': OK$' ) \
    && die "SHA256SUMS mismatch in $SRC before relocation -- a broken bundle must not be promoted" \
    || echo "      all files match SHA256SUMS"

# 2. Relocate the content under test to /tmp.
echo "--- 2/5  copy to clean location"
rm -rf "$DST"
cp -a "$SRC" "$DST"
echo "      $(du -sh "$DST" | awk '{print $1}') at $DST"

# 3. Remove the repository's build tree from reach.
echo "--- 3/5  renames build/ away (restored on exit)"
mv "$REPO_ROOT/build" "$REPO_ROOT/build.off"
BUILD_RENAMED=1
echo "      build/ -> build.off"

# 4. Boot strictly from the copy.
echo "--- 4/5  boot from the copy (--strict-artifact)"
mkdir -p "$LOG_DIR"
if ! qemu/scripts/verify-boot.sh --profile "$PROFILE" \
        --artifact "$DST" --strict-artifact --log "$LOG" >/dev/null 2>&1; then
    echo "      BOOT FAILED ($LOG)"
    printf '\nCLEAN-LOCATION-RESULT: FAIL (%s)\n' "$PROFILE" >> "$LOG"
    exit 1
fi

# 5. Require the pass signature and append the attestation marker.
echo "--- 5/5  verify the pass signature and attest"
grep -qE 'PROBE summary[[:space:]]+passed=0x1ff[[:space:]]+failed=0x000' "$LOG" \
    || die "log lacks the full PROBE pass -- refusing to attest"
cat >> "$LOG" <<EOF

CLEAN-LOCATION: $PROFILE
  bundle:    $SRC  (sha256sum -c clean before and after the boot)
  booted from: $DST  with the repo's build/ tree renamed away
  strict-artifact: yes (no build/ fallback permitted)
  at:          $TS
EOF

# 6. The ORIGINAL bundle must still be byte-consistent after all of this --
# catching the case where the test itself mutated what it was testing.
( cd "$SRC" && sha256sum -c metadata/SHA256SUMS | grep -v ': OK$' ) \
    && die "SHA256SUMS mismatch in $SRC AFTER the run -- the test touched the bundle" \
    || echo "      original bundle still matches SHA256SUMS"

note_and_exit() {
    echo
    echo "VERDICT: $PROFILE is self-contained. Promote it with:"
    echo "  qemu/scripts/package-artifact.sh --profile $PROFILE \\"
    echo "      --promote-to PORTABLE_ARTIFACT_VERIFIED --evidence $LOG"
    exit 0
}
note_and_exit
