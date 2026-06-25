# repo-agent-bootstrap

A **reusable GitHub workflow + LLM agent** that bootstraps repo-specific Copilot
agents and indices into any target repository. The generated artifacts make
downstream AI agent calls **cheaper and more accurate** by replacing
broad-codebase scans with a curated `repo-index.md`, a typed `taxonomy.yaml`,
and a coordinator agent that knows the repo's actual shape.

> **Status:** scaffolding. Drop this into a new repo (e.g.
> `org/repo-agent-bootstrap`), tag `v1`, then call from target repos.

---

## What it generates (in the target repo)

### Layer 1 — LLM-generated, one-shot (via the `Bootstrap agents` workflow)

| Path | Purpose |
|---|---|
| `site/content/repo-index.md` | Curated subsystem → docs / packages / tests / ADRs map. Human-browsable. |
| `taxonomy.yaml` | Identifier registry using the org-wide type vocabulary. |
| `docs-manifest.yaml` | Index of every doc page with status (`current` / `stale` / `draft`). |
| `.github/agents/<repo>.agent.md` | Repo coordinator — knows the repo's name, stack, packages, and tier examples. |
| `.github/agents/{context-discovery,planning,architecture,implementation,testing,review}.agent.md` | Sub-agents — generic, driven by indices + taxonomy. |
| `.github/instructions/*.instructions.md` | Language-specific review rules (only for languages actually present). |
| `.github/copilot-instructions.md` | Short pointer file with the Repository Overview filled in. |
| `.github/workflows/agent-index.yml` | Caller for layer-2 — the deterministic indexer (runs on push). |
| `.agent-index/.gitkeep` | Placeholder so the layer-2 workflow has somewhere to write on first push. |

### Layer 2 — Deterministic, on every push (via the `Build agent index` workflow)

| Path | Producer | Purpose |
|---|---|---|
| `.agent-index/symbols.json` | `universal-ctags` | Symbol table: every function / type / method → file:line + signature. Replaces "where is X defined?" text searches. |
| `.agent-index/logs.json` | `scripts/build-logs.py` (regex + AST-lite) | Log-to-code map: every literal log message → file:line + level. Replaces "where does this log line come from?" text searches. |

These files are **machine-generated, deterministic, and committed back to
main** by the workflow with `[skip ci]`. No LLM involved.

See [`docs/index-formats.md`](docs/index-formats.md) for the JSON schemas.

---

## How it works

```
target-repo (any repo)
  ├── .github/workflows/bootstrap-agents.yml   (15-line caller — manual trigger)
  │     │
  │     │ workflow_call → layer 1 (LLM, one-shot)
  │     ▼
  │   repo-agent-bootstrap (this repo, @v1)
  │     └── .github/workflows/bootstrap.yml
  │           ├── checks out target repo
  │           ├── checks out templates (this repo)
  │           ├── runs claude-code-action with agents/bootstrap.agent.md
  │           │     → detects stack, builds repo-index.md / taxonomy.yaml /
  │           │       docs-manifest.yaml, renders coordinator from template,
  │           │       copies sub-agents, drops layer-2 caller workflow
  │           └── opens a DRAFT PR in the target repo
  │
  └── .github/workflows/agent-index.yml        (auto — runs on every push)
        │
        │ workflow_call → layer 2 (deterministic, no LLM)
        ▼
      repo-agent-bootstrap (this repo, @v1)
        └── .github/workflows/index.yml
              ├── checks out target repo + scripts
              ├── apt install universal-ctags + jq
              ├── runs build-symbols.sh    → .agent-index/symbols.json
              ├── runs build-logs.py       → .agent-index/logs.json
              └── commits indices to main with [skip ci]
```

Layer 1 runs **rarely** (weeks/months) and is LLM-driven. Layer 2 runs **on
every push** and uses only deterministic tools.

---

## Repo layout

```
.github/
  workflows/
    bootstrap.yml                       # reusable layer-1 workflow (LLM, on-demand)
    index.yml                           # reusable layer-2 workflow (deterministic, on push)
examples/
  caller-workflow.yml                   # layer-1 caller — drop into target repos
  caller-index-workflow.yml             # layer-2 caller — drop into target repos
  caller-weekly-refresh.yml             # OPTIONAL — weekly cron to refresh repo-index.md
agents/
  bootstrap.agent.md                    # meta-prompt: detect → generate → write
scripts/
  build-symbols.sh                      # ctags wrapper → symbols.json (no LLM)
  build-logs.py                         # per-language log extractor → logs.json (no LLM)
docs/
  index-formats.md                      # JSON schemas for .agent-index/*.json
templates/
  coordinator.agent.md.tmpl             # repo coordinator with {{PLACEHOLDERS}}
  copilot-instructions.md.tmpl          # short pointer file template
  repo-index.example.md                 # format reference for the agent
  docs-manifest.example.yaml            # format reference for the agent
  sub-agents/
    context-discovery.agent.md          # consumes .agent-index/*.json FIRST, then docs
    planning.agent.md
    architecture.agent.md
    implementation.agent.md
    testing.agent.md
    review.agent.md
  instructions/
    README.md                           # how to populate language rules
vocab/
  taxonomy-types.yaml                   # org-wide type vocabulary
```

