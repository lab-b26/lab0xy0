#!/usr/bin/env bash
#
# build.sh --profile <baseline|kasan|kcov|debug> [--jobs N] [--restage]
#
# ONE shared build entry point for all profiles. One Linux source tree with
# separate `make O=...` output directories, one Kbase payload staged once.
#
# Steps (each logged, nothing hidden):
#   1. stage the Kbase payload into the kernel tree  (see "STAGING" below)
#   2. kbuild-ify the staged directories             (Makefile/Kbuild precedence)
#   3. wire drivers/gpu/{Kconfig,Makefile}           (idempotent, tagged)
#   4. seed build/<profile>/.config: kernel defconfig + the profile fragment
#   5. VERIFY every CONFIG_* in the fragment actually took   <-- safety net
#   6. compile the kernel
#   7. build the Kbase module in-tree (CONFIG_MALI_MIDGARD=m)
#   8. emit build metadata for the manifest
#
# STAGING, and why it is not a plain copy
# ---------------------------------------
# The r54p0 payload root `driver/product/kernel/` mirrors the LINUX TREE ROOT:
# it contains `drivers/`, `include/` and `Documentation/`. So staging merges the
# payload root into the kernel source root, not into `drivers/gpu/arm/`.
#
# Kbase ships BOTH a `Makefile` and a `Kbuild` in every directory it owns.
# kbuild prefers `Makefile` over `Kbuild` when both exist, and the `Makefile`s
# here are the Android/out-of-tree ones (they expect KDIR and error otherwise).
# So the Android `Makefile` is set aside and `Kbuild` is copied over it. This is
# done ONLY inside the disposable fetched tree; the vendor archive under
# vendor/arm/ is never modified.
#
# To get a pristine tree again:
#   rm -rf kernel/sources/linux/<version> && kernel/scripts/fetch-kernel.sh
#
# Nothing is packaged here; packaging is a later step (see artifacts/README.md).
# Run on the BUILD host. See ../BUILD-HOST.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KERNEL_SRC_ROOT="$REPO_ROOT/kernel/sources/linux"
KBASE_TREE="$REPO_ROOT/work/kbase-patched/driver/product/kernel"
BUILD_ROOT="$REPO_ROOT/build"
LOG_DIR="$BUILD_ROOT/logs"

# Marker written next to every line this script injects. It MUST be a comment
# that is valid in BOTH files it lands in: kconfig accepts `#` (and NOT the C
# comment `/* ... */`, which is a hard kconfig syntax error) and GNU make also
# accepts `#`. A C comment here makes `make defconfig` fail outright.
# See analysis/findings.md F-14.
WIRE_TAG="# Kbase integration added by kernel/scripts/build.sh -- do not edit"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

PROFILE=""; JOBS=""; RESTAGE=0
usage() {
    cat <<'EOF'
Usage: build.sh --profile <baseline|kasan|kcov|debug> [--jobs N] [--restage]

Options:
  --profile <name>   baseline | kasan | kcov | debug   (required)
  --jobs N           parallel make jobs (default: nproc)
  --restage          re-stage Kbase into the kernel tree even if already staged
  -h, --help         show this help

Scope reminder (do not duplicate policy; see research/program-scope.md):
  baseline  control/reproduction          -> INVESTIGATION-ONLY in x86 (DECISION-1)
  kasan     memory-safety + validation    -> may conform on real HW
  kcov      coverage-guided discovery     -> DISCOVERY-ONLY
  debug     crash/root-cause analysis     -> DISCOVERY-ONLY

This compiles; it does not boot, package, or mark any artifact portable.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)   [ $# -ge 2 ] || { echo "error: --profile needs a value" >&2; exit 2; }; PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#*}"; shift ;;
        --jobs)      [ $# -ge 2 ] || { echo "error: --jobs needs a value" >&2; exit 2; };    JOBS="$2";   shift 2 ;;
        --jobs=*)    JOBS="${1#*}"; shift ;;
        --restage)   RESTAGE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

case "$PROFILE" in
    baseline|kasan|kcov|debug) ;;
    "") echo "error: --profile is required" >&2; usage; exit 2 ;;
    *)  echo "error: unknown profile '$PROFILE'" >&2; usage; exit 2 ;;
esac
[ -n "$JOBS" ] || JOBS=$(nproc)

