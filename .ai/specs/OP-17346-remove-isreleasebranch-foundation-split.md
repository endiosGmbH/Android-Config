# Refactoring Specification: Remove the `isReleaseBranch` Foundation-version split

Ticket: OP-17346 · Related incident: OP-17339 (v26.07)

## Context

**Current State**

`Android-Config/version.gradle` carries two Foundation version variables and picks between them at
build time based on the *consuming repo's* branch:

```groovy
// version.gradle
version.foundation         = "5.5.46"      // LATEST (develop)
version.foundation_release = "5.5.46"      // STABLE (release/*, master)
def selectedFoundationVersion = isReleaseBranch() ? version.foundation_release : version.foundation
```

`isReleaseBranch()` (in `branch-utils.gradle`) returns true for `release/*` and `master`;
`getCurrentBranch()` reads the branch from CI env (`GITHUB_REF_NAME`, `GIT_BRANCH`, …). Auth has **no**
such split — `version_auth` always uses `version.foundation_auth`.

Each consuming repo also fetches `version.gradle` from a branch-specific URL
(`apply from: …/Android-Config/<branch>/version.gradle`), which `release-start` repoints per release
branch. So the Foundation version is now selected **twice**: once by *which config branch is fetched*,
and again by the *in-file `isReleaseBranch()` split*.

**Problem Statement**

- **Correctness footgun:** the two mechanisms can disagree. In v26.07 (OP-17339) the release branch
  fetched the correct `release/v26.07` config, but the in-file split still resolved
  `version.foundation_release`, which was stale (`5.5.12-RC4`, previous release) — so the whole
  release line built against the old Foundation and broke on newer Foundation APIs (Lottie tile).
- **Redundancy:** with per-branch config URLs, the fetched file is already branch-specific; the
  in-file split duplicates that decision.
- **Maintainability:** four tools encode the split (`release-start`, `release-finish`,
  `check-version-compat`, `rules/release.md`), so the concept must be kept consistent across all of
  them.

**Motivation**

One source of truth per branch: each config branch's `version.foundation` is exactly what that branch
builds against. Eliminates the class of bug where `foundation_release` drifts from the branch's intent.

**Urgency**

Not blocking (OP-17339 patched v26.07 directly and made `release-start` set `foundation_release` at
cut). This is the durable simplification; do it deliberately, not mid-release.

---

## Goals & Scope

**Objective**

Collapse to a single `version.foundation` per config branch; remove `version.foundation_release` and
the `isReleaseBranch()`-based Foundation selection. Consumer-facing `ext.version_foundation` /
`ext.version_auth` interface stays identical.

**Scope Included**

```
- Android-Config/version.gradle            (all branches: develop, master, release/*)
- Android-Config/branch-utils.gradle       (isReleaseBranch — remove/retire if unused elsewhere)
- endios-android-tools: release-start       (drop the foundation_release-from-release-candidate step added in OP-17339)
- endios-android-tools: release-finish      (update version.foundation on master instead of foundation_release)
- endios-android-tools: check-version-compat (compare against version.foundation for every branch)
- endiosAgentRules-Android/rules/release.md (remove the release/master → foundation_release rule)
```

**Scope Excluded**

- `version.foundation_auth` (no split today; unchanged).
- The per-branch apply-from URL repointing (keep — it is now the *only* selection mechanism).
- Any change to consuming repos' `build.gradle` (interface unchanged).

---

## Acceptance Criteria

**Behavior Preservation**
- [ ] A develop build resolves develop config's `version.foundation` (latest) — unchanged.
- [ ] A `release/vYY.MM` build resolves that release config's `version.foundation` (release Foundation).
- [ ] A `master` build resolves master config's `version.foundation` (last released Foundation) — **new**: previously read `foundation_release`.
- [ ] `ext.version_foundation` / `ext.version_auth` / `OVERRIDE_*` behavior identical for consumers.

**Correctness**
- [ ] No repo can resolve a Foundation version other than the one in the config branch it fetches.
- [ ] `check-version-compat` validates Auth↔Foundation using the single `version.foundation`.

**Cleanup**
- [ ] `version.foundation_release` removed from all Android-Config branches.
- [ ] `isReleaseBranch()` removed, or retained only if a non-version consumer still needs it (audit first).
- [ ] `release-finish` sets `version.foundation` on master to the released version; the OP-17339 `foundation_release` step in `release-start` is removed.
- [ ] `rules/release.md` updated.

---

## Technical Considerations

**Current architecture**
```
consumer branch ──▶ apply-from URL ──▶ Android-Config/<branch>/version.gradle
                                              │
                              isReleaseBranch(consumer branch) ? foundation_release : foundation
```

**Target architecture**
```
consumer branch ──▶ apply-from URL ──▶ Android-Config/<branch>/version.gradle
                                              │
                                        version.foundation   (single value, per branch)
```

**master semantics change (the main risk)**

Today master builds read `foundation_release`. After this change master builds read
`version.foundation`, so master's `version.foundation` must hold the last *released* Foundation.
`release-finish` becomes responsible for setting master's `version.foundation` (it already updates
`foundation_release` on a backmerge branch — repoint that to `version.foundation`). Verify no
develop-vs-master drift is introduced.

**Migration path**
1. Land config change on `develop` (single `version.foundation`, keep value = current latest).
2. Update the three commands + rules in the toolbox (one plugin bump).
3. Set master's `version.foundation` to the current released value in the same change (so master
   builds keep resolving stable).
4. Existing `release/*` branches already have a correct `version.foundation` (OP-17339); optionally
   drop their now-unused `foundation_release`.

---

## Design Decisions

**Why**: per-branch config URLs already isolate versions; the in-file split is redundant and was the
root cause of OP-17339. One value per branch is simpler and unambiguous.

**Alternatives considered**
- *Keep the split, just always set `foundation_release` correctly at cut (OP-17339)* — done as the
  interim fix, but leaves two variables to keep in sync (the footgun remains).
- *Remove the split only on release branches* — rejected: diverges `version.gradle` across branches
  and leaves master inconsistent.

---

## Test Strategy

- Dry-run `getCurrentBranch()`/resolution on develop, a `release/vXX.YY`, and master worktrees; assert
  each resolves its branch's `version.foundation`.
- Build one widget + the app on a `release/*` branch against the new config; assert the release
  Foundation resolves and compiles (the OP-17339 Lottie case).
- Run `check-version-compat` on develop, release, and master and confirm it reports against the single
  `version.foundation`.
- Confirm `release-finish` on a mock backmerge sets master's `version.foundation`, and `release-start`
  no longer needs the `foundation_release` step.
