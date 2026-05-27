#!/usr/bin/env bash
# build-cidata.sh — build a NoCloud cidata.iso for ad-hoc consumption of
# kali-rolling-arm64-base. cloud-init in the guest reads the ISO on first
# boot and applies the user-data inside.
#
# Usage:
#   ./seed/build-cidata.sh                          # uses ./seed/lab-seed.yaml + auto-detected ~/.ssh/id_*.pub
#   ./seed/build-cidata.sh seed/other.yaml          # explicit yaml
#   ./seed/build-cidata.sh -i ~/.ssh/foo.pub        # explicit pubkey, suppresses auto-detect
#   ./seed/build-cidata.sh -i k1.pub -i k2.pub seed/other.yaml  # repeatable + custom yaml
#
# SSH key sources, merged into the yaml's ssh_authorized_keys:
#   1. Whatever the yaml already contains under users[0].ssh_authorized_keys.
#   2. Each `-i <path>` argument (in argv order). Presence of any `-i`
#      suppresses the auto-detect in step 3 — be explicit.
#   3. Auto-detect: every ~/.ssh/id_*.pub on the host, validated like any
#      other source. Skipped if any `-i` is passed.
#
# Output: ./output-seed/cidata.iso
#
# After build:
#   tart clone kali-rolling-arm64-base test-vm
#   tart run --disk=$(pwd)/output-seed/cidata.iso:ro test-vm
#   ssh <user>@$(tart ip test-vm)
#
# macOS-targeted but tool-portable. Uses xorriso (brew install xorriso),
# which is already required by the Kali Packer wrapper for ISO repacking.
# Previously used hdiutil makehybrid, but that produced an Apple_partition_
# scheme hybrid image whose ISO9660 label was hidden behind the Apple
# partition map — Linux's blkid in the guest couldn't see LABEL=cidata,
# and cloud-init fell through to DataSourceNone. xorriso produces a flat
# ISO9660 + Joliet + Rock Ridge image that Linux blkid sees cleanly.
# The filesystem label MUST be "cidata" (case-insensitive) for cloud-init's
# NoCloud datasource to auto-detect.

set -euo pipefail

cd "$(dirname "$0")/.."

# ---- argument parsing -------------------------------------------------------

USER_DATA=""
declare -a EXPLICIT_KEY_FILES=()

usage() {
  cat <<USAGE
Usage: $0 [-i <ssh-pubkey-path>]... [user-data.yaml]

  -i <path>    SSH public key file to inject into the cidata user-data's
               ssh_authorized_keys. Repeatable. Passing any -i suppresses
               the auto-detect of ~/.ssh/id_*.pub — be explicit.
  -h, --help   This message.

  user-data.yaml  Optional positional argument; default seed/lab-seed.yaml.

Examples:
  $0
  $0 -i ~/.ssh/id_ed25519.pub
  $0 -i lab-key.pub -i ops-key.pub seed/lab-seed.yaml
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i)
      shift
      [[ $# -eq 0 ]] && { echo "ERROR: -i requires a path argument" >&2; exit 1; }
      EXPLICIT_KEY_FILES+=("$1")
      shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$USER_DATA" ]]; then
        echo "ERROR: only one user-data path may be passed (got '$USER_DATA' and '$1')" >&2
        exit 1
      fi
      USER_DATA="$1"
      shift
      ;;
  esac
done
USER_DATA="${USER_DATA:-seed/lab-seed.yaml}"

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

# ---- yaml-side key validation (existing pipeline) ---------------------------

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

# Layer (a): structural sanity. A valid pubkey is `<algo> <base64> [comment...]`.
# Token 1 must be a known algo. Token 2 must NOT also be a known algo
# (that's the `ssh-ed25519 ssh-ed25519 AAAA...` duplication bug, which
# ssh-keygen happily accepts).
is_ssh_algo() {
  case "$1" in
    ssh-rsa|ssh-ed25519|ssh-dss) return 0 ;;
    ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) return 0 ;;
    sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) return 0 ;;
  esac
  return 1
}

# validate_pubkey_line <key-content> <source-description>
# Runs the same two-layer check on a single key line.
validate_pubkey_line() {
  local key="$1"
  local source="$2"
  local f1 f2 _
  read -r f1 f2 _ <<< "$key" || true
  if ! is_ssh_algo "$f1"; then
    echo "ERROR: SSH key from ${source} doesn't start with a known algorithm:" >&2
    echo "         ${key}" >&2
    echo "       First token must be one of: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp{256,384,521}, sk-*@openssh.com." >&2
    exit 1
  fi
  if is_ssh_algo "$f2"; then
    echo "ERROR: SSH key from ${source} has a duplicated algorithm prefix:" >&2
    echo "         ${key}" >&2
    echo "       Looks like the algo name was pasted twice ('$f1 $f2 ...'). Keep just the first." >&2
    exit 1
  fi

  # Layer (b): hand off to ssh-keygen for base64 + structural sanity.
  # Process substitution (<(...)) writes the key to a /dev/fd/<n> handle
  # that ssh-keygen reads — no on-disk temp file to clean up.
  if ! ssh-keygen -l -f <(printf '%s\n' "$key") >/dev/null 2>&1; then
    echo "ERROR: invalid SSH public key from ${source}:" >&2
    echo "         ${key}" >&2
    echo "       ssh-keygen rejected it. Likely causes: broken base64, copy-paste" >&2
    echo "       line wrapping, or an unknown algorithm token." >&2
    exit 1
  fi
}

