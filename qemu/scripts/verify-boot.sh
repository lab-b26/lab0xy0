#!/usr/bin/env bash
#
# verify-boot.sh --profile <baseline|kasan|kcov|debug> [--artifact DIR] [--log FILE]
#
# Boot a prebuilt profile artifact and assert, from the serial console, that:
#
#   1. the kernel boots far enough to run /init            (BOOTMARK userspace-up)
#   2. mali_kbase.ko loads with default parameters         (BOOTMARK insmod-rc 0)
#   3. Kbase identifies itself and probes a device         ("Probed as mali0")
#   4. /dev/mali0 exists                                    (BOOTMARK dmesg has it,
#                                                          or lsmod shows the mod)
#   5. the EL0 target interface answers                     (BOOTMARK probe-rc with
#                                                          no failure bits)
#
# Assertion 5 is the one that matters. Steps 1-4 only show the module initialised;
# whether an ordinary unprivileged process can actually drive /dev/mali0 is a
# separate question, and it is the question a fuzzer depends on.
#
# Exit status is a bitmask of failed assertions, so a partial failure is still
# evidence rather than one opaque non-zero.
#   0  everything passed
#   1  kernel did not reach userspace
#   2  insmod failed
#   3  Kbase did not report a probed device
#   4  no evidence /dev/mali0 was created
#   5  the target probe did not fully pass
#   8  QEMU itself failed / produced no serial log
#
# Nothing here builds anything. The serial log is kept under research/boot-logs/
# so the run can be re-read without repeating it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$REPO_ROOT/research/boot-logs"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

PROFILE=""; ARTIFACT=""; LOG=""; TIMEOUT=600
usage() {
    cat <<'EOF'
Usage: qemu/scripts/verify-boot.sh --profile <name> [options]

  --profile <name>   baseline | kasan | kcov | debug   (required)
  --artifact DIR     artifact bundle (default: artifacts/<profile>)
  --strict-artifact  every component must resolve from the bundle; a missing
                     file is a hard error, not a silent build-tree substitute.
                     The portability test relies on this.
  --log FILE         keep the serial log here
                     (default: research/boot-logs/<date>-<profile>-BOOT.log)
  --timeout SEC      give up after this long (default: 600)

Exit status is the bitmask of failed assertions; see the header of this script.
EOF
}

STRICT_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --artifact) ARTIFACT="${2:-}"; shift 2 ;;
        --log) LOG="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --strict-artifact) STRICT_ARGS=(--strict-artifact); shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "$PROFILE" in
    baseline|kasan|kcov|debug) ;;
    *) [ -n "$PROFILE" ] || die "--profile is required"; die "unknown profile: $PROFILE" ;;
esac

[ -n "$LOG" ] || { mkdir -p "$LOG_DIR"; LOG="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$PROFILE-BOOT.log"; }

echo "=============================================================="
echo " verify-boot.sh -- profile $PROFILE"
echo "=============================================================="
echo "serial log: $LOG"
[ "${#STRICT_ARGS[@]}" -gt 0 ] && \
    echo "strict:    every component must resolve from the bundle (no build-tree fallback)"

set +e
timeout "$TIMEOUT" "$REPO_ROOT/qemu/scripts/run.sh" \
    --profile "$PROFILE" \
    ${ARTIFACT:+--artifact "$ARTIFACT"} \
    "${STRICT_ARGS[@]}" \
    --serial "$LOG"
QEMU_RC=$?
set -e

if [ ! -s "$LOG" ]; then
    echo
    echo "VERDICT: FAIL (no serial output produced; qemu rc=$QEMU_RC)"
    exit 8
fi

FAILED=0
echo
echo "--- assertions ---"

# 1. userspace
if grep -q 'BOOTMARK userspace-up' "$LOG"; then
    echo "  [ok]   kernel booted and ran /init"
else
    echo "  [FAIL] kernel never reached userspace"
    FAILED=$((FAILED | 1))
fi

# 2. insmod
INSMOD_RC="$(grep -o 'BOOTMARK insmod-rc [0-9-]*' "$LOG" | tail -1 | awk '{print $3}' || true)"
if [ "${INSMOD_RC:-}" = "0" ]; then
    echo "  [ok]   mali_kbase.ko loaded (rc=0, default parameters)"
