# Release prep: release/v26.08

This repo was prepared for release/v26.08 by the `release-start` command:

- branched from `origin/release-candidate` (auto-detected: release-candidate if present, else develop)
- version.gradle apply-from URLs repointed to `Android-Config/release/v26.08`
- back-merge comment added above repointed URLs
- `version.foundation_release` set to `5.5.49-RC2` (= tested `version.foundation` from release-candidate; release/* builds read foundation_release)

Restore the URLs to `develop` when merging `release/v26.08` back into develop (handled by
`release-finish`). pomVersion is NOT touched here — `-RC` is added per repo only at publish time.
