# Bootstrap acceptance evidence

## Scope

This evidence verifies exact action-source selection and tool bootstrap. It does
not establish published installation, registry upload or production delivery.
The external readiness and setup identity cases below exercise their specific
live integrations without granting a package-upload success claim.

## External readiness and publishing identity

[Folo run 36215204197](https://github.com/folo-rs/folo/actions/runs/36215204197)
invokes `identity-probe.yml` at
e4d98d54c913f41866774670a3e27236ddc1d5dd from the registered consumer
`release.yml`. Its controller job has no OIDC permission; the separate probe
exchanges the caller identity with crates.io and immediately revokes the temporary
credential. The consumer's ordinary publish, planning, native build and alert
jobs are explicitly skipped. This is real exchange/revocation evidence, not a
proof of every package's grant or any upload.

[Folo run 36215945180](https://github.com/folo-rs/folo/actions/runs/36215945180)
uses action 512ff6afc7e101f21243b15ed7dbedddc2ac052d to run the public
`check.yml` workflow. Release-context resolution, version/publication-input
validation, exact external checker installation and captured-source API
compatibility all execute successfully against the consumer repository.

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

## Registry dry-run contract

[Run 36202618251](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36202618251)
uses action commit cbe1a0dda7abe338f7acc3d9a15d618d9838e426 and reviewed Folo
source 70e69a525d4017d7659307d315a0b4d57ee93162, which declares
`cargo-release-plan 0.4.1`. Installation and command-flag verification pass on
every supported native runner.

The Linux consumer fixture runs the real registry command through the action
adapter. It has no OIDC or registry upload credentials and queries the public
crates.io sparse index for a uniquely named package. The observed contract is:

- Nonempty dry-run work yields `would_publish`, linked to the original publication
  ID, with `dry_run: true` and `complete: false`.
- Reusing an outcome path fails without changing its prior bytes.
- Missing publication input fails without producing an outcome.
- Source differing from the publication fails and retains a linked, incomplete
  outcome with errors.
- The original publication remains byte-identical and the fixture is clean after
  the deliberate source-mismatch case is restored.

This verifies dry-run invocation and outcome handling, not credential exchange,
registry upload or completion of the full release process.

[Run 36202618728](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36202618728)
passes the registry adapter's regression suite on Linux, Windows and macOS,
workflow validation and exact current-revision identity verification.

## Complete non-live command and native staging coverage

[Run 36216624842](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36216624842)
uses action e34f5027b7ae4755590204440cdb392bd2c2acfd. Every supported
native runner installs the controller and stages an actual frozen binary batch
without uploads. The batch produces a ZIP/checksum pair, remains explicitly
`no_upload` and incomplete as a delivery receipt, and leaves source clean.
Build output uses an absolute `CARGO_TARGET_DIR` outside source. Windows jobs use
the pinned standalone 7-Zip extra archive, including ARM64's emulated x64 tool.

The Linux job also installs the exact external checker, executes its real
self-comparison through CRP, records an unavailable comparison without inventing
compatibility, checks the GitHub phase's full registry prerequisite and exercises
both incomplete and valid empty-work reports without issue writes.

[Run 36216625025](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36216625025)
completes queued nested executions under one supported `queue: max` group without
cancelling queued work. Its synthetic artifacts exercise the production routing
helper; this is a scheduling proof, not a substitute for the command/native tests.

### Failed producer and native-only reruns

[Run 36216622141, attempt 1](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36216622141/attempts/1)
deliberately fails a synthetic reconciliation job after it writes usable routing
artifacts. Its independent native slots still execute; the producer's failure
remains visible. A separate queued execution deliberately fails only one native
slot after a successful producer. Queued executions are not cancelled.

[Attempt 2](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36216622141/attempts/2)
reruns the failed work successfully. The previously blocked target downloads the
new producer artifact from attempt 2 and is now requested. The native-only retry
downloads its successful producer artifact from attempt 1. This verifies both
failed-job output propagation and retained successful-job artifact IDs without a
second artifact-resolution mechanism.

The temporary caller is retained in commit
e34f5027b7ae4755590204440cdb392bd2c2acfd for reproduction; it is removed
from the ongoing check graph after the proof. The reusable scheduling fixture
has no source compilation, registry writes, tag writes or OIDC authority.

## Regression and release gates

[Run 36192210190](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36192210190)
passes the bootstrap and invocation tests on Linux, Windows and macOS, workflow
syntax checks, and same-revision identity verification.

[Published-installation run 36192209989](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36192209989)
fails explicitly because the root `release.json` is absent. This is the expected
release blocker, not a passing installation result. Test fixture pins and source
canaries cannot satisfy it. Remaining product acceptance is tracked in
[release acceptance](../TODO.md).

With the selected production candidate manifest present,
[run 36215690642](https://github.com/folo-rs/cargo-release-plan-action/actions/runs/36215690642)
fails actual installation: Cargo reports that `cargo-release-plan` version
`=0.4.1` is unavailable from crates.io. This is a publication dependency, not
source-mode acceptance. Enforcement of the separate check requires the
repository-side configuration described in [maintainer setup](setup.md).
