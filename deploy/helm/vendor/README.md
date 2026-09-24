# Vendored Helm charts

`zenml/` contains the upstream ZenML OSS Helm chart version `0.96.2`. It is
the tested default used by this quickstart so a normal installation does not
need to download the chart from a public OCI registry.

- Upstream OCI reference: `oci://public.ecr.aws/zenml/zenml:0.96.2`
- Upstream manifest digest: `sha256:ff46d222a8312b1ab8971a38cdf69da692528b4c8e44e1b50cc5a094ce8a66d2`
- Upstream project: <https://zenml.io/>
- License: Apache License 2.0

When updating the bundled chart, pull and unpack the selected official chart,
record its manifest digest above, and run `make helm-test`.
