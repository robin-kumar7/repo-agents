# SETUP — repo-agent-bootstrap

Step-by-step setup. Follow top to bottom. Each step is copy-pasteable.

**What you'll end up with:**

- A central tooling repo (this one) at `org/repo-agent-bootstrap`.
- A target repo with three workflows: manual bootstrap, automatic indexer, weekly index refresh.
- AI agents in the target repo that use a curated `repo-index.md` + a deterministic symbol/log index to answer questions cheaply.

---

## Prerequisites

Check before you start:

```sh
git --version              # any recent version
gh --version               # GitHub CLI (optional but handy)
python3 --version          # 3.10+ recommended (for local testing of build-logs.py)
which jq || brew install jq    # macOS
```

You'll also need:

- **A GitHub account with permission to create a new repository** in your org (or a personal repo for testing).
- **An Anthropic API key** (for the LLM-driven bootstrap workflow). Get one at https://console.anthropic.com.
- **Repo-level admin** on each target repo (to add secrets + flip the "Allow Actions to create PRs" toggle). No org-level admin needed unless your org locks third-party Actions.

---

## Part 1 — Set up the tooling repo (one-time)

### 1.1 Create the repo

```sh
# Pick a location and create the repo (private or internal is fine).
gh repo create org/repo-agent-bootstrap --private --description "Bootstrap repo agents + indices for any target repo"

# OR via the GitHub web UI:
#   https://github.com/organizations/<org>/repositories/new
#   Name: repo-agent-bootstrap, visibility: private or internal
```

### 1.2 Clone and populate

```sh
git clone git@github.com:org/repo-agent-bootstrap.git
cd repo-agent-bootstrap

# Copy the scaffold contents (replace SOURCE with wherever your scaffold lives).
cp -r /path/to/scaffold/* .
cp -r /path/to/scaffold/.github .   # don't forget the dotfile dir
```

### 1.3 Populate `templates/instructions/`

The bootstrap copies language-specific review-rule files into each target repo
based on the languages it detects. The scaffold ships `templates/instructions/README.md`
explaining the expected set; you need to populate the actual files.

If you have an existing repo (like `data.exporter.kafka`) that already has
working `.github/instructions/`, copy those:

```sh
cp /path/to/data.exporter.kafka/.github/instructions/*.instructions.md \
   templates/instructions/
```

You should end up with at least these (one per language your org uses):

```sh
ls templates/instructions/
# copilot-review.instructions.md      ← required (umbrella)
# go-review.instructions.md
# java-review.instructions.md
# python-review.instructions.md
# shell-review.instructions.md
# docker-review.instructions.md
# helm-review.instructions.md
# ci-cd-review.instructions.md
# proto-review.instructions.md
# terraform-review.instructions.md
# sql-review.instructions.md
```

### 1.4 Review `vocab/taxonomy-types.yaml`

The scaffold includes a starter org-wide vocabulary. Open
`vocab/taxonomy-types.yaml` and:

- Remove types your org doesn't use.
- Add any types your org uses that aren't there (e.g. `feature-flag-system`,
  `event-source`).
- Do not let target repos invent types — the closed-world rule is what keeps
  taxonomies consistent across repos.

### 1.5 Edit `caller-*.yml` examples to reference your org

Open each file in `examples/` and replace `org` with your actual GitHub org:

```sh
# Three files to edit:
examples/caller-workflow.yml          # line: uses: org/repo-agent-bootstrap/...
examples/caller-index-workflow.yml    # line: uses: org/repo-agent-bootstrap/...
examples/caller-weekly-refresh.yml    # line: uses: org/repo-agent-bootstrap/...
```

```sh
# macOS sed (BSD):
sed -i '' 's#uses: org/repo-agent-bootstrap#uses: YOUR_ORG/repo-agent-bootstrap#g' examples/caller-*.yml
# GNU sed (Linux):
sed -i    's#uses: org/repo-agent-bootstrap#uses: YOUR_ORG/repo-agent-bootstrap#g' examples/caller-*.yml
```

### 1.6 Commit and tag `v1`

```sh
git add .
git commit -m "feat: initial scaffold for repo-agent-bootstrap"
git push -u origin main

git tag v1
git push --tags
```

Target repos pin to `@v1`, so future template changes don't break them
until you bump the tag.

### 1.7 (One-time) Allow other repos to call this workflow

GitHub's reusable-workflow security requires the tooling repo to allow access:

1. Go to **`https://github.com/<org>/repo-agent-bootstrap/settings/actions`**.
2. Under **Access**, select either:
   - "Accessible from repositories in the '<org>' organization" (recommended), or
   - "Accessible from repositories owned by the user 'org'".
3. Save.

Done. The tooling repo is ready.

---

## Part 2 — Adopt it in a target repo (per repo)

