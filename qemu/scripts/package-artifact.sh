#!/usr/bin/env bash
#
# package-artifact.sh -- bundle one profile's prebuilt components into a
#                        self-contained, relocatable artifact.
#
#   qemu/scripts/package-artifact.sh --profile <baseline|kcov|kasan|debug>
#                                    [--out DIR] [--validation-state STATE]
#
# What it collects, per artifacts/README.md:
#
#     <out>/kernel/bzImage          bootable image for this profile
#     <out>/kernel/vmlinux          with symbols (KCOV / crash triage)
#     <out>/kernel/config           the exact .config used
#     <out>/modules/…               Kbase .ko (+ deps), path preserved
#     <out>/rootfs/…                this profile's initramfs
#     <out>/metadata/manifest.json  structured identity
#     <out>/metadata/SHA256SUMS     integrity of every packaged file
#     <out>/README.md               how to run it
#
# It NEVER builds. A component that does not exist is a hard error, not a
# silent omission — an artifact missing its kernel is worse than no artifact,
# because it fails later and further away.
#
# The bundle must not reference the build tree: everything is copied in, and
# `run.sh --artifact` resolves bzImage and rootfs from inside the bundle. The
# clean-location test in artifacts/README.md is what proves that; this script
# only makes the bundle self-contained enough for that test to be meaningful.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build"

die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }
note() { printf '\n=== %s\n' "$*"; }
log()  { printf '      %s\n' "$*"; }

PROFILE=""; OUT=""; VALIDATION_STATE="BUILT"; PROMOTE_TO=""; EVIDENCE=""
usage() { sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)          PROFILE="${2:-}"; shift 2 ;;
        --out)              OUT="${2:-}"; shift 2 ;;
        --validation-state) VALIDATION_STATE="${2:-}"; shift 2 ;;
        --promote-to)       PROMOTE_TO="${2:-}"; shift 2 ;;
        --evidence)         EVIDENCE="${2:-}"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$PROFILE" ] || die "--profile is required"
case "$PROFILE" in
    baseline|kcov|kasan|debug) ;;
    *) die "unknown profile: $PROFILE" ;;
esac

# Only these five states mean anything (artifacts/README.md). Refusing anything
# else is the point: "BUILT but actually portable" is the mistake this prevents.
case "$VALIDATION_STATE" in
    BUILT|BOOT_VERIFIED|KBASE_LOAD_VERIFIED|TARGET_VERIFIED|PORTABLE_ARTIFACT_VERIFIED) ;;
    *) die "unknown validation state: $VALIDATION_STATE" ;;
esac

[ -n "$OUT" ] || OUT="$REPO_ROOT/artifacts/$PROFILE"

