# Maintainer setup and action release

## Merge requirements

The action repository's `main` branch was observed unprotected when this candidate
was prepared: the branch API reported `protected: false`, repository ruleset
discovery returned no rulesets, and the branch-protection endpoint reported
`Branch not protected`. A failed check alone therefore does not prevent merging.

An authorized repository administrator must enforce these stable check names
before merging a releasable candidate:

| Required check | Obligation |
| --- | --- |
| Action validation | Bootstrap/invocation tests, exact-source identity and workflow syntax. |
| Source installation | Source installation and real read-only/no-upload operations on every promised native target. |
| Published installation | Actual exact published source, native archives without fallback and external checker. |
| Workflow scheduling | Hosted queue and artifact-routing semantics. |

Use a branch ruleset or branch protection targeting `main`, require pull requests
and these checks from GitHub Actions, and choose administrator/bypass policy
explicitly. Do not treat source-mode success as a substitute for Published
installation. No protection or ruleset changes are performed by this integration.

## Version selection

`release.json` is the action's independent release plan. Its `action_version`
selects the action tag; `tools` selects the exact tested application and checker
versions. The initial candidate is action 0.1.0 with CRP 0.5.0 and checker 0.50.0.
The compiler, binstall and Windows archive installer are also pinned.

The native target/runner table declares the archive promises tested by
Published installation. Source-mode controller versions come from the selected
source metadata, never from released executable caches. The checker remains a
separately pinned external tool in source mode.

## Release procedure

Keep the PR as a draft while any mandatory installation or live-acceptance gate
is unavailable. The tool-owning repository first publishes the selected CRP
crate and native archives through its working publisher under separate
authorization. Explicitly rerun Published installation after those assets exist.

Run the candidate validation workflow at the exact candidate revision. Complete
the separately authorized live consumer pilot before production adoption:
identity exchange/revocation alone does not establish package-specific upload
grants or final binary delivery.

```powershell
gh workflow run validate-release.yml --ref CANDIDATE_BRANCH -f version=0.1.0
```

Confirm that the resulting run's source SHA is the reviewed candidate commit;
dispatching a branch does not make later changes to that branch part of the run.

After human authorization, publish immutable `v<action_version>` from that exact
tested commit, then advance the matching major reference to it. Publishing tags,
creating a GitHub/Marketplace release and consumer production cutover are
separate authorized operations; no push or PR workflow here performs them.
The action release description should identify the pinned tool combination.

## Consumer permissions and environment

Readiness checks need only `contents: read` and `actions: read`. Release callers
grant the workflow ceiling (`contents: write`, `issues: write`, `actions: read`,
`id-token: write`); called jobs reduce it to the phase-specific permission set.

Register crates.io Trusted Publishing against the consumer's entry workflow
`release.yml`, not this repository's called workflow. A registered environment
must match `publishing-environment`. Neither registration nor an environment is
created by the action. The identity probe proves exchange and immediate revocation
without uploads; each package's grant is a separate publication prerequisite.

No PAT, cross-repository secret, stronger tag credential or privileged runner
setup is required by this design.