Repeat these steps for each repo you want to enable agents in. The first time
takes ~10 minutes; subsequent repos take 2–3 minutes.

### Fast path: one command

If you have the tooling repo cloned locally and `gh` is authenticated, you can
do all of Part 2 with one script:

```sh
git clone git@github.com:org/some-service.git
cd some-service
/path/to/repo-agent-bootstrap/bin/onboard.sh           # interactive
# or, non-interactive:
/path/to/repo-agent-bootstrap/bin/onboard.sh --weekly --yes
```

The script does steps 2.1–2.7 in one shot:
- Detects target repo + tooling repo from git remotes.
- Drops the workflow files with `uses:` rewritten to your actual org.
- Commits, pushes a feature branch, opens a draft PR.
- Sets the `ANTHROPIC_API_KEY` secret (prompted silently).
- Adjusts workflow permissions (contents:write, allow PRs).

Aborts safely if the working tree is dirty, the branch already exists, or any
target workflow file already exists. Run `./bin/onboard.sh --help` for flags.

The rest of Part 2 covers the manual equivalent if you'd rather see each step.

### 2.1 Clone the target repo

```sh
git clone git@github.com:org/some-service.git
cd some-service
```

### 2.2 Drop the three caller workflows

```sh
mkdir -p .github/workflows

# Manual layer-1 bootstrap (LLM, on-demand)
curl -fsSL https://raw.githubusercontent.com/org/repo-agent-bootstrap/v1/examples/caller-workflow.yml \
  > .github/workflows/bootstrap-agents.yml

# Layer-2 deterministic indexer (auto, on push to main)
curl -fsSL https://raw.githubusercontent.com/org/repo-agent-bootstrap/v1/examples/caller-index-workflow.yml \
  > .github/workflows/agent-index.yml

# OPTIONAL: weekly cron to refresh repo-index.md (LLM)
curl -fsSL https://raw.githubusercontent.com/org/repo-agent-bootstrap/v1/examples/caller-weekly-refresh.yml \
  > .github/workflows/repo-index-weekly.yml
```

If the tooling repo is private, your local `gh` auth needs read access:

```sh
gh repo view org/repo-agent-bootstrap >/dev/null
# If this fails: gh auth refresh -h github.com -s read:org
```

### 2.3 Verify the workflows reference your actual org

If you populated the tooling repo's example files in step 1.5, this should
already be correct. Double-check:

```sh
grep -H 'uses: ' .github/workflows/bootstrap-agents.yml .github/workflows/agent-index.yml .github/workflows/repo-index-weekly.yml
# Each line should show: uses: YOUR_ORG/repo-agent-bootstrap/...
```

### 2.4 Add the Anthropic API key as a repo secret

```sh
gh secret set ANTHROPIC_API_KEY --repo org/some-service
# Paste the key when prompted, then press Enter.
```

Or via the web UI: **Settings → Secrets and variables → Actions → New repository secret**.

The layer-2 indexer workflow does NOT need this secret — it only uses
`universal-ctags` + `python3`. Only the layer-1 bootstrap and the weekly
refresh need it.

### 2.5 Flip the required repo settings

Go to **`https://github.com/<org>/some-service/settings/actions`** and enable:

- [ ] **Workflow permissions** → "Read and write permissions" (layer 2 needs to commit `.agent-index/` back to main)
- [ ] **Workflow permissions** → "Allow GitHub Actions to create and approve pull requests" (layer 1 + weekly refresh need to open PRs)

### 2.6 (If org locks third-party Actions) Ask your org admin

Some orgs restrict which third-party Actions can run. If your org admin has
done this, the bootstrap workflow will fail with "action is not allowed". Ask
them to allow:

- `anthropics/claude-code-action@v1`
- `peter-evans/create-pull-request@v6`
- `actions/checkout@v4`

This is a one-time, one-line allowlist entry per Action. Not ongoing
admin involvement.

### 2.7 Commit the workflows

```sh
git add .github/workflows/
git commit -m "ci: enable repo-agent-bootstrap workflows"
git push
```

---

## Part 3 — Verify (first run)

### 3.1 Run the layer-1 bootstrap

Open `https://github.com/<org>/some-service/actions/workflows/bootstrap-agents.yml`
in a browser:

