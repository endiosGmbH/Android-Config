# Spec: Auto-publish widgets on release branches via reusable workflow

**Ticket:** [AGENCY-7501](https://endios.atlassian.net/browse/AGENCY-7501)
**Created:** 2026-05-26
**Status:** Draft

## Context

Each Android widget repo currently owns a near-identical copy of `.github/workflows/release.yml`. The trigger is hard-coded to `develop`, so version bumps made on `release/*` branches do not publish artifacts to Maven — someone has to publish by hand. AGENCY-7436 hit this exact gap on `release/v26.04` of `oneWidgetOffers`.

The literal fix is one line per repo. But since we are about to touch every widget repo anyway, this is also the right moment to centralise the workflow body: the only thing that genuinely varies per repo is the list of publishable modules.

Scope of *this* spec is a **pilot**: introduce the reusable workflow in Android-Config and migrate `oneWidgetOffers-Android` to it. The remaining 52 widget repos are out of scope and will be handled in a follow-up sweep once the pilot is verified on `release/v26.04`.

## Requirements

### Functional
- A reusable workflow lives in `Android-Config/.github/workflows/widget-publish.yml` and accepts a list of Gradle modules as input. It performs the same checkout / JDK setup / `local.properties` injection / `gradle build` + `gradle publish` steps the existing per-repo workflows do today.
- `oneWidgetOffers-Android/.github/workflows/release.yml` is replaced with a thin caller that:
  - Triggers on push to `develop` **and** `release/**`.
  - Delegates to the reusable workflow with its 3 publishable modules listed: `oneWidgetOffers`, `oneWidgetOffersLarge`, `oneWidgetOffersBasic`.
  - Inherits secrets so FTP/htaccess creds reach the reusable workflow.
- A push to `release/v26.04` triggers the publish job and produces Maven artifacts at the new pomVersion (`4.5.11-RC`, already bumped by AGENCY-7436).
- The `develop` trigger remains functionally unchanged: pushes to develop still publish.

### Non-Functional
- The deprecated module `oneWidgetProfilePremium` (only present in the ProfilePremium repo, not Offers) must remain unpublished — i.e. the design must support repos that have modules in `settings.gradle` which intentionally do *not* go to Maven. The explicit-list approach satisfies this.
- The reusable workflow file is the single source of truth for publish logic. Future changes (JDK bump, new secrets, etc.) should land in Android-Config once, not in 53 repos.

## Behaviors (Verification Plan)

This is a CI/infra change — there are no unit tests to write. Instead, each behaviour below is verified by observing the GitHub Actions run after the change is merged. The checklist is for the pilot only.

1. [ ] Reusable workflow defined: `Android-Config/.github/workflows/widget-publish.yml` exists with `on: workflow_call`, accepts a `modules` input (JSON array), and runs build+publish for each entry.
2. [ ] Caller in `oneWidgetOffers-Android/.github/workflows/release.yml` triggers on `develop` **and** `release/**`, references `endiosGmbH/Android-Config/.github/workflows/widget-publish.yml@develop`, lists the 3 Offers modules, and uses `secrets: inherit`.
3. [ ] Push to `develop` still results in a successful publish run for all 3 Offers modules.
4. [ ] Push (or merge) to `release/v26.04` triggers the publish run and produces 3 Maven artifacts at pomVersion `4.5.11-RC`. (AGENCY-7436's existing bump satisfies the precondition.)
5. [ ] Step names in the GitHub Actions UI remain readable per-module (e.g. `Build :oneWidgetOffers`, `Publish :oneWidgetOffers`) so log triage is unchanged.

## Technical Notes

- **Reusable workflow signature:**
  ```yaml
  on:
    workflow_call:
      inputs:
        modules:
          description: 'JSON array of Gradle module names to build and publish'
          required: true
          type: string
  ```
  Modules are iterated via matrix (`max-parallel: 1` to preserve current serial behaviour and avoid concurrent FTP uploads) so each step keeps a recognisable name in the Actions UI.
- **`uses:` pinning:** widget callers reference `@develop`. Rationale: widgets already consume Android-Config gradle scripts via local filesystem `apply from:` — there's no existing pin-to-tag convention to mirror. If publish drift becomes a problem we can switch to `@master` or a tag once the pattern is proven.
- **Secrets:** the FTP/htaccess creds (`ENDIOS_DE_FTP_USER`, `ENDIOS_DE_FTP_PASSWORD`, `ENDIOS_DE_HTACCESS_USER`, `ENDIOS_DE_HTACCESS_PASSWORD`) already live at the **endiosGmbH organization level** — confirmed via `gh secret list -R endiosGmbH/oneWidgetOffers-Android` returning empty while develop publishes succeed. The reusable workflow references them via `${{ secrets.* }}`; the widget caller uses `secrets: inherit` so the org-level values flow through. No secret management work is required for this ticket.
- **Affected files:**
  - `Android-Config/.github/workflows/widget-publish.yml` *(new)*
  - `Android-Config/.ai/specs/AGENCY-7501.md` *(this file)*
  - `oneWidgetOffers-Android/.github/workflows/release.yml` *(replace)*
- **Companion PR:** one PR in `Android-Config` (must land first), one PR in `oneWidgetOffers-Android` (depends on Android-Config PR being merged so `@develop` resolves to a commit that contains the reusable workflow).
- **Branches:** `feature/AGENCY-7501` in both repos.
- **No `pomVersion` bump** in either repo — this change does not produce a new artifact, it changes how artifacts get built.
- **Out of scope (follow-up):** migrate the remaining 52 widget repos. Tracked separately so the pilot can be verified end-to-end first.

## Open Questions

- Should the publish step run in parallel across modules (faster) or remain serial as today? Spec defaults to serial via `matrix.max-parallel: 1` to keep behaviour identical; happy to switch to parallel if the team prefers.
- Long-term: do we want to pin widget callers to `@master` or a tag once the pattern is stable, to insulate widgets from in-flight Android-Config develop changes?

## QA

**Recommended app:** _N/A — CI infra change, no app-level QA needed._
**Verification:** observe the GitHub Actions run on `release/v26.04` of `oneWidgetOffers-Android` after merge and confirm 4 Maven artifacts appear at version `4.5.11-RC`.