# --- locate inputs ---------------------------------------------------------
PIN="$REPO_ROOT/kernel/sources/kernel.pin"
[ -f "$PIN" ] || die "kernel.pin missing."
VER=$(grep -E '^version=' "$PIN" | cut -d= -f2-)
case "$VER" in ""|UNSET) die "kernel.pin version is UNSET — resolve a pin first:
       kernel/scripts/resolve-kernel-pin.sh   (or fill kernel.pin by hand)" ;; esac

KERNEL_SRC="$KERNEL_SRC_ROOT/$VER"
[ -d "$KERNEL_SRC" ] || die "kernel source not found: $KERNEL_SRC
       Run kernel/scripts/fetch-kernel.sh first."
[ -d "$KBASE_TREE" ] || die "patched Kbase tree not found: $KBASE_TREE
       Run kernel/scripts/apply-patches.sh first."

OUT="$BUILD_ROOT/$PROFILE"
LOG="$LOG_DIR/$PROFILE.log"
mkdir -p "$OUT" "$LOG_DIR"

echo "=============================================================="
echo " build.sh --profile $PROFILE   (jobs=$JOBS)"
echo "=============================================================="
echo "kernel source : $KERNEL_SRC"
echo "Kbase payload : $KBASE_TREE"
echo "output dir    : $OUT"
echo "log           : $LOG"
echo "scope         : see kernel/configs/$PROFILE.config header"
echo

: > "$LOG"
log() { printf '      %s\n' "$*" | tee -a "$LOG"; }
note() { printf '\n=== %s ===\n' "$*" | tee -a "$LOG"; }

STAGE_MARK="$KERNEL_SRC/.kbase-staged"

# Classify a Kconfig symbol against the pinned tree, so step 5 can say WHY a
# fragment line did not take effect instead of always blaming a missing Kconfig
# line. F-24: `CONFIG_DEBUG_INFO=y` was reported as "symbol not in the Kconfig",
# which sent the reader hunting for a Kconfig line that in fact EXISTS at
# lib/Kconfig.debug:227. It is a prompt-less derived `bool` that the
# "Debug information" choice `select`s, so a config fragment can never set it.
# The three outcomes are genuinely different problems with different fixes:
#
#   absent     the kernel does not have this symbol at all      -> wrong kernel
#   invisible  it exists but has no prompt, so it is derived and
#              not directly settable                           -> set the
#              `select`ing symbol (usually a `choice` member) instead
#   settable   it is a normal user-settable symbol but did not
#              take effect                                    -> a `depends on`
#              clause is unsatisfied, or a `choice` picked a sibling
kconfig_symbol_kind() {
    awk -v sym="$1" '
        BEGIN { result = "absent"; inf = 0 }
        $0 == "config " sym || $0 == "menuconfig " sym { inf = 1; result = "invisible"; next }
        inf && (/^(menu)?config / || /^choice$/ || /^endchoice$/ || /^endmenu$/) { inf = 0 }
        inf && /^[[:space:]]*(bool|tristate|int|hex|string)[[:space:]]+"/ { result = "settable"; exit }
        END { print result }
    ' $(find "$KERNEL_SRC" -name 'Kconfig*' -type f) 2>/dev/null
}

# One-line, actionable explanation of a fragment symbol that did not take.
explain_missing() {
    _sym="$1"; _want="$2"
    case "$(kconfig_symbol_kind "$_sym")" in
        invisible)
            printf 'present but NOT user-settable (no prompt): it is a derived\n' >&2
            printf '              symbol, almost always `select`ed by a choice member.\n' >&2
            printf '              Set the member of that choice instead of %s.\n' "$_sym" >&2
            printf '              (grep -rn "^config %s" for the stanza.)\n' "$_sym" >&2
            ;;
        settable)
            printf 'user-settable but did NOT take effect: a `depends on` clause is\n' >&2
            printf '              unsatisfied, or a `choice` selected a different member.\n' >&2
            ;;
        *)
            printf 'not present in the pinned kernel Kconfig at all -> wrong kernel version?\n' >&2
            ;;
    esac
}

# --- 1. stage the Kbase payload -------------------------------------------
note "1/8  staging the Kbase payload into the kernel tree"

if [ -f "$STAGE_MARK" ] && [ "$RESTAGE" -eq 0 ]; then
    log "already staged (marker: $(basename "$STAGE_MARK")); use --restage to redo"