else
    echo "  [FAIL] insmod rc=${INSMOD_RC:-unknown}"
    FAILED=$((FAILED | 2))
fi

# 3. probe
if grep -q 'Probed as mali' "$LOG"; then
    echo "  [ok]   Kbase probed a device: $(grep -o 'Probed as mali[0-9]*' "$LOG" | head -1)"
else
    echo "  [FAIL] Kbase never reported a probed device"
    FAILED=$((FAILED | 4))
fi

# 4. device node
if grep -q 'mali_kbase ' "$LOG" && grep -q 'Kernel DDK version' "$LOG"; then
    echo "  [ok]   module present in lsmod and self-identified (Kernel DDK version)"
else
    echo "  [FAIL] no evidence the module is present / self-identifying"
    FAILED=$((FAILED | 8))
fi

# 5. target interface
PROBE_RC="$(grep -o 'BOOTMARK probe-rc [0-9]*' "$LOG" | tail -1 | awk '{print $3}' || true)"
PROBE_SUMMARY="$(grep -o 'PROBE summary.*' "$LOG" | tail -1 || true)"
if [ -n "${PROBE_SUMMARY:-}" ] && echo "$PROBE_SUMMARY" | grep -q "failed=0x000"; then
    echo "  [ok]   EL0 target interface fully exercised"
    echo "         $PROBE_SUMMARY"
elif [ -n "${PROBE_SUMMARY:-}" ]; then
    echo "  [PART] target probe did not fully pass"
    echo "         $PROBE_SUMMARY"
    grep '^PROBE' "$LOG" | sed 's/^/         /'
    FAILED=$((FAILED | 16))
else
    echo "  [FAIL] the target probe never ran (rc=${PROBE_RC:-unknown})"
    FAILED=$((FAILED | 16))
fi

# 6. negative-argument battery (F-33 audit seams): every malformed ioctl must
#    be rejected, and the kernel must not have printed a fatal signature during
#    it. "unexpected=N" counts both accepted-what-should-reject and
#    rejected-what-should-accept; a WARN/BUG in dmesg is caught by the serial
#    scan below, so the orgy of indicator layers here is deliberate.
NEG_SUM="$(grep -o 'NEGARGS summary.*' "$LOG" | tail -1 || true)"
if [ -n "${NEG_SUM:-}" ] && echo "$NEG_SUM" | grep -q "unexpected=0"; then
    echo "  [ok]   malformed ioctls all rejected (kbase-negargs)"
    echo "         $NEG_SUM"
elif echo "$NEG_SUM" | grep -q "skipped"; then
    echo "  [ok]   negargs skipped (not present in this bundle)"
else
    echo "  [FAIL] negargs battery failed or missing"
    echo "         ${NEG_SUM:-(no NEGARGS summary line)}"
    grep '^NEGARGS' "$LOG" 2>/dev/null | sed 's/^/         /' | tail -8
    FAILED=$((FAILED | 32))
fi

# 7. no fatal kernel noise across the whole boot, not just the battery window.
#    Oversized-ioctl paths that WARN rather than reject would still show here.
#    Exclusions are the recorded, expected-noise lines from boot-logs/README.md.
if grep -E 'BUG: |Call Trace:|kernel BUG|general protection' "$LOG" | grep -vE 'Unsupported request to change|BUG_ON\(.*== 0\)' >/dev/null 2>&1; then
    echo "  [FAIL] kernel BUG/call-trace found in serial log"
    grep -nE 'BUG: |Call Trace:|kernel BUG|general protection' "$LOG" | head -4 | sed 's/^/         /'
    FAILED=$((FAILED | 64))
else
    echo "  [ok]   no kernel BUG / call-trace in serial log"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "VERDICT: PASS -- boot, Kbase load, and EL0 target interface all verified"
    echo "          log: $LOG"
    exit 0
fi
echo "VERDICT: FAIL (failed-assertion bitmask = $FAILED)"
echo "        log: $LOG"
exit "$FAILED"
