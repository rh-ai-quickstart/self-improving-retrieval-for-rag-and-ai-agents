# Why add ZenML to Red Hat OpenShift AI?

Red Hat OpenShift AI provides the enterprise platform on which this quickstart
runs: Kubernetes workload execution, identity and access controls, integrated
image storage, experiment tracking, model serving, networking, and operational
guardrails. ZenML adds an ML-focused workflow and control-plane layer over
those capabilities.

This quickstart makes that choice to demonstrate an operating model in which
ML developers work through a compact Python API while a platform team supplies
the OpenShift infrastructure and configures the services behind it.

## What ZenML adds to the platform

### Runtime-adaptive workflows in Python

ZenML's experimental dynamic-pipeline mode executes the pipeline function at
runtime. It can inspect intermediate results, use regular Python control flow,
and decide which steps to launch next. Independent steps can be submitted
concurrently, and later decisions can depend on their materialized outputs.

That model is useful when workflow shape is discovered during execution rather
than fully known when the pipeline is submitted. Examples include:

- discovering datasets or customer segments and creating work for each one;
- evaluating a changing set of model candidates;
- branching according to validation or policy results; and
- promoting, indexing, or deploying only the artifact selected at runtime.

This quickstart applies that pattern directly: candidate embedding models are
evaluated concurrently, their results converge on a winner, and the winning
model determines the subsequent indexing and deployment work.

OpenShift AI Pipelines can also implement conditions and fan-out through KFP
constructs such as `dsl.If` and `dsl.ParallelFor`. ZenML's reason for being in
this architecture is the different authoring model: runtime decisions remain
inside the Python pipeline function instead of being expressed through a
compiled workflow DSL.

Teams likely to benefit include evaluation-platform teams, applied-AI groups
with exploratory workflows, and organizations whose work items or deployment
decisions are frequently discovered during execution.

### A portable MLOps stack abstraction

ZenML separates pipeline logic from a named **stack**. The stack identifies the
orchestrator, artifact store, image builder, container registry, experiment
tracker, and other infrastructure integrations used for a run.

This gives a platform team one place to assemble an approved environment while
pipeline authors continue to use the same step and pipeline interfaces. A
developer can use a lightweight local stack during development and switch to a
shared OpenShift-backed stack for remote execution. Individual stack services
can also change without redesigning the logical workflow.

The abstraction is particularly useful for:

- organizations supporting local, integration, and production environments;
- platform teams offering a common workflow interface over approved tools;
- hybrid or multi-platform organizations that want to reduce direct coupling
  between ML code and one execution backend; and
- teams that expect their experiment tracker, artifact store, or orchestrator
  choices to evolve independently.

Portability is not automatic or absolute. Platform-specific operations still
belong behind explicit adapters. In this repository, evaluation and indexing
are broadly portable, while deployment deliberately uses KServe and OpenShift
Routes. Moving the complete application would require replacing that adapter.

### ML-oriented artifacts, metadata, and lifecycle context

ZenML automatically materializes step outputs as versioned artifacts and
records their relationships to steps and pipeline runs. It also provides model
abstractions that can associate artifacts, metrics, metadata, and multiple
workflows with versions of an ML system.

For teams, the value is a consistent way to navigate questions such as:

- Which data and code produced this evaluation result?
- Which run selected the deployed model?
- Which metrics justified that selection?
- Which indexed corpus and endpoint belong to the deployment?

The quickstart demonstrates this by recording the benchmark, model results,
winner, FAISS bundle, and deployment metadata in one ZenML run. The deployment
step publishes the search UI, API documentation, and health endpoint as
clickable metadata, connecting the operational application back to the
workflow that produced it.

This is most useful to teams running several connected training, evaluation,
promotion, and deployment workflows, or teams that want ML lifecycle context
above the execution records of an individual pipeline system. The complete
visual model-management experience depends on the ZenML edition; this
quickstart uses the run, step, artifact, and metadata capabilities available to
its configured ZenML deployment and does not replace an enterprise model
registry.

### A developer-facing layer with a platform-owned backend

ZenML pipelines are ordinary Python functions decorated with `@pipeline`, and
their units of work are typed functions decorated with `@step`. Materializers
handle persistence of step inputs and outputs, while the active stack supplies
the infrastructure configuration.

This creates a useful organizational boundary:

- ML developers concentrate on data preparation, evaluation, selection, and
  deployment policy in Python.
