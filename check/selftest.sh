#!/usr/bin/env bash
#
# selftest.sh -- prove that check/check-all.sh actually catches things.
#
#   check/selftest.sh            run every case
#   check/selftest.sh --list     show the cases and exit
#
# WHY THIS EXISTS
#
#   A checker that never fails is indistinguishable from no checker at all. The
#   defect this repository keeps hitting is a tool that reports success while
#   being wrong: F-20 (merge deleted "is not set" lines), F-21 (a config line
#   that meant the opposite of what it said), F-24 (a symbol that cannot be set),
#   F-26 (an inert line credited as a satisfied one), and the KCOV run that
#   reported 656023 "covered PCs" that were the popcount of a PC list when the
#   real figure was 2882.
#
#   Every one of those produced a plausible green result. So the checks written
#   to catch them have to be shown to go red when the defect is reintroduced.
#   That demonstration is what this script is: it re-injects each historical
#   defect and asserts the named check FAILS.
#
#   A case that cannot be made to fail is reported as NOT PROVEN, never as
#   passing. A check whose negative case does not work is worse than no check,
#   because it is trusted.
#
# SAFETY
#
#   Cases mutate real repository files. Every touched file is copied to a
#   backup directory first, restored by a trap on EXIT/INT/TERM, and verified
#   byte-identical afterwards. If this script is killed with SIGKILL the
#   backups are left in /tmp/check-selftest-backup.* and are named in the
#   failure message; nothing is silently left broken.
#
# SCOPE: DISCOVERY-ONLY. This tests the harness, not the driver.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CHECK="$REPO_ROOT/check/check-all.sh"
BACKUP="/tmp/check-selftest-backup.$$"
LIST_ONLY=0
[ "${1:-}" = "--list" ] && LIST_ONLY=1

mkdir -p "$BACKUP"
BACKED=()

cleanup() {
    local f
    for f in "${BACKED[@]:-}"; do
        [ -n "$f" ] && [ -f "$BACKUP/$f" ] && cp -f "$BACKUP/$f" "$f" 2>/dev/null
    done
    # the ghost profile is created, not modified, so it has no backup
    rm -f kernel/configs/ghost.config 2>/dev/null
    if [ "${SELFTEST_VERIFIED:-0}" -ne 1 ]; then
        printf '\n!! backups left in %s (files: %s)\n' "$BACKUP" "${BACKED[*]:-none}" >&2
    fi
    rm -rf "$BACKUP" 2>/dev/null
}
trap cleanup EXIT INT TERM

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLD=''; C_OFF=''
fi

PASS=0; FAIL=0; NOTPROVEN=0

printf '%s' "$C_BLD"
printf 'selftest -- proving each check actually goes red\n'
printf 'repo: %s\n' "$REPO_ROOT"
printf '%s\n\n' "$C_OFF"

# snapshot <file>...     record originals so they can be restored
snapshot() {
    local f
    for f in "$@"; do
        [ -e "$f" ] || { printf 'selftest: target missing: %s\n' "$f" >&2; exit 2; }
        mkdir -p "$BACKUP/$(dirname "$f")"
        cp -p "$f" "$BACKUP/$f"
        BACKED+=("$f")
    done
}

# failing_ids <tier>   the check IDs that failed in a run of that tier
failing_ids() {
    NO_COLOR=1 "$CHECK" --tier "$1" 2>/dev/null \
        | sed -n 's/^ *FAIL  \([ABCD][0-9][0-9]*\).*/\1/p' | tr '\n' ' '
}

# expect_fail <name> <check-id> <tier>   (mutation already applied)
expect_fail() {
    local name="$1" cid="$2" tier="$3" got
    got=$(failing_ids "$tier")
    case " $got " in
        *" $cid "*)
            printf '  %sPROVEN%s  %-40s %s fired as expected\n' \
                   "$C_GRN" "$C_OFF" "$name" "$cid"
            PASS=$((PASS+1)) ;;
        *)
            printf '  %sNOT PROVEN%s  %-35s %s did NOT fire (tier %s failing: %s)\n' \
                   "$C_YLW" "$C_OFF" "$name" "$cid" "$tier" "${got:-none}"
            NOTPROVEN=$((NOTPROVEN+1)) ;;
    esac
}

# expect_pass <name> <check-id> <tier>   (clean tree must stay green)
expect_pass() {
    local name="$1" cid="$2" tier="$3" out
    out=$(NO_COLOR=1 "$CHECK" --tier "$tier" 2>&1)
    if printf '%s' "$out" | grep -qE "FAIL  $cid "; then
        printf '  %sFAIL%s  %-40s %s fired on the CLEAN tree (false positive)\n' \
               "$C_RED" "$C_OFF" "$name" "$cid"
        FAIL=$((FAIL+1))
    else
        printf '  %sCLEAN%s  %-40s %s correctly silent\n' \
               "$C_GRN" "$C_OFF" "$name" "$cid"
        PASS=$((PASS+1))
    fi
}

