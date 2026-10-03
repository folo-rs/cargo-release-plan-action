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

## Version selection

`release.json` owns the independent `action_version`, exact `tools` versions,
installation compiler, installer and native target/runner table. The first
combination is action 0.1.0, CRP 0.5.10, checker 0.50.0, Rust 1.98.1 and
cargo-binstall 1.23.0. Source canaries use released CRP source
c87bba72df22124f87a3c858b15e858138c7008b.

CRP exposes CLI/artifact contracts: plan/report/prepared schema 6,
decisions/compatibility schema 2 and release-context schema 2. It does not expose
a supported Rust library API. Source-mode controller versions come from source
metadata, not executable caches or the published CRP pin; its checker is still
separately pinned.

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
gh workflow run validate-release.yml --ref CANDIDATE_BRANCH -f version=0.1.0
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
