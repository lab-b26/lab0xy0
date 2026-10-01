#!/usr/bin/env bash
#
# apply-patches.sh — create the patched Kbase tree from pristine r54p0.
#
# Reproducible and non-destructive:
#   work/kbase-pristine/   fresh extract of the vendor archive, never modified
#   work/kbase-patched/    pristine + the six Arm virtual-device patches
#
# The pristine tree is NEVER patched in place, so it can always be re-diffed.
# The six vendor patch files are used as-is (never edited).
#
# Records a patch-series identity (SHA-256 over the ordered patch checksums) for
# the build manifest.
#
# Run on the BUILD host after fetch-kernel.sh. See ../BUILD-HOST.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDOR_TAR="$REPO_ROOT/vendor/arm/AX504X08X-SW-99002-r54p0-01eac0.tar.gz"
PATCH_DIR="$REPO_ROOT/patches/virtual-device"
WORK="$REPO_ROOT/work"
PRISTINE="$WORK/kbase-pristine"
PATCHED="$WORK/kbase-patched"
KERNEL_SRC_ROOT="$REPO_ROOT/kernel/sources/linux"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

echo "=============================================================="
echo " apply-patches.sh — pristine r54p0 -> patched r54p0"
echo "=============================================================="

[ -f "$VENDOR_TAR" ] || die "vendor archive missing: $VENDOR_TAR"
( cd "$REPO_ROOT/vendor/arm" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    || die "vendor archive checksum verification FAILED"
echo "vendor archive verified."

# --- 1. pristine extract (idempotent) ------------------------------------
if [ -d "$PRISTINE/driver" ]; then
    echo "pristine tree already present: $PRISTINE"
else
    rm -rf "$PRISTINE"; mkdir -p "$PRISTINE"
    echo "extracting pristine r54p0 -> $PRISTINE ..."
    tar -xzf "$VENDOR_TAR" -C "$PRISTINE" || die "extract failed"
fi
[ -d "$PRISTINE/driver/product/kernel" ] || die "unexpected pristine layout (no driver/product/kernel)"

# --- 2. patched copy (fresh each run, from pristine) ---------------------
rm -rf "$PATCHED"
cp -a "$PRISTINE" "$PATCHED"
echo "copied pristine -> $PATCHED"

# --- 3. apply the six patches in numeric order ---------------------------
# Patches are applied from the driver/ directory with -p1, matching the
# verified applicability result (see ../../analysis/virtual-device.md).
DRIVER="$PATCHED/driver"
echo
echo "applying patches in order (from $DRIVER, patch -p1):"

applied=0
for p in "$PATCH_DIR"/0*.patch; do
    [ -f "$p" ] || die "missing patch: $p"
    name=$(basename "$p")
    printf '  %-64s ' "$name"
    if ( cd "$DRIVER" && patch -p1 --forward --silent < "$p" ); then
        echo "applied"
        applied=$((applied+1))
    else
        echo "FAILED"
        die "patch $name did not apply to pristine r54p0. Do not proceed.
       Verify with: (cd $DRIVER && git apply --check -p1 < '$p')
       Expected on r54p0: all six apply cleanly. A failure here means the source
       or patch set changed — stop and investigate (see analysis/findings.md)."
    fi
done
echo "applied $applied/6 vendor patches."

# --- 3b. research-authored patches (ours, from kernel/patches/) -----------
# Kept strictly separate from the vendor series: Arm's six are third-party
# and byte-preserved under patches/virtual-device/, while these are authored
# here. They are applied AFTER the vendor series (they are written against
# vendor-patched source) and are identified by their own hash.
echo
echo "applying research patches in order (from $DRIVER, patch -p1):"
research_applied=0
shopt -s nullglob
for p in "$REPO_ROOT/kernel/patches"/0*.patch; do
    rname=$(basename "$p")
    printf '  %-64s ' "$rname"
    if ( cd "$DRIVER" && patch -p1 --forward --silent < "$p" ); then
        echo "applied"
        research_applied=$((research_applied+1))
    else
        echo "FAILED"
        die "research patch $rname did not apply. It was authored against
       r54p0 + the six vendor patches; if either changed, regenerate it
       against the current tree. See analysis/findings.md."
    fi
done
shopt -u nullglob
[ "$research_applied" -eq 0 ] && echo "  (none present)"

# --- 4. patch-series identity for the build manifest ---------------------
# The vendor series hash stays EXACTLY as before (it is the identity of the
# six Arm patches alone). The research series gets its own hash, and the
# manifest carries both, so an artifact can never be attributed to the wrong
# patch set.
echo
SERIES_FILE="$PATCH_DIR/SHA256SUMS"
[ -f "$SERIES_FILE" ] || die "patches/virtual-device/SHA256SUMS missing"
SERIES_HASH=$(sha256sum "$SERIES_FILE" | awk '{print $1}')
echo "vendor patch-series identity (sha256 of ordered checksums): $SERIES_HASH"
echo "$SERIES_HASH" > "$PATCHED/.patch-series.sha256"

RESEARCH_HASH=$(cat "$REPO_ROOT"/kernel/patches/0*.patch 2>/dev/null | sha256sum | awk '{print $1}')
[ -n "$RESEARCH_HASH" ] || RESEARCH_HASH="none"
echo "research patch-series identity (sha256 over $research_applied patch(es)): $RESEARCH_HASH"
echo "$RESEARCH_HASH" > "$PATCHED/.research-patch-series.sha256"

# --- 5. confirm the known guards are present -----------------------------
echo
echo "spot-checking expected patched source (from analysis/):"
cc=0
if grep -q 'KERNEL_VERSION(4, 1, 0) > LINUX_VERSION_CODE' \
     "$DRIVER/product/kernel/include/linux/version_compat_defs.h"; then
    echo "  [ok] patch 0001 guard (4.1 polarity) present"; cc=$((cc+1))
else echo "  [--] patch 0001 guard not found (informational)"; fi
if grep -q 'define dmb(opt) mb()' \
     "$DRIVER/product/kernel/include/linux/version_compat_defs.h"; then
    echo "  [ok] patch 0004 dmb() fallback present"; cc=$((cc+1))
else echo "  [--] patch 0004 dmb() fallback not found (informational)"; fi
echo "  ($cc/2 spot-checks confirmed; informational only)"

echo
echo "DONE. Patched Kbase tree: $DRIVER/product/kernel"
echo "Patch-series hash: $SERIES_HASH"
echo "Next: kernel/scripts/build.sh --profile baseline"
exit 0