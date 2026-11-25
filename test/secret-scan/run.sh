#!/usr/bin/env bash
# Local harness for resources/eo-secret-scan.sh: throwaway repos, fake tokens made at runtime.
# Usage: test/secret-scan/run.sh [case...]   (needs gitleaks 8.30.1 on PATH and network for install)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESOURCES="${EO_RESOURCES:-$HERE/../../resources}"
SCRIPT="$RESOURCES/eo-secret-scan.sh"
CONFIG="$RESOURCES/eo-gitleaks.toml"
GITLEAKS_BIN="$(command -v gitleaks)" || { echo "gitleaks not on PATH"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0; FAIL=0; FAILED=()

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }
# Token prefixes are split so this file never holds a token-shaped literal.
fake_pat() { printf '%s%s' 'gh''p_' "$(rand 36)"; }
fake_gcp() { printf '%s%s' 'AI''za' "$(rand 35)"; }

# A repo whose refs/remotes/origin/develop stands in for the fetched PR target.
new_repo() {
  local d="$WORK/$1"; mkdir -p "$d"; git -C "$d" init -q -b feature
  echo base > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -q -m base
  git -C "$d" update-ref refs/remotes/origin/develop HEAD
  echo "$d"
}
commit_file() { # repo path content message
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -A; git -C "$1" commit -q -m "$4"
}
# Jenkins "merge with target" build: HEAD^1 = PR head, HEAD^2 = origin/<target>.
jenkins_merge() { git -C "$1" merge -q --no-ff --no-edit refs/remotes/origin/develop >/dev/null; }

scan() { # repo target -> sets RC, OUT
  OUT="$WORK/out.$RANDOM"
  (cd "$1" && GITLEAKS="$GITLEAKS_BIN" bash "$SCRIPT" scan "$2" "$CONFIG") > "$OUT" 2>&1
  RC=$?
}

ok() { PASS=$((PASS+1)); echo "  ok   $CASE: $1"; }
ko() { FAIL=$((FAIL+1)); FAILED+=("$CASE"); echo "  FAIL $CASE: $1"; [ -n "${OUT:-}" ] && [ -f "$OUT" ] && sed 's/^/       | /' "$OUT"; }
expect_rc() { [ "$RC" = "$1" ] && ok "exit $1" || ko "exit $RC, want $1"; }
expect_out() { grep -qE -- "$1" "$OUT" && ok "log matches /$1/" || ko "log lacks /$1/"; }
expect_no() { grep -qF -- "$1" "$OUT" && ko "log contains the secret value" || ok "log omits the value"; }

# ---- D1: install -------------------------------------------------------------------------
shim() { # dir name body
  mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}
case_install_ok() {
  local d="$WORK/inst"; mkdir -p "$d"; OUT="$WORK/out.inst"
  bash "$SCRIPT" install "$d" > "$OUT" 2>&1; RC=$?; expect_rc 0
  "$d/gitleaks" version > "$OUT" 2>&1; expect_out '^8\.30\.1$'
}
case_install_bad_arch() {
  local s="$WORK/shim-arch"; OUT="$WORK/out.arch"
  shim "$s" uname 'case "$1" in -m) echo i386;; *) echo Darwin;; esac'
  PATH="$s:$PATH" bash "$SCRIPT" install "$WORK/inst-arch" > "$OUT" 2>&1; RC=$?
  expect_rc 2; expect_out 'unsupported.*i386'
}
case_install_bad_os() {
  local s="$WORK/shim-os"; OUT="$WORK/out.os"
  shim "$s" uname 'case "$1" in -m) echo arm64;; *) echo Linux;; esac'
  PATH="$s:$PATH" bash "$SCRIPT" install "$WORK/inst-os" > "$OUT" 2>&1; RC=$?
  expect_rc 2; expect_out 'unsupported.*Linux'
}
case_install_bad_checksum() {
  local s="$WORK/shim-curl"; OUT="$WORK/out.sum"
  # Fake curl: writes junk to the -o target instead of downloading.
  shim "$s" curl 'while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo junk > "$2"; exit 0; }; shift; done; exit 1'
  PATH="$s:$PATH" bash "$SCRIPT" install "$WORK/inst-sum" > "$OUT" 2>&1; RC=$?
  expect_rc 2; expect_out 'checksum'
  [ ! -e "$WORK/inst-sum/gitleaks" ] && ok "no binary left behind" || ko "binary extracted despite bad checksum"
}

