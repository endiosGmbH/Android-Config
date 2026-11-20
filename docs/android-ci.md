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
  androidScreenDiff.groovy # opt-in: Before / After / Diff screen report + flow tests
  githubStatusWrap.groovy  # per-check reporter via publishChecks (best-effort)
resources/android-ci/
  screen_diff.py           # pixel compare, HTML report, PR comment (Python stdlib only)
  screen_diff_test.py      # its unit tests: python3 resources/android-ci/screen_diff_test.py
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

## Which library version a job loads

`@Library('android-ci') _` loads the library's **default version**, set in the Global Pipeline
Library config: `develop`. So a change to `vars/` reaches every repo as soon as it merges to
Android-Config `develop`. *Allow default version to be overridden* is on, so a PR can test an
unmerged library branch by pinning it in its own `Jenkinsfile.prverify`:

```groovy
@Library('android-ci@feature/OP-12345-my-change') _
```

Revert the pin before that PR merges. (The PR-verify job builds the PR's own Jenkinsfile, so
the pin takes effect on that PR's build.)

## Screen diff (opt-in)

Adds a Before / After / Diff report of the screenshot tests and runs the flow tests on a
Gradle Managed Device. A repo opts in with one key:

```groovy
androidPRVerify(lintTask: 'lintDebug', unitTestTask: 'testDebugUnitTest',
                screenDiff: [module: 'oneWidgetMeterReading'])
```

The repo must provide, in that module: Roborazzi with `recordRoborazziDebug`, screenshots in
`<module>/build/outputs/roborazzi/` named `<screenId>__<state>.png`, and a Gradle Managed
Device `ciDevice` (arm64 image — the agents are Apple Silicon). Reference images are not
committed: the check records the base itself. All names are keys with defaults — see the
header of `vars/androidScreenDiff.groovy` (`recordTask`, `outputDir`, `device`,
`flowTestTask`, `threshold`, timeouts, `githubCredentialsId`, `flowTests`, `comment`).

What the stages do:

| Stage | What | Fails the build when |
|---|---|---|
| `screens: PR` | `recordRoborazziDebug` on the PR merge checkout → `build/screen-diff/after/` | (reported in `screens: report`) |
| `screens: base` | the same task in a detached git worktree of `origin/<target>` (the target revision the PR was merged with) → `build/screen-diff/before/` | never — a base without snapshot tests or a red base shows as a warning, its screens as new |
| `screens: report` | `screen_diff.py compare`: same-named PNGs are pixel-compared → unchanged / changed / new / removed, diff images, `build/screen-diff/report/index.html` archived as an artifact | a snapshot test failed on the PR. **A pixel change alone never fails** |
| `flow tests` | `ciDeviceDebugAndroidTest` on the PR only, `--no-daemon`, 40 min timeout, JUnit results published | a flow test failed or timed out |
| post | creates or updates **one** PR comment (marked `<!-- android-ci:screen-diff -->`) with the counts and the report link; removes the base worktree; kills leftover emulators | never — the comment is best-effort |

Compare rule: byte-identical files are unchanged; otherwise pixels are decoded to RGBA and
compared exactly. `threshold` (default `0`) is the largest fraction of differing pixels still
counted as unchanged; a size change is always "changed". The base is `origin/<target>`, not
the merge base: the PR checkout already contains the target's newest commits, so comparing to
the target tip shows only what the PR changes.

Report: `<BUILD_URL>artifact/build/screen-diff/report/index.html`. It uses a separate
`report.css` and no JavaScript because Jenkins serves artifacts with a Content-Security-Policy
that blocks inline styles and scripts; clicking an image opens it full screen (CSS `:target`).

Emulator isolation: the managed device runs with `ANDROID_USER_HOME=$HOME/.android-ci/gmd-executor-<n>`
and `ANDROID_ADB_SERVER_PORT=5037+<n>` (same port scheme as the app's uitests/maestro jobs). The
post step kills every process that still holds files in that folder, so it never touches
another executor's emulator. Each executor keeps its own AVD there (a few GB each).

Agent requirements: `python3` (3.8+, stdlib only; Pillow is used if present, just faster),
`rsync`, `lsof`, and a Secret-text credential `GITHUB_TOKEN_ENDIOSONEGITHUB` that is visible
to the PR-verify job (global scope) and may comment on PRs.

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
