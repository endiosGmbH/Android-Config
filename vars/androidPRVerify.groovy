#!/usr/bin/env groovy

/**
 * Shared PR-verify pipeline for endios Android repos.
 *
 * Replaces the CircleCI `*_pr_verify` workflow: ktlint + detekt on the Kotlin
 * changeset (vs the PR base branch), Android lint, and unit tests. Each check
 * reports an independent `ci/jenkins: <check>` GitHub commit status.
 *
 * Before any Gradle work, a gitleaks secret scan (`resources/eo-secret-scan.sh`,
 * config `resources/eo-gitleaks.toml`) checks only what the PR adds vs
 * `origin/${CHANGE_TARGET}`. It is non-blocking for now: a finding turns the stage
 * red and posts `ci/jenkins: secret-scan` as failure, but leaves the build result.
 *
 * Usage — repo `Jenkinsfile.prverify`:
 *
 *   @Library('android-ci') _
 *   androidPRVerify()
 *
 * Overridable config (defaults match endiosOneApp-Android):
 *
 *   androidPRVerify(
 *     baseBranch   : 'develop',
 *     ktlintVersion: '0.40.0',
 *     detektVersion: '1.22.0',
 *     detektConfig : 'tooling/.detekt/detekt-config.yml',
 *     detektPlugin : 'tooling/.detekt/detekt-formatting-1.22.0.jar',
 *     lintTask     : 'lintDevelopDebug',
 *     unitTestTask : 'testDevelopDebugUnitTest',
 *     agentLabel   : 'android',
 *   )
 *
 * Note: suppressing the native `continuous-integration/jenkins/pr-head` status
 * is a job-level trait (skip-notifications-trait plugin), configured on the
 * Multibranch job — not here. HMAC webhook-secret validation is Jenkins-side too;
 * the bouncer (bouncer.jenkins.endios.one) does not validate payloads.
 */
