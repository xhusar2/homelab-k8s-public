# TAK Server (Kubernetes)

Runs [pvarki/docker-atak-server](https://github.com/pvarki/docker-atak-server) layout: PostGIS `StatefulSet`, shared Longhorn volume for `/opt/tak/data`, init `firstrun`, then **config / messaging / api / retention / pluginmanager** in one `Deployment` pod (shared network namespace, same as Docker Compose `network_mode: service:takserver_config`).

## Before Argo CD sync

Create secrets **once** in namespace `tak` (not stored in git):

```bash
kubectl create namespace tak --dry-run=client -o yaml | kubectl apply -f -

kubectl -n tak create secret generic tak-server-secrets \
  --from-literal=POSTGRES_PASSWORD='REPLACE_WITH_STRONG_DB_PASSWORD' \
  --from-literal=ADMIN_CERT_PASS='REPLACE_ADMIN_PKCS12_PASSWORD' \
  --from-literal=TAKSERVER_CERT_PASS='REPLACE_SERVER_CERT_PASSWORD' \
  --from-literal=CA_PASS='REPLACE_CA_PASSWORD'
```

Edit `configmap.yml` if needed:

- `TAK_SERVER_ADDRESS` / `TAK_SERVER_NAME` — must match what clients use (DNS or node IP + NodePort is not enough for hostname checks; use real DNS or IP as appropriate for your CA / enrollment flow).

## Client access

- **ClusterIP** `tak-server.tak.svc`: ports `8089`, `8443`, `8444`, `8446`, `8080`.
- **NodePort** `tak-server-external`: `31889` → 8089, `32443` → 8443 (Argo CD already uses `30443` in this repo; change these if they clash elsewhere).

| Port | Use |
|------|-----|
| `8089` | SSL streaming (COT, position/events) |
| `8443` | HTTPS Marti API — **mission/data package upload**, cert tooling, admin |

Internet path via edge-gateway: publish **both** `8089` and `8443` on the VPS (`vps-forward.sh` + `edge-gateway` `forwards`). Streaming alone is not enough for package push.

HTTP `Ingress` to port 8443 is **not** included: ATAK expects TLS on those ports; use NodePort, LoadBalancer, edge-gateway, or Traefik **TCP** `IngressRoute` with TLS passthrough if you front it with Traefik.

## Image / version

Default image: `ghcr.io/pvarki/takserver:5.7-RELEASE-8`. Bump the tag in `deployment.yml` when you want a newer pvarki build.

## Legal / distribution

TAK Server is subject to BAA / export controls. Use only images and binaries you are entitled to run. The pvarki image is a community packaging; verify terms for your environment.

## Troubleshooting

- First sync fails on missing `Secret`: create `tak-server-secrets` as above.
- Pod stays `Init:0/2`: check Postgres pod logs; confirm Longhorn volumes bind.
- Re-run from scratch: delete the `tak-server` Deployment and both PVCs (Postgres `StatefulSet` PVC + `tak-server-data-longhorn-pvc`) — **data loss**.