else
    [ -f "$KERNEL_SRC/drivers/gpu/arm/midgard/Kbuild" ] && \
        die "a Kbase tree is already present at $KERNEL_SRC/drivers/gpu/arm but the
       staging marker is missing. The tree is in an unknown state. Reset it with:
         rm -rf '$KERNEL_SRC' && kernel/scripts/fetch-kernel.sh"
    log "merging payload root into kernel tree root"
    cp -a "$KBASE_TREE/." "$KERNEL_SRC/"
    [ -d "$KERNEL_SRC/drivers/gpu/arm/midgard" ] \
        || die "staging did not produce drivers/gpu/arm/midgard — payload layout changed?"
    # Fingerprint the payload so a changed Kbase is detected on a later build.
    PAYLOAD_FP=$(find "$KBASE_TREE" -type f -printf '%P\n' | sort \
                 | while read -r f; do sha256sum "$KBASE_TREE/$f"; done | sha256sum | awk '{print $1}')
    printf 'payload=%s\nstaged_at=%s\n' "$PAYLOAD_FP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$STAGE_MARK"
    log "staged (payload fingerprint $PAYLOAD_FP)"
fi

# --- 2. kbuild-ify: Makefile shadows Kbuild -------------------------------
note "2/8  kbuild-ify (kbuild prefers Makefile over Kbuild)"
for d in drivers/gpu/arm drivers/gpu/arm/midgard; do
    dir="$KERNEL_SRC/$d"
    [ -d "$dir" ] || die "expected staged directory missing: $dir"
    if [ -f "$dir/Kbuild" ] && [ -f "$dir/Makefile" ] \
       && [ ! -f "$dir/Makefile.android-orig" ]; then
        mv "$dir/Makefile" "$dir/Makefile.android-orig"
        cp -a "$dir/Kbuild" "$dir/Makefile"
        log "$d/Makefile: Android Makefile set aside, Kbuild installed in its place"
    elif [ -f "$dir/Makefile.android-orig" ]; then
        log "$d: already kbuild-ified"
    elif [ -f "$dir/Makefile" ] && [ ! -f "$dir/Kbuild" ]; then
        log "$d: only a Makefile present, left as-is"
    else
        log "$d: nothing to do"
    fi
done

# --- 3. wire the kernel side (idempotent, tagged) --------------------------
note "3/8  wiring drivers/gpu (idempotent)"
wire_kconfig() {   # $1 = file to append to, $2 = line to ensure
    local f="$KERNEL_SRC/$1" line="$2"
    if grep -qxF "$line" "$f"; then
        log "$1: already wired"
    else
        printf '\n%s\n%s\n' "$WIRE_TAG" "$line" >> "$f"
        log "$1: + $line"
    fi
}
[ -f "$KERNEL_SRC/drivers/gpu/Kconfig" ]  || die "drivers/gpu/Kconfig not found in the kernel tree"
[ -f "$KERNEL_SRC/drivers/gpu/Makefile" ] || die "drivers/gpu/Makefile not found in the kernel tree"

wire_kconfig drivers/gpu/Kconfig  'source "drivers/gpu/arm/Kconfig"'
wire_kconfig drivers/gpu/Makefile 'obj-$(CONFIG_MALI_MIDGARD) += arm/'

# --- 4. seed the config ---------------------------------------------------
note "4/8  seeding $OUT/.config (kernel defconfig + profile fragment)"
FRAG="$REPO_ROOT/kernel/configs/$PROFILE.config"
[ -f "$FRAG" ] || die "config fragment missing: $FRAG"

if [ -f "$OUT/.config" ]; then
    log "reusing existing $OUT/.config (delete $OUT to reconfigure)"
