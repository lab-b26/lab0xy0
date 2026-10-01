#!/usr/bin/env bash
#
# check-all.sh -- verify every claim this repository makes.
#
# Usage:
#   check/check-all.sh                 # tiers A + B (default: no QEMU needed)
#   check/check-all.sh --tier A        # static only; seconds; no build, no QEMU
#   check/check-all.sh --tier B        # artifact integrity
#   check/check-all.sh --tier C        # boots every packaged artifact in QEMU
#   check/check-all.sh --tier D        # state-ledger consistency
#   check/check-all.sh --all           # A + B + C + D
#   check/check-all.sh --list          # show the checks and exit
#
# Exit status: 0 if every selected check passed, 1 otherwise.
#
# WHY THIS EXISTS
#
#   Every serious defect found in this project so far had the same shape: a
#   tooling layer accepted a wrong input and produced a plausible result.
#
#     F-20  build.sh's fragment merge deleted every "is not set" line
#     F-21  kasan.config named no choice member, so it meant the opposite
#     F-24  debug.config asked for CONFIG_DEBUG_INFO, which cannot be set
#     F-25  a fragment header claimed a build that had not happened
#     kcov  a coverage tool reported 656023 "covered PCs" that were the
#           popcount of a PC *list*; the real figure was 2882
#
#   In each case the tool did not crash. It reported success, or a large
#   impressive number, or a plausible message. That is the dangerous shape:
#   a wrong answer that looks right survives review, while a crash does not.
#
#   So this script does not test that the code runs. It tests that the CLAIMS
#   are still true. Where a claim can be checked mechanically, it is checked
#   mechanically, and the check is in version control so the next person does
#   not have to remember it.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
#   It does not build anything (tier A/B/D need no toolchain) and it does not
#   reach the internet. A check that needs a 15-minute kernel build is not a
#   check, it is a build. Those live in kernel/BUILD-PLAN.md.
#
#   It also does not decide whether a claim is *true of real hardware*. Per
#   DECISION-1 this whole harness is DISCOVERY-ONLY. A green run here means
#   "the simulator claims are internally consistent", never "the driver is
#   correct on an Arm GPU".
#
# SCOPE CLASS: DISCOVERY-ONLY. See research/program-scope.md and DECISION-1.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TIERS="AB"
RUN_C=0
LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --tier)  TIERS="$(printf '%s' "$2" | tr -d '[:lower:]')"; shift 2 ;;
        --all)   TIERS="ABCD"; RUN_C=1; shift ;;
        --list)  LIST_ONLY=1; shift ;;
        -h|--help)
            sed -n '3,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- reporting --

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLD=$'\033[1m';  C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLD=''; C_DIM=''; C_OFF=''
fi

PASS=0; FAIL=0; SKIP=0
declare -a FAILED_NAMES=()

if [ -z "${NO_COLOR:-}" ]; then printf '%s' "$C_BLD"; fi
printf 'check-all -- verifying claims (tiers: %s)\n' "$TIERS"
printf 'repo: %s\n' "$REPO_ROOT"
if [ -z "${NO_COLOR:-}" ]; then printf '%s' "$C_OFF"; fi
printf 'scope: DISCOVERY-ONLY (DECISION-1) -- a green run is not a conformance claim\n\n'

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %-46s %s\n' "$C_GRN" "$C_OFF" "$1" "${2:-}"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1")
         printf '  %sFAIL%s  %-46s %s\n' "$C_RED" "$C_OFF" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %-46s %s\n' "$C_YLW" "$C_OFF" "$1" "${2:-}"; }
head_() { if [ -z "${NO_COLOR:-}" ]; then printf '%s' "$C_BLD"; fi
          printf '%s\n' "$1"
          if [ -z "${NO_COLOR:-}" ]; then printf '%s' "$C_OFF"; fi; }

# A check gets: name, then a function that returns 0 (pass) or 1 (fail).
# The optional 2nd arg is detail printed only on failure.
check() {
    _name="$1"; _fn="$2"; _detail="${3:-}"
    if "$_fn"; then ok "$_name"; else bad "$_name" "$_detail"; fi
}

