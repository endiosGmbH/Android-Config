#!/usr/bin/env groovy

/**
 * Before / After / Diff screen report and flow tests for a PR (opt-in part of
 * `androidPRVerify`).
 *
 * A repo opts in from its `Jenkinsfile.prverify`:
 *
 *   androidPRVerify(..., screenDiff: [module: 'oneWidgetMeterReading'])
 *
 * What runs, in order:
 *   1. recordHead — `recordRoborazziDebug` on the PR (the merge checkout). A failing
 *      snapshot test fails the build, but only after the report is written.
 *   2. recordBase — the same task in a detached git worktree of `origin/<target>`,
 *      the target revision the PR was merged with. Never fails the build: if the
 *      base can't record (e.g. it has no snapshot tests yet), the report says so.
 *   3. report     — pixel-compares same-named PNGs (screen_diff.py, Python stdlib
 *      only) and archives `build/screen-diff/report/` as a build artifact. Changed
 *      pixels never fail the build; they are reported for review.
 *   4. flowTests  — `<device>DebugAndroidTest` on a Gradle Managed Device, PR only.
 *   5. comment    — (post) creates or updates one PR comment with the counts and
 *      the report link. Best-effort: a GitHub error never fails the build.
 *
 * Config keys (all optional except `module`):
 *
 *   module                 : Gradle module with the screenshot tests (required)
 *   recordTask             : 'recordRoborazziDebug'
 *   outputDir              : '<module>/build/outputs/roborazzi'
 *   threshold              : 0.0   largest fraction of differing pixels still "unchanged"
 *   recordTimeoutMinutes   : 25    per run (head and base each)
 *   flowTests              : true
 *   device                 : 'ciDevice'   Gradle Managed Device name
 *   flowTestTask           : '<device>DebugAndroidTest'
 *   flowTestArgs           : '-Pandroid.testoptions.manageddevices.emulator.gpu=swiftshader_indirect'
 *   flowTestTimeoutMinutes : 40
 *   githubCredentialsId    : 'GITHUB_TOKEN_ENDIOSONEGITHUB'  Secret-text token for the PR comment
 *   comment                : true
 */

/** Returns the normalised config, or null when the repo has not opted in. */
Map config(def raw, String baseBranch) {
    if (!raw) {
        return null
    }
    Map given = raw instanceof Map ? raw : [:]
    if (!given.module) {
        error "androidPRVerify: screenDiff needs a module, e.g. screenDiff: [module: 'oneWidgetMyFeature']"
    }
    Map sd = [
        recordTask            : 'recordRoborazziDebug',
        threshold             : 0.0,
        recordTimeoutMinutes  : 25,
        flowTests             : true,
        device                : 'ciDevice',
        flowTestArgs          : '-Pandroid.testoptions.manageddevices.emulator.gpu=swiftshader_indirect',
        flowTestTimeoutMinutes: 40,
        githubCredentialsId   : 'GITHUB_TOKEN_ENDIOSONEGITHUB',
        comment               : true,
    ] + given
    sd.outputDir = sd.outputDir ?: "${sd.module}/build/outputs/roborazzi"
    sd.flowTestTask = sd.flowTestTask ?: "${sd.device}DebugAndroidTest"
    sd.baseBranch = baseBranch
    sd.workDir = 'build/screen-diff'
    sd.reportDir = "${sd.workDir}/report"
    return sd
}

/** Records the PR's screenshots into <workDir>/after. Never throws for a test failure. */
void recordHead(Map sd) {
    int rc = record(sd, '.', "${sd.workDir}/after", 'head')
    env.SCREEN_DIFF_HEAD = rc == 0 ? 'passed' : 'failed'
}

/** Records the target branch's screenshots into <workDir>/before. Never fails the build. */
void recordBase(Map sd) {
    String target = env.CHANGE_TARGET?.trim() ?: sd.baseBranch
    String ref = "origin/${target}"
    env.SCREEN_DIFF_BASE_REF = ref
    // No `git fetch` here: GIT_ASKPASS credentials are scoped to `checkout scm`, and the
    // branch source has already fetched the target to build the merge.
    if (sh(returnStatus: true, script: "git rev-parse --verify --quiet '${ref}' > /dev/null") != 0) {
        echo "WARNING: ${ref} is not available; the report will show every screen as new."
        env.SCREEN_DIFF_BASE = 'missing'
        return
    }
    String dir = baseDir()
    removeBaseWorktree()
    sh """
      git worktree add --detach '${dir}' '${ref}'
      cp local.properties '${dir}/local.properties'
    """
    int rc = record(sd, dir, "${sd.workDir}/before", 'base')
    if (rc == 0) {
        env.SCREEN_DIFF_BASE = 'passed'
    } else if (sh(returnStatus: true, script: "grep -qi \"task '${sd.recordTask}' not found\" '${sd.workDir}/base.log'") == 0) {
        env.SCREEN_DIFF_BASE = 'no-snapshots'
    } else {
        env.SCREEN_DIFF_BASE = 'failed'
    }
}

