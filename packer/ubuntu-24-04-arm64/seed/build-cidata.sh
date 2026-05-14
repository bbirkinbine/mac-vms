#!/usr/bin/env bash
# build-cidata.sh — build a NoCloud cidata.iso for ad-hoc consumption of
# ubuntu-24-04-arm64-base. cloud-init in the guest reads the ISO on first
# boot and applies the user-data inside.
#
# Usage:
#   ./seed/build-cidata.sh                          # uses ./seed/lab-seed.yaml
#   ./seed/build-cidata.sh seed/other.yaml          # explicit yaml
#
# Output: ./output-seed/cidata.iso
#
# After build:
#   tart clone ubuntu-24-04-arm64-base test-vm
#   tart run --disk=$(pwd)/output-seed/cidata.iso:ro test-vm
#   ssh <user>@$(tart ip test-vm)
#
# macOS-only. Uses hdiutil (which ships with macOS) — the homelab x86
# equivalent uses genisoimage on Linux. Same NoCloud ISO9660 output;
# the filesystem label MUST be "cidata" (lower or upper case) for
# cloud-init's NoCloud datasource to auto-detect it.

set -euo pipefail

cd "$(dirname "$0")/.."

USER_DATA="${1:-seed/lab-seed.yaml}"

if [[ ! -f "${USER_DATA}" ]]; then
  echo "ERROR: ${USER_DATA} not found." >&2
  echo "       Copy seed/lab-seed.example.yaml to seed/lab-seed.yaml and fill it in." >&2
  exit 1
fi

for c in hdiutil shasum; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c not on PATH" >&2; exit 1; }
done

mkdir -p output-seed

WORK="$(mktemp -d -t cidata-build.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

# meta-data is required by the NoCloud datasource. instance-id is the
# cache key cloud-init uses to decide whether to re-run modules on subsequent
# boots — derive from a hash of the user-data so identical seeds produce
# the same id (idempotent re-runs are no-ops) but edits force re-application.
INSTANCE_ID="lab-$(shasum -a 256 "${USER_DATA}" | awk '{print substr($1,1,12)}')"
LOCAL_HOSTNAME="$(awk '/^hostname:/ {print $2; exit}' "${USER_DATA}" | tr -d '\r' || true)"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-lab}"

cat > "${WORK}/meta-data" <<META
instance-id: ${INSTANCE_ID}
local-hostname: ${LOCAL_HOSTNAME}
META

cp "${USER_DATA}" "${WORK}/user-data"

OUT="output-seed/cidata.iso"
# Volume label MUST be cidata (case-insensitive) for NoCloud auto-detect.
# Joliet + Rock Ridge so long filenames survive — cloud-init reads them
# fine either way, but Joliet is the friendlier representation for human
# inspection via diskimage browsers.
hdiutil makehybrid -quiet \
  -o "${OUT}" \
  -hfs -joliet -iso \
  -default-volume-name cidata \
  -joliet-volume-name cidata \
  -hfs-volume-name cidata \
  "${WORK}"

echo "Wrote ${OUT}"
echo "  instance-id:   ${INSTANCE_ID}"
echo "  local-hostname: ${LOCAL_HOSTNAME}"
echo
echo "Next:"
echo "  tart clone ubuntu-24-04-arm64-base test-vm"
echo "  tart run --disk=$(pwd)/${OUT}:ro test-vm    # detach after first boot"
echo "  ssh <user-from-yaml>@\$(tart ip test-vm)"