# append_line <file> <text>
# Guard against a file with no trailing newline: without this the appended line
# is glued onto the last existing line and the mutation silently lands in the
# middle of a comment, where no check can see it. That happened to the first run
# of this script -- two cases reported NOT PROVEN for the right reason with the
# wrong cause, and the bug was in the test, not the check.
append_line() {
    [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ] && printf '\n' >> "$1"
    printf '%s\n' "$2" >> "$1"
}

# insert_before <file> <pattern> <text>
insert_before() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, pat, text = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().split('\n')
for i, l in enumerate(lines):
    if l.startswith(pat):
        lines.insert(i, text)
        break
else:
    sys.exit('pattern not found: ' + pat)
open(path, 'w', encoding='utf-8').write('\n'.join(lines))
PY
}

if [ "$LIST_ONLY" -eq 1 ]; then
    cat <<'EOF'
Positive controls -- these must stay SILENT on the clean tree
  A2  fragments match the pinned Kconfig
  A3  MALI_DEBUG=y confined to debug.config
  A7  header/count claims match the filesystem
  A5  vendor patches byte-identical

Negative cases -- each must turn its check RED
  F-24   A2   re-inject CONFIG_DEBUG_INFO=y        (prompt-less symbol)
  F-24b  A2   inject a symbol absent from the kernel
  F-26   A11  call a SETTABLE symbol inert        (escape-hatch abuse)
  F-21   A3   set MALI_DEBUG=y outside debug.config (scope escape)
  F-25   A7   a header claims BUILT for a profile with no build
  F-25b  A7   a documented count disagrees with disk
  --     A8   cite a boot log that does not exist
  --     A6   leave a gap in the findings numbering
  vendor A5   modify a byte of a vendor patch
  F-28   B1   corrupt a SHA256SUMS-covered bundle file
  --     A12  a DONE task cites a check that does not exist
  --     A12b a check range spanning the two ladders (A2-B5)
  --     A12c a DONE task whose Evidence line was deleted
  --     A12d a MISSING path on a WRAPPED Evidence continuation line
  F-31   --   hide a bundle file; --strict-artifact must REFUSE
EOF
    exit 0
fi

printf '%s\n' "--- positive control: the clean tree must be green ---"
expect_pass "clean tree, tier A"          "A2"  A
expect_pass "clean tree, scope guard"     "A3"  A
expect_pass "clean tree, header honesty"  "A7"  A
expect_pass "clean tree, vendor patches"  "A5"  A

# expect_refuses <name> <cmd...>   the command must exit non-zero
expect_refuses() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  %sNOT PROVEN%s  %-40s the command SUCCEEDED but must fail\n' \
               "$C_YLW" "$C_OFF" "$name"
        NOTPROVEN=$((NOTPROVEN+1))
    else
        printf '  %sPROVEN%s  %-40s refused as required\n' \
               "$C_GRN" "$C_OFF" "$name"
        PASS=$((PASS+1))
    fi
}

printf '\n%s\n' "--- negative cases: each defect must turn its check red ---"

# --- F-24: a symbol that exists but has no prompt -----------------------------
snapshot kernel/configs/debug.config
insert_before kernel/configs/debug.config 'CONFIG_DEBUG_INFO_DWARF5=y' 'CONFIG_DEBUG_INFO=y'
expect_fail "F-24 prompt-less symbol in fragment" A2 A
cp -p "$BACKUP/kernel/configs/debug.config" kernel/configs/debug.config

# --- F-24b: a symbol the kernel does not have at all ---------------------------
snapshot kernel/configs/baseline.config
append_line kernel/configs/baseline.config 'CONFIG_MALI_NOT_A_REAL_SYMBOL=y'
expect_fail "F-24b symbol absent from kernel" A2 A
cp -p "$BACKUP/kernel/configs/baseline.config" kernel/configs/baseline.config

# --- F-26 abuse: claim a settable symbol is inert, to silence A2 ---------------
snapshot kernel/configs/baseline.config
insert_before kernel/configs/baseline.config 'CONFIG_PM_DEVFREQ=y' \
    '# F-26 INERT: PM_DEVFREQ is prompt-less and unreachable from a fragment.'
expect_fail "F-26 INERT note on a settable symbol" A11 A
cp -p "$BACKUP/kernel/configs/baseline.config" kernel/configs/baseline.config