/**
 * Runs the record task in `dir` and copies the PNGs to `dest` (workspace-relative).
 * Deletes the previous output and test results first so Gradle can't skip the
 * test task as up to date and leave stale screenshots behind.
 */
private int record(Map sd, String dir, String dest, String label) {
    String log = "${env.WORKSPACE}/${sd.workDir}/${label}.log"
    sh "rm -rf '${dest}' && mkdir -p '${dest}'"
    int rc = 1
    timeout(time: sd.recordTimeoutMinutes, unit: 'MINUTES') {
        // Exit code via a file instead of `pipefail`, which plain /bin/sh may not support.
        // `|| rc=` keeps `sh -e` from ending the group before the code is written.
        rc = sh(returnStatus: true, script: """
          cd '${dir}'
          rm -rf '${sd.outputDir}' '${sd.module}/build/test-results'
          { rc=0; ./gradlew :${sd.module}:${sd.recordTask} --no-build-cache || rc=\$?; echo \$rc > '${log}.rc'; } 2>&1 | tee '${log}'
          exit "\$(cat '${log}.rc')"
        """)
    }
    sh """
      if [ -d '${dir}/${sd.outputDir}' ]; then
        rsync -a --include='*/' --include='*.png' --exclude='*' '${dir}/${sd.outputDir}/' '${dest}/'
      fi
      echo "${label}: \$(find '${dest}' -name '*.png' | wc -l | tr -d ' ') screenshot(s)"
    """
    return rc
}

/** Builds the report, archives it, and fails the build if the PR's snapshot tests failed. */
void report(Map sd) {
    String tool = "${sd.workDir}/screen_diff.py"
    writeFile file: tool, text: libraryResource('android-ci/screen_diff.py')

    List<String> warnings = []
    String baseRef = env.SCREEN_DIFF_BASE_REF ?: "origin/${sd.baseBranch}"
    switch (env.SCREEN_DIFF_BASE) {
        case 'missing':
            warnings << "${baseRef} was not available, so every screen shows as new."
            break
        case 'no-snapshots':
            warnings << "${baseRef} has no ${sd.recordTask} task yet, so every screen shows as new."
            break
        case 'failed':
            warnings << "Recording ${baseRef} failed; screens it did not record show as new (see base.log)."
            break
    }
    if (env.SCREEN_DIFF_HEAD != 'passed') {
        warnings << 'Snapshot tests failed on this PR; screens it did not record show as removed.'
    }

    String subtitle = "${env.CHANGE_ID ? 'PR #' + env.CHANGE_ID + ' vs ' : ''}${baseRef} - build #${env.BUILD_NUMBER}"
    String warningArgs = warnings.collect { "--warning ${shq(it)}" }.join(' ')
    sh """
      python3 '${tool}' compare \
        --before '${sd.workDir}/before' --after '${sd.workDir}/after' --out '${sd.reportDir}' \
        --threshold ${sd.threshold} --title ${shq('Screen diff - ' + sd.module)} --subtitle ${shq(subtitle)} \
        ${warningArgs}
    """
    archiveArtifacts artifacts: "${sd.reportDir}/**, ${sd.workDir}/*.log", allowEmptyArchive: true
    env.SCREEN_DIFF_COUNTS = readFile("${sd.reportDir}/summary.txt").trim()
    echo "Screen diff: ${env.SCREEN_DIFF_COUNTS} — ${reportUrl(sd)}"

    if (env.SCREEN_DIFF_HEAD != 'passed') {
        error "Snapshot tests (${sd.recordTask}) failed on this PR — see the console log and head.log."
    }
}