else
    ( cd "$KERNEL_SRC" && make O="$OUT" defconfig ) >>"$LOG" 2>&1 \
        || die "defconfig failed — see $LOG"
    # The fragment is already in .config syntax. Two classes of line are
    # SYMBOL-bearing and must both survive the merge:
    #
    #     CONFIG_X=value                 the symbol set
    #     # CONFIG_X is not set          the ONLY kconfig encoding for "off"
    #
    # F-20: an earlier merge used `grep -v '^#'`, which silently deleted every
    # `is not set` line. A fragment could then not express "must be off" at all,
    # and any Kconfig `choice` fell back to its kconfig `default` — on the kasan
    # profile that turned `# CONFIG_MALI_REAL_HW is not set` into
    # `CONFIG_MALI_REAL_HW=y`. Step 5/8 caught it, so it was not silent
    # end-to-end, but the fragment was un-honourable. Keep both forms.
    #
    # Prose comments and blank lines are dropped: they are documentation, and
    # `# CONFIG_X=y  <- note` is not valid kconfig anyway (trailing text).
    # Unknown symbols still reach step 5, which fails the build.
    sed -n -e '/^CONFIG_[A-Za-z0-9_]*=/p' \
           -e '/^# CONFIG_[A-Za-z0-9_]* is not set$/p' \
           "$FRAG" > "$OUT/.fragment" || die "could not read fragment $FRAG"

    # Drop any pre-existing .config line for a symbol the fragment mentions, so
    # the fragment is the single authority and no duplicate line can win by
    # position (kconfig honours the first occurrence; relying on that is a trap).
    frag_syms=$(sed -n -e 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p' \
                        -e 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p' \
                        "$OUT/.fragment" | sort -u)
    if [ -n "$frag_syms" ]; then
        sympat=$(printf '%s\n' "$frag_syms" | paste -sd'|')
        sed -i -E "/^($sympat)(=| |$)|^# ($sympat) is not set$/d" "$OUT/.config"
    fi
    cat "$OUT/.fragment" >> "$OUT/.config"

    ( cd "$KERNEL_SRC" && make O="$OUT" olddefconfig ) >>"$LOG" 2>&1 \
        || die "olddefconfig failed after merging the fragment — see $LOG"
    log "merged fragment ($(grep -c . "$OUT/.fragment") symbol lines, 'is not set' preserved)"
fi

# --- 5. VERIFY the fragment actually took ---------------------------------
note "5/8  verifying every fragment symbol took effect"

checked=0; failed=0
while IFS= read -r line; do
    case "$line" in
        '# CONFIG_'*' is not set')
            sym=$(printf '%s' "$line" | sed -n 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p')
            [ -n "$sym" ] || continue
            checked=$((checked+1))
            if grep -q "^${sym}=" "$OUT/.config"; then
                printf '      [ MISMATCH ] %-44s expected unset, found: %s\n' \
                    "$sym" "$(grep -m1 "^${sym}=" "$OUT/.config")"
                failed=$((failed+1))
            else
                printf '      [ ok      ] %-44s unset\n' "$sym"
            fi
            ;;
        'CONFIG_'*'='*)
            sym=$(printf '%s' "$line" | cut -d= -f1)
            want=$(printf '%s' "$line" | cut -d= -f2-)
            checked=$((checked+1))
            got=$(grep -m1 "^${sym}=" "$OUT/.config" | cut -d= -f2- || true)
            if [ "$want" = "n" ]; then
                # kconfig NEVER writes "CONFIG_X=n": an n-valued symbol is
                # encoded as the line "# CONFIG_X is not set". Looking only for
                # "^CONFIG_X=" therefore reports a false MISSING for every
                # fragment line that disables a symbol (e.g. CONFIG_MALI_DEBUG=n).
                # Both spellings mean n; accept either, and only call it MISSING
                # when the symbol is absent from the Kconfig altogether.
                # See analysis/findings.md F-15.
                if [ -n "$got" ]; then
                    printf '      [ MISMATCH ] %-44s wanted n, got %s\n' "$sym" "$got"
                    failed=$((failed+1))
                elif grep -qx "# ${sym} is not set" "$OUT/.config"; then
                    printf '      [ ok      ] %-44s = n\n' "$sym"
                else
                    printf '      [ MISSING  ] %-44s wanted n — %s\n' "$sym" \
                        "$(kconfig_symbol_kind "$sym")"
                    failed=$((failed+1))
                fi
            elif [ -z "$got" ]; then
                printf '      [ MISSING  ] %-44s wanted %s — %s\n' "$sym" "$want" \
                    "$(kconfig_symbol_kind "$sym")"
                explain_missing "$sym" "$want"
                failed=$((failed+1))
            elif [ "$got" != "$want" ]; then
                printf '      [ MISMATCH ] %-44s wanted %s, got %s\n' "$sym" "$want" "$got"
                failed=$((failed+1))
            else
                # F-26: a prompt-less symbol cannot be set by this fragment at
                # all. It can still be y because something else `select`s it, and
                # a plain `[ ok ]` would credit the fragment for a value it did
                # not produce. The result is right; the cause is not this line.
                if [ "$(kconfig_symbol_kind "$sym")" = "invisible" ]; then
                    printf '      [ ok*     ] %-44s = %s\n' "$sym" "$got"
                    printf '%s\n' "      *INERT: $sym has no prompt, so this fragment did not set it."
                    printf '%s\n' "      It is y because another symbol selects it. The requirement is"
                    printf '%s\n' "      met, but not by this line. See analysis/findings.md F-26."
                else
                    printf '      [ ok      ] %-44s = %s\n' "$sym" "$got"
                fi
            fi
            ;;
    esac
