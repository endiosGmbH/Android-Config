#!/usr/bin/env groovy

/**
 * Runs `body` while reporting a GitHub check named `checkName`
 * (e.g. "ci/jenkins: ktlint"): IN_PROGRESS before, COMPLETED/SUCCESS on clean
 * exit, COMPLETED/FAILURE on throw.
 *
 * Uses the GitHub Checks plugin's `publishChecks` step. Publishing is best-effort:
 * if it can't post (plugin/credentials not set up for the Checks API — e.g. a PAT
 * instead of a GitHub App), it logs a warning rather than failing the build, so the
 * check's real pass/fail is never masked by a reporting problem. The body's own
 * failure always propagates.
 */
def call(String checkName, Closure body) {
    publish(checkName, 'IN_PROGRESS', null)
    try {
        body()
        publish(checkName, 'COMPLETED', 'SUCCESS')
    } catch (err) {
        publish(checkName, 'COMPLETED', 'FAILURE')
        throw err
    }
}

private void publish(String checkName, String status, String conclusion) {
    try {
        if (conclusion) {
            publishChecks name: checkName, status: status, conclusion: conclusion
        } else {
            publishChecks name: checkName, status: status
        }
    } catch (Throwable t) {
        echo "Check '${checkName}' (${status}${conclusion ? '/' + conclusion : ''}) not published: ${t.message}"
    }
}
