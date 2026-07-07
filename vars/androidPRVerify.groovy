#!/usr/bin/env groovy

/**
 * Shared PR-verify pipeline for endios Android repos.
 *
 * Replaces the CircleCI `*_pr_verify` workflow: ktlint + detekt on the Kotlin
 * changeset (vs the PR base branch), Android lint, and unit tests. Each check
 * reports an independent `ci/jenkins: <check>` GitHub commit status.
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
                                sh """
                                  curl -sSLO https://github.com/detekt/detekt/releases/download/v${cfg.detektVersion}/detekt-cli-${cfg.detektVersion}.zip
                                  unzip -o detekt-cli-${cfg.detektVersion}.zip
                                  INPUT=\$(echo "${env.KOTLIN_CHANGESET}" | tr '\\n' ',')
                                  ./detekt-cli-${cfg.detektVersion}/bin/detekt-cli --config ${cfg.detektConfig} --plugins ${cfg.detektPlugin} --input "\$INPUT"
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
                sh 'rm -rf local.properties ktlint detekt-cli-*.zip detekt-cli-*/'
            }
        }
    }
}
