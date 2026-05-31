#!/usr/bin/env bash
# sync-portfolio.sh — Copy private homelab GitOps into this public portfolio tree and scrub PII.
#
# Typical flow:
#   export PRIVATE_SRC=~/Code/homelab/homelab-k8s-public
#   ./scripts/sync-portfolio.sh --dry-run
#   ./scripts/sync-portfolio.sh
#   ./scripts/sync-portfolio.sh --verify   # fail if scrub patterns remain
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PRIVATE_SRC="${PRIVATE_SRC:-${HOME}/Code/homelab/homelab-k8s-public}"
PUBLIC_DEST="${PUBLIC_DEST:-${REPO_ROOT}}"
CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/config/sync-portfolio.conf}"

DRY_RUN=0
VERIFY_ONLY=0
RSYNC_DELETE=0
VERBOSE=0

log()  { printf '[sync-portfolio] %s\n' "$*" >&2; }
warn() { printf '[sync-portfolio] WARN: %s\n' "$*" >&2; }
die()  { printf '[sync-portfolio] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sync-portfolio.sh [OPTIONS]

Sync private homelab configuration into the public portfolio repository and
replace domains, accounts, and LAN IPs with uppercase placeholders.

Options:
  -n, --dry-run       Show rsync/scrub actions without writing
  -v, --verbose       Trace shell and print each scrub replacement
  -d, --delete        Pass --delete to rsync (remove dest files absent in source)
      --verify        After sync, exit non-zero if forbidden patterns remain
  -h, --help          Show this help

Environment:
  PRIVATE_SRC         Source tree (default: ~/Code/homelab/homelab-k8s-public)
  PUBLIC_DEST         Destination tree (default: repository root)
  CONFIG_FILE         Scrub rules file (default: config/sync-portfolio.conf)

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -d|--delete) RSYNC_DELETE=1; shift ;;
    --verify) VERIFY_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

if [[ ! -f "${CONFIG_FILE}" ]]; then
  die "Missing scrub config: ${CONFIG_FILE} (copy config/sync-portfolio.conf.example)"
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${RSYNC_EXCLUDES:?RSYNC_EXCLUDES must be set in CONFIG_FILE}"
: "${SCRUB_RULES:?SCRUB_RULES must be set in CONFIG_FILE}"
: "${FORBIDDEN_PATTERNS:?FORBIDDEN_PATTERNS must be set in CONFIG_FILE}"

if [[ "${VERBOSE}" -eq 1 ]]; then
  set -x
fi

# Pairs sorted longest-from-first so jellyfin.example.com wins over example.com.
declare -a SCRUB_FROM=() SCRUB_TO=()