---

## Setup (one-time, per target repo)

1. **Create this tooling repo** (private or internal). Push the layout above.
   Tag a stable release:
   ```sh
   git tag v1
   git push --tags
   ```

2. **Populate `templates/instructions/`** with your org's language-specific
   review rules. See [`templates/instructions/README.md`](templates/instructions/README.md).

3. **Populate `vocab/taxonomy-types.yaml`** with your org-wide type vocabulary
   (services, modes, APIs, topics, metrics, failure modes, ADRs). A starter is
   included.

4. **In each target repo**, add **both** caller workflows:
   ```sh
   cp examples/caller-workflow.yml \
      <target-repo>/.github/workflows/bootstrap-agents.yml      # layer 1
   cp examples/caller-index-workflow.yml \
      <target-repo>/.github/workflows/agent-index.yml           # layer 2
   ```
   In both files, replace `org/repo-agent-bootstrap` in the `uses:` line with
   your actual tooling repo path. (After the first layer-1 bootstrap PR is
   merged, future repos get the layer-2 caller dropped automatically.)

5. **Set repo secrets** in each target repo:
   - `ANTHROPIC_API_KEY` — only for the layer-1 LLM workflow. The layer-2
     deterministic workflow needs no secrets beyond `GITHUB_TOKEN`.

6. **Repo settings → Actions → General**:
   - ✅ "Allow GitHub Actions to create and approve pull requests" (layer 1)
   - ✅ "Read and write permissions" for `GITHUB_TOKEN` (layer 2, so the bot
     can commit `.agent-index/*.json` back to main)
   - If your org locks third-party actions, ask the org admin to allow:
     - `anthropics/claude-code-action` (layer 1)
     - `peter-evans/create-pull-request` (layer 1)
     - `actions/checkout` (both)

7. **Run layer 1 first**: Actions tab → "Bootstrap agents" → Run workflow →
   pick mode `full`. Merge the resulting draft PR after review.

8. **Layer 2 starts automatically** on the next push to `main` (or trigger it
   manually via Actions tab → "Build agent index" → Run workflow). It will
   commit `.agent-index/symbols.json` + `.agent-index/logs.json` back to main
   with `[skip ci]`.

