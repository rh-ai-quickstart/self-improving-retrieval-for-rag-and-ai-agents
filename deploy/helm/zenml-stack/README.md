# zenml-stack Helm chart

Provisions the OpenShift workload infrastructure for the ZenML remote stack:

- Orchestrator service account and RBAC
- KServe deployment permissions
- Optional cluster-scoped MLflow CR and integration RoleBinding
- [S4](https://github.com/rh-aiservices-bu/s4) artifact store (S3 API `:7480`, UI `:5000`, bucket bootstrap Job)
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

Override `s4.s3.*` and `s4.auth.*` for non-demo installs. Demo defaults are
`s4admin` / `s4secret` (S3) and `admin` / `changeme` (UI).

Registry pull credentials are normally refreshed post-install by
`make refresh-stack-credentials`. Set `registry.createPullSecret`,
`registry.dockerServer`, and `registry.dockerPassword` only when you want Helm
to create the pull Secret during chart install.

You can also supply `S4_SECRET_ACCESS_KEY` / `S4_UI_AUTH_PASSWORD` through
`deployment.env`, which overrides the chart secrets file at install time.

## Endpoints

| Concern | Value |
|---------|-------|
| In-cluster S3 API | `http://s4:7480` |
| In-cluster UI | `http://s4:5000` |
| Credentials Secret | `s4-credentials` (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) |
| UI Route | `s4` |
| S3 API Route | `s4-api` (enabled so ZenML CLI can register the artifact store) |
| Default bucket | `zenml-artifacts` |

## Upgrading from MinIO

A prior `zenml-stack` install that deployed hand-rolled MinIO (`deployment/minio`,
Secret `minio-root`, Route `minio-s3`, Job `minio-bootstrap`) will not delete those
resources automatically when you upgrade to S4. After `helm upgrade` (or
`make bootstrap-stack`):

1. Confirm S4 is healthy (`deployment/s4`, Routes `s4` / `s4-api`, Job `s4-bootstrap`).
2. Re-run ZenML registration so the artifact store points at `https://<s4-api>/`
   with credentials from `s4-credentials` (`openshift-s4` / `s4-artifact-store`).
3. Remove leftover MinIO objects when ready (`deployment/minio`, `pvc/minio-data`,
   Secret `minio-root`, Route `minio-s3`, Job `minio-bootstrap`) — preferably via a
   deliberate cleanup, not by leaving dual stores enabled.
4. Refresh local `deployment.env` from `deployment.env.example` (`S4_*` vars).
