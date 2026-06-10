#!/usr/bin/env bash
# Build tax_payer and push to homelab registry (matches cronjob.yml).
set -euo pipefail

REGISTRY="${REGISTRY:-LAN_IP_OCTET_PLACEHOLDER0.10:32000}"
IMAGE="${IMAGE:-tax-payer:local}"
APP_DIR="${APP_DIR:-.}"
NAMESPACE="${NAMESPACE:-default}"
CRONJOB="${CRONJOB:-tax-payer}"
RUN_TEST=false

usage() {
  cat <<'EOF'
Usage: publish-image.sh [options]

Build and push to the in-cluster registry.

Environment:
  REGISTRY    Registry host:port (default: LAN_IP_OCTET_PLACEHOLDER0.10:32000)
  IMAGE       Repo:tag (default: tax-payer:local)
  APP_DIR     Path to tax_payer repo (default: .)
  NAMESPACE   Kubernetes namespace (default: default)
  CRONJOB     CronJob name for --test (default: tax-payer)

Options:
  -h, --help    Show this help
  -t, --test    Push, run one-off Job, print logs

Examples:
  APP_DIR=~/Code/tax_payer ./publish-image.sh
  APP_DIR=~/Code/tax_payer ./publish-image.sh --test
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -t|--test) RUN_TEST=true; shift ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

FULL="${REGISTRY}/${IMAGE}"
echo "==> Building ${FULL} from ${APP_DIR}"
docker build -t "${FULL}" "${APP_DIR}"
echo "==> Pushing ${FULL}"
docker push "${FULL}"

if [[ "$RUN_TEST" == true ]]; then
  JOB="tax-payer-test-$(date +%s)"
  echo "==> Running test job ${JOB}"
  kubectl create job --from="cronjob/${CRONJOB}" "${JOB}" -n "${NAMESPACE}"
  kubectl wait --for=condition=complete "job/${JOB}" -n "${NAMESPACE}" --timeout=300s
  kubectl logs -n "${NAMESPACE}" "job/${JOB}"
  kubectl delete job -n "${NAMESPACE}" "${JOB}"
fi

echo "Done. imagePullPolicy: Always — node re-pulls ${FULL} each run."
