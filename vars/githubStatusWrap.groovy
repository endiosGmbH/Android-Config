#!/usr/bin/env groovy

/**
 * Runs `body` while reporting a single GitHub commit status under `context`
 * (e.g. "ci/jenkins: ktlint"): PENDING before, SUCCESS on clean exit, FAILURE
 * on throw. Repo + commit SHA are inferred from the checked-out SCM by the
 * GitHub plugin's githubNotify step.
 */
def call(String context, Closure body) {
    githubNotify context: context, status: 'PENDING', description: 'Running'
    try {
        body()
        githubNotify context: context, status: 'SUCCESS', description: 'Passed'
    } catch (err) {
        githubNotify context: context, status: 'FAILURE', description: 'Failed'
        throw err
    }
}