def call(Map config = [:]) {
    Map cfg = [
        baseBranch   : 'develop',
        ktlintVersion: '0.40.0',
        detektVersion: '1.22.0',
        detektConfig : 'tooling/.detekt/detekt-config.yml',
        detektPlugin : 'tooling/.detekt/detekt-formatting-1.22.0.jar',
        lintTask     : 'lintDevelopDebug',
        unitTestTask : 'testDevelopDebugUnitTest',
        agentLabel   : 'android',
    ] + config

    pipeline {
        agent { label cfg.agentLabel }

        options {
            skipDefaultCheckout()
            disableConcurrentBuilds()
            timeout(time: 45, unit: 'MINUTES')
            buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '30'))
        }

        environment {
            ANDROID_HOME     = '/Users/endiosworker/Library/Android/sdk'
            ANDROID_SDK_ROOT = '/Users/endiosworker/Library/Android/sdk'
            JAVA_HOME        = '/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home'
            PATH             = "${JAVA_HOME}/bin:/opt/homebrew/bin:${env.PATH}"
        }

        stages {
            stage('Checkout & Changeset') {
                steps {
                    // skipDefaultCheckout() is on, so check out explicitly (once).
                    checkout scm

                    withCredentials([
                        string(credentialsId: 'MAVEN_USER', variable: 'MAVEN_USER'),
                        string(credentialsId: 'MAVEN_PASS', variable: 'MAVEN_PASS'),
                    ]) {
                        sh '''
                          cat > local.properties << EOF
ENDIOS_DE_HTACCESS_USER=${MAVEN_USER}
ENDIOS_DE_HTACCESS_PASSWORD=${MAVEN_PASS}
EOF
                        '''
                    }

                    script {
                        // Resolve the Kotlin changeset WITHOUT a network fetch — a raw `git fetch`
                        // in an sh step has no credentials (GIT_ASKPASS is scoped to `checkout scm`).
                        //
                        // The GitHub Branch Source already fetches the PR's target branch into
                        // refs/remotes/origin/<target> (it needs it to build the merge), so we diff
                        // the working tree against it with a three-dot (merge-base) range. This is
                        // robust whether or not Jenkins produced a real merge commit — a branch that
                        // is already up to date with the target yields no merge commit, which the old
                        // merge-parent approach mis-read as "no changes" and skipped linting entirely.
                        // Mirrors CircleCI's resolve_changeset (diff-filter=dr drops deletes/renames).
                        String target = env.CHANGE_TARGET?.trim() ?: cfg.baseBranch
                        String targetRef = "origin/${target}"
                        boolean hasRef = sh(returnStatus: true, script: "git rev-parse --verify --quiet ${targetRef} > /dev/null") == 0
                        if (hasRef) {
                            echo "Resolving changeset vs ${targetRef} (merge-base)"
                            env.KOTLIN_CHANGESET = sh(
                                returnStdout: true,
                                script: "git diff --name-only --diff-filter=dr ${targetRef}...HEAD | grep '\\.kt[s\"]\\?\$' || true"
                            ).trim()
                        } else {
                            // Fail closed, not open: if we can't determine the target ref, lint every
                            // Kotlin file rather than silently skipping and passing a broken PR.
                            echo "WARNING: ${targetRef} not available (CHANGE_TARGET='${env.CHANGE_TARGET}'). " +
                                 "Running ktlint/detekt over ALL Kotlin files as a safe fallback."
                            env.KOTLIN_CHANGESET = sh(
                                returnStdout: true,
                                script: "git ls-files '*.kt' '*.kts' || true"
                            ).trim()
                        }
                        echo "Kotlin changeset:\n${env.KOTLIN_CHANGESET ?: '(none)'}"
                    }
                }
            }

            stage('Secret scan') {
                steps {
                    // Non-blocking: the stage goes red, the build result stays as it is.
                    catchError(buildResult: 'SUCCESS', stageResult: 'FAILURE', catchInterruptions: false) {
                        script {
                            secretScanStatus('pending', 'Scanning this PR for credentials')
                            int rc = 2
                            try {
                                writeFile file: '.eo-gitleaks.toml', text: libraryResource('eo-gitleaks.toml')
                                writeFile file: '.eo-secret-scan.sh', text: libraryResource('eo-secret-scan.sh')
                                // No credentials in scope; exit 0 clean, 1 credentials found, 2 could not run.
                                rc = sh(returnStatus: true, script: '''
                                  bash .eo-secret-scan.sh install . &&
                                    GITLEAKS=./gitleaks bash .eo-secret-scan.sh scan "${CHANGE_TARGET:-}" .eo-gitleaks.toml
                                ''')
                            } finally {
                                if (rc == 0) {
                                    secretScanStatus('success', 'No credentials added by this PR')
                                } else if (rc == 1) {
                                    secretScanStatus('failure', 'This PR adds credentials, see the Jenkins log')
                                } else {
                                    secretScanStatus('error', 'Secret scan could not run, see the Jenkins log')
                                }
                            }
                            if (rc != 0) {
                                error("Secret scan failed (exit ${rc}), see the log above")
                            }
                        }
                    }
                }
            }

            stage('ktlint') {
                steps {
                    githubStatusWrap('ci/jenkins: ktlint') {
                        script {
                            if (!env.KOTLIN_CHANGESET?.trim()) {
                                echo 'No Kotlin changes — skipping ktlint.'
                            } else {
                                sh """
                                  curl -sSLO https://github.com/pinterest/ktlint/releases/download/${cfg.ktlintVersion}/ktlint
                                  chmod a+x ktlint
                                  echo "${env.KOTLIN_CHANGESET}" | xargs ./ktlint --android --relative --disabled_rules=import-ordering --color
                                """
                            }
                        }
                    }
                }
            }

            stage('detekt') {
                steps {
                    githubStatusWrap('ci/jenkins: detekt') {
                        script {
                            if (!env.KOTLIN_CHANGESET?.trim()) {
                                echo 'No Kotlin changes — skipping detekt.'
                            } else {
                                // Build the comma-separated --input in Groovy: shelling `tr '\n' ','`
                                // left a trailing comma, so detekt parsed an empty path and crashed.
                                String input = env.KOTLIN_CHANGESET.readLines().findAll { it?.trim() }.join(',')
                                // --plugins is optional: some repos (e.g. oneDataProvider) run detekt
                                // without the formatting plugin. Omit the flag when detektPlugin is blank.
                                String pluginArg = cfg.detektPlugin ? "--plugins ${cfg.detektPlugin}" : ''
                                sh """
                                  curl -sSLO https://github.com/detekt/detekt/releases/download/v${cfg.detektVersion}/detekt-cli-${cfg.detektVersion}.zip
                                  unzip -o detekt-cli-${cfg.detektVersion}.zip
                                  ./detekt-cli-${cfg.detektVersion}/bin/detekt-cli --config ${cfg.detektConfig} ${pluginArg} --input "${input}"
                                """
                            }
                        }
                    }
                }
            }

            stage('lint') {
                steps {
                    githubStatusWrap('ci/jenkins: lint') {
                        sh "./gradlew ${cfg.lintTask}"
                    }
                }
            }

            stage('tests') {
                steps {
                    githubStatusWrap('ci/jenkins: tests') {
                        sh "./gradlew ${cfg.unitTestTask}"
                    }
                }
            }
        }

        post {
            always {
                sh 'rm -rf local.properties ktlint detekt-cli-*.zip detekt-cli-*/ gitleaks gitleaks_*.tar.gz .eo-gitleaks.toml .eo-secret-scan.sh'
            }
        }
    }
}

