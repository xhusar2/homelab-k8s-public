#!/usr/bin/env bash
# Generate TAK client cert bundle for ATAK via SSH → node kubectl → tak-api pod.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${TAK_CONFIG:-${SCRIPT_DIR}/tak-client-cert.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a && source "$CONFIG_FILE" && set +a
fi

usage() {
  cat <<EOF
Usage: tak-client-cert.sh [options] <client-name>

Creates a non-admin client cert on the TAK server and downloads <client-name>.p12.

Configuration (first match wins): CLI flags > environment > ${CONFIG_FILE}

Required (env or flags):
  TAK_SSH_HOST / -H     SSH host for the k8s node
  TAK_SSH_USER / -u     SSH user
  TAK_SERVER / -s       TAK server address (written to bundle README)

Client PKCS12 password:
  TAK_CLIENT_PASS       From env file, or use -p to prompt (recommended if unset)

Optional:
  -o DIR               Output directory (default: script directory)
  -g GROUPS            certmod groups, space-separated (default: TAK_CERT_GROUPS or __ANON__)
  -p, --prompt-pass    Prompt for client PKCS12 password
  -h, --help           Show this help

Environment:
  TAK_CONFIG            Path to env file (default: scripts/tak-client-cert.env)
  TAK_CERT_GROUPS       Groups for certmod -g (default: __ANON__)
  TAK_NAMESPACE         k8s namespace (default: tak)
  TAK_DEPLOY            Deployment name (default: tak-server)
  TAK_CONTAINER         Container name (default: tak-api)
  TAK_SECRET_NAME       Secret with CA_PASS (default: tak-server-secrets)
  TAK_SSH_OPTS          Extra ssh -o options (space-separated)
  TAK_KUBECONFIG        kubeconfig path on the remote node
  TAK_KUBECTL           kubectl command on the remote node

Setup: cp scripts/tak-client-cert.env.example scripts/tak-client-cert.env

Requires: ssh to the k8s node, kubectl on the node, openssl in tak-api.
EOF
}

SSH_HOST="${TAK_SSH_HOST:-}"
SSH_USER="${TAK_SSH_USER:-}"
NAMESPACE="${TAK_NAMESPACE:-tak}"
DEPLOY="${TAK_DEPLOY:-tak-server}"
CONTAINER="${TAK_CONTAINER:-tak-api}"
SECRET_NAME="${TAK_SECRET_NAME:-tak-server-secrets}"
CERT_GROUPS="${TAK_CERT_GROUPS:-__ANON__}"
OUT_DIR="$SCRIPT_DIR"
SERVER_ADDR="${TAK_SERVER:-}"
CLIENT_PASS="${TAK_CLIENT_PASS:-}"
PROMPT_CLIENT_PASS=false
CLIENT_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT_DIR="$2"; shift 2 ;;
    -H) SSH_HOST="$2"; shift 2 ;;
    -u) SSH_USER="$2"; shift 2 ;;
    -s) SERVER_ADDR="$2"; shift 2 ;;
    -g) CERT_GROUPS="$2"; shift 2 ;;
    -p | --prompt-pass) PROMPT_CLIENT_PASS=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$CLIENT_NAME" ]]; then
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      CLIENT_NAME="$1"
      shift
      ;;
  esac
done

