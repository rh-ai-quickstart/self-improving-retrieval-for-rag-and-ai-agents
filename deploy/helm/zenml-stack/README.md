# zenml-stack Helm chart

Provisions the OpenShift workload infrastructure for the ZenML remote stack:

- Orchestrator service account and RBAC
- KServe deployment permissions
- MinIO artifact store (PVC, Deployment, Service, Route, bootstrap Job)
- Optional cluster-scoped MLflow CR and integration RoleBinding
- OpenShift ImageStream for pipeline images

Install via the repository bootstrap script:

```bash
make bootstrap-stack
```

Or directly:

```bash
helm upgrade --install zenml-stack deploy/helm/zenml-stack \
  --namespace zenml-workloads \
  --create-namespace \
  -f deploy/helm/zenml-stack/secrets.yaml \
  --wait
```

ZenML component registration still runs as a post-install script step because it
requires the local ZenML CLI and Docker.

## Secrets

Copy the example secrets file and restrict its permissions before the first
install:

```bash
cp deploy/helm/zenml-stack/secrets.yaml.example deploy/helm/zenml-stack/secrets.yaml
chmod 600 deploy/helm/zenml-stack/secrets.yaml
```

Leave `minio.rootPassword` empty to auto-generate credentials on first
install. Existing cluster Secrets are preserved on later upgrades even when
this field stays empty.

Registry pull credentials are normally refreshed post-install by
`make refresh-stack-credentials`. Set `registry.createPullSecret`,
`registry.dockerServer`, and `registry.dockerPassword` only when you want Helm
to create the pull Secret during chart install.

You can also supply `MINIO_ROOT_PASSWORD` through `deployment.env`, which
overrides the chart secrets file at install time.
