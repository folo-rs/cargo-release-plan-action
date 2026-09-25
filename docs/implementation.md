# Implementation

## Bootstrap boundary

GitHub-owned orchestration lives in YAML and a small PowerShell bootstrap.
Release-policy parsing, reconciliation and rendered reports belong in the
`cargo-release-plan` executable rather than in a second shell implementation.

## Exact reusable-workflow source

`action-source.yml` is a private reusable workflow called using a relative
workflow reference. GitHub selects it at the enclosing workflow's commit.
Before any action-owned file can execute, its inline bootstrap queries
`GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt}` with the
caller's read-only token. It selects the exact action-source workflow path from
`referenced_workflows` and requires one unique, full commit SHA.

The attempt endpoint matters on reruns: a whole-run rerun can resolve a moving
reference again, whereas failed-job reruns retain the original called workflow.
The caller's `github.sha` and `github.workflow_ref` describe the caller and are
not evidence of the called action's revision. Neither a mutable-ref lookup nor
OIDC is a fallback when attempt metadata is missing.

Downstream jobs check out the public action repository at the resolved SHA with
persisted credentials disabled and call its composite through a local path.
Multiple action revisions in the same run are rejected if their source metadata
is ambiguous; the bootstrap does not guess which call it is serving.

References:

- [Workflow run attempts](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt)
- [Reusing workflows and rerun behavior](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)

## Evidence

`ActionSource.Tests.ps1` extracts and executes the inline bootstrap itself.
Fixtures cover caller/source separation, SHA and tag spellings, nested calls,
repeated and ambiguous identities, missing metadata, API errors and attempts.
These are unit fixtures, not evidence that GitHub resolves a tag in a particular
way.

`identity.yml` is the read-only hosted canary. It checks out the resolved action,
executes an action from that checkout, compares its Git commit with the expected
SHA and writes caller/action identities to the job summary. Its optional
first-attempt failure exists solely to exercise rerun behavior. It requests no
OIDC, repository write or publication permission.
