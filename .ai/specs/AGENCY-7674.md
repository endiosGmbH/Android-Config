# Spec: Bump Retrofit to 3.x and OkHttp to 4.12.x

**Ticket:** [AGENCY-7674](https://endios.atlassian.net/browse/AGENCY-7674)
**Created:** 2026-06-16
**Status:** Implemented

## Context

Phase 0a of the Gson → kotlinx-serialization migration (Epic [OP-16714](https://endios.atlassian.net/browse/OP-16714)). The official `converter-kotlinx-serialization` adapter requires Retrofit ≥ 2.10, so the network stack must move off Retrofit 2.6.1 before the migration can begin. Going straight to 3.0.0 is essentially free: the `retrofit2.*` package and Maven coordinate are unchanged, 3.x is forward binary-compatible with 2.x, and its only hard new requirement — OkHttp ≥ 4.12 — is bumped here anyway. Independent of the migration, the bump pulls in 5+ years of bug fixes and security patches.

This Story is the **Android-Config layer only** — the single `version.gradle` constant change that gates everything downstream. Foundation rebuild + patch-release and the per-widget bumps are tracked as follow-on work (they are blocked on a published Foundation artifact and cannot proceed until this lands).

## Requirements

### Functional
- `version.gradle` declares `version.retrofit = "3.0.0"` (was `2.6.1`).
- `version.gradle` declares `version.okhttp = "4.12.0"` (was `4.9.1`).
- No other version constant changes; Gson and its Retrofit converter stay untouched (removed in a later phase).

### Non-Functional
- No source-level change required in any consuming repo — `retrofit2.*` and `okhttp3.*` imports must continue to resolve unchanged.

## Behaviors

This is a build-configuration constant change with no testable runtime behavior, so there is no red-green-refactor cycle. Correctness is established by the upfront API audit (below) and verified downstream by Foundation/widget CI compiling against the new versions.

- [x] Audit every consuming repo for Retrofit/OkHttp APIs removed or changed between the old and new versions.
- [x] `version.gradle` shows Retrofit `3.0.0` and OkHttp `4.12.0`.

## API Audit (Work step 1)

Audited Foundation, Auth, and all ~26 `oneWidget*-Android` repos for the APIs the ticket flagged as at-risk across Retrofit 2.6 → 3.0:

| Flagged API | Occurrences | Verdict |
|---|---|---|
| `Retrofit.Builder#callFactory` | 0 | Not used |
| `retrofit2.Call#enqueue(Callback)` | 0 | All `.enqueue(` hits are `WorkManager` / Foundation's own `Requester` DSL, not Retrofit |
| `MoshiConverterFactory` (changed ctors) | 0 | Not used — the stack uses `GsonConverterFactory` |

Retrofit is wired in a single place — `endiosOneFoundation-Android/one-core-network/.../service/internal/IOService.kt` — using only `Retrofit.Builder().client(...).addConverterFactory(GsonConverterFactory.create()).baseUrl(...)` plus `.create()`. All of these are source-compatible in Retrofit 3.0.

OkHttp usage (`OkHttpClient.Builder`, `Cache`, `Interceptor`/`Interceptor.Chain`, `HttpLoggingInterceptor`, `Response`, `request.url.host`) is stable within the 4.x line; 4.9 → 4.12 introduces no breaking changes.

**Conclusion:** no source change required in any repo. Risk confirmed low, matching the ticket's assessment.

## Technical Notes

- **Affected files/modules:** `Android-Config/version.gradle` (two lines).
- **Base branch:** `develop`. Android-Config's GitHub default is `master`, so `--base develop` must be passed explicitly; the app reads `version.gradle` from the branch it resolves against.
- **No CHANGELOG / no pomVersion:** Android-Config publishes no versioned artifact and has no `CHANGELOG.md`.
- **Downstream (out of scope here):** Foundation must rebuild against the new versions and patch-release before any widget repo can bump Foundation. Widget bumps then proceed in parallel. Each consuming widget gets a device smoke test focused on network paths.

## Open Questions

- None. Scope, target versions, and base branch are unambiguous in the ticket.

## QA

**Recommended app:** _Not applicable to this PR._ The Android-Config change is a `version.gradle` constant bump — there is no buildable/runnable artifact to QA locally. Network-path smoke testing (request/response, cache, interceptors, timeouts) happens downstream, per widget, once Foundation is rebuilt and the widgets bump to it — that is where `/qa-local` applies. Fallback app for that downstream testing is CSS 2.0 (`de.endios.one.css`).