# write_bundle_readme -- generated README for the bundle. Shared by the
# packaging path and the promotion path; if the two ever generated different text,
# a promoted bundle would describe a different lifecycle than a packaged one.
write_bundle_readme() {
cat > "$OUT/README.md" <<EOF
# Artifact — \`${PROFILE}\`

\`kbase-${KBASE_RELEASE}\` on Linux \`${KERNEL_VERSION}\`, profile \`${PROFILE}\`.

| | |
|---|---|
| validation status | **${VALIDATION_STATE}** |
| scope class | **${SCOPE_CLASS}** (DECISION-1: INVESTIGATION-ONLY) |
| kernel image | \`kernel/bzImage\` |
| symbols | \`kernel/vmlinux\` |
| config | \`kernel/config\` (sha256 \`${CONFIG_SHA:0:12}…\`) |
| Kbase module | \`modules/${KMOD_REL}\` |
| rootfs | \`rootfs/rootfs-${PROFILE}.cpio.gz\` |
| manifest | \`metadata/manifest.json\` |
| integrity | \`metadata/SHA256SUMS\` |

## Run it

\`\`\`bash
# from anywhere; no repo needed
qemu-system-x86_64 -machine q35 -m 2048 -smp 4 -no-reboot \\
  -kernel kernel/bzImage \\
  -initrd rootfs/rootfs-${PROFILE}.cpio.gz \\
  -append "console=ttyS0 panic=-1 rdinit=/init loglevel=7" \\
  -enable-kvm -nographic

# or, with this repo's wrappers
qemu/scripts/run.sh --profile ${PROFILE} --artifact <this directory>
qemu/scripts/verify-boot.sh --profile ${PROFILE} --artifact <this directory>
\`\`\`

Add \`-accel tcg -cpu max\` instead of \`-enable-kvm\` where KVM is unavailable.

## Verify integrity

\`\`\`bash
sha256sum -c metadata/SHA256SUMS
\`\`\`

## What ${VALIDATION_STATE} does and does not mean

$(case "$VALIDATION_STATE" in
  BUILT)                  echo "It was compiled. Nothing has been booted." ;;
  BOOT_VERIFIED)          echo "It boots. The Kbase module has NOT been shown to load." ;;
  KBASE_LOAD_VERIFIED)    echo "It boots and Kbase loads. The ioctl surface has NOT been exercised." ;;
  TARGET_VERIFIED)        echo "It boots, Kbase loads, and /dev/mali0 ioctls respond. Portability has NOT been tested." ;;
  PORTABLE_ARTIFACT_VERIFIED) echo "It additionally passed the clean-location test: booted from a copy with the build tree unavailable." ;;
esac)

Per **DECISION-1** this bundle is **DISCOVERY-ONLY** regardless of validation
status. It is \`MALI_NO_MALI\` on x86_64; results from it must be re-confirmed on
conforming real hardware before they mean anything.
EOF
}

# ---- promotion mode: raise an EXISTING bundle's validation_status -----------
# No build tree is touched or needed. This exists because a bundle that has
# passed the clean-location test must be able to record that AFTER its build
# tree was pruned to reclaim disk -- requiring build/ here would make the disk
# choreography in TODO.md impossible.
#
# A promotion is a CLAIM, so it carries evidence:
#   - the target must sit at or above the current rung on this tool's ladder
#     (demotion is a deliberate re-packaging with a lower --validation-state,
#     never a side effect of this flag);
#   - PORTABLE_ARTIFACT_VERIFIED additionally requires --evidence <log>, and
#     that log must contain the full PROBE pass signature AND a
#     "CLEAN-LOCATION: <profile>" marker. A log from a different profile, or
#     one whose boot did not reach PROBE 0x1ff, is not evidence THIS bundle is
#     portable. check/check-all.sh B3 re-verifies all of it.
if [ -n "$PROMOTE_TO" ]; then
    _MF="$OUT/metadata/manifest.json"
    [ -f "$_MF" ] || die "no bundle at $OUT to promote (no metadata/manifest.json)"
    _CUR=$(sed -n 's/.*"validation_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_MF" | head -1)
    [ -n "$_CUR" ] || die "no readable validation_status in $_MF"

    # NOTE: this ordering is THIS TOOL's ladder (package-time vocabulary).
    # artifacts/README.md names the same rung QEMU_BOOT_VERIFIED where this tool
    # says BOOT_VERIFIED. Only PORTABLE_ARTIFACT_VERIFIED is promoted to in
    # practice, so the two vocabularies never compare rung-for-rung here.
    _LAD="BUILT BOOT_VERIFIED KBASE_LOAD_VERIFIED TARGET_VERIFIED PORTABLE_ARTIFACT_VERIFIED"
    _lad_pos() { local w="$1" s n=0; for s in $_LAD; do n=$((n+1)); [ "$s" = "$w" ] && { echo $n; return; }; done; echo 0; }
    _CN=$(_lad_pos "$_CUR"); _TN=$(_lad_pos "$PROMOTE_TO")
    [ "$_TN" -gt 0 ] || die "unknown promote target: $PROMOTE_TO"
    [ "$_CN" -gt 0 ] || die "bundle current state '$_CUR' is not on the ladder"
    [ "$_TN" -lt "$_CN" ] && die "refusing to demote: $_CUR is rung $_CN, target $PROMOTE_TO is rung $_TN"

    if [ "$PROMOTE_TO" = PORTABLE_ARTIFACT_VERIFIED ]; then
        [ -n "$EVIDENCE" ] || die "promotion to PORTABLE_ARTIFACT_VERIFIED requires --evidence <clean-location log>"
        [ -f "$EVIDENCE" ] || die "evidence log not found: $EVIDENCE"
        grep -qE 'PROBE summary[[:space:]]+passed=0x1ff[[:space:]]+failed=0x000' "$EVIDENCE" \
            || die "evidence $EVIDENCE contains no full PROBE pass (passed=0x1ff)"
        grep -q "CLEAN-LOCATION: $PROFILE" "$EVIDENCE" \
            || die "evidence $EVIDENCE has no 'CLEAN-LOCATION: $PROFILE' marker -- it does not attest THIS bundle"
    fi

    note "promoting $OUT : $_CUR -> $PROMOTE_TO"
    # Re-read identity from the existing manifest: the build tree may be gone.
    read -r KERNEL_VERSION KBASE_RELEASE CONFIG_SHA KMOD_REL SCOPE_CLASS < <(
        python3 - "$_MF" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
print(m["kernel_release"], m["kbase_release"], m["kernel_config_sha256"],
      m["modules"]["kbase"].removeprefix("modules/"), m["scope_class"])
PYEOF
    )
    VALIDATION_STATE="$PROMOTE_TO"

    # Record the evidence in the manifest rather than merely asserting it --
    # a later reader must be able to open the log, not trust this script.
    python3 - "$_MF" "$PROMOTE_TO" "$EVIDENCE" <<'PYEOF'
import json, sys, datetime
p, state, ev = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(p))
m["validation_status"] = state
m["promoted_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if ev: m["clean_location_log"] = ev
json.dump(m, open(p, "w"), indent=2)
open(p, "a").write("\n")
PYEOF

    write_bundle_readme
    log "README.md (regenerated for $PROMOTE_TO)"

    # Sums AFTER README so the file that states the status is itself defended.
    ( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 \
        | sort -z | xargs -0 sha256sum > metadata/SHA256SUMS )
    log "metadata/SHA256SUMS ($(wc -l < "$OUT/metadata/SHA256SUMS") files)"
    note "done"
    log "state: $PROMOTE_TO   scope: $SCOPE_CLASS"
    exit 0
fi

BUILD="$BUILD_ROOT/$PROFILE"
[ -d "$BUILD" ] || die "no build tree for profile '$PROFILE' at $BUILD
Build it first:  kernel/scripts/build.sh --profile $PROFILE"




# --- every required input must exist BEFORE we create anything --------------
note "checking inputs"
BUILDDIR="$BUILD_ROOT/rootfs"
[ -f "$BUILD/arch/x86/boot/bzImage" ] || die "missing $BUILD/arch/x86/boot/bzImage"
log "ok  kernel image"
[ -f "$BUILD/vmlinux" ] || die "missing $BUILD/vmlinux"
log "ok  vmlinux (symbols)"
[ -f "$BUILD/.config" ] || die "missing $BUILD/.config"
log "ok  config"
[ -f "$BUILD/build-metadata.txt" ] || die "missing $BUILD/build-metadata.txt"
log "ok  build metadata"
[ -f "$BUILD/drivers/gpu/arm/midgard/mali_kbase.ko" ] \
    || die "missing $BUILD/drivers/gpu/arm/midgard/mali_kbase.ko"
log "ok  Kbase module"

# The rootfs embeds the module, so a rootfs built for a different profile is a
# silent-wrong-artifact bug. Require the profile-specific name to exist.
ROOTFS_SRC="$BUILDDIR/rootfs-$PROFILE.cpio.gz"
[ -f "$ROOTFS_SRC" ] || die "missing $ROOTFS_SRC
Build it first:  qemu/rootfs/build-rootfs.sh --profile $PROFILE"
log "ok  rootfs ($PROFILE)"

# --- collect ---------------------------------------------------------------
note "packaging -> $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"/{kernel,modules,rootfs,metadata}

cp "$BUILD/arch/x86/boot/bzImage" "$OUT/kernel/bzImage"
cp "$BUILD/vmlinux"              "$OUT/kernel/vmlinux"
cp "$BUILD/.config"              "$OUT/kernel/config"
cp "$BUILD/build-metadata.txt"   "$OUT/metadata/build-metadata.txt"
log "kernel/  bzImage, vmlinux, config"

# Preserve the in-tree module path so the layout is recognisable and so a
# dependency's own path stays meaningful.
KMOD_REL="drivers/gpu/arm/midgard/mali_kbase.ko"
mkdir -p "$OUT/modules/$(dirname "$KMOD_REL")"
cp "$BUILD/$KMOD_REL" "$OUT/modules/$KMOD_REL"
log "modules/ $KMOD_REL"

MODCOUNT=1
while IFS= read -r ko; do
    rel="${ko#$BUILD/}"
    mkdir -p "$OUT/modules/$(dirname "$rel")"
    cp "$ko" "$OUT/modules/$rel"
    MODCOUNT=$((MODCOUNT + 1))
done < <(find "$BUILD" -name '*.ko' -not -path "$BUILD/$KMOD_REL" | sort)
log "modules/ $MODCOUNT .ko total"

cp "$ROOTFS_SRC" "$OUT/rootfs/rootfs-$PROFILE.cpio.gz"
log "rootfs/  rootfs-$PROFILE.cpio.gz"

# --- manifest --------------------------------------------------------------
note "writing metadata"
sha256() { sha256sum "$1" | cut -d' ' -f1; }

KERNEL_VERSION=$(sed -n 's/^kernel_version=//p' "$BUILD/build-metadata.txt")
KBASE_RELEASE=$(sed -n 's/^kbase_release=//p'  "$BUILD/build-metadata.txt")
CONFIG_SHA=$(sed -n 's/^config_sha256=//p'        "$BUILD/build-metadata.txt")
VENDOR_SERIES=$(sed -n 's/^patch_series_sha256=//p' "$BUILD/build-metadata.txt")
RESEARCH_SERIES=$(sed -n 's/^research_patch_series_sha256=//p' "$BUILD/build-metadata.txt")
PAYLOAD_FP=$(sed -n 's/^payload_fingerprint=//p'  "$BUILD/build-metadata.txt")
BUILT_AT=$(sed -n 's/^built_at=//p'               "$BUILD/build-metadata.txt")
COMPILER=$(sed -n 's/^compiler=//p'               "$BUILD/build-metadata.txt")

QEMU_VER=$(qemu-system-x86_64 --version 2>/dev/null | head -1 || echo "unknown")
PIN_FILE="$REPO_ROOT/kernel/sources/kernel.pin"
PIN_RAW=$(grep -vE '^\s*(#|$)' "$PIN_FILE" 2>/dev/null | head -1 || echo "")

# Scope class is NOT cosmetic: a kcov/kasan/no-mali bundle is DISCOVERY-ONLY and
# must never be presented as an Arm-conforming validation kernel (F-9, DECISION-1).
case "$PROFILE" in
    baseline) SCOPE_CLASS="DISCOVERY-ONLY" ;;
    kcov)     SCOPE_CLASS="DISCOVERY-ONLY" ;;
    kasan)    SCOPE_CLASS="DISCOVERY-ONLY" ;;
    debug)    SCOPE_CLASS="DISCOVERY-ONLY" ;;
esac

cat > "$OUT/metadata/manifest.json" <<EOF
{
  "artifact_id": "kbase-${KBASE_RELEASE}-${KERNEL_VERSION}-${PROFILE}",
  "profile": "${PROFILE}",
  "kbase_release": "${KBASE_RELEASE}",
  "kernel_release": "${KERNEL_VERSION}",
  "kernel_pin": "${PIN_RAW}",
  "kernel_config_sha256": "${CONFIG_SHA}",
  "kernel_image_sha256": "$(sha256 "$OUT/kernel/bzImage")",
  "vmlinux_sha256": "$(sha256 "$OUT/kernel/vmlinux")",
  "patch_set": {
    "vendor_series_sha256": "${VENDOR_SERIES}",
    "research_series_sha256": "${RESEARCH_SERIES}",
    "payload_fingerprint": "${PAYLOAD_FP}"
  },
  "rootfs": {
    "file": "rootfs/rootfs-${PROFILE}.cpio.gz",
    "format": "cpio initramfs",
    "sha256": "$(sha256 "$OUT/rootfs/rootfs-${PROFILE}.cpio.gz")"
  },
  "modules": {
    "count": ${MODCOUNT},
    "kbase": "modules/${KMOD_REL}",
    "kbase_sha256": "$(sha256 "$OUT/modules/$KMOD_REL")"
  },
  "qemu_version": "${QEMU_VER}",
  "compiler": "${COMPILER}",
  "built_at": "${BUILT_AT}",
  "packaged_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "validation_status": "${VALIDATION_STATE}",
  "scope_class": "${SCOPE_CLASS}",
  "notes": [
    "Scope class is DISCOVERY-ONLY per DECISION-1: the x86_64 + MALI_NO_MALI",
    "harness is INVESTIGATION-ONLY and cannot produce Arm-conforming validation",
    "evidence. Clean boots here are not hardware-conformance results.",
    "validation_status is a claim about THIS bundle only. Raise it only by",
    "running the procedure in artifacts/README.md."
  ]
}
EOF
log "metadata/manifest.json"


# README is written BEFORE the sums: the previous order generated the sums
# first, leaving README.md -- the file that STATES validation_status and
# scope_class -- outside the integrity set (F-28). sha256sum -c must defend it.
write_bundle_readme
log "README.md"

# SHA256SUMS over everything except itself, so `sha256sum -c` works from inside.
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > metadata/SHA256SUMS )
log "metadata/SHA256SUMS ($(wc -l < "$OUT/metadata/SHA256SUMS") files)"


note "done"
du -sh "$OUT"
log "state: ${VALIDATION_STATE}   scope: ${SCOPE_CLASS}"
if [ "$VALIDATION_STATE" != PORTABLE_ARTIFACT_VERIFIED ]; then
    log "NOT yet portable — run the clean-location test in artifacts/README.md"
fi
