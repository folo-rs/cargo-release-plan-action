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

Licensed under [MIT](LICENSE).
