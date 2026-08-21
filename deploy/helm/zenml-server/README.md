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

## Secrets

Copy the example secrets file and restrict its permissions before the first
install:

```bash
cp deploy/helm/zenml-server/secrets.yaml.example deploy/helm/zenml-server/secrets.yaml
chmod 600 deploy/helm/zenml-server/secrets.yaml
```

Leave `database.password` and `database.rootPassword` empty to auto-generate
credentials on first install. Existing cluster Secrets are preserved on later
upgrades even when these fields stay empty.

You can also supply passwords through `deployment.env` (`ZENML_DB_PASSWORD`
and `ZENML_DB_ROOT_PASSWORD`), which override the chart secrets file at
install time.
