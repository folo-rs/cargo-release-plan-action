# Release acceptance

- Agree the unified application's exact published version, CLI flags and artifact
  protocol with the owning `folo-rs/folo` change before committing production pins
  or enabling publisher orchestration.
- Prove exact called-source identity on hosted SHA, immutable-tag and moving-major
  callers, including nesting, whole-run and failed-job reruns.
- Pass source-mode consumer checks independently from clean published-source and
  native-archive installation gates.
- Complete the authorized immutable-candidate live acceptance pilot before action
  release or production cutover. Do not publish action tags, configure Trusted
  Publishers or enable consumer publishing as part of read-only validation.
