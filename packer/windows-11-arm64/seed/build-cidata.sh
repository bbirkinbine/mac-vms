#!/usr/bin/env bash
# build-cidata.sh — build a seed CD-ROM (cidata.iso) for a clone of the
# Windows 11 ARM64 base qcow2. The in-guest FirstBootSeed task (installed
# by provision/30-install-firstboot-seed.ps1) reads windows-seed.json off
# this CD on first boot and injects the login defined there.
#
# Usage:
#   ./seed/build-cidata.sh                       # uses ./seed/lab-seed.json
#   ./seed/build-cidata.sh seed/other.json       # explicit seed file
#
# Output: output-cidata/cidata.iso
#
# Attach the result as a CD-ROM when you boot the clone:
#   - UTM: Drives -> New -> CD/DVD -> import output-cidata/cidata.iso
#   - qemu: add a usb-storage CD pointing at it (see docs/cloning-windows.md)
#
# macOS-only. Uses hdiutil's makehybrid (built in) — NOT genisoimage,
# which is the homelab Linux path. This pipeline is Apple-Silicon-only,
# so hdiutil is always present.

set -euo pipefail

# Operate from the pipeline directory (this script lives in seed/).
cd "$(dirname "$0")/.."

SEED="${1:-seed/lab-seed.json}"

if [[ ! -f "${SEED}" ]]; then
  echo "ERROR: ${SEED} not found." >&2
  echo "       Copy seed/lab-seed.example.json to seed/lab-seed.json and fill it in." >&2
  exit 1
fi

# Validate JSON up front. plutil ships with macOS; a malformed seed should
# fail here, not silently produce an ISO the guest can't parse. (-lint
# assumes a plist and rejects JSON, so use -convert to /dev/null, which
# parses as JSON and leaves the source untouched.)
if ! plutil -convert json -o /dev/null "${SEED}" >/dev/null 2>&1; then
  echo "ERROR: ${SEED} is not valid JSON. Check it with: plutil -convert json -o /dev/null ${SEED}" >&2
  exit 1
fi

# username/password are load-bearing; refuse to build a seed that can't log in.
for field in username password; do
  if ! /usr/bin/grep -q "\"${field}\"" "${SEED}"; then
    echo "ERROR: ${SEED} is missing required field \"${field}\"." >&2
    exit 1
  fi
done

mkdir -p output-cidata

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The consumer scans CD-ROM volumes for this exact filename. The CIDATA
# volume label is cosmetic for our JSON consumer (we match on filename,
# not label) but kept so the disc is recognizable as a seed.
cp "${SEED}" "${WORK}/windows-seed.json"

OUT="output-cidata/cidata.iso"
rm -f "${OUT}"
hdiutil makehybrid -quiet -iso -joliet \
  -default-volume-name CIDATA \
  -o "${OUT}" "${WORK}"

echo "Wrote ${OUT} from ${SEED}"
echo
echo "Next: boot a clone of the base qcow2 with ${OUT} attached as a CD-ROM."
echo "      See docs/cloning-windows.md for the UTM and qemu attach steps."