9. **(Optional) Enable the weekly refresh** by copying the third caller:
   ```sh
   cp examples/caller-weekly-refresh.yml \
      <target-repo>/.github/workflows/repo-index-weekly.yml
   ```
   This runs the bootstrap in `repo-index-only` mode every Monday at
   08:00 UTC and opens a draft PR if `site/content/repo-index.md` changed.
   Sentinel-aware: if you've removed the sentinel from `repo-index.md` to
   hand-maintain it, the weekly refresh will skip it. See
   ["Refreshing the index automatically"](#refreshing-the-index-automatically)
   below.

---

## Run modes

### Layer 1 — `Bootstrap agents` workflow (manual trigger)

| Mode | Generates | Use when |
|---|---|---|
| `full` | Everything in layer 1 + drops layer-2 caller workflow | First time, or when adopting a new template version |
| `refresh` | `repo-index.md`, `docs-manifest.yaml`, `taxonomy.yaml` only | After significant repo changes (new packages, new docs) |
| `repo-index-only` | `repo-index.md` only | Cheap quarterly refresh |
| `agents-only` | Coordinator + sub-agents + instructions + layer-2 caller | After updating templates in this repo |

### Layer 2 — `Build agent index` workflow (auto on push)

No modes. Runs on every push to `main` (excluding doc-only changes). Always
regenerates both `symbols.json` and `logs.json` from scratch — fast enough
(~30 seconds for a medium repo) that incremental generation isn't worth the
complexity.

### Refreshing the index automatically

`site/content/repo-index.md` is **LLM-generated** (part of layer 1) — it
cannot be produced by ctags or grep, because curating subsystems and writing
one-liners requires semantic understanding of the codebase.

If you want it to stay fresh without manual triggers, copy
[`examples/caller-weekly-refresh.yml`](examples/caller-weekly-refresh.yml)
into your target repo. It runs the bootstrap workflow on a Monday cron
(`0 8 * * 1` UTC) in `repo-index-only` mode and opens a draft PR if the
index actually changed.

**Honest caveats:**

- **LLM non-determinism.** Even on an unchanged codebase, two runs may
  produce slightly different wording for subsystem one-liners. Expect
  occasional "noise PRs" that only rephrase. You can close them without
  merging — nothing breaks.
- **Cost.** One LLM run per week per repo. `repo-index-only` mode is the
  cheapest of the bootstrap modes (only walks subsystems; does not regenerate
  agents, taxonomy, or instructions).
- **Sentinel-aware.** If you remove the sentinel from `repo-index.md` to
  hand-maintain it, the weekly refresh will skip the file. To opt back in,
  paste the sentinel line back at the top.
- **Cron timing.** GitHub schedules shared-runner crons "around" the scheduled
  time — expect minutes-to-hours of delay during peak load. Treat the cron
  as best-effort.

---

## Why this saves tokens

Without the indices, every agent call scans the full doc tree + source tree to
find relevant context. That's the same broad search repeated dozens of times
per session.

With the indices, the `context-discovery` sub-agent does **at most two cheap
lookups**:

1. For "where is `X` defined?" → one read of `.agent-index/symbols.json`,
   filter by name. Zero text searches, zero file reads.
2. For "where does this log line come from?" (e.g. operator pastes an error
   message) → one read of `.agent-index/logs.json`, filter by message.
   Zero text searches, zero file reads.
3. For everything else ("how does subsystem X work?") → one read of
   `repo-index.md`, then load only the 1–3 doc pages it points to.

The bundle the `context-discovery` sub-agent emits contains **references only**
(file:line, not file bodies). Downstream specialists open only the specific
files they need.

The quality of the layer-1 LLM artifacts (`repo-index.md`, `taxonomy.yaml`)
determines the savings on subsystem questions. The layer-2 deterministic
indices (`symbols.json`, `logs.json`) save tokens on symbol and log lookups,
which are the most frequent question shapes during incident triage and refactoring.

---

## Generated PRs are drafts

The bootstrap workflow opens a **draft** PR. Always human-review before merge:

- Verify `repo-index.md` accurately maps subsystems (the agent's guesses can be wrong).
- Verify `taxonomy.yaml` uses correct types from your org vocabulary, with no invented types.
- Verify the coordinator's tier examples make sense for the repo.
- Verify only relevant language instructions were copied.

---

## Safety contract — will bootstrap clobber my hand-edited files?

**No, not by default.** The layer-1 workflow has three layered guarantees:

1. **PR-only output.** The agent writes to a feature branch; the workflow opens
   a draft PR. Nothing reaches `main` without your explicit merge.

2. **Management sentinel per file.** Every file the bootstrap generates carries
   `<!-- managed-by: repo-agent-bootstrap v1 -->` (or the YAML equivalent) in
   its first 40 lines. Before overwriting an existing file, the bootstrap
   agent reads the first 40 lines and **refuses if the sentinel is missing**.

   - To **opt a file out of auto-management**, delete its sentinel line. Future
     bootstrap runs will list it under "skipped (user-managed)" and leave it
     alone.
   - To **opt back in**, paste the sentinel line back at the top of the file.

3. **Workflow-level allowlist (deterministic, not LLM-dependent).** After the
   agent finishes, the workflow runs `git status --porcelain` and verifies:
   - Every changed path is within this allowlist:
     - `site/content/repo-index.md`
     - `taxonomy.yaml`
     - `docs-manifest.yaml`
     - `.github/copilot-instructions.md`
     - `.github/agents/*.agent.md`
     - `.github/instructions/*.instructions.md`
     - `.github/workflows/agent-index.yml`
     - `.agent-index/.gitkeep`
   - Every changed file carries the management sentinel.

   If either check fails, the workflow **aborts before opening the PR**. You
   never see a PR with unexpected changes.

### Escape hatch: `force_overwrite`

If you intentionally want to re-bootstrap everything from scratch (e.g. you
took a long break and want fresh agent files), set `force_overwrite: true`
when triggering the workflow. This **bypasses the sentinel check** — files
lacking the sentinel will be overwritten and their prior content lost. The
path allowlist still holds, so the blast radius is bounded to the allowlist
paths.

The draft PR's body explicitly states `force_overwrite: true|false` so you
can see whether sentinel protection was active.

### Layer 2 has no risk of clobbering hand-edited files

The deterministic indexer (layer 2) only writes to `.agent-index/symbols.json`
and `.agent-index/logs.json`. These are generated files by definition — you
should never hand-edit them. The workflow commits them with `[skip ci]` and
never touches anything else.

---

## What this does NOT do

- ❌ Does not modify source code in the target repo.
- ❌ Does not auto-merge.
- ❌ Does not run on `push` or `schedule` by default — manual trigger only.
- ❌ Does not require org-level admin permissions (one-time third-party action
  allow-list is usually all that's needed).
- ❌ Does not work across repos in one call. One run = one target repo.
