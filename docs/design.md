# Reusable release integration

## Goals and responsibilities

This repository distributes the GitHub integration for `cargo-release-plan`.
Rust owns version assessment, configuration, publication reconciliation, artifact
validation and reports. The action owns exact installation, process invocation,
permissions, job routing and artifact transport.

The root composite selects an operation using `command`. Repository policy comes
from one configuration file relative to `working-directory`. An optional consumer
action at `.github/actions/release-plan-setup/action.yml` prepares Cargo build
prerequisites; it is not a release-policy hook.

## Distribution and source identity

Action releases have their own version, independent of the application version.
A release manifest selects exact application and external-tool versions.
`binstall` permits normal source fallback, `install` builds the exact published
package, and `path` builds the explicitly selected source checkout. Source mode
never restores a released executable cache.

Reusable workflows use the composite from their own exact action-repository
commit, not from the caller's commit or a separately resolved moving tag. The
consumer token needs `actions: read` for workflow-attempt metadata and
`contents: read` for checkout. Identity discovery never needs OIDC or a write token.
One workflow run uses one action revision.

## Checks and publication

Ordinary pull requests receive the full read-only gate: version readiness,
publication-input validation and supported external compatibility checks.
Fork pull requests use the tested source and base-repository release history,
without `pull_request_target` or publishing credentials. A separately exposed
version-readiness operation supports intentionally narrower merge-queue checks.

Release history is actual configured release-branch history, not the PR base or
a synthetic queue head. A merge target is the tested destination snapshot for a
PR or queue candidate. CRP interprets a not-yet-merged target as one final
snapshot/version release unit while retaining actual-history package anchors
for catch-up assessment. The action supplies these identities separately.
Readiness and compatibility share one context-resolved pair; ancestry
normalization, stale-target diagnostics and version decisions remain in Rust.

PR and merge-group targets come directly from their event payloads. Other check
events do not infer a merge target or treat candidate HEAD as release history.
Callers may explicitly select a known release-history commit. Merge-queue
readiness supplements individual PR checks rather than redefining their release
decisions according to queue batching.

Publication preserves an immutable source manifest and separate attempt outcomes.
Registry completion is a prerequisite to any GitHub writes. GitHub reconciliation
emits immutable native batches bound to actual package-tag commits. A tag failure
fails the run but does not prevent independent batches. Recovery creates the
missing tag at the original recorded source and retries the original failed run;
reconciliation refreshes tags and schedules newly unblocked batches.

The root registry operation consumes the unchanged publication manifest from
the original clean source and emits a new outcome for each attempt. Its dry-run
mode reads registry availability without publishing authority. A successful
dry-run is not completion, and a failed invocation can retain a partial outcome.
Missing outcomes are not interchangeable with valid empty work.

Native targets are x86_64 and aarch64 Linux and Windows, plus aarch64 macOS.
Release runs use non-cancelling `queue: max` serialization and matrix fail-fast is
disabled. Trusted Publishing registers the consumer's calling `release.yml`
workflow identity and optional environment, not the reusable workflow's identity.

## Acceptance boundaries

Read-only identity proofs and source-mode checks do not prove published
installation or production delivery. Action release requires exact published
package installation, clean native-archive installation without source fallback,
and the separately authorized live acceptance pilot. Unavailable pins block that
gate. This repository does not grant tagging authority, configure Trusted
Publishers or enable consumer publication.
