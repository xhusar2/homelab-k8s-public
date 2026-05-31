# Platform services

Shared cluster capabilities (ingress controllers, cert-manager, monitoring operators, policy engines) can be grouped under `platform/` as the fleet grows.

Today, platform manifests live alongside application charts:

| Concern | Location |
|--------|----------|
| Prometheus / Grafana stack | `charts/monitoring/` + `config/examples/monitoring/` |
| Argo CD exposure | `charts/argocd/` |

Migrate operators here when you split application charts from platform lifecycle and upgrade cadence.
