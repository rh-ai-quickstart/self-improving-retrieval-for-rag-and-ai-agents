# Self-Improving AI Agents with Replay-Driven Evolution

Turn an agent's own production runs into an automated optimization loop that makes it cheaper, faster, and more accurate on Red Hat® OpenShift® AI — with a hard safety floor that blocks any regression.

## Table of contents

- [Detailed description](#detailed-description)
  - [Architecture](#architecture)
- [Requirements](#requirements)
  - [Minimum hardware requirements](#minimum-hardware-requirements)
  - [Minimum software requirements](#minimum-software-requirements)
  - [Required user permissions](#required-user-permissions)
- [Deploy](#deploy)
  - [Prerequisites](#prerequisites)
  - [Supported models](#supported-models)
  - [Installation steps](#installation-steps)
  - [Uninstall](#uninstall)
- [References](#references)

## Detailed description

Imagine a support team that has shipped an AI agent to triage incoming B2B SaaS tickets. It works — most of the time. It reads each request, calls a couple of internal tools, and decides whether to answer the customer directly or escalate to a human. But the team knows it could be better: cheaper to run at scale, faster to respond, and more accurate on the edge cases it still gets wrong. The problem is *how* to improve it safely.

The conventional path is slow and manual. An engineer forms a hypothesis ("a smaller model would be cheaper," "this prompt wording over-escalates"), hand-builds an evaluation set, runs it, reads the diffs, and repeats. Each idea costs hours to days, so most ideas are never tested. Worse, the hand-built eval set is a *guess* about what production looks like — it drifts from reality the moment real traffic shifts, and it can silently reward a change that quietly breaks a case the agent used to handle correctly. For an agent that makes consequential decisions — escalate or don't, grant access or don't — an untested regression is not an inconvenience; it is a safety incident.

This AI quickstart demonstrates a different approach: **the agent improves itself, automatically, using its own production history as the benchmark.** Because every run of the agent is recorded as a fully *replayable* execution, any past run can be re-executed under a proposed change — a different model, a rewritten prompt, new tool logic — without touching production. That turns "replay a cohort of real runs under candidate X and compare the results" into a fitness function, and an evolutionary optimizer drives that fitness function on a loop: propose a change, replay the cohort, score it, keep the winners, mutate again. No human sits in the improvement loop, and no evaluation set is written by hand — the loop optimizes against the most representative test cases that exist: real traffic the agent already served.

The result is measurable and safe. In a reference run, the loop independently discovered a candidate that is significantly cheaper and faster with no loss of accuracy — and **zero safety regressions**, because a hard floor in the scoring function collapses any candidate's score to zero the moment it mishandles a case the baseline handled correctly. Cheaper and faster can never buy back a safety regression.

While the included demo is a customer-support copilot, the same machinery applies to any recorded agent — a coding assistant, an IT self-service agent, a claims or underwriting workflow, or any LLM application where you want continuous improvement without risking the behavior you already trust. You point the loop at *your* recorded runs, *your* definition of "correct," and *your* search space, and everything else is reusable as-is.

This quickstart allows you to explore self-improving agents by:

- **Recording production traffic as replayable executions** — running the support copilot on Red Hat OpenShift AI and capturing every model call, tool result, and decision as a durable, re-runnable execution.
- **Replaying a real cohort under a candidate change** — re-executing recorded tickets against a swapped model, a rewritten prompt, or new tool code, and seeing the decision, cost, and latency diff against the original run.
- **Running the evolutionary loop end-to-end** — letting the optimizer mutate candidates, replay the cohort, and keep the winners entirely on its own, then reading the ship / no-ship report it produces.
- **Watching the safety floor hold** — observing how a candidate that regresses a previously-safe decision is scored to zero and discarded, no matter how much cheaper or faster it is.
- **Adapting it to your own agent** — swapping in your flow, your labeled cohort, and your evolvable search space to point the same loop at a different workload.

The solution is built on:

- **Red Hat OpenShift AI** — MLOps platform with KServe / vLLM model serving and GPU acceleration; hosts the LLM turns that both the live agent and every replay call invoke.
- **Kitaru** (ZenML) — durable execution for agents. Records every run as a replayable execution and provides the replay API (`flow_overrides`, `checkpoint_overrides`, tagged batch replay) that turns history into a fitness function.
- **OpenEvolve** — the open-source evolutionary optimizer (an AlphaEvolve-style coding loop). Mutates candidate programs and drives the mutate → replay → compare → keep-winners loop, maintaining a diverse cost/latency frontier via MAP-Elites.
- **PydanticAI support copilot** — the agent under test: a Kitaru `@flow` whose model and instructions are inputs, so replay can override them.
- **Replay-as-fitness evaluator** — the bridge in this repository that materializes each candidate into replay overrides, replays the frozen cohort, and scores accuracy, cost, and latency against a recorded baseline under a hard safety floor.

### Architecture

![The replay-driven evolution loop on Red Hat OpenShift AI: the support copilot flow records runs via Kitaru while its LLM turns are served by vLLM on OpenShift AI; a frozen cohort of recorded runs feeds the OpenEvolve loop, which replays the cohort under each candidate and keeps only winners that clear the hard safety floor, ending in a ship/no-ship report](docs/screenshots/openshift-architecture.svg)

**Data flow.** The support copilot runs as a Kitaru `@flow` on OpenShift. Each of its LLM turns is served by a vLLM `ServingRuntime` through KServe on Red Hat OpenShift AI, and each run is recorded by Kitaru as a replayable execution — every model request, tool result, and the final decision persisted at a checkpoint boundary. A set of these recorded runs, together with ground-truth labels, is frozen into a **cohort** — the benchmark the loop optimizes against.

OpenEvolve then drives the outer loop. For each candidate it produces (a change to the model, the system prompt, or a deterministic tool's code), the evaluator materializes the candidate into Kitaru replay overrides — model and prompt become `flow_overrides`, tool code becomes a `checkpoint_overrides` code swap — and issues one **tagged batch replay** of the whole cohort. The replay re-executes each recorded ticket under the candidate, re-calling the models served on OpenShift AI, and produces replay children whose decisions, cost, and latency are diffed against the recorded originals.

The evaluator scores each candidate — accuracy against ground truth, cost and latency against the baseline — and applies the **hard safety floor**: if the candidate regresses accuracy on the restricted (dangerous) tickets the baseline handled correctly, the combined score becomes `0.0`. Winners are kept and mutated further; the rest are discarded. A two-stage cascade screens obviously-bad candidates on a small subset before spending the full cohort on them. When the budget is exhausted, the loop confirmation-replays the winner and writes a ship / no-ship report, with links to compare each replay child against its original in the Kitaru dashboard.

| Layer / Component | Technology | Purpose |
| --- | --- | --- |
| **Platform** | Red Hat OpenShift | Container orchestration; hosts the Kitaru server, the agent flow, and the evolution loop |
| **Model Serving** | Red Hat OpenShift AI (KServe + vLLM ServingRuntime) | GPU-accelerated LLM serving for every live and replayed model turn |
| **Durable Execution** | Kitaru (ZenML) | Records runs as replayable executions; provides replay with `flow_overrides` / `checkpoint_overrides` and tagged batch replay |
| **Optimizer** | OpenEvolve | Evolutionary outer loop (mutate → replay → score → keep), MAP-Elites cost/latency archive |
| **Agent Framework** | PydanticAI | The support copilot flow; model and instructions are flow inputs so replay can override them |
| **Fitness Function** | Replay-cohort evaluator (this repo) | Turns a candidate file into replay overrides, replays the cohort, scores under the safety floor |
| **Observability** | Kitaru dashboard | Side-by-side replay-vs-original compare (decision, cost, latency) for every candidate |
| **LLM (baseline)** | `meta-llama/Llama-3.2-3B-Instruct` (served on OpenShift AI) | The model the recorded production runs used |
| **LLM (candidate)** | `RedHatAI/Llama-3.2-1B-Instruct-quantized.w8a8` | A cheaper / faster alternative the loop is free to evolve toward |
...