done < <(grep -v '^[[:space:]]*$' "$FRAG")

log "checked $checked fragment symbols, $failed problem(s)"
if [ "$checked" -eq 0 ]; then
    die "the fragment contained no CONFIG_* symbols — refusing to continue."
fi
if [ "$failed" -ne 0 ]; then
    die "$failed fragment symbol(s) did not take effect. The build is NOT
       trustworthy, so it is stopped here rather than silently producing a
       kernel without Kbase.
       Common causes:
         - Kbase was not staged into the kernel tree (check step 1/2 above)
         - the symbol is a derived, prompt-less symbol: set the `select`ing
           symbol (usually a choice member) instead -- see F-24
         - a Kconfig 'depends on' clause is unsatisfied (e.g. MALI_EXPERT must be y
           before MALI_NO_MALI / LARGE_PAGE_SUPPORT are selectable)
         - a `choice` selected a different member than the fragment names
       See analysis/findings.md."
fi
CONFIG_SHA=$(sha256sum "$OUT/.config" | awk '{print $1}')
log "effective .config sha256: $CONFIG_SHA"

# --- 6. build the kernel --------------------------------------------------
note "6/8  building the kernel (long step; log: $LOG)"
( cd "$KERNEL_SRC" && make O="$OUT" -j"$JOBS" ) >>"$LOG" 2>&1 \
    || die "kernel build failed — see $LOG and analysis/findings.md for the failure categories."
log "kernel build finished"

# --- 7. build the Kbase module -------------------------------------------
note "7/8  building modules (Kbase as CONFIG_MALI_MIDGARD=m)"
( cd "$KERNEL_SRC" && make O="$OUT" -j"$JOBS" modules ) >>"$LOG" 2>&1 \
    || die "module build failed — see $LOG.
       First check whether the kbase-ify step and the drivers/gpu wiring took
       effect; analysis/findings.md records both requirements."
log "module build finished"

KO_COUNT=$(find "$OUT" -name '*.ko' | wc -l | tr -d ' ')
log "modules produced: $KO_COUNT"

# --- 8. build metadata for the manifest -----------------------------------
note "8/8  recording build metadata"
{
    echo "profile=$PROFILE"
    echo "kernel_version=$VER"
    echo "kbase_release=r54p0-01eac0"
    echo "config_sha256=$CONFIG_SHA"
    echo "fragment_sha256=$(sha256sum "$FRAG" | awk '{print $1}')"
    echo "patch_series_sha256=$(cat "$REPO_ROOT/work/kbase-patched/.patch-series.sha256" 2>/dev/null || echo unknown)"
    echo "research_patch_series_sha256=$(cat "$REPO_ROOT/work/kbase-patched/.research-patch-series.sha256" 2>/dev/null || echo none)"
    echo "payload_fingerprint=$(awk -F= '/^payload=/{print $2}' "$STAGE_MARK" 2>/dev/null || echo unknown)"
    echo "kbuildified=drivers/gpu/arm,drivers/gpu/arm/midgard"
    echo "modules_count=$KO_COUNT"
    echo "compiler=$(gcc --version 2>/dev/null | head -1)"
    echo "build_host=$(uname -srm)"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "scope=INVESTIGATION-ONLY in this x86 environment (DECISION-1)"
} > "$OUT/build-metadata.txt"
cat "$OUT/build-metadata.txt" | tee -a "$LOG"

echo
echo "done for $PROFILE."
echo "kernel image : $OUT/arch/x86/boot/bzImage  (if present)"
echo "modules      : $KO_COUNT .ko"
echo "config       : $OUT/.config"
echo "metadata     : $OUT/build-metadata.txt"
echo
echo "This is a COMPILE result only. Booting, loading Kbase, and packaging are"
echo "separate steps; an artifact is not portable until it passes the clean-location"
echo "test in artifacts/README.md. Update research/state.md only after verification."
exit 0