# --- F-21: a non-conforming option escaping its profile ------------------------
snapshot kernel/configs/kcov.config
append_line kernel/configs/kcov.config 'CONFIG_MALI_DEBUG=y'
expect_fail "F-21 MALI_DEBUG=y outside debug.config" A3 A
cp -p "$BACKUP/kernel/configs/kcov.config" kernel/configs/kcov.config

# --- F-25: a header claiming a boot that never happened ------------------------
# A ghost profile with a BUILT header and no build tree. A header can only be
# checked against a profile the checker knows nothing about, because every real
# profile here has now been built and has a boot log -- so claiming BOOTED on a
# real fragment would be a true statement, not a defect.
cat > kernel/configs/ghost.config <<'GHOST'
# ghost.config — created by check/selftest.sh, deleted immediately after.
# Validation:     BUILT and BOOTED on 2026-10-01; everything is fine.
GHOST
expect_fail "F-25 header claims BUILT, nothing built" A7 A
rm -f kernel/configs/ghost.config

# --- F-25b: a documented count that does not match disk ------------------------
snapshot artifacts/README.md
sed -i 's/^artifacts produced:   3/artifacts produced:  99/' artifacts/README.md
expect_fail "F-25b documented count is wrong" A7 A
cp -p "$BACKUP/artifacts/README.md" artifacts/README.md

# --- A8: citing a boot log that does not exist ---------------------------------
snapshot research/boot-logs/README.md
append_line research/boot-logs/README.md '`20991231T235959Z-baseline-BOOT.log`'
expect_fail "A8  cited boot log is missing" A8 A
cp -p "$BACKUP/research/boot-logs/README.md" research/boot-logs/README.md

# --- A6: a gap in the findings numbering ---------------------------------------
snapshot analysis/findings.md
insert_before analysis/findings.md '## Consolidated unknowns' '## F-99 — placeholder gap'
expect_fail "A6  gap in findings numbering" A6 A
cp -p "$BACKUP/analysis/findings.md" analysis/findings.md

# --- A5: editing a vendor patch (must stay byte-identical) ---------------------
snapshot patches/virtual-device/0001-mali-fix-build-error-for-CONFIG_OF-n-for-4.1-kernels.patch
append_line patches/virtual-device/0001-mali-fix-build-error-for-CONFIG_OF-n-for-4.1-kernels.patch \
    '# an innocent-looking research change to a vendor file'
expect_fail "A5  vendor patch modified" A5 A
cp -p "$BACKUP/patches/virtual-device/0001-mali-fix-build-error-for-CONFIG_OF-n-for-4.1-kernels.patch" \
      patches/virtual-device/0001-mali-fix-build-error-for-CONFIG_OF-n-for-4.1-kernels.patch

# --- A12: a DONE task citing a check that does not exist -----------------------
# A task that writes "Checks: A2, A99" reads as carefully verified work while A99
# verifies nothing. Citing a check is how a task asserts its claim is
# machine-checked, so a dangling citation is the same defect as an unchecked claim.
snapshot TODO.md
sed -i 's/^Checks: A2, A11, A7$/Checks: A2, A11, A99/' TODO.md
expect_fail "A12 DONE task cites a nonexistent check" A12 A
cp -p "$BACKUP/TODO.md" TODO.md

# --- A12b: a check range spanning the two ladders ------------------------------
# `A1-B5` looks like coverage and is meaningless: A is the static ladder, B the
# artifact ladder, and they need different preconditions to run at all. A range
# that silently crosses them hides which checks a task actually depends on.
snapshot TODO.md
sed -i 's/^Checks: A2, A6$/Checks: A2-B5/' TODO.md
expect_fail "A12b check range spans two ladders" A12 A
cp -p "$BACKUP/TODO.md" TODO.md

# --- A12c: a DONE task with no Evidence line at all ----------------------------
# Targets a task that actually IS marked DONE. The first attempt removed the
# Evidence line from a NOT-DONE step, which correctly does not fail -- the check
# only requires evidence for work claimed complete. A test that targets the wrong
# row reports NOT PROVEN for the wrong reason.
snapshot TODO.md
sed -i 's|^Evidence: `check/selftest.sh`, `check/README.md`$|# evidence deleted by selftest|' TODO.md
expect_fail "A12c DONE task with no evidence line" A12 A
cp -p "$BACKUP/TODO.md" TODO.md

