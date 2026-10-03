# Release handoff

Candidate implementation acceptance for action 0.1.0 with CRP 0.5.10 is recorded
in [the evidence record](docs/validation.md), including fresh install and strict
archive-only binstall on every native target. Keep the final PR head's required
checks green before seeking merge authorization.

- Have an administrator approve and enforce the main pull-request/check policy
  in [maintainer setup](docs/setup.md). Main currently has no effective protection.
- Obtain maintainer acceptance of the recorded Folo production runs as pilot
  evidence, qualified by their source-installed controllers and unchanged consumer
  contracts, and explicit authorization for the main merge that publishes.
- Observe the authorized main publisher; record the release URL, immutable commit,
  main installation/publication runs and verified full-version/major references.
- Complete separately authorized Folo adoption of the released immutable action
  commit across its root/check/release/identity-probe references. Preserve source
  mode and the registered consumer workflow identity; observe its ordinary run.

The selected CRP packages and native archives are already published. No new live
upload, Marketplace listing, manual bootstrap tag, Trusted Publisher change or
individual PR automation belongs to this handoff.
The [evidence record](docs/validation.md) separates published installation,
source/no-upload checks and actual production delivery.
