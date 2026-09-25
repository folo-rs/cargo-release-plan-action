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

## Installation

The composite first validates its command and selects an installation root.
Released modes require the root `release.json`; its SHA-256 digest, installation
method, runner OS and architecture form the installed-executable cache key. There are no prefix
restore keys. Cache hits still verify the selected executable's exact version.
The release manifest carries `schema_version`, independent `action_version`,
`install_toolchain`, `cargo_binstall_version` and exact versions under `tools`.

Source mode uses a distinct installation root and never invokes the executable
cache. Cargo metadata supplies the selected package version for executable
verification, and `cargo install --path --locked --force` rebuilds from the
selected checkout even if its declared version matches an existing binary.
The bootstrap explicitly selects the installation compiler; consumer rustup
overrides cannot silently select an older compiler.

The published-source path uses `cargo install --version =<version> --locked`.
The binstall path installs its exact installer and permits normal archive or
source fallback into the same isolated `--root`. Published-archive acceptance must separately disable source
fallback and use a clean root. Unit-test manifest fixtures do not satisfy that
acceptance gate.

## Offline invocation

`version-readiness` forwards `check` with the selected manifest, immutable baseline
and GitHub diagnostic format. It deliberately omits publication configuration.
The `check` action operation additionally passes one workspace-relative `--config`
path. Rust owns parsing and validating that file. The action does not infer
success from diagnostic text or hide the executable's failure.

Both operations are offline checks, not a replacement for the external
compatibility checker in the full pull-request gate.

## Publication preparation

`prepare-publish` forwards the explicit immutable `source`, workspace-relative
configuration and `output` destination to the installed controller. It runs from
the selected release checkout, independently of `source-path` used to install the
controller. Rust acquires release-branch history, validates the clean source and
creates or verifies the immutable publication file. The action does not parse
its human summary, fetch branch tips or rewrite its JSON.
Only the preparation invocation exports `github.token` as `GH_TOKEN`, enabling
the application's per-command GitHub CLI credential helper to read private
repositories. Installation and offline invocation do not receive this credential
from the action.

The hosted consumer canary uses a disposable, tracked Cargo library and
repository-local Git URL rewriting to exercise the real read-only fetch and
preparation path. It checks envelope source linkage, unchanged output on repeated
preparation and a clean source afterward, without contacting a registry writer
or receiving OIDC authority.

## Registry invocation

`publish-registry` forwards `publish registry`, the immutable publication path,
the original source manifest and a new outcome path. A canonical `dry-run`
boolean controls only the CLI's `--dry-run` switch. The bootstrap does not query
registry state, select package work or reinterpret exit status. Rust owns source
validation, Cargo ordering, OIDC exchange, credential cleanup and outcome creation.

The same immutable publication passes to each attempt. Outcomes are separate
files, and an error may leave either a failed outcome or no outcome if input
validation could not establish its identity. The adapter never creates a
substitute receipt, deletes a failed receipt or converts failure into a success.
A dry-run outcome is deliberately incomplete even when the invocation succeeds.

The source canary runs only dry-run registry operations with no OIDC or
publication credentials. It queries the real crates.io sparse index for a
uniquely named fixture package, checks `would_publish` without completion,
verifies that retry cannot overwrite an existing outcome and distinguishes
missing input from a valid failed-attempt receipt. No live upload or credential
exchange is part of this action-side proof.
