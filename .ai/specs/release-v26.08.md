# Release prep: release/v26.08

This repo was prepared for release/v26.08 by the `release-start` command:

- branched from `origin/release-candidate` (auto-detected: release-candidate if present, else develop)
- version.gradle apply-from URLs repointed to `Android-Config/release/v26.08`
- back-merge comment added above repointed URLs
- `version.foundation_release` set to `5.5.49-RC2` (= tested `version.foundation` from release-candidate; release/* builds read foundation_release)

Restore the URLs to `develop` when merging `release/v26.08` back into develop (handled by
`release-finish`). pomVersion is NOT touched here — `-RC` is added per repo only at publish time.

## version.foundation_release bumped 5.5.49-RC2 -> 5.5.61 (OP-17678)

5.5.49-RC2 (inherited from v26.07 via release-candidate) is too old for this release's widget set.
`oneWidgetPublicTransport` and `oneWidgetReport` migrated off the OP-17065 Views and *onto* the new
Compose replacements in the same change, so no version of either widget builds against 5.5.49-RC2:
the old source uses deleted classes, the new source uses classes that do not exist yet.

5.5.61 is the only version that satisfies every widget in the release:

| Symbol | 5.5.49-RC2 | 5.5.61 | 5.5.75 |
|---|---|---|---|
| Compose `OneSlider` (PublicTransport) | absent | present | present |
| Compose `OnePageIndicator` (Report) | absent | present | present |
| `PageIndicatorView` (Consumption, Parking, Webview) | present | present | REMOVED 5.5.67 |
| `OneSeekBar` | present | present | REMOVED 5.5.62 |

Verified against the published AARs, not just the CHANGELOG.

Removals in the 5.5.50–5.5.61 window (`OneBadgeLayout` 5.5.58, `OneExpandableListIndicator` +
`OneViewPdfFilePreview` 5.5.52) have zero references across all widget release/v26.08 branches.
`platform-auth` 5.0.58 was compiled against Foundation 5.5.28 and references none of the removed
views, so it is unaffected.

Every widget is republished at its next `-RC` iteration against 5.5.61.
