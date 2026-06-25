---
title: Repository Index
description: Curated map of subsystems → docs / packages / tests / ADRs. Read by the context-discovery agent on every request. Keep concise.
---
<!-- managed-by: repo-agent-bootstrap v1 — DO NOT EDIT directly; changes overwritten on regen. Remove this line to opt out of auto-management. -->

# Repository Index — {{REPO_NAME}}

This page is the **agent-facing map** of the repository. It is intentionally
short. Each subsystem points to its canonical doc page, its primary source
packages, its primary tests, and the design decisions that govern it. Update
this page when you add a package, rename a subsystem, or land an ADR.

**Used by**: the `context-discovery` agent (the first specialist dispatched on
every request). All other specialists consume the Context Bundle that
context-discovery produces from this index — they do **not** re-read the full
doc tree.

**Status legend** (mirrors `docs-manifest.yaml`):
- `current` (authoritative)
- `stale` (treat as advisory; verify against code)
- `draft` (under construction)

---

## Service one-liner

`{{REPO_NAME}}` is {{REPO_ONE_LINER}}.

---

## Subsystems

> Each subsystem entry uses the same shape. Keep entries to **one or two lines
> per bullet**. The goal is fast lookup, not exhaustive documentation.

### <Subsystem name>
- **Docs:** [`<relative path to canonical doc>`](<relative path>) — status: current | stale | draft
- **Packages:** `<pkg path>`, `<pkg path>`
- **Tests:** `<test path glob>`
- **ADRs:** see [`architecture/design-decisions.md#<anchor>`](architecture/design-decisions.md#<anchor>)

### <Next subsystem>
- **Docs:** ...
- **Packages:** ...
- **Tests:** ...
- **ADRs:** ...

<!-- Repeat for each subsystem. Examples of common subsystem categories:
     - Server / wiring
     - API handlers
     - Domain logic
     - Persistence layer
     - Message-bus consumers / producers
     - External clients
     - Cross-cutting (config, logging, metrics)
-->

---

## Entry points

- `<cmd/server or equivalent>` — <one line>
- `<cmd/cli or equivalent>` — <one line>

---

## Cross-service boundaries

- **Downstream consumer(s):** <list> — Contract: <gRPC service / Kafka topic / REST API>
- **Shared contracts:** <protobuf path / schema location> — changes here require coordinating with the consumer repo(s).
- **Shared topics / queues:** <list> — documented in [`<arch doc>`](<arch doc>).

---

## Conventions

- **Build / test:** [`Makefile`](../../Makefile) — common targets: `<list discovered targets>`
- **Lint config:** `<.golangci.yml | .eslintrc | etc.>`
- **Per-language instructions:** [`.github/instructions/*.instructions.md`](../../.github/instructions/)

---

## Maintenance

When you add a package, rename a subsystem, or land an ADR:
1. Add / update the entry above.
2. Add the page to `docs-manifest.yaml` with status `current`.
3. Update `taxonomy.yaml` if the change introduces a new identifier.

To regenerate this file from scratch, run the `Bootstrap agents` workflow
(Actions tab) in `refresh` or `repo-index-only` mode.

Keep entries to one or two lines. The goal is fast lookup, not exhaustive
documentation.
