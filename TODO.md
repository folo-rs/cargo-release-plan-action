# Release acceptance

- Publish the selected CRP package and native archives through the existing
  tool-owner publisher under separate authorization, then rerun clean published
  source/archive/checker installation acceptance independently of source checks.
- Enforce the required checks on `main`; the current fresh repository has no
  merge protection. Exact names and permissions are in [maintainer setup](docs/setup.md).
- Complete the authorized immutable-candidate live acceptance pilot before action
  release or production cutover. Do not publish action tags, configure Trusted
  Publishers or enable consumer publishing as part of read-only validation.

The [evidence record](docs/validation.md) distinguishes completed read-only and
identity proofs from package upload and complete live delivery.
