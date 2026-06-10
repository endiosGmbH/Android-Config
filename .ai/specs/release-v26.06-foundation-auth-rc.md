# Spec: [Android-Config] release/v26.06 foundation_auth -> 5.0.55-RC

**Ticket:** none (release-mechanics chore)
**Created:** 2026-06-10
**Status:** Done — committed directly to `release/v26.06`.

## Change
- `version.gradle`: `version.foundation_auth` `5.0.55` -> `5.0.55-RC`.

## Context
Companion to `foundation_release` -> 5.5.12-RC. platform-auth 5.0.55-RC is published (verified). Release builds read foundation_auth from this frozen release catalog, so they now resolve the -RC auth artifact, matching the rest of the release. Restore to plain on back-merge to develop.