/** Runs the flow tests on the Gradle Managed Device. Fails the build on a test failure. */
void flowTests(Map sd) {
    env.SCREEN_DIFF_FLOW = 'running'
    try {
        timeout(time: sd.flowTestTimeoutMinutes, unit: 'MINUTES') {
            // --no-daemon: the emulator must inherit this build's ANDROID_USER_HOME, and AGP
            // caches that location per JVM — a shared daemon would reuse another build's.
            sh """
              ${gmdEnv()}
              ./gradlew --no-daemon :${sd.module}:${sd.flowTestTask} ${sd.flowTestArgs ?: ''}
            """
        }
        env.SCREEN_DIFF_FLOW = 'passed'
    } catch (err) {
        env.SCREEN_DIFF_FLOW = 'failed'
        throw err
    } finally {
        junit testResults: "${sd.module}/build/outputs/androidTest-results/managedDevice/**/*.xml",
              allowEmptyResults: true
        archiveArtifacts artifacts: "${sd.module}/build/reports/androidTests/managedDevice/**",
                         allowEmptyArchive: true
        stopEmulators()
    }
}

/** Creates or updates the PR comment. Best-effort: never fails the build. */
void comment(Map sd) {
    String summary = "${sd.reportDir}/summary.json"
    if (!sd.comment || !env.CHANGE_URL || !fileExists(summary)) {
        echo 'Screen diff: no PR comment (not a PR build, comments off, or no report).'
        return
    }
    List<String> statuses = [
        "Snapshot tests=${env.SCREEN_DIFF_HEAD ?: 'not run'}",
        "Flow tests=${sd.flowTests ? (env.SCREEN_DIFF_FLOW ?: 'not run') : 'off'}",
    ]
    String statusArgs = statuses.collect { "--status ${shq(it)}" }.join(' ')
    try {
        withCredentials([string(credentialsId: sd.githubCredentialsId, variable: 'GITHUB_TOKEN')]) {
            // CHANGE_URL is read by the shell, and the token only via the environment.
            int rc = sh(returnStatus: true, script: """
              python3 '${sd.workDir}/screen_diff.py' comment --summary '${summary}' \
                --report-url ${shq(reportUrl(sd))} --pr-url "\$CHANGE_URL" \
                --build-label ${shq('build #' + env.BUILD_NUMBER)} ${statusArgs}
            """)
            if (rc != 0) {
                echo "WARNING: screen diff PR comment not posted (exit ${rc})."
            }
        }
    } catch (Throwable t) {
        echo "WARNING: screen diff PR comment not posted: ${t.message}"
    }
}

/** Removes the base worktree and stops any emulator this build left running. */
void cleanup(Map sd) {
    removeBaseWorktree()
    if (sd.flowTests) {
        stopEmulators()
    }
}

String reportUrl(Map sd) {
    return "${env.BUILD_URL}artifact/${sd.reportDir}/index.html"
}

private String baseDir() {
    return "${env.WORKSPACE_TMP ?: env.WORKSPACE + '@tmp'}/screen-diff-base"
}

private void removeBaseWorktree() {
    sh """
      git worktree remove --force '${baseDir()}' 2>/dev/null || true
      rm -rf '${baseDir()}'
      git worktree prune 2>/dev/null || true
    """
}

/**
 * Shell lines that isolate the managed device per executor: its own Android user
 * home (so the AVD lives in a folder only this executor uses) and its own ADB port
 * (same scheme as the app's uitests/maestro jobs).
 */
private String gmdEnv() {
    int executor = (env.EXECUTOR_NUMBER ?: '0') as Integer
    return """
      export ANDROID_USER_HOME="\$HOME/.android-ci/gmd-executor-${executor}"
      export ANDROID_ADB_SERVER_PORT=${5037 + executor}
      mkdir -p "\$ANDROID_USER_HOME"
    """
}

/**
 * Kills emulators left by this executor (timeout, abort, crashed Gradle). Finds
 * them by the files they hold open in this executor's Android user home, so it
 * never touches another job's emulator on the same agent.
 */
private void stopEmulators() {
    sh """
      ${gmdEnv()}
      PIDS=\$(lsof -t +D "\$ANDROID_USER_HOME" 2>/dev/null | sort -u)
      for pid in \$PIDS; do
        echo "Stopping leftover process \$pid: \$(ps -p \$pid -o command= | cut -c1-160)"
        kill -9 \$pid 2>/dev/null || true
      done
      pkill -9 -f "\$ANDROID_USER_HOME" 2>/dev/null || true
      "\$ANDROID_HOME/platform-tools/adb" -P \$ANDROID_ADB_SERVER_PORT kill-server 2>/dev/null || true
    """
}

/** Single-quotes a value for sh. */
private String shq(String value) {
    return "'" + value.replace("'", "'\"'\"'") + "'"
}