# ---- scan behaviors (numbers match the spec) -------------------------------------------------
case_b1_pat_in_kt_fails() {
  local r; r="$(new_repo b1)"; TOKEN="$(fake_pat)"
  commit_file "$r" app/src/main/java/Api.kt "val token = \"$TOKEN\"" "add api"; jenkins_merge "$r"
  scan "$r" develop; expect_rc 1
}

case_b1_control_clean_pr_passes() {
  local r; r="$(new_repo b1c)"
  commit_file "$r" app/src/main/java/Api.kt 'val greeting = "hello"' "add api"; jenkins_merge "$r"
  scan "$r" develop; expect_rc 0
}

case_b6_empty_target_fails() {
  local r; r="$(new_repo b6a)"; commit_file "$r" a.txt x "pr"
  scan "$r" ""; expect_rc 2; expect_out 'CHANGE_TARGET is empty'
}
case_b6_missing_target_ref_fails() {
  local r; r="$(new_repo b6b)"; commit_file "$r" a.txt x "pr"
  scan "$r" release/9.9; expect_rc 2; expect_out 'origin/release/9\.9 not found'
}
case_b6_no_merge_base_fails() {
  local r; r="$(new_repo b6c)"; commit_file "$r" a.txt x "pr"
  git -C "$r" checkout -q --orphan other; git -C "$r" commit -q -m unrelated
  git -C "$r" update-ref refs/remotes/origin/develop other; git -C "$r" checkout -q feature
  scan "$r" develop; expect_rc 2; expect_out 'no merge base between origin/develop and HEAD'
}

case_b2_4_log_names_file_and_rule_not_value() {
  local r; r="$(new_repo b2)"; TOKEN="$(fake_pat)"
  commit_file "$r" app/src/main/java/Api.kt "package x
val token = \"$TOKEN\"" "add api"; jenkins_merge "$r"
  scan "$r" develop; expect_rc 1
  expect_out '(^|[^/])app/src/main/java/Api\.kt:2( |$)'   # behavior 2: path:line
  expect_out 'Api\.kt:2 github-pat$'                      # behavior 3: rule
  expect_no "$TOKEN"                                       # behavior 4: never the value
  expect_no "${TOKEN:4}"
}

gservices() { # api key -> a google-services.json body
  printf '{\n  "client": [{\n    "api_key": [{\n      "current_key": "%s"\n    }]\n  }]\n}' "$1"
}
case_b5_google_services_key_passes() {
  local r; r="$(new_repo b5)"
  commit_file "$r" app/google-services.json "$(gservices "$(fake_gcp)")" "firebase"
  commit_file "$r" app/src/debug/google-services.json "$(gservices "$(fake_gcp)")" "firebase debug"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 0
}

case_b7_pat_in_google_services_fails() {
  local r; r="$(new_repo b7a)"; TOKEN="$(fake_pat)"
  commit_file "$r" app/google-services.json "{ \"github\": \"$TOKEN\" }" "pat in firebase file"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 1; expect_out 'google-services\.json:1 github-pat$'; expect_no "$TOKEN"
}
case_b7_firebase_key_in_kt_fails() {
  local r; r="$(new_repo b7b)"; TOKEN="$(fake_gcp)"
  commit_file "$r" app/src/main/java/Firebase.kt "val key = \"$TOKEN\"" "firebase key in code"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 1; expect_out 'Firebase\.kt:1 gcp-api-key$'; expect_no "$TOKEN"
}

