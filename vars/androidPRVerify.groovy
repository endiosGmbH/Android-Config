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

                    // Make the base branch available for the diff without fetching every branch.
                    sh "git fetch --no-tags --force origin ${cfg.baseBranch}:refs/remotes/origin/${cfg.baseBranch}"

                    script {
                        // Kotlin files changed on this PR vs the merge-base with the base branch.
                        // Mirrors CircleCI's resolve_changeset (diff-filter=dr drops deletes/renames).
                        env.KOTLIN_CHANGESET = sh(
                            returnStdout: true,
                            script: "git diff --name-only --diff-filter=dr --relative origin/${cfg.baseBranch}...HEAD | grep '\\.kt[s\"]\\?\$' || true"
                        ).trim()
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
