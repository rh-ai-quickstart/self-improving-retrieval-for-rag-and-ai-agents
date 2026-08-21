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
  --wait
```

ZenML component registration still runs as a post-install script step because it
requires the local ZenML CLI and Docker.
