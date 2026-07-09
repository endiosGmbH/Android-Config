# android-ci — Jenkins shared library

Shared pipeline steps for endios Android CI, hosted in this repo and registered in
Jenkins under the logical name **`android-ci`**. Analogous to the iOS `ios-ci` library
(OP-17160). First consumer: `endiosOneApp-Android` PR-verify (OP-17204).

Jenkins reads `vars/`, `src/`, and `resources/` from the repo root; the rest of
Android-Config (gradle scripts, `version.gradle`, `tooling/`) is ignored by the library.

## Contents

```
vars/
  androidPRVerify.groovy   # PR-verify pipeline (ktlint, detekt, lint, unit tests)
  githubStatusWrap.groovy  # per-check reporter via publishChecks (best-effort)
```

## Consuming it

Repo `Jenkinsfile.prverify`:

```groovy
@Library('android-ci') _
androidPRVerify()
```

Per-repo overrides (widgets/Foundation with different flavors):

```groovy
androidPRVerify(lintTask: 'lint', unitTestTask: 'testDebugUnitTest')
```

## Jenkins setup (one-time, infra)

1. **Register the library** — *Manage Jenkins → System → Global Pipeline Libraries*:
   name `android-ci`, default version `develop` (Android-Config's trunk), SCM = this repo.
   Tick *Allow default version to be overridden* so a repo can test a fix branch via
   `@Library('android-ci@some-branch')` before it merges.
2. **Shared webhook secret** — *Manage Jenkins → System → GitHub → Advanced → Shared secret*
   (a *Secret text* credential). Jenkins validates the webhook HMAC with it; the bouncer does not.

## Per-repo cutover checklist

For each repo (endiosOneApp done; widgets + Foundation to follow):

1. **Add `Jenkinsfile.prverify`** — thin wrapper: `@Library('android-ci') _` + `androidPRVerify(...)`
   (override `lintTask`/`unitTestTask` if the repo has different flavors).
2. **Delete `.circleci/config.yml`** — immediate cutover; a repo runs on exactly one CI.
3. **Create a Multibranch Pipeline job** pointed at `Jenkinsfile.prverify`. Branch-source
   **Behaviors — exactly one:**
   - ✅ *Discover pull requests from origin* → **"Merging the pull request with the current target branch revision"**
   - ❌ **No** *Discover branches* (builds every branch push → duplicate/irrelevant builds)
   - ❌ **No** *Discover pull requests from forks* (we take no external forks; its "head" strategy adds a `pr-head` status)
   - This yields a single status context: **`continuous-integration/jenkins/pr-merge`**.
4. **Webhook** — repo → Settings → Webhooks: URL `https://bouncer.jenkins.endios.one/github-webhook/`,
   content type `application/json`, secret = the shared secret above, events **Pushes + Pull requests** only.
5. **Branch protection** (target branch, usually `develop`): remove the `ci/circleci: *` required
   checks, add **`continuous-integration/jenkins/pr-merge`** as required. Keep *Require branches up to date*.

## Gotchas learned in the pilot (OP-17204)

- **Only the PR-verify job may discover PRs.** One webhook fans out to *every* Jenkins job whose
  branch source watches the repo. The `endiosOneApp-Android-Maestro` job discovered PRs and ran a
  full UI-test build on a PR-verify PR. Any other job on the repo (release, uitests, maestro) must
  **not** discover PRs. Nightly/manual jobs: keep branch discovery but add **"Suppress automatic
  SCM triggering"** so pushes don't auto-build (cron + manual still work).
- **Use the merge strategy, and diff against `origin/<target>`** — not the merge commit's parents.
  When a PR branch is already up to date with the target, Jenkins produces **no merge commit**, so a
  parent-based changeset resolves to empty and ktlint/detekt silently **skip** (a bad PR passes).
  `androidPRVerify` diffs `origin/${CHANGE_TARGET}...HEAD` (the branch source already fetches the
  target); if that ref is missing it fails closed by linting all Kotlin files.
- **Don't fetch inside an `sh` step.** `GIT_ASKPASS` credentials are scoped to `checkout scm`; a raw
  `git fetch` has none and dies with `could not read Username` on private repos. The target ref is
  already fetched — just diff against it.
- **`githubNotify` is not installed here; `publishChecks` is.** Status reporting uses `publishChecks`
  and is best-effort (a publish failure logs a warning, never fails the build).
- **Inline per-stage errors need a GitHub App.** With the current **PAT** branch-source credential,
  `publishChecks` logs `No suitable checks publisher found` — only the overall `pr-merge` status
  shows on the PR (details are in the Jenkins console). To render `ci/jenkins: *` checks and
  line-level annotations on the PR, the branch source must authenticate as a **GitHub App**.

## ⚠️ When Android-Config goes private

This library is loaded from Android-Config over SCM. Once the repo is private, Jenkins can no
longer fetch it anonymously — the Global Pipeline Library config **must** be given SCM checkout
credentials (a machine user / deploy key / PAT with read access). Without them, every consuming
job fails at library resolution before any stage runs. Update the library's *Source Code
Management → Credentials* at the same time the repo visibility changes.