has() { case "$TIERS" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

if [ "$LIST_ONLY" -eq 1 ]; then
    cat <<'EOF'
Tier A -- static, no build, no QEMU (seconds)
  A1  all shell scripts parse
  A2  config fragments name only user-settable Kconfig symbols   <- catches F-24
  A3  scope guard: non-conforming options confined to debug.config
  A4  kernel pin agrees with the extracted tree
  A5  vendor patches byte-identical and still apply
  A6  findings are numbered contiguously with no gaps or duplicates
  A7  documented counts match the filesystem                      <- catches F-25
  A8  every cited boot log exists and is a real PASS              <- catches overclaim
  A9  no build tree, source tree, or artifact bundle is committed
  A10 no orphan binary is committed

Tier B -- artifact integrity (needs artifacts/)
  B1  every bundle matches its own SHA256SUMS
  B2  every bundle's manifest is well-formed and in the state ladder
  B3  a PORTABLE_ARTIFACT_VERIFIED claim is backed by a clean-location log
  B4  no packaged file references an absolute build path
  B5  every bundle declares scope class DISCOVERY-ONLY

Tier C -- runtime (needs QEMU; boots each packaged artifact)
  C1  each packaged artifact passes all five boot assertions
  C2  a booted log is never cited without its PROBE summary

Tier D -- state ledger
  D1  state.md current state matches the last transition row
  D2  no document claims a state above the current one
EOF
    exit 0
fi

KERNEL_VER="$(sed -n 's/^version=//p' kernel/sources/kernel.pin 2>/dev/null | head -1)"
KERNEL_SRC="kernel/sources/linux/$KERNEL_VER"
[ -d "$KERNEL_SRC" ] || KERNEL_SRC=""

# ============================================================ TIER A: static ==

if has A; then
head_ "TIER A -- static checks (no build, no QEMU)"

a1_scripts_parse() {
    _bad=""
    for s in kernel/scripts/*.sh qemu/scripts/*.sh qemu/rootfs/*.sh; do
        [ -f "$s" ] || continue
        bash -n "$s" 2>/dev/null || _bad="$_bad $s"
    done
    [ -z "$_bad" ] || { printf 'syntax errors:%s\n' "$_bad" >&2; return 1; }
    return 0
}
check "A1  all shell scripts parse" a1_scripts_parse

# The F-24 class: a fragment line naming a symbol that exists but has no
# prompt can never take effect. build.sh step 5 catches this at build time,
# but only after paying for defconfig; this catches it in milliseconds.
# True if the fragment admits, in the comment block immediately above the line
# that sets $2, that the symbol is inert.
#
# The note must name the symbol as well as say INERT. Matching on the word
# alone is too coarse: in debug.config the DMA_SHARED_BUFFER note sits directly
# above four further symbols (PM_DEVFREQ, DEVFREQ_THERMAL, DEVFREQ_GOV_...,
# FW_LOADER), so a window-only match would silently mark all of them "declared
# inert" too. Requiring the name is what keeps the annotation attached to the
# one line it is about.
fragment_declares_inert() {
    _f="$1"; _s="$2"
    _ln=$(grep -n "^\(${_s}=\|${_s}=n\)" "$_f" | head -1 | cut -d: -f1)
    [ -n "$_ln" ] || return 1
    [ "$_ln" -gt 1 ] || return 1
    _from=$((_ln>6 ? _ln-6 : 1))
    _win=$(sed -n "${_from},$((_ln-1))p" "$_f")
    printf '%s' "$_win" | grep -q 'INERT' || return 1
    printf '%s' "$_win" | grep -q "${_s#CONFIG_}"
}

a2_fragment_symbols_settable() {
    _bad=""; _warn=""
    for frag in kernel/configs/*.config; do
        [ -f "$frag" ] || continue
        _prof=$(basename "$frag" .config)
        _cfg="build/$_prof/.config"
        _syms=$(sed -n -e 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p' \
                       -e 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p' "$frag" \
                 | sort -u)
        for sym in $_syms; do
            _short="${sym#CONFIG_}"
            if [ -z "$KERNEL_SRC" ]; then return 0; fi
            # Scan EVERY stanza: a symbol may be declared more than once, and one
            # prompt-less declaration must not mask a prompt-bearing one.
            _kind=$(awk -v s="$_short" '
                BEGIN { seen = 0; settable = 0 }
                $0 == "config " s || $0 == "menuconfig " s { seen = 1; inf = 1; next }
                inf && /^[[:space:]]*(bool|tristate|int|hex|string)[[:space:]]+"/ { settable = 1 }
                inf && (/^(menu)?config / || /^choice$/ || /^endchoice$/ || /^endmenu$/) { inf = 0 }
                END {
                    if (!seen)         print "absent"
                    else if (settable) print "settable"
                    else               print "invisible"
                }' $(find "$KERNEL_SRC" -name 'Kconfig*' -type f) 2>/dev/null)

            case "$_kind" in
                settable) continue ;;
                absent)
                    # The kernel has no such symbol: the fragment is wrong.
                    _bad="$_bad\n    $frag: $sym does not exist in $KERNEL_VER"
                    ;;
                invisible)
                    # A prompt-less symbol can NEVER be set by a fragment line, so
                    # the line is inert. This must be judged STRUCTURALLY, not by
                    # value: kconfig writes derived symbols into .config when they
                    # are y, so `CONFIG_DEBUG_INFO=y` appears in .config purely
                    # because some other line selects it. A value check therefore
                    # cannot tell "the fragment set this" from "a sibling did",
                    # and would pass the very defect it exists to catch (F-24).
                    #
                    # So an inert line is acceptable only if the fragment SAYS it
                    # is inert. Undeclared -> fail. Declared -> the requirement is
                    # recorded honestly and A11 confirms the claim is true.
                    if fragment_declares_inert "$frag" "$sym"; then
                        continue
                    fi
                    _bad="$_bad\n    $frag: $sym has no prompt, so the line is inert and does not say so"
                    ;;
            esac
        done
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A2  fragment symbols actually take effect" a2_fragment_symbols_settable \
      "a fragment asks for a symbol it cannot actually set, without saying so"

# Program policy: MALI_DEBUG=n is MANDATORY (program-scope 8.3). Exactly one
# profile may violate it, and only if it declares itself non-conforming.
a3_scope_guard() {
    _bad=""
    for frag in kernel/configs/*.config; do
        [ -f "$frag" ] || continue
        _p=$(basename "$frag" .config)
        if grep -qE '^CONFIG_MALI_DEBUG=y' "$frag"; then
            if [ "$_p" != "debug" ]; then
                _bad="$_bad\n    $_p sets MALI_DEBUG=y; only debug.config may (8.3)"
            fi
            if ! grep -qi 'NON-CONFORMING\|DISCOVERY-ONLY' "$frag"; then
                _bad="$_bad\n    $_p sets MALI_DEBUG=y but does not declare itself non-conforming"
            fi
        fi
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A3  MALI_DEBUG=y confined to debug.config" a3_scope_guard \
      "a non-conforming option escaped its profile, or is undeclared"

a4_pin_matches_tree() {
    [ -n "$KERNEL_VER" ] || { printf 'kernel.pin has no KERNEL_VERSION\n' >&2; return 1; }
    [ -d "$KERNEL_SRC" ] || return 0   # tree not fetched; nothing to contradict
    _v=$(sed -n 's/^VERSION *= *//p' "$KERNEL_SRC/Makefile" | head -1)
    _p=$(sed -n 's/^PATCHLEVEL *= *//p' "$KERNEL_SRC/Makefile" | head -1)
    _s=$(sed -n 's/^SUBLEVEL *= *//p' "$KERNEL_SRC/Makefile" | head -1)
    _actual="$_v.$_p.$_s"
    [ "$_actual" = "$KERNEL_VER" ] && return 0
    printf 'pin says %s, tree is %s\n' "$KERNEL_VER" "$_actual" >&2
    return 1
}
check "A4  kernel pin matches extracted tree" a4_pin_matches_tree

a5_vendor_patches_intact() {
    _d=patches/virtual-device
    [ -d "$_d" ] || { printf 'no %s directory\n' "$_d" >&2; return 1; }
    _n=$(find "$_d" -maxdepth 1 -name '*.patch' | wc -l)
    [ "$_n" -gt 0 ] || { printf 'no vendor patches found\n' >&2; return 1; }
    # The recorded checksums are the authority. Vendor patches must stay
    # byte-identical to what Arm shipped; a needed change is a research patch,
    # never an edit here (see kernel/BUILD-PLAN.md, program-scope 8.3).
    if [ -f "$_d/SHA256SUMS" ]; then
        if ( cd "$_d" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
            return 0
        fi
        printf 'vendor patch bytes differ from SHA256SUMS:\n' >&2
        ( cd "$_d" && sha256sum -c SHA256SUMS 2>&1 | grep -v ': OK$' >&2 ) || true
        return 1
    fi
    printf 'no SHA256SUMS in %s\n' "$_d" >&2
    return 1
}
check "A5  vendor patches byte-identical" a5_vendor_patches_intact \
      "a vendor patch was edited; restore it and record a finding instead"

a6_findings_contiguous() {
    _f=analysis/findings.md
    [ -f "$_f" ] || { printf 'no %s\n' "$_f" >&2; return 1; }
    _nums=$(grep -oE '^## F-[0-9]+' "$_f" | sed 's/## F-//' | sort -n -u)
    [ -n "$_nums" ] || { printf 'no findings found\n' >&2; return 1; }
    _expected=1; _bad=""
    for n in $_nums; do
        if [ "$n" -ne "$_expected" ]; then
            _bad="$_bad\n    expected F-$_expected, found F-$n"
        fi
        _expected=$((_expected+1))
    done
    # duplicates (same number twice in the body) are also a defect
    _dups=$(grep -oE '^## F-[0-9]+' "$_f" | sort | uniq -d)
    [ -z "$_dups" ] || _bad="$_bad\n    duplicate headings: $_dups"
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A6  findings numbered contiguously" a6_findings_contiguous

# The F-25 class: a document states a count or a state; check the filesystem.
a7_docs_match_reality() {
    _bad=""
    # artifacts produced: N  in artifacts/README.md
    if [ -f artifacts/README.md ]; then
        _claimed=$(sed -n 's/^artifacts produced:[[:space:]]*\([0-9]*\).*/\1/p' artifacts/README.md | head -1)
        _actual=$(find artifacts -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [ -n "$_claimed" ] && [ "$_claimed" -ne "$_actual" ]; then
            _bad="$_bad\n    artifacts/README.md says $_claimed artifacts, $_actual exist"
        fi
    fi
    # Per-profile bundle status in the table must match the filesystem: a
    # profile documented as "not packaged" must have no artifacts/<p> dir, and
    # a profile that HAS a bundle must not be documented as unpackaged.
    if [ -f artifacts/README.md ]; then
        for prof in baseline kasan kcov debug; do
            _row=$(grep -E "^\| \`$prof\` \|" artifacts/README.md | head -1)
            [ -n "$_row" ] || continue
            _has=no; [ -d "artifacts/$prof" ] && _has=yes
            if [ "$_has" = yes ] && printf '%s' "$_row" | grep -qi 'not packaged'; then
                _bad="$_bad\n    $prof has artifacts/$prof but the table says 'not packaged'"
            fi
            if [ "$_has" = no ] && printf '%s' "$_row" | grep -qiE 'PORTABLE_ARTIFACT_VERIFIED|TARGET_VERIFIED'; then
                _bad="$_bad\n    $prof table claims a validation state but no bundle exists"
            fi
        done
    fi
    # Fragment headers state what has happened to a profile. Those claims must be
    # backed by the filesystem -- this is the F-25 check. While fixing F-24 I
    # rewrote one header from "PROVISIONAL - never fed to a build" to
    # "BUILT + BOOTED" for a profile that had not been built. Headers are where
    # that temptation lives: a stale header is visibly wrong, and the quickest
    # way to make it look maintained is to write the result you EXPECT.
    for frag in kernel/configs/*.config; do
        [ -f "$frag" ] || continue
        _prof=$(basename "$frag" .config)
        _hdr=$(sed -n 's/^# *Validation: *//p' "$frag" | head -1)
        [ -n "$_hdr" ] || continue
        # Strip the negations FIRST, or a negative claim reads as a positive one
        # and the check fails every honest header. Handles "NOT YET BUILT",
        # "NOT BUILT", "never", "PROVISIONAL", "UNKNOWN".
        _pos=$(printf '%s' "$_hdr" \
               | sed -E -e 's/not +(yet +)?built//Ig' -e 's/never //Ig' \
                     -e 's/^ *PROVISIONAL//Ig' -e 's/UNKNOWN//Ig')
        case "$_pos" in
            *BUILT*)
                # "BUILT" may be backed by the build tree OR, when the tree has
                # been pruned to reclaim disk (kasan was), by a tracked boot log.
                # A full-pass boot log can only exist if the kernel was built and
                # ran, so it is durable evidence; a 1 GB build/ tree is not. What
                # is NOT acceptable is claiming BUILT with neither.
                if [ -f "build/$_prof/.config" ]; then
                    :
                elif [ "$(grep -lE 'PROBE summary[[:space:]]+passed=0x1ff[[:space:]]+failed=0x000' \
                          research/boot-logs/*-"$_prof"-BOOT.log 2>/dev/null | wc -l)" -gt 0 ]; then
                    :
                else
                    _bad="$_bad\n    $_prof header claims BUILT, but there is neither build/$_prof/.config nor a full-pass $_prof boot log"
                fi
                ;;
        esac
        case "$_pos" in
            *BOOTED*)
                _real=$(grep -lE 'PROBE summary[[:space:]]+passed=0x1ff[[:space:]]+failed=0x000' \
                        research/boot-logs/*-"$_prof"-BOOT.log 2>/dev/null | wc -l)
                [ "$_real" -gt 0 ] || \
                    _bad="$_bad\n    $_prof header claims BOOTED but no full-pass $_prof boot log exists"
                ;;
        esac
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A7  documented status matches filesystem" a7_docs_match_reality \
      "a count, per-profile status, or header claim disagrees with disk (F-25)"

a8_cited_logs_real() {
    _bad=""
    # (1) Every log named in the boot-log index must exist.
    if [ -f research/boot-logs/README.md ]; then
        for t in $(grep -oE '`[0-9]{8}T[0-9]{6}Z-[a-z]+-BOOT\.log`' research/boot-logs/README.md | tr -d '`'); do
            [ -f "research/boot-logs/$t" ] || _bad="$_bad\n    cited log missing: $t"
        done
    fi
    # (2) A log that reports the probe ran must report a FULL pass. A log with
    #     `probe-rc 0` but a partial `failed=` would be an overclaim if cited as
    #     a pass, so this fires only when the summary contradicts the rc.
    for log in research/boot-logs/*-BOOT.log; do
        [ -f "$log" ] || continue
        grep -q 'BOOTMARK probe-rc 0' "$log" || continue
        if ! grep -qE 'PROBE summary[[:space:]]+passed=0x1ff[[:space:]]+failed=0x000' "$log"; then
            _bad="$_bad\n    $(basename "$log"): probe-rc 0 but no full-pass PROBE summary"
        fi
    done
    # (3) The index's per-profile PASS count must not exceed the logs that exist.
    if [ -f research/boot-logs/README.md ]; then
        for prof in baseline kasan kcov debug; do
            _claim=$(sed -n "s/^| \`$prof\` | PASS [x×]*\([0-9]*\).*/\1/p" research/boot-logs/README.md | head -1)
            [ -n "$_claim" ] || continue
            _real=$(grep -lE 'PROBE summary[[:space:]]+passed=0x1ff[[:space:]]+failed=0x000' \
                    research/boot-logs/*-"$prof"-BOOT.log 2>/dev/null | wc -l)
            if [ "$_real" -lt "$_claim" ]; then
                _bad="$_bad\n    index claims ${_claim}x PASS for $prof, only $_real full-pass logs exist"
            fi
        done
    fi
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A8  cited logs exist and show real passes" a8_cited_logs_real \
      "a cited boot log is missing or does not show a full pass"

a9_no_tree_committed() {
    _bad=$(git ls-files 2>/dev/null | grep -E '^(build/|kernel/sources/.*/[^/]+$|artifacts/[^/]+/)' \
           | grep -vE '^artifacts/README' | head -5)
    [ -z "$_bad" ] || { printf 'tracked build/artifact files:\n%s\n' "$_bad" >&2; return 1; }
    return 0
}
check "A9  no build tree committed" a9_no_tree_committed

a10_no_orphan_binary() {
    _bad=""
    # A tracked file >512 KB that is not a legitimate large input.
    #
    # Exempt: artifacts/ (bundles, gitignored anyway), *.patch, *.pdf, and
    # vendor/ -- the vendored Arm Kbase source archive is a real build INPUT
    # (kernel/scripts consumes it, vendor/arm/README.md documents it), so
    # tracking it is correct. Exempting it by path is honest; the check still
    # guards against a stray binary anywhere else, which is the case that
    # actually happened (the orphan qemu/target/kbase-probe.stable).
    for f in $(git ls-files 2>/dev/null); do
        [ -f "$f" ] || continue
        case "$f" in
            artifacts/*|vendor/*|*.patch|*.pdf) continue ;;
        esac
        _sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        if [ "$_sz" -gt 524288 ]; then _bad="$_bad\n    $f ($((_sz/1024)) KB)"; fi
    done
    [ -z "$_bad" ] || { printf 'large tracked files:%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A10 no orphan binary committed" a10_no_orphan_binary

# The INERT annotation is an escape hatch, so it needs a counterweight: an
# annotation must not be usable to excuse a symbol that IS settable. Without
# this, "add the word INERT" becomes a way to switch the check off. Every
# annotated symbol must genuinely be prompt-less in the pinned tree.
a11_inert_claims_are_true() {
    _bad=""
    for frag in kernel/configs/*.config; do
        [ -f "$frag" ] || continue
        [ -n "$KERNEL_SRC" ] || return 0
        # every symbol that carries an INERT note above it
        for sym in $(sed -n -e 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p' \
                            -e 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p' "$frag" | sort -u); do
            fragment_declares_inert "$frag" "$sym" || continue
            _short="${sym#CONFIG_}"
            _kind=$(awk -v s="$_short" '
                BEGIN { seen = 0; settable = 0 }
                $0 == "config " s || $0 == "menuconfig " s { seen = 1; inf = 1; next }
                inf && /^[[:space:]]*(bool|tristate|int|hex|string)[[:space:]]+"/ { settable = 1 }
                inf && (/^(menu)?config / || /^choice$/ || /^endchoice$/ || /^endmenu$/) { inf = 0 }
                END {
                    if (!seen)         print "absent"
                    else if (settable) print "settable"
                    else               print "invisible"
                }' $(find "$KERNEL_SRC" -name 'Kconfig*' -type f) 2>/dev/null)
            if [ "$_kind" = "settable" ]; then
                _bad="$_bad\n    $frag: $sym is annotated INERT but IS settable (annotation is a lie)"
            fi
        done
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A11 INERT annotations are truthful" a11_inert_claims_are_true \
      "a fragment calls a settable symbol inert to silence A2"

a12_todo_evidence_exists() {
    _bad=""
    [ -f TODO.md ] || { printf 'no TODO.md\n' >&2; return 1; }
    # Every step marked DONE must cite evidence that exists. A task list is a
    # record of what happened; if "done" is only an assertion it drifts into a
    # wish list -- the exact failure this repository guards against in its
    # technical claims, and one it would then fail to guard against in its own
    # plan.
    #
    # Read the file as (heading, status, evidence) triples. _ev accumulates the
    # Evidence lines belonging to the CURRENT heading only.
    _head=""; _st=""; _ev=""
    while IFS= read -r line; do
        case "$line" in
            "## P"*|"### P"*)
                # flush the previous step
                if [ "$_st" = "DONE" ] && [ -z "$_ev" ]; then
                    _bad="$_bad\n    $(printf '%s' "$_head" | cut -c1-54): DONE with no Evidence: line"
                fi
                _head="$line"; _st=""; _ev="" ;;
            "Status: "*)   _st="${line#Status: }" ;;
            "Evidence: "*)  _ev="x" ;;
        esac
    done < TODO.md
    if [ "$_st" = "DONE" ] && [ -z "$_ev" ]; then
        _bad="$_bad\n    $(printf '%s' "$_head" | cut -c1-54): DONE with no Evidence: line"
    fi

    # Every check ID a task cites must be a REAL check. A task that writes
    # "Checks: A2, A11, A99" reads as carefully verified work; A99 verifies
    # nothing. Citing a check is how a task claims its claim is machine-checked,
    # so a dangling citation is the same defect as an unchecked claim.
    #
    # IDs come from two places: the `check "A1 ..."` registrations, and the
    # dynamic per-bundle emissions (`ok "C1 ..."` inside the tier C loop), which
    # a scan of `check "` alone would miss -- C1 is real, it just runs once per
    # bundle instead of once.
    _known=$(
        { grep -oE '^[[:space:]]*check[[:space:]]+"[A-D][0-9]+' check/check-all.sh
          grep -oE '^[[:space:]]*(ok|bad|skip)[[:space:]]+"[A-D][0-9]+' check/check-all.sh
        } 2>/dev/null | grep -oE '[A-D][0-9]+' | sort -u
    )
    _cited=$(grep -E '^Checks:' TODO.md | sed 's/[–—]/-/g' \
             | grep -oE '[A-D][0-9]+(-[A-D]?[0-9]+)?' | sort -u)
    _expanded=/tmp/.todo-checks.$$
    : > "$_expanded"
    for _tok in $_cited; do
        case "$_tok" in
            *-*)
                _lo=${_tok%%-*}; _hi=${_tok#*-}
                _ll=${_lo%%[0-9]*}; _ln=${_lo##*[!0-9]}
                _hl=${_hi%%[0-9]*}; _hn=${_hi##*[!0-9]}
                # Default the end-letter ONLY when absent ("A1-12"). Overriding a
                # real letter erased the mismatch this test exists to find:
                # "A2-B5" had its B replaced by A and passed. Two of the checks'
                # own bugs were found by running their negative case rather than
                # by reading them -- F-29, F-30, and now this.
                [ -z "$_hl" ] && _hl=$_ll
                if [ "$_ll" != "$_hl" ]; then
                    _bad="$_bad\n    TODO.md cites a check range spanning two ladders: $_tok"
                    continue
                fi
                for _n in $(seq "$_ln" "$_hn"); do printf '%s%s\n' "$_ll" "$_n" >> "$_expanded"; done
                ;;
            *)  printf '%s\n' "$_tok" >> "$_expanded" ;;
        esac
    done
    for _id in $(sort -u "$_expanded"); do
        printf '%s\n' "$_known" | grep -qx "$_id" || \
            _bad="$_bad\n    TODO.md cites check $_id, which check-all.sh does not define"
    done
    rm -f "$_expanded"

    # Every repo-relative path on an Evidence: line must exist. This is where the
    # check earns its keep: an Evidence line is a machine-checkable assertion, so
    # a log that was deleted or a file that was renamed breaks it. Backticked
    # names elsewhere in the file are prose references (`midgard/Kbuild`,
    # `kcov.config`) and are deliberately NOT verified -- demanding that every
    # mention be written as a full repo path would only make the document
    # unreadable without making the plan any more honest.
    # An Evidence entry wraps across lines (several are too long for one), so
    # grepping only ^Evidence: checked the FIRST line and silently skipped the
    # rest -- half the citation unverified. Collect the whole field: the
    # Evidence line plus its continuations, up to a blank line or the next field.
    awk '
        /^Evidence:/            { inev = 1; print; next }
        inev && /^[[:space:]]*$/ { inev = 0 }
        inev && /^(Status:|Checks:|Evidence:|###|##|---)/ { inev = 0 }
        inev                    { print }
    ' TODO.md \
        | grep -oE '`[A-Za-z0-9_./-]+`' | tr -d '`' | sort -u > /tmp/.todo-ev.$$
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
            kernel/*|qemu/*|check/*|analysis/*|research/*|artifacts/*|\
            build/*|patches/*|vendor/*|TODO.md) ;;
            *) continue ;;
        esac
        # strip an anchor, e.g. file.md#section
        _q=${p%%#*}
        [ -e "$_q" ] || _bad="$_bad\n    TODO.md Evidence cites a missing path: $p"
    done < /tmp/.todo-ev.$$
    rm -f /tmp/.todo-ev.$$
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "A12 TODO DONE items cite real evidence" a12_todo_evidence_exists \
      "a task is marked DONE without evidence, or cites a path that is gone"

printf '\n'
fi

# ====================================================== TIER B: artifacts ===

# Global, so tier D can validate bundle manifests even when tier B is not
# selected (`--tier D` must not depend on `--tier B` having run first).
_artifacts=$(find artifacts -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

if has B; then
head_ "TIER B -- artifact integrity"

b1_bundle_hashes() {
    _bad=""
    for a in $_artifacts; do
        [ -f "$a/metadata/SHA256SUMS" ] || { _bad="$_bad\n    $a: no SHA256SUMS"; continue; }
        ( cd "$a" && sha256sum -c metadata/SHA256SUMS >/dev/null 2>&1 ) \
            || _bad="$_bad\n    $a: sha256sum -c FAILED"
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}

b2_manifest_wellformed() {
    _bad=""
    for a in $_artifacts; do
        _m="$a/metadata/manifest.json"
        [ -f "$_m" ] || { _bad="$_bad\n    $a: no manifest.json"; continue; }
        for k in artifact_id kernel_release validation_status scope_class \
                 kernel_config_sha256 kernel_image_sha256 vmlinux_sha256; do
            grep -q "\"$k\"" "$_m" || _bad="$_bad\n    $(basename $a): manifest missing '$k'"
        done
        # A status invented outside the ladder is as wrong as a missing one: the
        # ladder is what keeps "it compiled", "it booted", "it loaded Kbase" and
        # "it is portable" as four separate claims instead of one vague one.
        _st=$(sed -n 's/.*"validation_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_m" | head -1)
        case "$_st" in
            BUILT|TARGET_VERIFIED|QEMU_BOOT_VERIFIED|KBASE_LOAD_VERIFIED|\
            KCOV_VERIFIED|PORTABLE_ARTIFACT_VERIFIED) ;;
            *)
                _bad="$_bad\n    $(basename $a): validation_status '$_st' is not a state in the ladder"
                ;;
        esac
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}

b3_portable_claim_backed() {
    _bad=""
    for a in $_artifacts; do
        _m="$a/metadata/manifest.json"
        [ -f "$_m" ] || continue
        grep -q '"validation_status"[[:space:]]*:[[:space:]]*"PORTABLE_ARTIFACT_VERIFIED"' "$_m" 2>/dev/null || continue
        _p=$(basename "$a")
        # The manifest must NAME its evidence, and the named log must attest THIS
        # bundle: a full PROBE pass, and a CLEAN-LOCATION marker carrying the
        # profile name. The first version of this check searched the whole
        # boot-logs directory for the word "clean-location" and found it in
        # README.md itself -- any bundle could then claim PORTABLE and pass.
        _ev=$(sed -n 's/.*"clean_location_log"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_m" | head -1)
        if [ -z "$_ev" ]; then
            _bad="$_bad\n    $_p claims PORTABLE_ARTIFACT_VERIFIED but records no clean_location_log"
            continue
        fi
        if [ ! -f "$_ev" ]; then
            _bad="$_bad\n    $_p: clean_location_log '$_ev' does not exist"
            continue
        fi
        grep -qE 'PROBE summary[[:space:]]+passed=0x1ff[[:space:]]+failed=0x000' "$_ev" || \
            _bad="$_bad\n    $_p: '$_ev' contains no full PROBE pass (passed=0x1ff)"
        grep -q "CLEAN-LOCATION: $_p" "$_ev" || \
            _bad="$_bad\n    $_p: '$_ev' has no 'CLEAN-LOCATION: $_p' marker -- it may attest a different bundle"
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}

# A packaged bundle must not reference the machine that built it. An absolute
# path into build/ is what made the first relocated bundle secretly
# repo-dependent (F-22), so it is checked mechanically here.
b4_no_abs_build_path() {
    _bad=""
    for a in $_artifacts; do
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if grep -qE "$REPO_ROOT/build/|/workspaces/[^/]*/build/" "$f" 2>/dev/null; then
                _bad="$_bad\n    ${f#$REPO_ROOT/}: references an absolute build path"
            fi
        done < <(find "$a" -type f \( -name '*.sh' -o -name '*.json' -o -name '*.md' -o -name 'run*' -o -name '*.txt' \) 2>/dev/null)
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}

b5_scope_discovery_only() {
    _bad=""
    for a in $_artifacts; do
        _m="$a/metadata/manifest.json"; [ -f "$_m" ] || continue
        grep -q 'DISCOVERY-ONLY' "$_m" || _bad="$_bad\n    $(basename $a): scope_class is not DISCOVERY-ONLY"
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}

if [ -z "$_artifacts" ]; then
    skip "B1..B5 artifact integrity" "no artifacts/ bundles present yet"
else
    check "B1  every bundle matches its SHA256SUMS" b1_bundle_hashes
    check "B2  manifests well-formed" b2_manifest_wellformed
    check "B3  PORTABLE claim is backed by a log" b3_portable_claim_backed
    check "B4  no absolute build path in bundles" b4_no_abs_build_path
    check "B5  every bundle DISCOVERY-ONLY" b5_scope_discovery_only
fi
printf '\n'
fi

# ========================================================= TIER C: runtime ==

if has C || [ "$RUN_C" -eq 1 ]; then
head_ "TIER C -- runtime (boots each packaged artifact)"
for a in $_artifacts; do
    _p=$(basename "$a")
    if [ ! -f "$a/kernel/bzImage" ]; then
        skip "C1  $_p boots" "no kernel/bzImage in bundle"
        continue
    fi
    if qemu/scripts/verify-boot.sh --profile "$_p" --artifact "$a" \
         --strict-artifact --log "/tmp/check-all-$_p.log" >/dev/null 2>&1; then
        ok "C1  $_p boots (5 assertions)" ""
    else
        bad "C1  $_p boots (5 assertions)" "verify-boot.sh failed; see /tmp/check-all-$_p.log"
    fi
done
printf '\n'
fi

# ==================================================== TIER D: state ledger ==

if has D; then
head_ "TIER D -- state ledger"

d1_state_matches_log() {
    [ -f research/state.md ] || return 1
    _cur=$(sed -n 's/^Current state:[[:space:]]*//p' research/state.md | head -1)
    _last=$(grep -oE '\| `[A-Z_]+` → `[A-Z_]+` \|' research/state.md | tail -1 \
            | sed 's/.*→ `\([A-Z_]*\)`.*/\1/')
    [ -n "$_last" ] || return 0   # no transition rows yet
    if [ "$_cur" != "$_last" ]; then
        printf 'Current state: %s but last transition targets %s\n' "$_cur" "$_last" >&2
        return 1
    fi
    return 0
}
check "D1  state.md matches last transition" d1_state_matches_log

# There are TWO ladders and they share four names. That collision is the source of
# the trouble here, and it is recorded as F-30:
#
#   project ladder  (research/state.md)   NOT_STARTED ... PORTABLE_ARTIFACT_
#                   VERIFIED -> SYZKALLER_CONNECTED -> FUZZING_STARTED
#   artifact ladder (artifacts/README.md) BUILT -> TARGET_VERIFIED ->
#                   QEMU_BOOT_VERIFIED -> KBASE_LOAD_VERIFIED -> KCOV_VERIFIED ->
#                   PORTABLE_ARTIFACT_VERIFIED
#
# A bundle that really IS PORTABLE_ARTIFACT_VERIFIED is true while the project
# ledger still reads NOT_STARTED: one bundle's portability is not the same event
# as the project's state. An earlier version of D2 compared the two directly and
# failed on a correct claim. Comparing across ledgers is meaningless -- each claim
# has to be validated against the ledger that owns it.
#
# A MENTION of a state name is also not a CLAIM. artifacts/README.md must explain
# what PORTABLE_ARTIFACT_VERIFIED means and kernel/BUILD-PLAN.md must define the
# ladder at all; neither asserts the project got there. The first version grepped
# for the bare name and failed on both, which is worse than having no check: a
# check that fires on correct documentation teaches its reader to ignore it.

_LADDER_PROJECT="NOT_STARTED SOURCE_INVENTORIED KBASE_IDENTIFIED PATCHES_VERIFIED \
PROGRAM_SCOPE_VERIFIED KERNEL_COMPATIBILITY_IDENTIFIED MINIMAL_CONFIG_DRAFTED \
BASELINE_BUILT KCOV_BUILT KASAN_BUILT DEBUG_BUILT ROOTFS_BUILT \
QEMU_BOOT_VERIFIED KBASE_LOAD_VERIFIED KCOV_VERIFIED PORTABLE_ARTIFACT_VERIFIED \
SYZKALLER_CONNECTED FUZZING_STARTED"

_LADDER_ARTIFACT="BUILT TARGET_VERIFIED QEMU_BOOT_VERIFIED KBASE_LOAD_VERIFIED \
KCOV_VERIFIED PORTABLE_ARTIFACT_VERIFIED"

# ladder_pos <ladder> <name>
ladder_pos() {
    local want="$2" s n=0
    for s in $1; do n=$((n+1)); [ "$s" = "$want" ] && { printf '%d' "$n"; return 0; }; done
    printf '0'
}

# D2 -- project ledger only. The transition table must move monotonically upward,
# and no project document may assert a current state ahead of the ledger. D1
# already ties `Current state:` to the last row, so what is left is catching a row
# that moves backward behind its predecessor.
d2_project_ladder_monotonic() {
    _bad=""
    _last=0
    while IFS='|' read -r _dt _st _fromto _cmd _res _ev; do
        _to=$(printf '%s' "$_fromto" | sed -n 's/.*→[[:space:]]*\`*\([A-Z_]*\)\`*.*/\1/p')
        [ -n "$_to" ] || continue
        _p=$(ladder_pos "$_LADDER_PROJECT" "$_to")
        [ "$_p" -gt 0 ] || continue
        [ "$_p" -ge "$_last" ] || \
            _bad="$_bad\n    research/state.md: transition to $_to moves BACKWARD (ladder $_p after $_last)"
        _last=$_p
    done < <(sed -n '/^| Date | State | From/,$p' research/state.md | tail -n +2)

    _cur=$(sed -n 's/^Current state:[[:space:]]*\`*//p' research/state.md | head -1)
    _cp=$(ladder_pos "$_LADDER_PROJECT" "$_cur")
    [ "$_cp" -gt 0 ] || return 0
    for f in research/state.md research/test-matrix.md kernel/BUILD-PLAN.md TODO.md; do
        [ -f "$f" ] || continue
        for s in $_LADDER_PROJECT; do
            _p=$(ladder_pos "$_LADDER_PROJECT" "$s")
            [ "$_p" -le "$_cp" ] && continue
            grep -qE "^Current state:[[:space:]]*\`?$s\`?[[:space:]]*$" "$f" 2>/dev/null && \
                _bad="$_bad\n    $f asserts 'Current state: $s' (position $_p) above the ledger's $_cur ($_cp)"
        done
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "D2  project ladder moves one way only" d2_project_ladder_monotonic \
      "a transition row goes backward, or a doc asserts a project state the ledger has not reached"

# D3 -- artifact ledger only. A bundle's validation_status is validated against the
# artifact ladder. A manifest may never name a state that exists ONLY on the
# project ladder (SYZKALLER_CONNECTED, FUZZING_STARTED, BASELINE_BUILT, ...):
# those describe the project, not a directory of files, and a manifest asserting
# one would be claiming a fuzzer that does not exist.
d3_bundle_state_within_reach() {
    _bad=""
    for a in $_artifacts; do
        _m="$a/metadata/manifest.json"
        [ -f "$_m" ] || continue
        _st=$(sed -n 's/.*"validation_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_m" | head -1)
        [ -n "$_st" ] || continue
        for s in $_LADDER_PROJECT; do
            case " $_LADDER_ARTIFACT " in *" $s "*) continue ;; esac
            [ "$_st" = "$s" ] && \
                _bad="$_bad\n    $(basename $a): validation_status '$_st' is a PROJECT-ladder state, not an artifact state"
        done
    done
    [ -z "$_bad" ] || { printf '%b\n' "$_bad" >&2; return 1; }
    return 0
}
check "D3  bundle state is on the artifact ladder" d3_bundle_state_within_reach \
      "a bundle names a project-ladder state such as SYZKALLER_CONNECTED"
printf '\n'
fi

# ------------------------------------------------------------------ summary --

printf '%s' "$C_BLD"
printf '────────────────────────────────────────────────────────────\n'
printf '  passed %d   failed %d   skipped %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '  failing checks:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
fi
printf '%s' "$C_OFF"
if [ "$FAIL" -gt 0 ]; then
    printf '\n%sRESULT: FAIL%s -- at least one documented claim is not true.\n' "$C_RED" "$C_OFF"
    exit 1
fi
printf '\n%sRESULT: PASS%s -- every checked claim holds (DISCOVERY-ONLY; not a conformance claim).\n' \
    "$C_GRN" "$C_OFF"
exit 0