1. Click **Run workflow**.
2. Mode: `full`.
3. Templates ref: `v1` (or whatever tag you pushed).
4. Force overwrite: leave **unchecked** (you're not overwriting anything yet).
5. Click **Run workflow**.

Watch the run. You should see:

```
✔ Checkout target repo
✔ Checkout bootstrap templates
✔ Validate inputs
✔ Run bootstrap agent          ← takes 2–10 minutes (LLM)
✔ Clean up templates checkout
✔ Validate diff against allowlist
✔ Verify management sentinel on every changed file
✔ Open draft pull request
```

If "Validate diff against allowlist" fails, the agent wrote outside the
allowlist — this is a bug in the agent prompt. **No PR was opened, nothing
was changed in your repo.** Open an issue against the tooling repo.

### 3.2 Review the draft PR

Open the PR the workflow created (titled `chore: bootstrap repo agents + index`).

Check:

- [ ] `site/content/repo-index.md` — does the subsystem map make sense?
- [ ] `taxonomy.yaml` — are identifiers using real types from your vocab? Any in `unmapped:`?
- [ ] `.github/agents/<repo>.agent.md` — does the coordinator's tier examples table fit your repo?
- [ ] `.github/instructions/` — only the languages your repo actually uses?
- [ ] `.github/workflows/agent-index.yml` — present (lets layer 2 start on next push)?

If something is wrong, you can either:
- Fix in the PR directly and merge (then close-and-reopen the PR to re-trigger checks if needed), or
- Close the PR, fix the templates in the tooling repo, bump the tag, re-run.

### 3.3 Merge the PR

Once it looks right, mark as "Ready for review" → merge.

### 3.4 Wait for layer 2 to populate

On the next push to `main` (or trigger manually via Actions tab → "Build agent
index" → Run workflow), the indexer runs and commits two files:

```sh
git pull
ls -la .agent-index/
# .agent-index/symbols.json     ← every function/type/method definition
# .agent-index/logs.json        ← every literal log statement
# .agent-index/.gitkeep         ← placeholder
```

Verify the content:

```sh
jq '.symbols | length' .agent-index/symbols.json
# → some number > 0
jq '.logs | length' .agent-index/logs.json
# → some number > 0
```

### 3.5 (Optional) Verify the weekly refresh is scheduled

Open `https://github.com/<org>/some-service/actions/workflows/repo-index-weekly.yml`.
You should see "This workflow has a workflow_dispatch event trigger and a
schedule trigger: `0 8 * * 1`".

To test without waiting until Monday, click **Run workflow** → keep mode
`repo-index-only` → **Run workflow**. If nothing changed in the repo, no PR is
opened.

---

## Part 4 — Operating it

### Re-bootstrap (full or partial)

Actions tab → **Bootstrap agents** → Run workflow → pick a mode:

| Mode | When to use |
|---|---|
| `full` | Major repo restructure; new templates released in tooling repo |
| `refresh` | Significant package/doc churn; want index + taxonomy + manifest refreshed |
| `repo-index-only` | Just the subsystem map; cheapest mode |
| `agents-only` | Tooling repo released new sub-agent templates and you want them |

### Stop the weekly cron

Actions tab → **Refresh repo index (weekly)** → "⋯" menu → **Disable workflow**.

### Skip auto-management on a specific file

Open the file. In its first 40 lines, find the line containing
`managed-by: repo-agent-bootstrap` and **delete it**. Commit. Future bootstrap
runs will report the file under "skipped (user-managed)" and never overwrite it.

To opt back in, paste the sentinel line back at the top of the file (after
YAML frontmatter if present).

### Update the tooling repo and roll out

When you change templates in the tooling repo:

```sh
# In the tooling repo
git tag v2
git push --tags
```

In each target repo, bump the `templates_ref` in the caller workflows
(`v1` → `v2`). Or update via search-and-replace across all your target
repos.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Resource not accessible by integration" | Workflow permissions too low | Settings → Actions → "Read and write" + "Allow PRs" |
| "Action `xxx` is not allowed" | Org locks third-party Actions | Org admin allowlists the specific Action |
| Bootstrap PR aborts at "Validate diff against allowlist" | Agent wrote outside allowlist | Bug in agent prompt; file an issue against tooling repo |
| Bootstrap PR aborts at "Verify management sentinel" | Agent forgot the sentinel | Re-run; if persistent, fix the bootstrap agent prompt |
| Layer-2 commit fails with "permission denied" | GITHUB_TOKEN lacks write permission | Settings → Actions → Workflow permissions → "Read and write" |
| Weekly refresh keeps opening noise PRs | LLM non-determinism in wording | Close them without merging; nothing breaks. Or pin to a lower-temperature model. |
| `repo-index.md` says wrong things about a subsystem | LLM guessed wrong | Edit the file directly (sentinel-protected) and merge. Or fix at the source by improving package READMEs. |

---

## You're done

You now have:

- ✅ A central tooling repo at `<org>/repo-agent-bootstrap@v1`.
- ✅ A target repo with three workflows: manual bootstrap, auto indexer on push, weekly index refresh.
- ✅ Repo-specific agents at `.github/agents/`.
- ✅ A curated `site/content/repo-index.md` + deterministic `.agent-index/*.json` that downstream agents consult **before** any text search.

To add another target repo, repeat **Part 2** + **Part 3**.

To update the templates org-wide, edit the tooling repo, bump the tag, and
bump `templates_ref` in each target's caller workflow.