case_b8_existing_secret_on_target_passes() {
  local r; r="$(new_repo b8)"; TOKEN="$(fake_pat)"
  git -C "$r" checkout -q -b dev refs/remotes/origin/develop
  commit_file "$r" Legacy.kt "val old = \"$TOKEN\"" "legacy credential"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q feature
  git -C "$r" reset -q --hard refs/remotes/origin/develop
  commit_file "$r" Other.kt 'val ok = 1' "pr"; jenkins_merge "$r"
  scan "$r" develop; expect_rc 0
}
case_b9_target_moved_on_merge_build_passes() {
  local r; r="$(new_repo b9)"; TOKEN="$(fake_pat)"
  commit_file "$r" Other.kt 'val ok = 1' "pr"
  git -C "$r" checkout -q -b dev refs/remotes/origin/develop
  commit_file "$r" Legacy.kt "val old = \"$TOKEN\"" "target gains a credential later"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q feature
  jenkins_merge "$r"
  [ "$(git -C "$r" rev-parse HEAD^2)" = "$(git -C "$r" rev-parse refs/remotes/origin/develop)" ] \
    && ok "HEAD is a Jenkins-style merge" || ko "setup: no merge commit"
  scan "$r" develop; expect_rc 0
}
case_b9_target_removed_secret_unmerged_passes() {
  local r; r="$(new_repo b9b)"; TOKEN="$(fake_pat)"
  git -C "$r" checkout -q -b dev refs/remotes/origin/develop
  commit_file "$r" Legacy.kt "val old = \"$TOKEN\"" "legacy credential"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q feature
  git -C "$r" reset -q --hard refs/remotes/origin/develop; commit_file "$r" Other.kt 'val ok = 1' "pr"
  git -C "$r" checkout -q dev; git -C "$r" rm -q Legacy.kt; git -C "$r" commit -q -m "target removes it"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q feature
  scan "$r" develop; expect_rc 0   # PR built without a merge commit, behind its target
}
case_b10_added_then_removed_fails() {
  local r; r="$(new_repo b10)"; TOKEN="$(fake_pat)"
  commit_file "$r" Api.kt "val t = \"$TOKEN\"" "add"; commit_file "$r" Api.kt 'val t = ""' "remove"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 1; expect_out 'Api\.kt:1 github-pat$'; expect_no "$TOKEN"
}
case_b11_merge_resolution_adds_secret_fails() {
  local r; r="$(new_repo b11)"; TOKEN="$(fake_pat)"
  commit_file "$r" Conf.kt 'val v = "pr"' "pr side"
  git -C "$r" checkout -q -b dev refs/remotes/origin/develop
  commit_file "$r" Conf.kt 'val v = "target"' "target side"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q feature
  git -C "$r" merge -q refs/remotes/origin/develop >/dev/null 2>&1
  printf 'val v = "%s"\n' "$TOKEN" > "$r/Conf.kt"; git -C "$r" add -A; git -C "$r" commit -q --no-edit
  scan "$r" develop; expect_rc 1; expect_out 'Conf\.kt:1 github-pat$'; expect_no "$TOKEN"
}

ALL_CASES=(install_ok install_bad_arch install_bad_os install_bad_checksum
  b1_control_clean_pr_passes b1_pat_in_kt_fails
  b6_empty_target_fails b6_missing_target_ref_fails b6_no_merge_base_fails
  b2_4_log_names_file_and_rule_not_value b5_google_services_key_passes
  b7_pat_in_google_services_fails b7_firebase_key_in_kt_fails
  b8_existing_secret_on_target_passes b9_target_moved_on_merge_build_passes
  b9_target_removed_secret_unmerged_passes b10_added_then_removed_fails
  b11_merge_resolution_adds_secret_fails)

if [ $# -gt 0 ]; then CASES=("$@"); else CASES=("${ALL_CASES[@]}"); fi
for CASE in "${CASES[@]}"; do
  echo "case $CASE"; OUT=""; "case_$CASE"
done
echo "passed $PASS, failed $FAIL${FAILED:+ (${FAILED[*]})}"
[ "$FAIL" = 0 ]