load_scrub_rules() {
  local line from to
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    from="${line%%|*}"
    to="${line#*|}"
    [[ "${from}" == "${line}" ]] && die "Invalid scrub rule (expected FROM|TO): ${line}"
    SCRUB_FROM+=("${from}")
    SCRUB_TO+=("${to}")
  done <<< "${SCRUB_RULES}"

  local -a order=()
  local i j tmp len_i len_j
  for i in "${!SCRUB_FROM[@]}"; do order+=("${i}"); done
  for ((i = 0; i < ${#order[@]}; i++)); do
    for ((j = i + 1; j < ${#order[@]}; j++)); do
      len_i="${#SCRUB_FROM[order[i]]}"
      len_j="${#SCRUB_FROM[order[j]]}"
      if (( len_j > len_i )); then
        tmp="${order[i]}"
        order[i]="${order[j]}"
        order[j]="${tmp}"
      fi
    done
  done

  local -a sf=() st=()
  for i in "${order[@]}"; do
    sf+=("${SCRUB_FROM[i]}")
    st+=("${SCRUB_TO[i]}")
  done
  SCRUB_FROM=("${sf[@]}")
  SCRUB_TO=("${st[@]}")
}

escape_sed_literal() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'
}

load_scrub_rules

should_scrub_file() {
  local file="$1"
  case "${file}" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.zip|*.tar|*.gz|*.tgz|*.bin|*.p12|*.pem|*.key)
      return 1
      ;;
  esac
  return 0
}

scrub_file() {
  local file="$1"
  local i escaped expr
  for i in "${!SCRUB_FROM[@]}"; do
    escaped="$(escape_sed_literal "${SCRUB_FROM[i]}")"
    expr="s|${escaped}|${SCRUB_TO[i]}|g"
    sed -i -e "${expr}" "${file}" 2>/dev/null \
      || sed -i '' -e "${expr}" "${file}" 2>/dev/null \
      || return 1
  done
}

scrub_tree() {
  local root="$1"
  local file

  while IFS= read -r -d '' file; do
    should_scrub_file "${file}" || continue
    if ! grep -Iq . "${file}" 2>/dev/null; then
      continue
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "would scrub: ${file#"${root}/"}"
      continue
    fi
    scrub_file "${file}" || warn "scrub skipped: ${file}"
    [[ "${VERBOSE}" -eq 1 ]] && log "scrubbed: ${file#"${root}/"}"
  done < <(find "${root}" -type f \
    ! -path '*/.git/*' \
    ! -path '*/environments/local/*' \
    -print0)
}

apply_path_remap() {
  # Legacy private repos may still use charts-and-manifests/
  local src="${PUBLIC_DEST}/charts-and-manifests"
  local dst="${PUBLIC_DEST}/charts"
  if [[ -d "${src}" && ! -d "${dst}" ]]; then
    log "remap: charts-and-manifests -> charts"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "would mv ${src} ${dst}"
    else
      mv "${src}" "${dst}"
    fi
  fi
}

run_rsync() {
  local -a excludes=()
  local item
  while IFS= read -r item || [[ -n "${item}" ]]; do
    [[ -z "${item}" || "${item}" =~ ^[[:space:]]*# ]] && continue
    excludes+=(--exclude "${item}")
  done <<< "${RSYNC_EXCLUDES}"

  local -a rsync_args=(
    -a
    --human-readable
    --info=stats2,name
    "${excludes[@]}"
  )

  [[ "${RSYNC_DELETE}" -eq 1 ]] && rsync_args+=(--delete)
  [[ "${DRY_RUN}" -eq 1 ]] && rsync_args+=(--dry-run)

  log "rsync ${PRIVATE_SRC}/ -> ${PUBLIC_DEST}/"
  rsync "${rsync_args[@]}" "${PRIVATE_SRC}/" "${PUBLIC_DEST}/"
}

verify_scrub() {
  local pattern line hit=0
  local -a scan_roots=(apps bootstrap charts platform config docs scripts)
  local root tmp
  tmp="$(mktemp)"

  while IFS= read -r pattern || [[ -n "${pattern}" ]]; do
    [[ -z "${pattern}" || "${pattern}" =~ ^[[:space:]]*# ]] && continue
    for root in "${scan_roots[@]}"; do
      [[ -d "${PUBLIC_DEST}/${root}" ]] || continue
      if grep -RIn --exclude-dir=.git \
        --exclude='sync-portfolio.conf' \
        --exclude='sync-portfolio.conf.example' \
        -E "${pattern}" "${PUBLIC_DEST}/${root}" >"${tmp}" 2>/dev/null; then
        warn "forbidden pattern still present (${pattern}):"
        sed 's/^/  /' "${tmp}" >&2
        hit=1
      fi
    done
  done <<< "${FORBIDDEN_PATTERNS}"

  rm -f "${tmp}"
  [[ "${hit}" -eq 0 ]] || die "verify failed — scrub or extend SCRUB_RULES in ${CONFIG_FILE}"
  log "verify OK"
}

main() {
  if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
    verify_scrub
    exit 0
  fi

  if [[ ! -d "${PRIVATE_SRC}" ]]; then
    cat >&2 <<EOF
[sync-portfolio] ERROR: PRIVATE_SRC not found: ${PRIVATE_SRC}

This repo is the public portfolio destination. Create a separate private clone
for real domains, LAN IPs, and secrets, then sync into here:

  git clone git@github.com:YOUR_USER/homelab-k8s.git ${HOME}/Code/homelab/homelab-k8s-public
  # edit real values in homelab-k8s-public only
  export PRIVATE_SRC=${HOME}/Code/homelab/homelab-k8s-public
  export PUBLIC_DEST=${REPO_ROOT}
  ./scripts/sync-portfolio.sh

Or one-shot scrub without a second clone (source = this tree, dest = new folder):

  export PRIVATE_SRC=${REPO_ROOT}
  export PUBLIC_DEST=${HOME}/Code/homelab/homelab-k8s-portfolio
  ./scripts/sync-portfolio.sh --dry-run

EOF
    exit 1
  fi

  command -v rsync >/dev/null || die "rsync is required"
  command -v sed >/dev/null || die "sed is required"

  run_rsync
  apply_path_remap
  scrub_tree "${PUBLIC_DEST}"
  verify_scrub
  log "done → ${PUBLIC_DEST}"
}

main "$@"
