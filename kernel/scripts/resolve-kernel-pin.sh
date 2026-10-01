#!/usr/bin/env bash
#
# resolve-kernel-pin.sh [--dry-run] [--force]
#
# Choose a Linux kernel version and write it into kernel/sources/kernel.pin,
# following Arm's VERIFIED guidance:
#
#   "If you are configuring a new virtual environment for testing, we recommend you
#    always use the latest Android Common Kernel or the latest Linux Kernel stable
#    or longterm release before testing."
#   -- research/documents/arm_gpu_bug_bounty_device_configuration_guidelines.pdf
#     version 20250623-1.0 (quoted in analysis/kernel-compatibility.md)
#
# Selection rule: the newest release that kernel.org marks with the moniker
# "longterm". That set IS the Longterm (LTS) series, so this implements "latest
# LTS" literally and without guessing. "stable" releases are excluded on purpose:
# they are the short-lived stable queue, not LTS.
#
# The checksum is taken from kernel.org's own sha256sums.asc for the exact file —
# it is never invented, and never copied from a mirror.
#
# Guarantees:
#   - refuses to overwrite an already-pinned, non-UNSET pin unless --force
#   - writes exactly one active version=, url=, sha256= line each
#   - keeps every existing comment in the pin file
#   - --dry-run prints the decision and writes nothing
#
# Run on the BUILD host (needs network). See ../BUILD-HOST.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="$REPO_ROOT/kernel/sources/kernel.pin"
RELEASES_JSON="https://www.kernel.org/releases.json"

DRY=0; FORCE=0
usage() {
    cat <<'EOF'
Usage: resolve-kernel-pin.sh [--dry-run] [--force]

Resolves the newest longterm (LTS) Linux release and writes it to
kernel/sources/kernel.pin with an authoritative SHA-256.

  --dry-run   show the decision, write nothing
  --force     replace an existing non-UNSET pin
EOF
}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --force)   FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

[ -f "$PIN" ] || die "pin file not found: $PIN"
current=$(grep -E '^version=' "$PIN" | cut -d= -f2- || true)
if [ -n "$current" ] && [ "$current" != "UNSET" ] && [ "$FORCE" -eq 0 ]; then
    die "kernel.pin is already pinned to $current. Refusing to overwrite.
       Re-run with --force if the pin really should change."
fi

command -v curl >/dev/null || die "curl is required to reach kernel.org"
command -v python3 >/dev/null || die "python3 is required to parse releases.json"

echo "=============================================================="
echo " resolve-kernel-pin.sh — latest LTS from kernel.org"
echo "=============================================================="
echo "reading $RELEASES_JSON"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 --retry-delay 2 "$RELEASES_JSON" -o "$tmp" \
    || die "could not fetch releases.json"

# --- pick the newest longterm release -------------------------------------
# No jq dependency on the build host; python3 is already required for the kernel
# build anyway.
IFS='|' read -r VER MONIKER ISO ISEOL SOURCE <<<"$(python3 - "$tmp" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rel = d.get("releases") or []
def key(r):
    v = (r.get("version") or "").split("-")[0]
    return tuple(int(p) for p in v.split(".") if p.isdigit())
lt = [r for r in rel if (r.get("moniker") or "") == "longterm"]
if not lt:
    sys.exit("no release carries the 'longterm' moniker")
best = max(lt, key=key)
# "|"-delimited: a whitespace-separated `read` collapses empty fields and would
# silently shift these values into the wrong variables (the date lives at
# released.isodate; there is no top-level "isodate" key in this document).
print("|".join([best.get("version", ""), best.get("moniker", ""),
               best.get("released", {}).get("isodate", ""),
               "EOL" if best.get("iseol") else "", best.get("source", "")]))
PY
)" || die "failed to select a longterm release from releases.json"

[ -n "$VER" ] || die "releases.json produced an empty version"

TARBALL="linux-${VER}.tar.xz"

# --- locate the tarball: which kernel.org directory actually holds it -------
# Do NOT derive the directory by string surgery on the version. kernel.org files
# the CURRENT series under v<major>.x (6.18.x and 6.12.x both live in v6.x,
# 5.15.x in v5.x) and only frozen series get their own vX.Y directory, so
# "v6.18/sha256sums.asc" 404s. releases.json already names the real location
# in `source`; try that first, then the conventional layouts as a fallback.
#
# A candidate is accepted only if its sha256sums.asc actually LISTS the
# tarball, so a stale layout fails loudly here instead of writing a bad pin.
# See analysis/findings.md F-13.
MAJ=$(printf '%s' "$VER" | cut -d- -f1 | cut -d. -f1)
MIN=$(printf '%s' "$VER" | cut -d- -f1 | cut -d. -f2)
BASE="https://cdn.kernel.org/pub/linux/kernel"

