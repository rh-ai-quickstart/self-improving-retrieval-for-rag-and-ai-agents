# zenml-server Helm chart

Umbrella chart for Phase 1 server infrastructure:

- Upstream [ZenML](https://zenml.io/) server (OCI subchart)
- [Bitnami MySQL](https://github.com/bitnami/charts/tree/main/bitnami/mysql) for persistent metadata storage.
  The subchart (11.1.19) still names `docker.io/bitnami/mysql:8.4.3-debian-12-r0`,
  which Docker Hub removed. This chart overrides the image to
  `docker.io/bitnamilegacy/mysql:8.4.3-debian-12-r0` in `values.yaml` and
  `values-openshift.yaml`. That repository is public; OpenShift does not need
  a pull secret. Do not swap in `registry.redhat.io/rhel8/mysql-80` (the
  `openshift/mysql-persistent` ImageStream image): it is not compatible with
  the Bitnami entrypoint, data directory, probes, or `existingSecret` auth.
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

`make bootstrap-server` installs this chart in two Helm passes:

1. Create Secret `zenml-db-password` in the namespace.
2. `helm upgrade --install` with `zenml.enabled=false` (MySQL only).
3. Wait until Service `zenml-mysql` exists and the StatefulSet is Ready.
4. `helm upgrade` with `zenml.enabled=true` so the ZenML pre-install
   db-migration Job runs after MySQL DNS works.

Do not install ZenML and MySQL in a single Helm pass: the upstream ZenML
chart's db-migration Job is a **pre-install** hook and would run before
the Bitnami MySQL Service exists.

## Secrets

`make bootstrap-server` creates Kubernetes Secret `zenml-db-password` (or
`ZENML_DB_PASSWORD_SECRET`) in the server namespace **before** Helm install.
Bitnami MySQL (`mysql.auth.existingSecret`) and ZenML
(`server.database.passwordSecretRef`) both reference that existing Secret.
The Secret keys are `password` (ZenML `passwordSecretRef`),
`mysql-password` (Bitnami MySQL app user, same value as `password`), and
`mysql-root-password` (MySQL root).

Leave `ZENML_DB_PASSWORD` and `ZENML_DB_ROOT_PASSWORD` empty in
`deployment.env` to generate random passwords on first install. Existing
cluster Secrets are preserved on later runs.

Chart file `secrets.yaml` is Helm values only. It is not the Kubernetes
Secret named `zenml-db-password`. Copy the example if you want optional Helm
overrides; do not treat that file as cluster credential storage:

```bash
cp deploy/helm/zenml-server/secrets.yaml.example deploy/helm/zenml-server/secrets.yaml
chmod 600 deploy/helm/zenml-server/secrets.yaml
```
