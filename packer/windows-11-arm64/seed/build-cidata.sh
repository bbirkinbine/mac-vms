#!/usr/bin/env bash
# build-cidata.sh — build a seed CD (cidata.iso) for a clone of the Windows
# 11 ARM64 base qcow2. The in-guest FirstBootSeed task reads windows-seed.json
# off this CD on first boot and injects the login defined there.
#
# Mirrors the "sensible defaults" UX of the Ubuntu/Kali build-cidata.sh, so a
# zero-config run produces a working clone (the Windows parallel of
# `just spawn ubuntu` → `ssh ubuntu@<ip>`):
#
#   - Default username 'admin' (the runtime user; the build-time Administrator
#     is disabled on first boot of a seeded clone, the way the Linux build
#     user 'packer' is removed).
#   - Default hostname 'windows'.
#   - Auto-injects every ~/.ssh/id_*.pub on the host (override with -i,
#     repeatable, which suppresses auto-detect) — same as the Linux script.
#   - A password is ALWAYS set. Unlike the Linux key-only default, a Windows
#     account needs a password for console/RDP, so if the seed omits one a
#     strong random password is generated and PRINTED here at build time.
#     Set "password" in the seed to choose your own. SSH keys work either way.
#
# Usage:
#   ./seed/build-cidata.sh                          # defaults + auto ~/.ssh/id_*.pub
#   ./seed/build-cidata.sh seed/lab-seed.json       # explicit seed (still gets auto keys)
#   ./seed/build-cidata.sh -i ~/.ssh/foo.pub        # explicit pubkey, suppresses auto-detect
#   ./seed/build-cidata.sh -o /tmp/vm.iso seed.json # custom output path
#   ./seed/build-cidata.sh --env                    # write a generated password to
#                                                   #   .env.windows-vms instead of stdout
#   ./seed/build-cidata.sh --env=/path/.env.vms     # ... to a specific file
#
# Output: output-cidata/cidata.iso (default) or the -o path.
#
# Attach the result as a CD-ROM when you boot the clone (or just use
# `just run-windows --seed <seed.json>`, which calls this for you):
#   - UTM: Drives -> New -> CD/DVD -> import output-cidata/cidata.iso
#   - qemu: a usb-storage CD (see docs/cloning-windows.md)
#
# macOS-only. Uses hdiutil's makehybrid (built in). The in-guest consumer
# matches windows-seed.json by FILENAME (not by volume label), so the
# Apple-partition-map label-hiding that pushed the Linux pipelines to xorriso
# does not affect this one. plutil (also built in) parses/validates the JSON.

set -euo pipefail

# Operate from the pipeline directory (this script lives in seed/).
cd "$(dirname "$0")/.."

REPO_ROOT="$(cd ../.. && pwd)"
DEFAULT_USERNAME="admin"
DEFAULT_HOSTNAME="windows"
DEFAULT_ENV_FILE="${REPO_ROOT}/.env.windows-vms"

# ---- argument parsing -------------------------------------------------------

SEED=""
OUTPUT_PATH=""
ENV_FILE=""
declare -a EXPLICIT_KEY_FILES=()

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: -i requires a path argument" >&2; exit 1; }
      EXPLICIT_KEY_FILES+=("$1")
      ;;
    -o)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: -o requires a path argument" >&2; exit 1; }
      OUTPUT_PATH="$1"
      ;;
    --env) ENV_FILE="$DEFAULT_ENV_FILE" ;;
    --env=*) ENV_FILE="${1#--env=}" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      [[ -z "$SEED" ]] || { echo "ERROR: only one seed path may be passed" >&2; exit 1; }
      SEED="$1"
      ;;
  esac
  shift
done

# Default to seed/lab-seed.json only if it exists; otherwise synthesize a
# seed from defaults (zero-config path — no file needed at all).
if [[ -z "$SEED" && -f seed/lab-seed.json ]]; then
  SEED="seed/lab-seed.json"
fi
if [[ -n "$SEED" && ! -f "$SEED" ]]; then
  echo "ERROR: ${SEED} not found." >&2
  echo "       Pass a seed JSON, or run with no args for the defaults" >&2
  echo "       (user '${DEFAULT_USERNAME}', auto ~/.ssh/id_*.pub keys)." >&2
  exit 1
