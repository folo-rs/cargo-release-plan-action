# cargo-release-plan-action

Reusable GitHub integration for `cargo-release-plan`, distributed independently
from the Rust application in [folo-rs/folo](https://github.com/folo-rs/folo).

**Release candidate, not a published action release.** `release.json` selects
action 0.1.0, `cargo-release-plan` 0.4.1 and `cargo-semver-checks` 0.50.0.
Source checks do not establish that the exact crate and native archives are
published, or authorize production cutover.
See [release acceptance](TODO.md) for the remaining gates.

## Read-only workflow identity proof

The reusable `.github/workflows/identity.yml` canary resolves its own exact action
source from the calling run's attempt metadata, then executes a local composite
from that checkout. The caller grants only `actions: read` and `contents: read`.
It does not grant OIDC, repository write permissions or secrets.

Callers must use one action revision per workflow run. A whole-run rerun can
select the new commit behind a moving reference; a failed-job rerun retains its
original called workflow. Missing or ambiguous identity evidence is an error.

## Development

The integration uses PowerShell 7.6, Git, Rustup/Cargo and GitHub CLI. Official
action dependencies use Node.js 24 and require Actions Runner 2.327.1 or newer.
The native hosted runners in the source canary provide these prerequisites.

PowerShell 7.6 and Pester 5.7.1 run the bootstrap tests:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path tests -CI
actionlint -ignore '^unexpected key "queue" for "concurrency" section\.'
```

The hosted workflow pins Pester and actionlint, and exercises Linux, Windows and
macOS. Rust release policy and its tests belong in the application repository.
Maintainer documentation describes the [design](docs/design.md) and
[implementation](docs/implementation.md). The
[bootstrap acceptance evidence](docs/validation.md) records hosted identity,
rerun and native installation results separately from production release gates.
The narrow linter exclusion covers `queue: max`, which GitHub supports but the
pinned actionlint version does not recognize. Hosted scheduling tests exercise it.

## Standard reusable workflows

Pin `check.yml` and `release.yml` to one reviewed immutable action commit. Replace
`ACTION_COMMIT` below with that commit; no floating action tag is required.

```yaml
name: Release readiness
on: pull_request
permissions:
  contents: read
  actions: read
jobs:
  release-check:
    uses: folo-rs/cargo-release-plan-action/.github/workflows/check.yml@ACTION_COMMIT
    with:
      working-directory: .
      config: .cargo/release_plan.toml
```

The check workflow fetches the configured release branch, checks version and
publication inputs, and enforces captured-source API comparisons with the pinned
external checker. It supports fork pull requests without OIDC, writes or secrets.
The lower `version-readiness` command remains available for deliberately narrower
merge-queue checks using an explicit tested `base`.

```yaml
name: Release
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      source-sha:
        description: Optional original full SHA for explicit-source recovery
        default: ''
permissions:
  contents: write
  issues: write
  actions: read
  id-token: write
jobs:
  release:
    uses: folo-rs/cargo-release-plan-action/.github/workflows/release.yml@ACTION_COMMIT
    with:
      config: .cargo/release_plan.toml
      source: ${{ inputs.source-sha || '' }}
      publishing-environment: ''
```

Configure crates.io Trusted Publishing for this consumer's calling `release.yml`,
including `publishing-environment` if its registration specifies an environment.
The reusable workflow restricts permissions per phase. It holds one noncancelling
`queue: max` lock around the entire release, completes registry publication before
GitHub writes, and keeps independent native batches running after a tag failure.
The final report preserves failure and issues the original-source manual-tag
handoff. It never moves an existing tag.

Both workflows accept `working-directory`, `config`, `install-method` and
`source-path`. The workspace paths select the consumer release/check source, not
this action repository; `source-path` selects controller code in the caller's
invocation checkout.
For source dogfooding, choose `install-method: path` and point `source-path` at
the Folo tree containing the controller package. An optional consumer composite
at `.github/actions/release-plan-setup/action.yml` prepares build prerequisites;
it must not change release source. The lower composite supports custom job graphs.

### Reruns and explicit-source recovery

Reruns retrieve the original manifest. Attempt-qualified receipts and frozen
batches remain separate artifacts, and the reporter selects current applicable
evidence without overwriting prior files. Fixed native routing slots ensure
manual tagging can unblock work on a retry even if the first reconciliation
produced no batch for that target. Unused slots do not install or build tools.

If the original manifest was never uploaded or has expired, the original run
cannot resume safely. Start a **new** manual invocation with the recorded full
source commit instead of selecting the current branch tip:

```powershell
gh workflow run release.yml --ref main -f source-sha=ORIGINAL_FULL_SOURCE_SHA
```

This uses the recovery input in the example caller above. It prepares new
evidence at that explicit source, rather than inventing an old receipt. In source
mode the controller still builds from the invocation checkout, not the historical
release source, so recovery can use corrected automation.
The root `prepare-publish` command also accepts the exact source and an explicit
checkout for custom recovery workflows.

## Source dogfooding

The root composite exposes `version`, `version-readiness`, `check`,
`release-context`, `check-compatibility`, `check-published`,
`check-publishing-identity`, `prepare-publish`, `publish-registry`,
`publish-github`, `publish-binaries` and `publish-report`. Source
mode builds `packages/cargo-release-plan` from the selected Folo checkout using
the pinned installation compiler, independently of a consumer toolchain override.
It checks the executable's exact `--version` and adds its installation directory
to `PATH`. `version-readiness` requires a full immutable `base` SHA and does not
run the full pull-request gate.

`check` also forwards `config`, defaulting to `.cargo/release_plan.toml` relative
to `working-directory`. Rust validates publication inputs without remote writes.
An absent or invalid configuration fails the operation; the action neither parses
the configuration nor interprets human diagnostics. Neither offline command
provides external API compatibility checking.

`prepare-publish` requires `source` as a full immutable commit and `output` as the
publication manifest destination. `working-directory` selects a clean source
checkout with full history and tracked configuration, manifests and lockfile.
Keep the output outside that checkout or ignored. Rust fetches the configured
release branch, verifies source membership and writes immutable intent; the
action does not choose a branch tip or inspect publication policy.
GitHub-facing invocations receive the caller token; permissions remain the
caller's responsibility. Tool source builds and offline commands do not receive
that token from the action.

`source-path` selects controller code for installation independently of that
release checkout. Preparation performs no registry or GitHub writes and is not
a successful publication receipt.

`publish-registry` consumes the immutable `publication` file and writes a
separate `output` outcome. `working-directory` must select the clean original
source, not the current release-branch tip. Paths are absolute or relative to
that directory. Use a new outcome destination for each attempt and retain the
original manifest unchanged.

Set `dry-run: 'true'` to query crates.io availability without acquiring publishing
credentials or uploading. A successful dry-run still records `complete: false`;
it cannot authorize later publication phases. `dry-run` defaults to `'false'`,
matching the CLI. Real registry publication requires caller-provided GitHub OIDC
authority and configured crates.io Trusted Publishing. The calling consumer
workflow, not the reusable workflow, is the registered workflow identity.
Only the release registry job and setup probe receive OIDC. Adding a reusable
workflow does not schedule publishing in a consumer repository.

The command's failure remains a failed action even when it writes a partial
outcome. Preserve that file for diagnosis. Missing or invalid inputs can fail
without an outcome; an absent file is not evidence of empty work or success.
The action does not interpret stderr, reconcile registry state or rewrite receipts.

`publish-github` accepts `batches` for its new frozen-batch directory.
`publish-binaries` consumes `batch`, emits `output`, stages under `artifacts`,
and accepts `no-upload: 'true'`. `publish-report` consumes retained `outcomes`
and platform `jobs`, uses the caller `repository`, writes `output` even on
incomplete delivery, and accepts `no-issue: 'true'` for read-only inspection.

`install` and `binstall` use exact root-manifest pins. `binstall` permits normal
source fallback; archive acceptance separately forbids it. The manifest under
`tests/fixtures` is only a unit-test fixture and never a production fallback.
Source builds and source fallback need a native C/C++ toolchain and CMake.
Native staging uses `zip`/`unzip` on Unix; Windows installs the pinned standalone
`7za.exe` and retains its license, including x64 emulation on Windows ARM64.

## Release acceptance

The setup-only `.github/workflows/identity-probe.yml` installs its controller in a
read-only job, then transfers the exact executable to a separate job with
`id-token: write`. That job calls `check-publishing-identity` to exchange and
immediately revoke a crates.io credential without uploading a package. It accepts
`install-method`, `source-path` and optional `publishing-environment`.
When the Trusted Publisher registration specifies an environment, this input must
name that environment. Run one setup probe per workflow run.

Invoke the probe from the consumer's registered `release.yml` with its normal
publisher disabled for that invocation. The caller grants `contents: read`,
`actions: read` and `id-token: write`; the reusable workflow limits OIDC to its
probe job. Successful exchange does not prove every package's publishing grant.
The root `check-publishing-identity` command is also available to callers that
manage their own installation and permission boundaries.

`Published installation` fails while selected packages or promised archives are
unavailable. Source installation and unit-test fixtures cannot make that check
pass. Isolated jobs verify published-source installation,
the default binstall method and every promised native archive without source
fallback. Full protocol and external-checker acceptance must accompany their
implementation before release.

Required checks need repository-side enforcement; see [maintainer setup](docs/setup.md).
Do not publish action tags, merge this candidate or enable consumer
publishing until its release acceptance obligations are fulfilled.

Licensed under [MIT](LICENSE).