# --- A12d: a MISSING path on a WRAPPED continuation line ----------------------
# Evidence entries wrap, and the first implementation read only the `Evidence:`
# line, so everything after the first line went unverified. Two attempts at this
# case were wrong before this one:
#   - deleting a citation proves nothing, because the file still exists and the
#     check verifies that CITED paths exist, not which citations are present;
#   - the path has to sit on a CONTINUATION line, or a check that reads only the
#     first line would pass and this case would prove nothing either.
# So: point a continuation line at a file that does not exist.
snapshot TODO.md
sed -i 's|`qemu/scripts/verify-boot.sh`|`qemu/scripts/this-file-does-not-exist.sh`|' TODO.md
expect_fail "A12d missing path on a wrapped line" A12 A
cp -p "$BACKUP/TODO.md" TODO.md

# --- B1: a corrupted byte inside a packaged bundle -----------------------------
# Pick a file that SHA256SUMS actually covers. The first version of this case
# appended to the bundle's README.md, which is NOT in SHA256SUMS -- so the case
# correctly produced no failure, and the check was right and the test was wrong.
# (That exclusion is itself recorded as F-28.)
_bundle_file=""
for _a in artifacts/*/; do
    [ -d "$_a" ] || continue
    _sum="$_a/metadata/SHA256SUMS"
    [ -f "$_sum" ] || continue
    _rel=$(sed -n 's/^[a-f0-9]\{64\}  //p' "$_sum" | grep -vE 'metadata/(SHA256SUMS|manifest\.json)$' | head -1)
    [ -n "$_rel" ] && { _bundle_file="$_a${_rel#./}"; break; }
done
if [ -n "$_bundle_file" ] && [ -f "$_bundle_file" ]; then
    snapshot "$_bundle_file"
    append_line "$_bundle_file" 'tampered'
    expect_fail "B1  covered bundle file corrupted" B1 B
    cp -p "$BACKUP/${_bundle_file#./}" "$_bundle_file"
else
    printf '  %sSKIP%s  %-40s no SHA256SUMS-covered file found in any bundle\n' \
           "$C_YLW" "$C_OFF" "B1  covered bundle file corrupted"
fi

# --- F-31: --strict-artifact must not fall back to build/ --------------------
# Tier C is the portability test, and it runs with --strict-artifact so a bundle
# missing a file FAILS instead of quietly booting from build/<p>/. The first
# implementation of that flag was a no-op: `shift` left the fallback inside "$@",
# so the candidate loop matched it and the STRICT gate was never reached. The flag
# printed strict=1 in a trace while the boot used build/ regardless -- a portability
# check that can only ever pass. Only the negative case catches that class of bug.
_bundle=""
for _a in artifacts/*/; do
    [ -f "$_a/kernel/bzImage" ] && { _bundle="$_a"; break; }
done
if [ -n "$_bundle" ]; then
    _prof=$(basename "$_bundle")
    mv "$_bundle/kernel/bzImage" "$BACKUP/hidden-bzImage"
    BACKED+=("$_bundle/kernel/bzImage")
    expect_refuses "F-31 strict mode refuses build/ fallback" \
        qemu/scripts/run.sh --profile "$_prof" --artifact "$_bundle" --strict-artifact
    mv "$BACKUP/hidden-bzImage" "$_bundle/kernel/bzImage"
else
    printf '  %sSKIP%s  %-40s no bundle with a kernel image to hide\n' \
           "$C_YLW" "$C_OFF" "F-31 strict mode refuses build/ fallback"
fi

printf '\n'
printf '%s' "$C_BLD"
printf '────────────────────────────────────────────────────────────\n'
printf '  proven %d   not-proven %d   hard-fail %d\n' "$PASS" "$NOTPROVEN" "$FAIL"
printf '%s\n' "$C_OFF"

# The whole point is that the tree came back untouched. Verify it rather than
# assert it: a selftest that leaves the repository modified is itself a defect.
_verify() {
    local f bad=0
    for f in "${BACKED[@]:-}"; do
        [ -n "$f" ] || continue
        if [ -f "$BACKUP/$f" ]; then
            cmp -s "$BACKUP/$f" "$f" || { printf '  RESTORE FAILED: %s\n' "$f"; bad=1; }
        fi
    done
    return $bad
}
if _verify; then
    SELFTEST_VERIFIED=1
    printf '  all mutated files restored byte-identical\n'
else
    printf '\n%sRESULT: FAIL%s -- the selftest did not restore the tree.\n' "$C_RED" "$C_OFF"
    exit 1
fi

if [ "$NOTPROVEN" -gt 0 ] || [ "$FAIL" -gt 0 ]; then
    printf '\n%sRESULT: FAIL%s -- %d check(s) did not go red on a re-injected defect.\n' \
           "$C_RED" "$C_OFF" "$((NOTPROVEN+FAIL))"
    exit 1
fi
printf '\n%sRESULT: PASS%s -- every check was proven to catch its defect.\n' "$C_GRN" "$C_OFF"
exit 0