---
description: "Use when using GitHub CLI (gh), managing GitHub repositories, creating issues or pull requests, triggering GitHub Actions workflows, managing secrets, or performing any GitHub repository operations."
---
# GitHub CLI (gh) Guide

## Authentication

Login to GitHub:
```bash
gh auth login
```

Follow the prompts to authenticate via browser or token. For non-interactive environments, use a Personal Access Token (PAT):
```bash
gh auth login --with-token <<< "<your-pat>"
```

Check current auth status:
```bash
gh auth status
```

---

## Repository Operations

```bash
# View current repo info
gh repo view

# Clone a repo
gh repo clone bthek1/AWS_setup

# Create a new repo
gh repo create <name> --public|--private

# List repos
gh repo list bthek1
```

---

## Issues

```bash
# List open issues
gh issue list

# View an issue
gh issue view <number>

# Create an issue
gh issue create --title "Title" --body "Description"

# Close an issue
gh issue close <number>
```

---

## Pull Requests

```bash
# List pull requests
gh pr list

# Create a pull request
gh pr create --title "Title" --body "Description" --base main

# View a pull request
gh pr view <number>

# Check out a PR branch locally
gh pr checkout <number>

# Merge a pull request
gh pr merge <number> --squash
```

---

## GitHub Actions

```bash
# List workflow runs
gh run list

# Watch a running workflow
gh run watch

# View logs for a run
gh run view <run-id> --log

# Trigger a workflow manually
gh workflow run <workflow-name>

# List workflows
gh workflow list
```

---

## Secrets Management

```bash
# Set a repo secret (e.g. AWS credentials for Actions)
gh secret set AWS_ACCESS_KEY_ID
gh secret set AWS_SECRET_ACCESS_KEY

# List secrets
gh secret list

# Delete a secret
gh secret delete <secret-name>
```

---

## Useful Defaults for This Project

| Item | Value |
|------|-------|
| Repo owner | `bthek1` |
| Repo name | `AWS_setup` |
| Default branch | `main` |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `not logged in` | Run `gh auth login` |
| `HTTP 401` | Token expired — run `gh auth login` again |
| `HTTP 403` | Insufficient token scopes — re-login and grant required scopes |
| `Could not resolve to a Repository` | Check `gh repo view` and confirm remote is set |