/**
 * Posts the `ci/jenkins: secret-scan` commit status on the PR head, as iosPRVerify's
 * ghStatus does. Best-effort: a missing credential or API error only logs a warning.
 */
void secretScanStatus(String state, String description) {
    String context = 'ci/jenkins: secret-scan'
    try {
        String slug = githubSlug(env.CHANGE_URL)
        if (!slug) {
            echo "WARNING: ${context} status '${state}' not posted: no GitHub PR URL (CHANGE_URL='${env.CHANGE_URL}')"
            return
        }
        // HEAD is the Jenkins merge commit when its second parent is the target; the PR head is HEAD^1.
        String sha = sh(returnStdout: true, script: '''
          p2=$(git rev-parse -q --verify 'HEAD^2' || true)
          if [ -n "$p2" ] && [ "$p2" = "$(git rev-parse -q --verify "origin/${CHANGE_TARGET:-}" || true)" ]; then
            git rev-parse 'HEAD^1'; else git rev-parse HEAD; fi
        ''').trim()
        String body = groovy.json.JsonOutput.toJson([
            state      : state,
            context    : context,
            description: description,
            target_url : "${env.BUILD_URL}console".toString(),
        ])
        withEnv(["EO_STATUS_URL=https://api.github.com/repos/${slug}/statuses/${sha}", "EO_STATUS_BODY=${body}"]) {
            withCredentials([string(credentialsId: 'GITHUB_TOKEN_ENDIOSONEGITHUB', variable: 'GH_TOKEN')]) {
                // Token on curl's stdin, never in argv.
                String code = sh(returnStdout: true, script: '''
                  set +x
                  printf 'Authorization: token %s\\n' "$GH_TOKEN" | curl -sS -o /dev/null -w '%{http_code}' \\
                    -X POST -H @- -H 'Accept: application/vnd.github+json' -d "$EO_STATUS_BODY" "$EO_STATUS_URL" || true
                ''').trim()
                if (code == '201') {
                    echo "${context}: ${state} posted"
                } else {
                    echo "WARNING: ${context} status '${state}' not posted (HTTP ${code ?: 'none'})"
                }
            }
        }
    } catch (org.jenkinsci.plugins.workflow.steps.FlowInterruptedException e) {
        throw e
    } catch (Throwable t) {
        echo "WARNING: ${context} status '${state}' not posted: ${t.message}"
    }
}

@NonCPS
static String githubSlug(String changeUrl) {
    def m = (changeUrl ?: '') =~ /github\.com\/([^\/]+\/[^\/]+)\/pull\//
    return m.find() ? m.group(1) : null
}
