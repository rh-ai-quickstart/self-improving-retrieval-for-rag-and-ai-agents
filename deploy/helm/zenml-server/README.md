# zenml-server Helm chart

Umbrella chart for Phase 1 server infrastructure:

- Upstream [ZenML](https://zenml.io/) server (OCI subchart)
- [Bitnami MySQL](https://github.com/bitnami/charts/tree/main/bitnami/mysql) for persistent metadata storage
- OpenShift Route for HTTPS access
- Database credential Secret wired into the ZenML server

Install via the repository bootstrap script:

```bash
make bootstrap-server
```

Before the first install, chart dependencies are built automatically:

```bash
helm dependency build deploy/helm/zenml-server
```

Key values are supplied from `deployment.env` by
`scripts/deploy_zenml_on_os.sh`.