fi

for c in plutil hdiutil ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c not on PATH" >&2; exit 1; }
done

if [[ -n "$SEED" ]] && ! plutil -convert json -o /dev/null "$SEED" >/dev/null 2>&1; then
  echo "ERROR: ${SEED} is not valid JSON. Check: plutil -convert json -o /dev/null ${SEED}" >&2
  exit 1
fi

# ---- read fields from the seed (empty if absent) ----------------------------

seed_get() {  # seed_get <keypath> <fmt>  — echoes value or nothing
  [[ -n "$SEED" ]] || return 0
  plutil -extract "$1" "${2:-raw}" -o - "$SEED" 2>/dev/null || true
}

USERNAME="$(seed_get username raw)"; USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
HOSTNAME_VAL="$(seed_get hostname raw)"; HOSTNAME_VAL="${HOSTNAME_VAL:-$DEFAULT_HOSTNAME}"
PASSWORD="$(seed_get password raw)"
GROUPS_JSON="$(seed_get groups json)"; GROUPS_JSON="${GROUPS_JSON:-[\"Administrators\"]}"

# A Windows account needs a password (console/RDP). If the seed omits one,
# generate a strong random password and print it below. The suffix guarantees
# the upper/lower/digit/symbol complexity Windows wants regardless of what the
# random base64 happens to contain.
PW_GENERATED=0
if [[ -z "$PASSWORD" ]]; then
  command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl needed to generate a default password" >&2; exit 1; }
  PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c1-16)-Aa9!"
  PW_GENERATED=1
fi

# ---- collect + validate SSH keys --------------------------------------------

declare -a KEYS=()
declare -a SEEN=()

is_ssh_algo() {
  case "$1" in
    ssh-rsa|ssh-ed25519|ssh-dss) return 0 ;;
    ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) return 0 ;;
    sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) return 0 ;;
  esac
  return 1
}

add_key() {  # add_key <key-line> <source>
  local key="$1" source="$2" f1 f2 _
  read -r f1 f2 _ <<<"$key" || true
  if ! is_ssh_algo "$f1"; then
    echo "ERROR: SSH key from ${source} doesn't start with a known algorithm: ${key}" >&2
    exit 1
  fi
  if is_ssh_algo "$f2"; then
    echo "ERROR: SSH key from ${source} has a duplicated algorithm prefix: ${key}" >&2
    exit 1
  fi
  if ! ssh-keygen -l -f <(printf '%s\n' "$key") >/dev/null 2>&1; then
    echo "ERROR: invalid SSH public key from ${source}: ${key}" >&2
    exit 1
  fi
  local token="$f1 $f2" t
  for t in "${SEEN[@]:-}"; do [[ "$t" == "$token" ]] && return 0; done
  SEEN+=("$token")
  KEYS+=("$key")
}

# (a) keys already in the seed's ssh_authorized_keys array
if [[ -n "$SEED" ]]; then
  i=0
  while k="$(plutil -extract "ssh_authorized_keys.$i" raw -o - "$SEED" 2>/dev/null)"; do
    [[ -n "$k" ]] && add_key "$k" "${SEED} (entry #$((i+1)))"
    i=$((i+1))
  done
fi