# Dedup token = "<algo> <base64>" (first two whitespace-delimited fields).
# Comments and trailing whitespace are ignored, so the same key with
# different `user@host` labels still dedupes. Pure-bash set on top of an
# indexed array — keeps the script bash-3.2 compatible (macOS default).
declare -a SEEN_TOKENS=()
dedup_token() {
  local f1 f2 _
  read -r f1 f2 _ <<< "$1" || true
  printf '%s %s' "$f1" "$f2"
}
seen_already() {
  local needle="$1" t
  for t in "${SEEN_TOKENS[@]:-}"; do
    [[ "$t" == "$needle" ]] && return 0
  done
  return 1
}

YAML_KEY_COUNT=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  key="${line}"
  key="${key#"${key%%[![:space:]]*}"}"   # strip leading whitespace
  key="${key#- }"
  key="${key#\"}"; key="${key%\"}"
  key="${key#\'}"; key="${key%\'}"
  YAML_KEY_COUNT=$((YAML_KEY_COUNT + 1))
  validate_pubkey_line "$key" "${USER_DATA} (entry #${YAML_KEY_COUNT})"
  SEEN_TOKENS+=("$(dedup_token "$key")")
done < <(grep -E -- '^[[:space:]]*-[[:space:]]+(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)' "${USER_DATA}" || true)

# ---- external key sources (-i flags or auto-detect from ~/.ssh) -------------

