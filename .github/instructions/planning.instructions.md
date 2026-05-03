---
description: "Use when planning new features, designing technical solutions, or starting any multi-phase implementation. Covers plan file structure, phase requirements, deliverables, and completion criteria."
applyTo: "docs/Plans/**"
---

# Planning Guidelines

## Where Plans Live

All feature planning and technical design must be documented as markdown files in `docs/Plans/`.

- **Location**: `docs/Plans/` - use subdirectories to organize by status
  - `docs/Plans/In_progress/` - active work
  - `docs/Plans/Completed/` - finished features
- **Format**: One markdown file per feature (e.g., `CRM_ANALYTICS_GRAPHS_PLAN.md`)
- **Phases**: Break every plan into clearly numbered phases

## Phase Requirements

Each phase must:

- Represent a **self-contained, deployable increment** - the codebase must remain functional after completing it
- Include **specific deliverables** (models, views, APIs, templates, etc.)
- Include **testing requirements** - unit tests and/or integration tests that verify stability
- Be **completable independently** before the next phase begins

## Phase Template

```markdown
## Phase N: <Short Title>

**Status**: Not started | 🔄 In Progress | ✅ Completed <date>

**Goal**: One-sentence description of what this phase delivers.

**Deliverables**:

- [ ] Item 1
- [ ] Item 2

**Tests**:

- [ ] Test coverage for item 1
- [ ] Test coverage for item 2

**Stability Criteria**: What must pass before this phase is considered complete.

**Notes**: Deviations, decisions, or follow-up items (fill in when completing the phase).
```

## Rules

- **DO plan in phases** - never design a feature as a single monolithic block
- **DO write the plan file first** before starting implementation
- **DO update the plan after every phase** - mark the phase complete, add status notes, mark the next phase as in progress, and record what was actually built (deviations, decisions, follow-up items) in the phase's **Notes** section
- **DO NOT skip testing requirements** - each phase must have passing tests before the next begins
- Plans are living documents; move the file from `In_progress/` to `Completed/` when done
- **AT THE END OF EVERY PLAN**: run `ruff check` on all modified files and fix any linting errors; also check the Problems tab and resolve all reported issues before considering the plan complete
- **UPDATE RELEVANT DOCS**: after completing a plan, update any `docs/project_docs/` files (architecture, guides, standards) that describe the changed behaviour - do not leave docs out of sync with the implementation
