# Bootstrap

Cluster-level install artifacts live here: Argo CD install manifests, `AppProject` definitions, repository credentials templates, and optional **app-of-apps** roots.

Recommended order:

1. Install K3s / Kubernetes and storage (Longhorn, etc.).
2. Install Argo CD into `argocd` namespace.
3. Apply `apps/` (or a single bootstrap Application that points at `apps/`).
4. Configure private `environments/local/` values on the cluster side.

This public portfolio intentionally omits bootstrap secrets and kubeconfig material.
