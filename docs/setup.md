# Maintainer setup and action release

## Merge requirements

An authorized administrator must require pull requests and these GitHub Actions
checks on `main` before merging a releasable candidate:

| Required check | Obligation |
| --- | --- |
| Action validation | Bootstrap/invocation and release tests, action version readiness, exact-source identity and workflow syntax. |
| Source installation | Source installation and real read-only/no-upload operations on every promised native target. |
| Published installation | Fresh exact published-source and archive-only installation on every manifest target, with external-checker acceptance. |
| Workflow scheduling | Hosted queue and artifact-routing semantics. |

The workflows report these aggregates for all pull-request file changes,
including documentation-only changes. Source-mode success does not replace
Published installation. Up-to-date checks and no bypass are required.
No approving-review count or merge queue is required by this design.
The integration does not mutate repository rules.

### How hosted macOS capacity failures are detected

[WorkflowGate.psm1](../.github/scripts/WorkflowGate.psm1) detects capacity failure
from **authenticated GitHub check-run annotations**, not job logs or a
queued/cancelled status. Using the workflow token with `actions: read` and
`checks: read`, it follows the job's `check_run_url` only within the current
repository's API, reads `GET /repos/{owner}/{repo}/check-runs/{check_run_id}`,
then paginates
`GET /repos/{owner}/{repo}/check-runs/{check_run_id}/annotations`.
At least one annotation must have level `failure` and this **exact,
case-sensitive** message (no trailing period):

```text
The job was not acquired by Runner of type hosted even after multiple attempts
```

The only permitted accompanying annotation has level `notice` and this exact,
case-sensitive message; it may appear more than once:

```text
Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.
```

**The notice alone is insufficient.** Any other annotation, unreadable evidence,
or mismatch between the fetched annotations and `output.annotations_count`
blocks the exception. Annotation text is compared as data, never executed.

The gate also requires all of the following:

- The authenticated run matches the current repository, run ID, head SHA, event
  and attempt. It paginates `GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs?filter=all`
  and selects the unique newest execution of each exact expected job name across
  attempts, retaining older successful jobs only when they were not rerun.
- The candidate is an explicitly allowlisted macOS leg, with labels exactly
  `["macos-latest"]`, status `completed`, conclusion `cancelled`, a present and
  empty `steps` array, and no allocated runner (`runner_id` zero/null and
  `runner_name` empty/null).
- Its check has the same job name and head SHA, belongs to the run's check suite,
  is owned by GitHub Actions (app ID `15368`, slug `github-actions`), and is also
  `completed`/`cancelled`. The gate rechecks run identity after reconciliation.

Queued status can mean a job is still waiting; cancellation can be user-requested
or unrelated to capacity. Neither proves acquisition failure. Missing, unknown
or contradictory evidence, skipped dependencies, non-macOS failures and real
executed-step failures remain blocking. A proven exception emits an explicit
warning naming the job, ID and attempt; the raw job remains cancelled, not passed.

Published installation permits this exception only on pull requests. Its Linux
archive leg independently downloads the exact macOS archive using only
`crate-meta-data`; missing registry packages or archives still block without
source fallback. Main publication and manual published-installation validation
continue to require every native execution. Consumer publication and promised
release artifacts are unchanged.

## Version selection

`release.json` owns the independent `action_version`, exact `tools` versions,
installation compiler, installer and native target/runner table. The selected
combination is action 0.2.4, CRP 0.8.10, checker 0.50.0, Rust 1.98.1 and
cargo-binstall 1.23.0. Source canaries use exact CRP candidate source
2f69a49f51f1986db02a1e89839997a2b769645e from the
[paired Folo dependency candidate](https://github.com/folo-rs/folo/pull/972).
This source pin does not establish published-package or archive availability.

Validation, installation and consumer workflows use `ubuntu-latest` and
`windows-latest` for x64 and `macos-latest` for ARM64 to follow GitHub's current
stable hosted images. Linux and Windows ARM64 retain `ubuntu-24.04-arm` and
`windows-11-arm` because no matching latest aliases exist. Target selection and
native acceptance continue to verify operating system and architecture rather
than assuming an image version.

CRP exposes CLI/artifact contracts: plan/report/prepared schema 8,
decisions schema 2, compatibility schema 3 and release-context schema 2. It does not expose
a supported Rust library API. Source-mode controller versions come from source
metadata, not executable caches or the published CRP pin; its checker is still
separately pinned.

The independent action patch version selects latest hosted x64 images in
distributed consumer workflows without changing CLI, schema or command contracts.
Native source preparation installs the selected compiler without updating the
shared Rustup executable. Planning and compatibility contracts
include defining-type origins and explicit unsupported procedural-macro evidence.
Consumers use matching planning evidence and keep command inputs stable; the
action does not convert older artifacts.

Runtime, consumer workflow and pin changes require an action increment.
Documentation, tests and owned CI-only edits may retain the version and release
identity. Keep one pending increment for the whole candidate.

## Release procedure

1. Select exact versions and matching source canaries. The tool owner must publish
   the selected packages and native archives first; metadata availability alone
   is not action installation acceptance.
2. Obtain the current candidate's required PR checks and inspect every source and
   published installation leg. Rerun failed availability checks when upstream
   publication completes; they do not rerun automatically.
3. Have the maintainer accept production pilot evidence, confirm enforcement of
   the main rules policy and authorize the merge. Merging is authorization
   to publish the action, not a nonpublishing staging operation.
4. Observe `publish-action.yml` repeat installation at the exact merged commit,
   then reconcile `v<action_version>`, a nondraft/non-prerelease GitHub Release
   with generated notes, and the matching major reference. Verify actual objects,
   not just a green workflow. Full-version tags never move; equivalent CI-only
   reruns retain their original commit. GitHub uses its default Latest selection.
5. Update consumer references to the published immutable commit in a separately
   authorized follow-up. Folo retains `install-method: path`, `source-path: .`
   and its registered calling `release.yml` identity. Its pointer-only adoption
   does not require a Cargo package version increment.

The [release acceptance evidence](validation.md) records production pilots and
their installation methods separately from published-installation acceptance.
No additional live upload or OIDC probe is needed for action publication.

## Recovery and optional validation

Retry the failed main publication run to retain its original source commit.
The serialized phase refreshes tags, verifies content and reconciles missing
objects. A new dispatch on main repeats acceptance for the selected main commit:

```powershell
gh workflow run publish-action.yml --ref main
```

Dispatch is a publishing operation requiring authorization. Do not create a
manual first tag or move a conflicting full-version tag. Diagnose a conflict
before further writes. The ordinary workflow token is sufficient.

`validate-release.yml` is an optional read-only convenience after the workflow
is registered on main. It is not a first-merge bootstrap prerequisite. The same
validation is already available through the PR checks:

```powershell
gh workflow run validate-release.yml --ref CANDIDATE_BRANCH -f version=0.2.4
```

## Consumer permissions and environment

Readiness needs `contents: read` and `actions: read`. Consumer release callers
grant `contents: write`, `issues: write`, `actions: read` and `id-token: write`;
called jobs reduce that ceiling per phase. This consumer publisher is distinct
from `publish-action.yml`, which never requests OIDC.

Register crates.io Trusted Publishing against the consumer's calling `release.yml`,
not this repository's reusable workflow. A registered environment must match
`publishing-environment`. The identity probe exchanges and immediately revokes
a credential without uploading; package publishing grants remain separate.
No PAT, cross-repository secret or stronger tag credential is required.
