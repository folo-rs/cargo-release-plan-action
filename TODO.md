# Release acceptance

- Agree the unified application's exact published version, CLI flags and artifact
  protocol with the owning `folo-rs/folo` change before committing production pins
  or enabling publisher orchestration.
- Pass clean published-source and native-archive installation gates independently
  from the [verified source and workflow identity checks](docs/validation.md).
- Extend the published gate to the finalized full-check/publication CLI and exact
  external compatibility-checker installation. The bootstrap gate checks only the
  currently exposed offline check, preparation and registry flags.
- Complete the authorized immutable-candidate live acceptance pilot before action
  release or production cutover. Do not publish action tags, configure Trusted
  Publishers or enable consumer publishing as part of read-only validation.
