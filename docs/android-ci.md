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
  githubStatusWrap.groovy  # per-check GitHub commit-status wrapper
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
2. **Create a Multibranch Pipeline** job per consuming repo pointed at `Jenkinsfile.prverify`,
   discovering **Pull Requests only** (not branches) to avoid duplicate builds.
3. **Webhook:** point the consuming repo's GitHub webhook at
   `https://bouncer.jenkins.endios.one/github-webhook` and set the shared secret.
   Jenkins validates the HMAC — the bouncer does not.
4. **Suppress the native status:** enable the *skip-notifications-trait* on the job so only
   the `ci/jenkins: *` statuses show (not `continuous-integration/jenkins/pr-head`).
5. **Branch protection:** once green, mark `ci/jenkins: ktlint|detekt|lint|tests` as required
   and remove the CircleCI checks.

## ⚠️ When Android-Config goes private

This library is loaded from Android-Config over SCM. Once the repo is private, Jenkins can no
longer fetch it anonymously — the Global Pipeline Library config **must** be given SCM checkout
credentials (a machine user / deploy key / PAT with read access). Without them, every consuming
job fails at library resolution before any stage runs. Update the library's *Source Code
Management → Credentials* at the same time the repo visibility changes.