# (b) external keys: explicit -i wins; else auto-detect ~/.ssh/id_*.pub
declare -a EXTRA_KEY_FILES=()
EXTRA_SOURCE=""
if [[ ${#EXPLICIT_KEY_FILES[@]} -gt 0 ]]; then
  EXTRA_KEY_FILES=("${EXPLICIT_KEY_FILES[@]}")
  EXTRA_SOURCE="explicit (-i)"
else
  shopt -s nullglob
  for k in "${HOME}/.ssh/"id_*.pub; do EXTRA_KEY_FILES+=("$k"); done
  shopt -u nullglob
  EXTRA_SOURCE="auto-detected from ${HOME}/.ssh/"
fi

if [[ ${#EXTRA_KEY_FILES[@]} -gt 0 ]]; then
  echo "==> SSH key sources: ${EXTRA_SOURCE}"
  for keyfile in "${EXTRA_KEY_FILES[@]}"; do
    [[ -f "$keyfile" ]] || { echo "ERROR: SSH key file not found: $keyfile" >&2; exit 1; }
    if [[ "$keyfile" != *.pub ]]; then
      echo "ERROR: '$keyfile' does not end in .pub — refusing to inject (pass the public half)." >&2
      exit 1
    fi
    if grep -qE -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$keyfile"; then
      echo "ERROR: '$keyfile' contains a PRIVATE KEY block — refusing to inject." >&2
      exit 1
    fi
    while IFS= read -r raw; do
      key="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -z "$key" || "$key" == \#* ]] && continue
      before=${#KEYS[@]}
      add_key "$key" "$keyfile"
      if [[ ${#KEYS[@]} -gt $before ]]; then
        echo "    + ${keyfile##*/}"
      else
        echo "    = ${keyfile##*/} (already present — skipped)"
      fi
    done <<<"$(cat "$keyfile")"
  done
fi

# ---- assemble the final windows-seed.json -----------------------------------

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

KEYS_JSON="["
for idx in "${!KEYS[@]}"; do
  KEYS_JSON+="\"$(json_escape "${KEYS[$idx]}")\""
  [[ $idx -lt $((${#KEYS[@]} - 1)) ]] && KEYS_JSON+=","
done
KEYS_JSON+="]"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SEED_OUT="${WORK}/windows-seed.json"

{
  printf '{\n'
  printf '  "hostname": "%s",\n' "$(json_escape "$HOSTNAME_VAL")"
  printf '  "username": "%s",\n' "$(json_escape "$USERNAME")"
  printf '  "password": "%s",\n' "$(json_escape "$PASSWORD")"
  printf '  "groups": %s,\n' "$GROUPS_JSON"
  printf '  "ssh_authorized_keys": %s\n' "$KEYS_JSON"
  printf '}\n'
} > "$SEED_OUT"

plutil -convert json -o /dev/null "$SEED_OUT" || {
  echo "ERROR: assembled windows-seed.json is not valid JSON (internal error)." >&2
  echo "       Dumping it for diagnosis:" >&2
  cat "$SEED_OUT" >&2
  exit 1
}

echo "==> seed: user '${USERNAME}', hostname '${HOSTNAME_VAL}', ${#KEYS[@]} SSH key(s)"
if [[ "$PW_GENERATED" -eq 1 ]]; then
  if [[ -n "$ENV_FILE" ]]; then
    # Write the generated password to an env file instead of stdout. Env-var
    # name is derived from the hostname so multiple instances stay distinct.
    token="$(printf '%s' "$HOSTNAME_VAL" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    token="${token%_}"
    if [[ ! -f "$ENV_FILE" ]]; then : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; fi
    {
      printf '# %s / %s — generated by build-cidata.sh\n' "$HOSTNAME_VAL" "$USERNAME"
      printf "WINVM_%s_PASSWORD='%s'\n" "$token" "$PASSWORD"
    } >> "$ENV_FILE"
    echo "==> generated ${USERNAME} password -> ${ENV_FILE} (WINVM_${token}_PASSWORD)"
  else
    echo "==> generated ${USERNAME} password: ${PASSWORD}"
    echo "    (set \"password\" in the seed to choose your own; SSH keys work too)"
  fi
else
  echo "==> ${USERNAME} password: taken from the seed"
fi
if [[ ${#KEYS[@]} -eq 0 ]]; then
  echo "    no SSH keys injected — log in with the password (RDP/console)."
fi

# ---- build the ISO ----------------------------------------------------------

if [[ -n "$OUTPUT_PATH" ]]; then
  OUT="$OUTPUT_PATH"; mkdir -p "$(dirname "$OUT")"
else
  OUT="output-cidata/cidata.iso"; mkdir -p output-cidata
fi
rm -f "$OUT"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name CIDATA -o "$OUT" "$WORK"

case "$OUT" in /*) OUT_ABS="$OUT" ;; *) OUT_ABS="$(pwd)/$OUT" ;; esac
echo "Wrote ${OUT_ABS}"
echo
echo "Next: boot a clone with this CD attached, then:  ssh ${USERNAME}@<vm>"
echo "      (or just: just run-windows --seed ${SEED:-<seed.json>})"