CANDIDATES=()
[ -n "${SOURCE:-}" ] && CANDIDATES+=("$(dirname "$SOURCE")")
CANDIDATES+=("$BASE/v${MAJ}.${MIN}" "$BASE/v${MAJ}.x")

echo
echo "selected release"
echo "  version   : $VER"
echo "  moniker   : $MONIKER"
echo "  released  : $ISO ${ISEOL:+(marked EOL)}"
echo "  tarball   : $TARBALL"
echo
echo "reasoning: newest release carrying the 'longterm' moniker. That set is"
echo "exactly the Longterm (LTS) series, which is what Arm's guidance asks for."
echo

# --- fetch the authoritative checksum -------------------------------------
SUMFILE=""; SHA=""
for dir in "${CANDIDATES[@]}"; do
    sum="$dir/sha256sums.asc"
    printf 'looking for %s in %s ...\n' "$TARBALL" "$dir"
    if curl -fsSL --retry 2 --retry-delay 2 "$sum" -o "$tmp.sums" 2>/dev/null; then
        sha=$(awk -v f="$TARBALL" '$2 == f {print $1}' "$tmp.sums" | head -1)
        if [ -n "$sha" ]; then
            SUMFILE="$sum"; SHA="$sha"; break
        fi
        echo "  not listed there"
    else
        echo "  no sha256sums.asc ($(curl -s -o /dev/null -w '%{http_code}' "$sum"))"
    fi
done

[ -n "$SUMFILE" ] || die "$TARBALL not found in any candidate directory:
       ${CANDIDATES[*]}
       The kernel.org layout may have changed again. Check
       https://cdn.kernel.org/pub/linux/kernel/ and, if needed, write
       kernel/sources/kernel.pin by hand from the authoritative checksums."

[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "checksum for $TARBALL is not 64 hex chars: $SHA"

DIR=$(dirname "$SUMFILE")
URL="$DIR/$TARBALL"
echo
echo "  directory : $DIR"
echo "  url       : $URL"
echo "  sha256    : $SHA   (from $SUMFILE)"

cat <<EOF
pin to be written:
  version=$VER
  url=$URL
  sha256=$SHA
EOF
echo

if [ "$DRY" -eq 1 ]; then
    echo "--dry-run: nothing written."
    echo
    echo "Compatibility note (analysis/kernel-compatibility.md): r54p0's highest"
    echo "observed KERNEL_VERSION gate is 6.13.0, but a gate is not a ceiling. If"
    echo "this release fails to build Kbase, record the first error per"
    echo "research/methodology.md, then re-run with --force for the next candidate."
    echo "Do not silently downgrade."
    exit 0
fi

# --- write the three active lines in place, preserving comments -----------
set_version() { # $1 = file, $2 = field, $3 = value
    if grep -qE "^$2=" "$1"; then
        # BSD/GNU-safe in-place edit of exactly one line.
        tmp2=$(mktemp) && awk -v k="$2" -v v="$3" -F= '
            $0 ~ "^" k "=" { print k "=" v; next } { print }' "$1" > "$tmp2" \
            && mv "$tmp2" "$1"
    else
        printf '%s=%s\n' "$2" "$3" >> "$1"
    fi
}
set_version "$PIN" version "$VER"
set_version "$PIN" url "$URL"
set_version "$PIN" sha256 "$SHA"

# Record the provenance inline so the pin explains itself.
{
    printf '\n# --- resolved %s by kernel/scripts/resolve-kernel-pin.sh ---\n' "$(date -u +%Y-%m-%d)"
    printf '# moniker=%s  released=%s %s\n' "$MONIKER" "$ISO" "${ISEOL:+(EOL)}"
    printf '# tarball directory: %s  (current series is filed under v<major>.x)\n' "$DIR"
    printf '# checksum source: %s\n' "$SUMFILE"
    printf '# ARM guidance: latest ACK or latest stable/longterm (see ../BUILD-HOST.md)\n'
} >> "$PIN"

echo "written to $PIN:"
grep -E '^(version|url|sha256)=' "$PIN"
echo
echo "Next: kernel/scripts/preflight.sh, then fetch-kernel.sh."
echo "Then COMMIT the pin so the kernel choice is reproducible."
exit 0