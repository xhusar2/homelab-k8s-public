#!/usr/bin/env bash
# Publish tax_payer:local to the K3s node (build → save → scp → ctr import).
set -euo pipefail

IMAGE="${IMAGE:-tax_payer:local}"
K3S_HOST="${K3S_HOST:-}"
APP_DIR="${APP_DIR:-.}"
NAMESPACE="${NAMESPACE:-default}"
CRONJOB="${CRONJOB:-tax-payer}"
RUN_TEST=false

usage() {
  cat <<'EOF'
Usage: publish-image.sh [options]

Build the Docker image locally, copy it to the K3s master, and import it
into containerd. The CronJob uses imagePullPolicy: Never and tag tax_payer:local.

Environment:
  K3S_HOST    SSH target for the K3s node (required), e.g. LINUX_USER_PLACEHOLDER@LAN_NODE_IP_EXAMPLE
  APP_DIR     Path to the app repo with the Dockerfile (default: .)
  IMAGE       Image tag to build/import (default: tax_payer:local)
  NAMESPACE   Kubernetes namespace (default: default)
  CRONJOB     CronJob name for --test (default: tax-payer)

Options:
  -h, --help    Show this help
  -t, --test    After import, run a one-off Job and print logs

Examples:
  K3S_HOST=user@k3s-master APP_DIR=~/Code/tax_payer ./publish-image.sh
  K3S_HOST=user@k3s-master APP_DIR=~/Code/tax_payer ./publish-image.sh --test
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -t|--test) RUN_TEST=true; shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$K3S_HOST" ]]; then
  echo "K3S_HOST is required (e.g. export K3S_HOST=LINUX_USER_PLACEHOLDER@LAN_NODE_IP_EXAMPLE)" >&2
  exit 1
fi

TAR="$(mktemp "${TMPDIR:-/tmp}/tax_payer-local.XXXXXX.tar")"
cleanup() { rm -f "$TAR"; }
trap cleanup EXIT

echo "==> Building $IMAGE in $APP_DIR"
docker build -t "$IMAGE" "$APP_DIR"

echo "==> Saving image"
docker save "$IMAGE" -o "$TAR"

REMOTE_TAR="/tmp/$(basename "$TAR")"
echo "==> Copying to $K3S_HOST:$REMOTE_TAR"
scp "$TAR" "$K3S_HOST:$REMOTE_TAR"

echo "==> Importing on K3s node"
ssh "$K3S_HOST" "sudo k3s ctr images import $REMOTE_TAR && rm -f $REMOTE_TAR"
ssh "$K3S_HOST" "sudo k3s ctr images ls | grep -F tax_payer || true"

if [[ "$RUN_TEST" == true ]]; then
  JOB="tax-payer-test-$(date +%s)"
  echo "==> Running test job $JOB"
  kubectl create job --from="cronjob/$CRONJOB" "$JOB" -n "$NAMESPACE"
  kubectl wait --for=condition=complete "job/$JOB" -n "$NAMESPACE" --timeout=300s
  kubectl logs -n "$NAMESPACE" "job/$JOB"
  kubectl delete job -n "$NAMESPACE" "$JOB"
fi

echo "Done. Next scheduled CronJob run will use the updated image."