[[ -n "$CLIENT_NAME" ]] || {
  usage
  exit 1
}
[[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || {
  echo "Invalid client name: $CLIENT_NAME" >&2
  exit 1
}

missing=()
[[ -n "$SSH_HOST" ]] || missing+=("TAK_SSH_HOST (or -H)")
[[ -n "$SSH_USER" ]] || missing+=("TAK_SSH_USER (or -u)")
[[ -n "$SERVER_ADDR" ]] || missing+=("TAK_SERVER (or -s)")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing required configuration:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Copy scripts/tak-client-cert.env.example to scripts/tak-client-cert.env" >&2
  exit 1
fi

if $PROMPT_CLIENT_PASS || [[ -z "$CLIENT_PASS" ]]; then
  read -r -s -p "Client PKCS12 password: " CLIENT_PASS
  echo
  [[ -n "$CLIENT_PASS" ]] || {
    echo "Empty password" >&2
    exit 1
  }
fi

mkdir -p "$OUT_DIR"
BUNDLE_DIR="$OUT_DIR/${CLIENT_NAME}-atak-bundle"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SSH_TARGET="${SSH_USER}@${SSH_HOST}"
CLIENT_PASS_B64="$(printf '%s' "$CLIENT_PASS" | base64 -w0 2>/dev/null || printf '%s' "$CLIENT_PASS" | base64)"

# shellcheck disable=SC2206
SSH_EXTRA_OPTS=(${TAK_SSH_OPTS:-})
SSH_CMD=(ssh "${SSH_EXTRA_OPTS[@]}" "$SSH_TARGET")

echo "==> Connecting to ${SSH_TARGET} — generating cert '${CLIENT_NAME}'"

REMOTE_LOG="$WORK_DIR/remote.log"
REMOTE_OUT="$WORK_DIR/remote.out"

if ! "${SSH_CMD[@]}" env TAK_KUBECTL="${TAK_KUBECTL:-}" TAK_KUBECONFIG="${TAK_KUBECONFIG:-}" bash -s -- \
  "$NAMESPACE" "$DEPLOY" "$CONTAINER" "$SECRET_NAME" "$CLIENT_NAME" "$CLIENT_PASS_B64" "$CERT_GROUPS" \
  >"$REMOTE_OUT" 2>"$REMOTE_LOG" <<'REMOTE'
set -euo pipefail

NS="$1"
DEPLOY="$2"
CONT="$3"
SECRET_NAME="$4"
NAME="$5"
CLIENT_PASS_B64="$6"
CERT_GROUPS="$7"

CLIENT_PASS="$(printf '%s' "$CLIENT_PASS_B64" | base64 -d)"
CERTS_DIR="/opt/tak/certs"
FILES_DIR="${CERTS_DIR}/files"

b64enc() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64; }

resolve_kubectl() {
  if [[ -n "${TAK_KUBECTL:-}" ]]; then
    read -r -a KUBECTL <<<"$TAK_KUBECTL"
  else
    KUBECTL=(kubectl)
  fi

  if [[ -n "${TAK_KUBECONFIG:-}" ]]; then
    export KUBECONFIG="$TAK_KUBECONFIG"
    return
  fi

  local cfg candidates=()
  [[ -n "${KUBECONFIG:-}" ]] && candidates+=("$KUBECONFIG")
  candidates+=("$HOME/.kube/config")
  [[ -r /etc/rancher/k3s/k3s.yaml ]] && candidates+=("/etc/rancher/k3s/k3s.yaml")

  for cfg in "${candidates[@]}"; do
    [[ -r "$cfg" ]] || continue
    if KUBECONFIG="$cfg" "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
      export KUBECONFIG="$cfg"
      return
    fi
  done

  if "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
    return
  fi

  echo "ERROR: kubectl not usable on node (no readable kubeconfig?)" >&2
  echo "On the node (one-time, as admin), install kubeconfig for ${USER:-$(whoami)}:" >&2
  echo "  mkdir -p ~/.kube" >&2
  echo "  k3s kubectl config view --raw > ~/.kube/config && chmod 600 ~/.kube/config" >&2
  echo "Or: export TAK_KUBECONFIG=/path/to/kubeconfig" >&2
  exit 10
}

resolve_kubectl
echo "==> Using kubectl: ${KUBECTL[*]} (KUBECONFIG=${KUBECONFIG:-default})" >&2
KEXEC=("${KUBECTL[@]}" exec "deploy/${DEPLOY}" -c "${CONT}" -n "${NS}" --)

CAPASS="$("${KUBECTL[@]}" get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.CA_PASS}' | base64 -d)"
CAPASS_B64="$(b64enc "$CAPASS")"

echo "==> Checking for existing cert '${NAME}'..." >&2
for f in "${NAME}.p12" "${NAME}-public.p12" "${NAME}.pem"; do
  if "${KEXEC[@]}" test -f "${FILES_DIR}/${f}" 2>/dev/null; then
    echo "ERROR: cert already exists: ${FILES_DIR}/${f}" >&2
    echo "Remove it in the pod or pick another client name." >&2
    exit 2
  fi
done

echo "==> Creating client cert '${NAME}' (groups: ${CERT_GROUPS})..." >&2
"${KEXEC[@]}" env CAPASS_B64="$CAPASS_B64" CLIENT_PASS_B64="$CLIENT_PASS_B64" NAME="$NAME" \
  CERT_GROUPS="$CERT_GROUPS" bash -lc '
    set -euo pipefail
    CAPASS="$(printf "%s" "$CAPASS_B64" | base64 -d)"
    CLIENT_PASS="$(printf "%s" "$CLIENT_PASS_B64" | base64 -d)"
    cd /opt/tak/certs
    export CAPASS PASS="$CLIENT_PASS"
    ./makeCert.sh client "$NAME"
    pem="/opt/tak/certs/files/${NAME}.pem"
    if [[ ! -f "$pem" ]]; then
      echo "ERROR: expected PEM after makeCert: $pem" >&2
      exit 5
    fi
    group_args=()
    for group in $CERT_GROUPS; do
      group_args+=(-g "$group")
    done
    java -jar /opt/tak/utils/UserManager.jar certmod "${group_args[@]}" "$pem"
  '

modernize_p12() {
  local src="$1" in_pass_b64="$2" out_pass="$3" tmp_label="$4"
  "${KEXEC[@]}" env SRC="$src" IN_PASS_B64="$in_pass_b64" OUT_PASS="$out_pass" TMP_LABEL="$tmp_label" \
    bash -lc '
      set -euo pipefail
      IN_PASS="$(printf "%s" "$IN_PASS_B64" | base64 -d)"
      tmp="$(mktemp)"
      openssl pkcs12 -in "$SRC" -out "${tmp}.pem" -nodes -legacy -passin pass:"${IN_PASS}"
      openssl pkcs12 -export -in "${tmp}.pem" -out "/tmp/${TMP_LABEL}.p12" -passout pass:"${OUT_PASS}"
      rm -f "${tmp}.pem"
      base64 -w0 "/tmp/${TMP_LABEL}.p12" 2>/dev/null || base64 "/tmp/${TMP_LABEL}.p12" | tr -d "\n"
      rm -f "/tmp/${TMP_LABEL}.p12"
    '
}

CLIENT_SRC="${FILES_DIR}/${NAME}.p12"
if ! "${KEXEC[@]}" test -f "$CLIENT_SRC" 2>/dev/null; then
  echo "ERROR: expected client cert missing: ${CLIENT_SRC}" >&2
  exit 4
fi

echo "==> Repacking client cert for ATAK..." >&2
echo "@@CLIENT_BEGIN@@"
modernize_p12 "$CLIENT_SRC" "$CLIENT_PASS_B64" "$CLIENT_PASS" "client-modern"
echo
echo "@@CLIENT_END@@"

echo "==> Done on cluster." >&2
REMOTE
then
  cat "$REMOTE_LOG" >&2
  exit 1
fi

if [[ -s "$REMOTE_LOG" ]]; then
  grep -v '^$' "$REMOTE_LOG" >&2 || true
fi

extract_block() {
  local begin_marker="$1" end_marker="$2" dest="$3"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { capture = 1; next }
    $0 == end { capture = 0; next }
    capture { print }
  ' "$REMOTE_OUT" >"$dest"
}

CLIENT_B64="$WORK_DIR/client.b64"
extract_block "@@CLIENT_BEGIN@@" "@@CLIENT_END@@" "$CLIENT_B64"

if [[ ! -s "$CLIENT_B64" ]]; then
  echo "Failed to receive cert data from remote. Remote output:" >&2
  cat "$REMOTE_OUT" >&2
  exit 1
fi

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

base64 -d <"$CLIENT_B64" >"$BUNDLE_DIR/${CLIENT_NAME}.p12"

# README omits password (sensitive); user knows it from env or prompt
cat >"$BUNDLE_DIR/README.txt" <<EOF
TAK ATAK client certificate
===========================
Client name:  ${CLIENT_NAME}
Server:       ${SERVER_ADDR}
Ports:        8089 (SSL streaming), 8443 (HTTPS)
Groups:       ${CERT_GROUPS}

File:
  ${CLIENT_NAME}.p12 — import as client certificate

Use your existing truststore for CA trust.
EOF

echo "==> Bundle ready: $BUNDLE_DIR"
ls -la "$BUNDLE_DIR"
