# Example configuration

Sanitized Helm values and environment-specific settings safe for a **public** repository.

Copy files into `environments/local/` on your private clone and substitute real hostnames, storage sizes, and resource limits.

```bash
mkdir -p environments/local/monitoring
cp config/examples/monitoring/kube-prometheus-stack-values.yaml \
   environments/local/monitoring/
```

Argo CD public apps reference `config/examples/`; private clusters should override paths in a private `apps/` fork or patch via Kustomize.
