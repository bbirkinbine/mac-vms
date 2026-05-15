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
# macOS-targeted but tool-portable. Uses xorriso (brew install xorriso),
# which is already required by the Ubuntu Packer wrapper for ISO repacking.
# Previously used hdiutil makehybrid, but that produced an Apple_partition_
# scheme hybrid image whose ISO9660 label was hidden behind the Apple
# partition map — Linux's blkid in the guest couldn't see LABEL=cidata,
# and cloud-init fell through to DataSourceNone. xorriso produces a flat
# ISO9660 + Joliet + Rock Ridge image that Linux blkid sees cleanly.
# The filesystem label MUST be "cidata" (case-insensitive) for cloud-init's
# NoCloud datasource to auto-detect.

set -euo pipefail

cd "$(dirname "$0")/.."

USER_DATA="${1:-seed/lab-seed.yaml}"

if [[ ! -f "${USER_DATA}" ]]; then
  echo "ERROR: ${USER_DATA} not found." >&2
  echo "       Copy seed/lab-seed.example.yaml to seed/lab-seed.yaml and fill it in." >&2
  exit 1
fi

for c in xorriso shasum ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c not on PATH" >&2; exit 1; }
done

mkdir -p output-seed

WORK="$(mktemp -d -t cidata-build.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

# Preflight: reject pasted private keys outright. cloud-init publishes
# whatever is under ssh_authorized_keys to ~/.ssh/authorized_keys, so a
# private key block would land your secret on the box and (more importantly)
# fail to authenticate you. Look for a PEM-style header anywhere in the file.
if grep -qE -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "${USER_DATA}"; then
  echo "ERROR: ${USER_DATA} contains a PRIVATE KEY block." >&2
  echo "       Paste the PUBLIC key (~/.ssh/id_*.pub — a single line that" >&2
  echo "       starts with ssh-ed25519 / ssh-rsa / ecdsa-* / sk-*) instead." >&2
  exit 1
fi

# Preflight: validate each ssh_authorized_keys entry. Two layers of check —
# (a) a strict token-shape check to catch things ssh-keygen silently
# tolerates (notably a duplicated algo prefix, which ssh-keygen will read
# and return a real fingerprint for), and (b) ssh-keygen -l as a final
# sanity pass to catch broken base64 or unknown algorithms.
is_ssh_algo() {
  case "$1" in
    ssh-rsa|ssh-ed25519|ssh-dss) return 0 ;;
    ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) return 0 ;;
    sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) return 0 ;;
  esac
  return 1
}

KEY_COUNT=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  key="${line}"
  key="${key#"${key%%[![:space:]]*}"}"   # strip leading whitespace
  key="${key#- }"
  key="${key#\"}"; key="${key%\"}"
  key="${key#\'}"; key="${key%\'}"
  KEY_COUNT=$((KEY_COUNT + 1))

  # Layer (a): structural sanity. A valid pubkey is `<algo> <base64> [comment...]`.
  # Token 1 must be a known algo. Token 2 must NOT also be a known algo
  # (that's the `ssh-ed25519 ssh-ed25519 AAAA...` duplication bug, which
  # ssh-keygen happily accepts).
  read -r f1 f2 _ <<< "$key" || true
  if ! is_ssh_algo "$f1"; then
    echo "ERROR: SSH key #${KEY_COUNT} in ${USER_DATA} doesn't start with a known algorithm:" >&2
    echo "         ${key}" >&2
    echo "       First token must be one of: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp{256,384,521}, sk-*@openssh.com." >&2
    exit 1
  fi
  if is_ssh_algo "$f2"; then
    echo "ERROR: SSH key #${KEY_COUNT} in ${USER_DATA} has a duplicated algorithm prefix:" >&2
    echo "         ${key}" >&2
    echo "       Looks like the algo name was pasted twice ('$f1 $f2 ...'). Keep just the first." >&2
    exit 1
  fi

  # Layer (b): hand off to ssh-keygen for base64 + structural sanity.
  printf '%s\n' "$key" > "${WORK}/key-${KEY_COUNT}.pub"
  if ! ssh-keygen -l -f "${WORK}/key-${KEY_COUNT}.pub" >/dev/null 2>&1; then
    echo "ERROR: invalid SSH public key in ${USER_DATA}:" >&2
    echo "         ${key}" >&2
    echo "       ssh-keygen rejected it. Likely causes: broken base64, copy-paste" >&2
    echo "       line wrapping, or an unknown algorithm token." >&2
    exit 1
  fi
done < <(grep -E -- '^[[:space:]]*-[[:space:]]+(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)' "${USER_DATA}" || true)

if [[ "${KEY_COUNT}" -eq 0 ]]; then
  echo "WARN: no ssh_authorized_keys entries found in ${USER_DATA}." >&2
  echo "      You'll need console / password login to reach the clone." >&2
fi

# meta-data is required by the NoCloud datasource. instance-id is the
# cache key cloud-init uses to decide whether to re-run modules on subsequent
# boots — derive from a hash of the user-data so identical seeds produce
# the same id (idempotent re-runs are no-ops) but edits force re-application.
INSTANCE_ID="lab-$(shasum -a 256 "${USER_DATA}" | awk '{print substr($1,1,12)}')"
LOCAL_HOSTNAME="$(awk '/^hostname:/ {print $2; exit}' "${USER_DATA}" | tr -d '\r' || true)"
# Strip a single layer of surrounding single or double quotes if the user
# wrote `hostname: 'foo'` or `hostname: "foo"` — and they have to do that
# whenever the value collides with a YAML reserved word ('null', 'true',
# 'no', 'off', a pure number, etc.). We accept either form.
LOCAL_HOSTNAME="${LOCAL_HOSTNAME#\'}"; LOCAL_HOSTNAME="${LOCAL_HOSTNAME%\'}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME#\"}"; LOCAL_HOSTNAME="${LOCAL_HOSTNAME%\"}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-lab}"

# Force single-quote the hostname in meta-data so it always parses as a
# string on the guest side, regardless of what valid-DNS-hostname value
# the user put in their seed yaml. Valid hostnames (RFC 1123:
# [a-zA-Z0-9-] in labels) never contain a single quote, so this is safe.
cat > "${WORK}/meta-data" <<META
instance-id: ${INSTANCE_ID}
local-hostname: '${LOCAL_HOSTNAME}'
META

cp "${USER_DATA}" "${WORK}/user-data"

OUT="output-seed/cidata.iso"
# Volume label MUST be cidata (case-insensitive) for NoCloud auto-detect.
# -V sets the ISO9660 volume identifier; -joliet + -rock add long-filename
# and Unix-attribute extensions. xorriso refuses to overwrite by default,
# so drop the prior file first to make re-runs idempotent.
rm -f "${OUT}"
xorriso -as mkisofs \
  -V cidata \
  -joliet -rock \
  -o "${OUT}" \
  "${WORK}"

echo "Wrote ${OUT}"
echo "  instance-id:   ${INSTANCE_ID}"
echo "  local-hostname: ${LOCAL_HOSTNAME}"
echo
echo "Next:"
echo "  tart clone ubuntu-24-04-arm64-base test-vm"
echo "  tart run --disk=$(pwd)/${OUT}:ro test-vm    # detach after first boot"
echo "  ssh <user-from-yaml>@\$(tart ip test-vm)"
