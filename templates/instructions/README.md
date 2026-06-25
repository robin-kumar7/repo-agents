# templates/instructions/

This folder holds the **language-specific review rule files** that the bootstrap
agent selectively copies into each target repo's `.github/instructions/`.

The bootstrap agent detects which languages / tools the target repo actually
uses (via `go.mod`, `pom.xml`, `package.json`, `pyproject.toml`, `Dockerfile`,
`helm/`, `Makefile`, etc.) and copies **only the matching files**.

## Required files

Populate this folder by copying your org's standard review rule set. If you
have an existing repo with a working set (e.g. `data.exporter.kafka`), copy:

```sh
cp /path/to/data.exporter.kafka/.github/instructions/*.instructions.md \
   templates/instructions/
```

## Expected file set

| File | Triggered when target repo has… |
|---|---|
| `copilot-review.instructions.md` | Always copied (umbrella) |
| `go-review.instructions.md` | `go.mod` |
| `java-review.instructions.md` | `pom.xml` / `build.gradle*` |
| `python-review.instructions.md` | `pyproject.toml` / `requirements*.txt` / `setup.py` |
| `shell-review.instructions.md` | `*.sh` / `*.bash` / `bin/` scripts |
| `docker-review.instructions.md` | `Dockerfile*` / `docker-compose*.yml` |
| `helm-review.instructions.md` | `helm/` / `charts/` / `Chart.yaml` |
| `ci-cd-review.instructions.md` | `Jenkinsfile` / `Makefile` / `.github/workflows/` |
| `proto-review.instructions.md` | `*.proto` |
| `terraform-review.instructions.md` | `*.tf` / `*.tfvars` |
| `sql-review.instructions.md` | `*.sql` / `migrations/` |

If a target repo has **none** of the indicators for a given file, the bootstrap
agent skips that file. This keeps each target repo's instructions folder lean.

## File format

Each instructions file must have YAML frontmatter:

```markdown
---
description: "What this file covers, one line"
applyTo: "**/*.go,**/go.mod,**/go.sum"
---

# Review rules content here
```

`applyTo` is a comma-separated glob list. VS Code Copilot automatically applies
the file when the user is editing or reviewing a matching file.
