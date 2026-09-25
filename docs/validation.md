# Bootstrap acceptance evidence

## Scope

This evidence verifies exact action-source selection and tool bootstrap. It does
not establish the full compatibility gate, published installation, OIDC exchange,
registry upload or production delivery.

## Hosted workflow identity

Every proof grants only `actions: read` and `contents: read`. The nested resolver
queries the consumer's current workflow attempt and the verification job executes
a composite from the resulting action checkout.

The proof uses these action commits:

- Original source: f2f0621e8e1550ab831c75b70c292bb7315ea77d
- Moved reference source: a22e2cba19d71f505c6f40bb9acee9e5032b7a3f
- Test caller source: b57ca721ed55fa9d2ca595aa11ca20510980cf6e

| Case | Hosted evidence | Result |
| --- | --- | --- |
| External Folo caller, nested workflow, exact SHA | [Folo run 36189373798](https://github.com/folo-rs/folo/actions/runs/36189373798) | Original action source selected independently of the consumer's source. |
| Explicit SHA caller | [Run 36189530956](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36189530956) | Original action source checked out and executed. |
| Immutable test tag | [Run 36189530567](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36189530567) | Original action source checked out and executed. |
| Failed-job rerun after moving the test major | [Run 36189530689, attempt 2](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36189530689/attempts/2) | Resolver re-executed and retained the original action source. |
| Whole-run rerun of that same run | [Run 36189530689, attempt 3](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36189530689/attempts/3) | Resolver and composite used the moved reference source. |

The rerun proof fails a prerequisite on its first attempt, before the resolver.
Therefore the failed-job retry really executes identity discovery again; it does
not merely reuse an earlier successful resolver output.

The isolated proof references are
`identity-canary-70d4d6e8-v0.0.1` and `identity-canary-70d4d6e8-v0`. They are
test-only names, not action releases, and both refs are deleted after the proof.
Reproducing the experiment requires new
uniquely named temporary refs and cleanup of those exact owned refs.
The temporary callers are retained in the test caller commit above; the
permanent validation workflow exercises the current revision through
`identity.yml`.

## Source installation

[Run 36192209769](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36192209769)
builds source checkpoint 92e422059e4d524909160517c216f147d2d2d430 from
`folo-rs/folo` using action commit e93a6e90527ce24eb4204e980c62bf88f0430dcb.
All native legs succeed:

| Runner | Native target |
| --- | --- |
| ubuntu-24.04 | x86_64-unknown-linux-gnu |
| ubuntu-24.04-arm | aarch64-unknown-linux-gnu |
| windows-2025 | x86_64-pc-windows-msvc |
| windows-11-arm | aarch64-pc-windows-msvc |
| macos-15 | aarch64-apple-darwin |

Installation uses Rust 1.98.1 from a nested consumer directory whose
`rust-toolchain.toml` selects 1.88.0, with `RUSTUP_TOOLCHAIN=1.88.0` also set.
The installed standalone executable reports `cargo-release-plan 0.4.0`, is the
executable selected through `PATH`, and exposes the supported offline check
flags including `--config`. Source mode uses no released executable cache.

These source version and toolchain values identify this experiment, not the
future production tool pin or the minimum supported Cargo publication runtime.

## Actual consumer operations

[Run 36193668716](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36193668716)
executes the installed application through the action's invocation adapter against
a disposable publishable library. Narrow version readiness and config-aware
offline checking succeed; missing configuration fails. The source remains clean.

[Run 36194230068](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36194230068)
installs verified preparation source e0616415059db4382b23a396d93fd42965c5a685 on
every supported native runner. Its Linux consumer fixture additionally invokes
real `prepare-publish` using repository-local Git URL rewriting. The resulting
envelope identifies the selected source, repeated preparation preserves identical
bytes and source remains clean. This exercises the read-only preparation operation
without remote writes or publication credentials.

## Regression and release gates

[Run 36192210190](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36192210190)
passes the bootstrap and invocation tests on Linux, Windows and macOS, workflow
syntax checks, and same-revision identity verification.

[Published-installation run 36192209989](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36192209989)
fails explicitly because the root `release.json` is absent. This is the expected
release blocker, not a passing installation result. Test fixture pins and source
canaries cannot satisfy it. Remaining product acceptance is tracked in
[release acceptance](../TODO.md).