- Platform engineers configure and operate the ZenML server, OpenShift
  identities, workload resources, artifact storage, image flow, experiment
  tracking, and serving integrations.

The approach is attractive when an organization wants data scientists and ML
engineers to use a common ML workflow API without requiring every author to
work directly with Kubernetes resources or an orchestration-specific DSL. It
does not remove platform engineering: operating ZenML introduces an additional
service and integration lifecycle that the platform team must own.

### Composition of OpenShift AI capabilities

ZenML acts as connective workflow infrastructure; OpenShift remains the place
where the work runs and is served. In this quickstart the responsibilities are:

| Concern | Implementation |
| --- | --- |
| Cluster scheduling, identity, registry, and Routes | OpenShift |
| Model serving | OpenShift AI KServe |
| Experiment tracking | OpenShift AI MLflow |
| Pipeline definition, runtime decisions, and execution state | ZenML |
| Versioned pipeline artifacts | ZenML artifact management backed by MinIO |
| Search experience | FastAPI, Sentence Transformers, and FAISS |

The active ZenML stack uses the Kubernetes orchestrator directly and does not
submit this workflow to an OpenShift AI Pipelines server. OpenShift AI
Pipelines is therefore not required by this quickstart. ZenML coordinates the
platform services while preserving OpenShift's workload, security, networking,
and serving model.

This combination is a good fit for organizations that already rely on
OpenShift AI but want a higher-level MLOps interface, or that want to standardize
ML workflow practices across more than one infrastructure configuration.

## Teams most likely to benefit

Adding ZenML to OpenShift AI is most compelling when several of these are true:

- Workflow topology or deployment decisions depend on intermediate results.
- ML practitioners prefer runtime Python control flow over a compiled pipeline
  DSL.
- A platform team manages infrastructure separately from pipeline authors.
- The organization needs the same logical workflows across local and remote
  environments.
- Different projects use varying combinations of artifact stores, experiment
  trackers, registries, or orchestrators.
- Artifact lineage and model lifecycle context must connect multiple workflows,
  not only tasks within one execution.
- OpenShift AI remains the required enterprise execution and serving platform.

## When OpenShift AI Pipelines may be the simpler choice

ZenML is an additional control-plane service, so it should solve a concrete
organizational or workflow need. OpenShift AI Pipelines may be the more direct
choice when a team:

- is already standardized on KFP components and its DSL;
- prefers compiled pipeline specifications and a Kubernetes-native or
  GitOps-oriented lifecycle;
- wants pipeline scheduling and management entirely within the OpenShift AI
  experience;
- does not require ZenML's stack abstraction or cross-workflow ML model view;
  or
- wants to avoid operating another server and set of integrations.

Both approaches can build repeatable containerized ML workflows on OpenShift.
The reason to add ZenML is not a lack of orchestration capability in OpenShift
AI Pipelines; it is a preference for ZenML's abstraction boundary between ML
developers, workflow logic, lifecycle metadata, and the underlying platform.

## Why this quickstart uses ZenML

The quickstart is designed to show that boundary in a concrete use case:

1. OpenShift AI supplies the environment for experiments and model serving.
2. ZenML dynamically fans out model evaluations and records their artifacts
   and metrics.
3. Runtime logic selects a winner and creates a versioned search index.
4. ZenML deploys the resulting application through the OpenShift-specific
   KServe adapter.
5. Deployment metadata links users from the producing pipeline run to the live
   search experience.

For teams with similar requirements, ZenML and OpenShift AI are complementary:
OpenShift provides the governed application platform, and ZenML provides the
ML-facing workflow layer used to compose and observe it.

## Further reading

- [ZenML dynamic pipelines](https://docs.zenml.io/concepts/steps_and_pipelines/dynamic_pipelines)
- [ZenML execution model](https://docs.zenml.io/concepts/steps_and_pipelines/execution)
- [ZenML core concepts and stacks](https://docs.zenml.io/getting-started/core-concepts)
- [ZenML artifacts](https://docs.zenml.io/concepts/artifacts)
- [ZenML model tracking](https://docs.zenml.io/user-guides/starter-guide/track-ml-models)
- [Red Hat OpenShift AI Pipelines](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/working_with_ai_pipelines/index)
- [Kubeflow Pipelines control flow](https://www.kubeflow.org/docs/components/pipelines/user-guides/core-functions/control-flow/)
- [Kubeflow Pipelines ML Metadata](https://www.kubeflow.org/docs/components/pipelines/concepts/metadata/)
