# cargo-release-plan-action

Reusable GitHub integration for `cargo-release-plan`, distributed independently
from the Rust application in [folo-rs/folo](https://github.com/folo-rs/folo).

**Bootstrap candidate, not a released publisher.** Production tool pins and the
complete release workflow are not available from this repository yet. No action
release or production publishing setup is implied by its read-only checks.
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
actionlint
```

The hosted workflow pins Pester and actionlint, and exercises Linux, Windows and
macOS. Rust release policy and its tests belong in the application repository.
Maintainer documentation describes the [design](docs/design.md) and
[implementation](docs/implementation.md). The
[bootstrap acceptance evidence](docs/validation.md) records hosted identity,
rerun and native installation results separately from production release gates.

## Source dogfooding

The root composite exposes `version`, `version-readiness`, offline `check`,
read-only `prepare-publish` and `publish-registry`. Source
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
The invocation receives the caller's GitHub token for read access through GitHub
CLI; the caller must grant `contents: read`. Tool source builds and offline
commands do not receive that token from the action.

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
This candidate has no hosted workflow granting that authority.

The command's failure remains a failed action even when it writes a partial
outcome. Preserve that file for diagnosis. Missing or invalid inputs can fail
without an outcome; an absent file is not evidence of empty work or success.
The action does not interpret stderr, reconcile registry state or rewrite receipts.

`install-method: install` and the default `binstall` remain blocked until the
root `release.json` pins the finalized application. The manifest under
`tests/fixtures` is only a unit-test fixture; its old published version does not
claim support for the unified protocol. It is never a production fallback.

## Release acceptance

`Published installation / manifest` deliberately fails while production pins are
unavailable. Source installation and unit-test fixtures cannot make that check
pass. With finalized pins, isolated jobs verify published-source installation,
the default binstall method and every promised native archive without source
fallback. Full protocol and external-checker acceptance must accompany their
implementation before release.

Do not publish action tags, merge this bootstrap candidate or enable consumer
publishing until its release acceptance obligations are fulfilled.

Licensed under [MIT](LICENSE).
