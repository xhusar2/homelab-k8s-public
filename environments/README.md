# Environment overlays (private)

This directory holds **cluster-specific values** that must not appear in the public portfolio repository.

## Layout

```text
environments/
└── local/                    # gitignored — your live cluster
    ├── kustomization.yaml    # optional overlay root
    └── monitoring/
        └── kube-prometheus-stack-values.yaml
```

## Workflow

1. Keep reusable manifests under `charts/` and Argo CD apps under `apps/`.
2. Copy sanitized examples from `config/examples/` into `environments/local/`.
3. Point private Argo CD `Application` specs at `environments/local/...` (private repo) or use a second Git source ref.
4. Publish to GitHub with `./scripts/sync-portfolio.sh` — the script never copies `environments/local/`.

## Argo CD multi-source pattern

Public repo (this tree) supplies chart paths; a private fork or `ref: values` branch supplies:

```yaml
valueFiles:
  - $values/environments/local/monitoring/kube-prometheus-stack-values.yaml
```

Replace placeholders in examples before applying to your cluster.
