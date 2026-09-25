# cargo-release-plan-action

Reusable GitHub integration for `cargo-release-plan`, distributed independently
from the Rust application in [folo-rs/folo](https://github.com/folo-rs/folo).

**Bootstrap candidate, not a released publisher.** Production tool pins and
publication commands are not available from this repository yet. No action
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

PowerShell 7.6 and Pester 5.7.1 run the bootstrap tests:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester -Path tests -CI
actionlint
```

The hosted workflow pins Pester and actionlint, and exercises Linux, Windows and
macOS. Rust release policy and its tests belong in the application repository.
Maintainer documentation describes the [design](docs/design.md) and
[implementation](docs/implementation.md).

## Source dogfooding

The root composite exposes `version`, `version-readiness` and offline `check`. Source
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