declare -a EXTRA_KEY_FILES=()
EXTRA_SOURCE=""
if [[ ${#EXPLICIT_KEY_FILES[@]} -gt 0 ]]; then
  EXTRA_KEY_FILES=("${EXPLICIT_KEY_FILES[@]}")
  EXTRA_SOURCE="explicit (-i)"
else
  # nullglob: if no files match the pattern, the glob expands to nothing
  # instead of staying literal. So 'for f in ~/.ssh/id_*.pub' is a no-op
  # when ~/.ssh/ has no id_*.pub files.
  shopt -s nullglob
  for k in "${HOME}/.ssh/"id_*.pub; do
    EXTRA_KEY_FILES+=("$k")
  done
  shopt -u nullglob
  EXTRA_SOURCE="auto-detected from ${HOME}/.ssh/"
fi

declare -a EXTRA_KEY_LINES=()
if [[ ${#EXTRA_KEY_FILES[@]} -gt 0 ]]; then
  echo "==> SSH key sources beyond ${USER_DATA}: ${EXTRA_SOURCE}"
  for keyfile in "${EXTRA_KEY_FILES[@]}"; do
    if [[ ! -f "$keyfile" ]]; then
      echo "ERROR: SSH key file not found: $keyfile" >&2
      exit 1
    fi
    # Path-shape guard: a public key file conventionally ends in .pub.
    # If the user passes ~/.ssh/id_ed25519 (no .pub), it's almost
    # certainly a private key. The content check below is the
    # authoritative defence; this is the friendlier error.
    if [[ "$keyfile" != *.pub ]]; then
      echo "ERROR: '$keyfile' does not end in .pub — refusing to inject." >&2
      echo "       Pass the PUBLIC key file (the one ending in .pub)." >&2
      exit 1
    fi
    # Content-side private-key guard.
    if grep -qE -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$keyfile"; then
      echo "ERROR: '$keyfile' contains a PRIVATE KEY block — refusing to inject." >&2
      echo "       Pass the .pub half of the keypair instead." >&2
      exit 1
    fi
    # Read each non-blank, non-comment line as a candidate key entry.
    # A single .pub file is usually one line, but multi-entry files
    # (concatenated authorized_keys-style) are also accepted. shellcheck's
    # SC2094 worries about read+write on the same file in a pipeline;
    # validate_pubkey_line takes the path only as an error-message label,
    # it doesn't open it. Pre-read the file content and iterate over that
    # to keep the shellcheck check happy.
    file_contents="$(cat "$keyfile")"
    while IFS= read -r raw; do
      key="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -z "$key" ]] && continue
      [[ "$key" == \#* ]] && continue
      validate_pubkey_line "$key" "$keyfile"
      token="$(dedup_token "$key")"
      if seen_already "$token"; then
        echo "    = ${keyfile##*/} (already present in ${USER_DATA} — skipped)"
        continue
      fi
      SEEN_TOKENS+=("$token")
      EXTRA_KEY_LINES+=("$key")
      fp="$(ssh-keygen -l -f <(printf '%s\n' "$key") 2>/dev/null | awk '{print $2, "("$4")"}')"
      echo "    + ${keyfile##*/} ${fp}"
    done <<< "$file_contents"
  done
fi

# ---- meta-data + user-data assembly ----------------------------------------

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
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-kali}"

# Force single-quote the hostname in meta-data so it always parses as a
# string on the guest side, regardless of what valid-DNS-hostname value
# the user put in their seed yaml. Valid hostnames (RFC 1123:
# [a-zA-Z0-9-] in labels) never contain a single quote, so this is safe.
cat > "${WORK}/meta-data" <<META
instance-id: ${INSTANCE_ID}
local-hostname: '${LOCAL_HOSTNAME}'
META

# Inject EXTRA_KEY_LINES (if any) into the user-data's
# ssh_authorized_keys: block. Strategy:
#   - Find the first `ssh_authorized_keys:` line.
#   - Normalize `: []` inline form to bare `:` so the multi-line list we
#     append is syntactically valid.
#   - Print the existing line, then emit `<indent>  - <key>` for each
#     extra key. <indent> is detected from the position of the
#     ssh_authorized_keys: marker so the appended entries align with
#     whatever indent the user is using.
#   - Subsequent occurrences of the marker (in pathological yamls with
#     multiple users) are left alone — we only inject into the first.
# If the yaml has no ssh_authorized_keys: line and EXTRA_KEY_LINES is
# non-empty, we abort with a clear message — silently dropping the
# explicit keys on the floor would be worse.
if [[ ${#EXTRA_KEY_LINES[@]} -gt 0 ]]; then
  if ! grep -qE '^[[:space:]]*ssh_authorized_keys[[:space:]]*:' "${USER_DATA}"; then
    echo "ERROR: ${USER_DATA} has no 'ssh_authorized_keys:' line, but extra keys" >&2
    echo "       were requested (${EXTRA_SOURCE}). Add 'ssh_authorized_keys: []'" >&2
    echo "       under the user definition in the yaml, then re-run." >&2
    exit 1
  fi
fi

if [[ ${#EXTRA_KEY_LINES[@]} -eq 0 ]]; then
  # No external keys to inject — copy verbatim. The yaml passes through
  # unchanged so an empty-list `ssh_authorized_keys: []` placeholder stays
  # as-is on the guest side (cloud-init treats it as "no keys").
  cp "${USER_DATA}" "${WORK}/user-data"
else
  # Inject extra keys into the first `ssh_authorized_keys:` block in the
  # yaml. Strategy: line-stream the file; when we hit the marker, capture
  # its leading-whitespace indent, normalize any inline `: []` form to
  # bare `:`, then emit each EXTRA_KEY_LINES entry as
  # `<indent>  - <key>` (YAML child indent = parent + 2 spaces).
  # First match wins; pathological yamls with multiple ssh_authorized_keys
  # blocks only see injection in the first. Done in bash rather than awk
  # because BWK awk on macOS rejects newline-bearing -v values.
  {
    injected_once=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$injected_once" -eq 0 ]] \
         && [[ "$line" =~ ^([[:space:]]*)ssh_authorized_keys[[:space:]]*: ]]; then
        indent="${BASH_REMATCH[1]}"
        # Normalize any inline empty-list form so the multi-line entries
        # below form a syntactically valid YAML list.
        if [[ "$line" =~ ^([[:space:]]*ssh_authorized_keys[[:space:]]*:)[[:space:]]*\[[[:space:]]*\][[:space:]]*$ ]]; then
          printf '%s\n' "${BASH_REMATCH[1]}"
        else
          printf '%s\n' "$line"
        fi
        for k in "${EXTRA_KEY_LINES[@]}"; do
          printf '%s  - %s\n' "$indent" "$k"
        done
        injected_once=1
      else
        printf '%s\n' "$line"
      fi
    done < "${USER_DATA}"
  } > "${WORK}/user-data"
fi

TOTAL_KEY_COUNT=$((YAML_KEY_COUNT + ${#EXTRA_KEY_LINES[@]}))
echo "==> SSH keys in user-data: ${TOTAL_KEY_COUNT} (yaml: ${YAML_KEY_COUNT}, injected: ${#EXTRA_KEY_LINES[@]})"
if [[ "${TOTAL_KEY_COUNT}" -eq 0 ]]; then
  echo "WARN: no ssh_authorized_keys entries in the final user-data." >&2
  echo "      You'll need console / password login to reach the clone." >&2
fi

# ---- xorriso ----------------------------------------------------------------

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
echo "  tart clone kali-rolling-arm64-base test-vm"
echo "  tart run --disk=$(pwd)/${OUT}:ro test-vm    # detach after first boot"
echo "  ssh <user-from-yaml>@\$(tart ip test-vm)"
