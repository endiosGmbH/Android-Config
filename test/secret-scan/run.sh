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
BG_PIDS=()
trap '[ ${#BG_PIDS[@]} -gt 0 ] && kill "${BG_PIDS[@]}" 2>/dev/null; rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0; FAIL=0; FAILED=()

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }
# Token prefixes are split so this file never holds a token-shaped literal.
fake_pat() { printf '%s%s' 'gh''p_' "$(rand 36)"; }
fake_gcp() { printf '%s%s' 'AI''za' "$(rand 35)"; }
# A `dir`-algorithm JWE: header..iv.ciphertext.tag (empty encrypted-key segment).
fake_jwe_dir() { printf '%s%s..%s.%s.%s' 'ey''J' "$(rand 30)" "$(rand 22)" "$(rand 60)" "$(rand 22)"; }

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
# Jenkins "merge with target" build: HEAD^1 = PR head, HEAD^2 = origin/<target>, Git plugin identity.
# A no-op when the PR already contains its target; move the target first for a real merge.
jenkins_merge() {
  GIT_COMMITTER_NAME=anonymous GIT_COMMITTER_EMAIL=nobody@nowhere \
    git -C "$1" merge -q --no-ff --no-edit refs/remotes/origin/develop >/dev/null
}

# A real merge build: the target gains a commit first, so jenkins_merge creates HEAD^2.
merge_build() {
  local r="$1" br; br="$(git -C "$r" symbolic-ref --short HEAD)"
  git -C "$r" checkout -q -B dev refs/remotes/origin/develop; commit_file "$r" "target-$RANDOM.txt" moved "target moves"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q "$br"; jenkins_merge "$r"
  [ "$(git -C "$r" rev-parse HEAD^2 2>/dev/null)" = "$(git -C "$r" rev-parse refs/remotes/origin/develop)" ] \
    && ok "HEAD is a Jenkins-style merge" || ko "setup: no merge commit"
}

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
case_install_no_dir_exits_2() {
  OUT="$WORK/out.nodir"; bash "$SCRIPT" install > "$OUT" 2>&1; RC=$?
  expect_rc 2; expect_out 'install needs a target dir'
}

# A local TCP listener that accepts and never answers -> sets PORT.
silent_listener() {
  local pf="$WORK/silent.port"; rm -f "$pf"
  python3 -I -c 'import socket,sys
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8)
open(sys.argv[1],"w").write(str(s.getsockname()[1]))
conns=[]
while True: conns.append(s.accept())' "$pf" > /dev/null 2>&1 & BG_PIDS+=($!); disown
  while [ ! -s "$pf" ]; do sleep 0.1; done; PORT="$(cat "$pf")"
}
bounded() { # seconds cmd... -> the command, killed (exit 142) after <seconds>
  perl -e 'alarm shift; exec @ARGV or die' "$@"
}
case_b16_stalled_download_exits_2() {
  local start; silent_listener; OUT="$WORK/out.stall"; start=$SECONDS
  EO_GITLEAKS_RELEASES="http://127.0.0.1:$PORT" EO_DOWNLOAD_MAX_TIME=2 \
    bounded 15 bash "$SCRIPT" install "$WORK/inst-stall" > "$OUT" 2>&1; RC=$?
  expect_rc 2; expect_out 'download of .* failed'
  [ $((SECONDS - start)) -le 10 ] && ok "gave up within the bound" || ko "took $((SECONDS - start)) s"
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
# Missing arguments are "could not run" (2), never "credentials found" (1).
case_b6_missing_config_exits_2() {
  local r; r="$(new_repo b6d)"; commit_file "$r" a.txt x "pr"; OUT="$WORK/out.$RANDOM"
  (cd "$r" && GITLEAKS="$GITLEAKS_BIN" bash "$SCRIPT" scan develop) > "$OUT" 2>&1; RC=$?
  expect_rc 2; expect_out 'scan needs a config'
}
case_b6_missing_gitleaks_exits_2() {
  local r; r="$(new_repo b6e)"; commit_file "$r" a.txt x "pr"; OUT="$WORK/out.$RANDOM"
  (cd "$r" && unset GITLEAKS && bash "$SCRIPT" scan develop "$CONFIG") > "$OUT" 2>&1; RC=$?
  expect_rc 2; expect_out 'GITLEAKS must point'
}
case_b6_no_args_exits_2() {
  local r; r="$(new_repo b6f)"; commit_file "$r" a.txt x "pr"; OUT="$WORK/out.$RANDOM"
  (cd "$r" && GITLEAKS="$GITLEAKS_BIN" bash "$SCRIPT" scan) > "$OUT" 2>&1; RC=$?
  expect_rc 2
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

case_b12_gitleaksignore_cannot_silence() {
  local r sha; r="$(new_repo b12a)"; TOKEN="$(fake_pat)"
  commit_file "$r" Api.kt "val t = \"$TOKEN\"" "add"; sha="$(git -C "$r" rev-parse HEAD)"
  printf '%s\n' "$sha:Api.kt:github-pat:1" "Api.kt:github-pat:1" > "$r/.gitleaksignore"
  git -C "$r" add -A; git -C "$r" commit -q -m "ignore own finding"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 1; expect_out 'Api\.kt:1 github-pat$'; expect_no "$TOKEN"
}
case_b12_inline_allow_cannot_silence() {
  local r; r="$(new_repo b12b)"; TOKEN="$(fake_pat)"
  commit_file "$r" Api.kt "val t = \"$TOKEN\" // gitleaks:allow" "add with inline allow"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 1; expect_out 'Api\.kt:1 github-pat$'; expect_no "$TOKEN"
}

case_b14_dir_jwe_in_kt_fails() {
  local r; r="$(new_repo b14)"; TOKEN="$(fake_jwe_dir)"
  commit_file "$r" Backend.kt "val jwe = \"$TOKEN\"" "dir jwe in code"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 1; expect_out 'Backend\.kt:1 endios-jwe-token$'; expect_no "$TOKEN"
}

# A PR's own .gitattributes must not hide its diff (`-diff` and `binary` make git log print no patch).
gitattributes_case() { # repo-name attribute
  local r; r="$(new_repo "$1")"; TOKEN="$(fake_pat)"
  commit_file "$r" .gitattributes "*.kt $2" "no diffs for kotlin"
  commit_file "$r" Api.kt "val t = \"$TOKEN\"" "add"
  jenkins_merge "$r"; scan "$r" develop; expect_rc 1; expect_out 'Api\.kt:1 github-pat$'; expect_no "$TOKEN"
}
case_b13_gitattributes_nodiff_cannot_silence() { gitattributes_case b13a -diff; }
case_b13_gitattributes_binary_cannot_silence() { gitattributes_case b13b binary; }

# Merge-build variants: same PRs, built as a real merge with a moved target.
case_b1_pat_in_kt_merge_build_fails() {
  local r; r="$(new_repo b1m)"; TOKEN="$(fake_pat)"
  commit_file "$r" app/src/main/java/Api.kt "val token = \"$TOKEN\"" "add api"; merge_build "$r"
  scan "$r" develop; expect_rc 1; expect_out 'Api\.kt:1 github-pat$'; expect_no "$TOKEN"
}
case_b5_google_services_key_merge_build_passes() {
  local r; r="$(new_repo b5m)"
  commit_file "$r" app/google-services.json "$(gservices "$(fake_gcp)")" "firebase"
  merge_build "$r"; scan "$r" develop; expect_rc 0
}
case_b10_added_then_removed_merge_build_fails() {
  local r; r="$(new_repo b10m)"; TOKEN="$(fake_pat)"
  commit_file "$r" Api.kt "val t = \"$TOKEN\"" "add"; commit_file "$r" Api.kt 'val t = ""' "remove"
  merge_build "$r"; scan "$r" develop; expect_rc 1; expect_out 'Api\.kt:1 github-pat$'; expect_no "$TOKEN"
}
case_b13_gitattributes_nodiff_merge_build_cannot_silence() {
  local r; r="$(new_repo b13m)"; TOKEN="$(fake_pat)"
  commit_file "$r" .gitattributes "*.kt -diff" "no diffs for kotlin"
  commit_file "$r" Api.kt "val t = \"$TOKEN\"" "add"
  merge_build "$r"; scan "$r" develop; expect_rc 1; expect_out 'Api\.kt:1 github-pat$'; expect_no "$TOKEN"
}

# ---- status post: the commit that carries ci/jenkins: secret-scan ------------------------------
# Fake statuses API: 201 for a SHA listed in <known>, else 422 "No commit found" (GitHub's text);
# mode "fail" answers 500 to all, mode "limit" a 422 with another message to all.
# Logs "<code> <sha> auth=<yes|no> state=<state>" per request; never the token itself.
fake_api() { # known-file mode -> sets API, API_LOG
  local pf="$WORK/api.port.$RANDOM"; API_LOG="$WORK/api.log.$RANDOM"; : > "$API_LOG"
  python3 -I -c 'import http.server,json,sys
known_f,mode,log_f,port_f,token=sys.argv[1:6]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        sha=self.path.rsplit("/",1)[-1]
        body=json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        known=open(known_f).read().split()
        code=500 if mode=="fail" else 422 if mode=="limit" else (201 if sha in known else 422)
        msg="This SHA and context has reached the maximum number of statuses." if mode=="limit" else "No commit found for SHA: "+sha
        auth="yes" if self.headers.get("Authorization")=="token "+token else "no"
        open(log_f,"a").write("%d %s auth=%s state=%s context=%s\n"%(code,sha,auth,body["state"],body["context"]))
        out=json.dumps({"message":msg}).encode() if code==422 else b"{}"
        self.send_response(code); self.send_header("Content-Length",str(len(out))); self.end_headers()
        self.wfile.write(out)
    def log_message(self,*a): pass
s=http.server.HTTPServer(("127.0.0.1",0),H)
open(port_f,"w").write(str(s.server_port)); s.serve_forever()' "$1" "$2" "$API_LOG" "$pf" "$DUMMY_TOKEN" > /dev/null 2>&1 &
  BG_PIDS+=($!); disown
  while [ ! -s "$pf" ]; do sleep 0.1; done; API="http://127.0.0.1:$(cat "$pf")"
}
DUMMY_TOKEN="dummy-$(rand 16)"
post_status() { # repo state api -> sets RC, OUT
  OUT="$WORK/out.$RANDOM"
  (cd "$1" && printf '%s\n' "$DUMMY_TOKEN" | EO_GITHUB_API="$3" EO_STATUS_REPO=o/r \
    EO_STATUS_TARGET_URL=http://jenkins.invalid/1/console EO_STATUS_MAX_TIME="${EO_STATUS_MAX_TIME:-20}" \
    bounded 15 bash "$SCRIPT" post-status "$2" "Scanning") > "$OUT" 2>&1
  RC=$?
}
known() { # repo revs... -> file listing their SHAs
  local f="$WORK/known.$RANDOM" r="$1"; shift
  for rev in "$@"; do git -C "$r" rev-parse "$rev"; done > "$f"; echo "$f"
}
expect_api() { # repo expected-lines ("code rev" each)
  local want="" line; while read -r code rev; do
    [ -n "$code" ] && want+="$code $(git -C "$1" rev-parse "$rev") auth=yes"$'\n'
  done <<< "$2"
  local got; got="$(cut -d' ' -f1-3 "$API_LOG")"$'\n'
  [ "$got" = "$want" ] && ok "API saw: $(echo $2)" || ko "API saw: $(cat "$API_LOG" | tr '\n' ';'), want $(echo $2)"
}
moved_target_merge() { # repo-name -> Jenkins merge of a PR whose target moved
  local r; r="$(new_repo "$1")"; commit_file "$r" a.kt 'val a = 1' "pr"
  git -C "$r" checkout -q -b dev refs/remotes/origin/develop; commit_file "$r" d.kt 'val d = 1' "target"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q feature; jenkins_merge "$r"
  echo "$r"
}
case_b15_jenkins_merge_posts_on_pr_head() {
  local r; r="$(moved_target_merge sa)"
  fake_api "$(known "$r" HEAD^1 HEAD^2)" ok
  post_status "$r" pending "$API"; expect_rc 0
  post_status "$r" success "$API"; expect_rc 0
  expect_api "$r" "422 HEAD
201 HEAD^1
201 HEAD^1"
  grep -q 'context=ci/jenkins: secret-scan' "$API_LOG" && ok "context name" || ko "context name"
}
case_b15_other_422_on_merge_only_warns() {
  local r; r="$(moved_target_merge sg)"
  fake_api "$(known "$r" HEAD^1 HEAD^2)" limit
  post_status "$r" pending "$API"; expect_rc 0
  expect_out "WARNING: .*'pending' not posted \(HTTP 422\)"; expect_no "$DUMMY_TOKEN"
  expect_api "$r" "422 HEAD"
}
case_b15_forged_identity_author_merge_posts_on_head() {
  local r; r="$(new_repo sb)"; commit_file "$r" a.kt 'val a = 1' "pr"
  git -C "$r" checkout -q -b dev refs/remotes/origin/develop; commit_file "$r" d.kt 'val d = 1' "target"
  git -C "$r" update-ref refs/remotes/origin/develop HEAD; git -C "$r" checkout -q feature
  jenkins_merge "$r"   # the author forges the Jenkins identity on a merge they push
  fake_api "$(known "$r" HEAD HEAD^1 HEAD^2)" ok
  post_status "$r" pending "$API"; expect_rc 0; post_status "$r" failure "$API"; expect_rc 0
  expect_api "$r" "201 HEAD
201 HEAD"
}
case_b15_linear_posts_on_head() {
  local r; r="$(new_repo sc)"; commit_file "$r" a.kt 'val a = 1' "pr"
  fake_api "$(known "$r" HEAD HEAD^1)" ok
  post_status "$r" pending "$API"; expect_rc 0; post_status "$r" success "$API"; expect_rc 0
  expect_api "$r" "201 HEAD
201 HEAD"
}
case_b15_pending_forgets_a_previous_build_sha() {
  local r; r="$(new_repo sd)"; commit_file "$r" a.kt 'val a = 1' "pr"
  git -C "$r" rev-parse HEAD^1 > "$r/.eo-secret-scan.sha"   # left over from an older build
  fake_api "$(known "$r" HEAD HEAD^1)" ok
  post_status "$r" pending "$API"; expect_rc 0
  expect_api "$r" "201 HEAD"
}
case_b15_api_failure_only_warns() {
  local r; r="$(new_repo se)"; commit_file "$r" a.kt 'val a = 1' "pr"
  fake_api "$(known "$r" HEAD)" fail
  post_status "$r" pending "$API"; expect_rc 0; expect_out "WARNING: .*'pending' not posted \(HTTP 500\)"
  expect_no "$DUMMY_TOKEN"
}
case_b16_stalled_status_post_only_warns() {
  local r start; r="$(new_repo sf)"; commit_file "$r" a.kt 'val a = 1' "pr"; silent_listener; start=$SECONDS
  EO_STATUS_MAX_TIME=2 post_status "$r" pending "http://127.0.0.1:$PORT"
  expect_rc 0; expect_out "WARNING: .*'pending' not posted"; expect_no "$DUMMY_TOKEN"
  [ $((SECONDS - start)) -le 10 ] && ok "gave up within the bound" || ko "took $((SECONDS - start)) s"
}

case_b17_unresolvable_head_leaves_no_temp_file() {
  local r="$WORK/sh" tmp="$WORK/tmp-sh" s="$WORK/shim-sh" real; mkdir -p "$r" "$tmp"; git -C "$r" init -q -b feature
  real="$(command -v mktemp)"; shim "$s" mktemp "exec '$real' '$tmp/tmp.XXXXXX'"   # BSD mktemp ignores TMPDIR
  PATH="$s:$PATH" post_status "$r" pending "http://127.0.0.1:9"
  expect_rc 2; expect_out 'cannot resolve HEAD'
  [ -z "$(ls -A "$tmp")" ] && ok "temp dir left empty" || ko "left behind: $(ls -A "$tmp" | tr '\n' ' ')"
}

ALL_CASES=(install_ok install_bad_arch install_bad_os install_bad_checksum install_no_dir_exits_2 b16_stalled_download_exits_2
  b1_control_clean_pr_passes b1_pat_in_kt_fails
  b6_empty_target_fails b6_missing_target_ref_fails b6_no_merge_base_fails
  b6_missing_config_exits_2 b6_missing_gitleaks_exits_2 b6_no_args_exits_2
  b2_4_log_names_file_and_rule_not_value b5_google_services_key_passes
  b7_pat_in_google_services_fails b7_firebase_key_in_kt_fails
  b8_existing_secret_on_target_passes b9_target_moved_on_merge_build_passes
  b9_target_removed_secret_unmerged_passes b10_added_then_removed_fails
  b11_merge_resolution_adds_secret_fails
  b12_gitleaksignore_cannot_silence b12_inline_allow_cannot_silence
  b13_gitattributes_nodiff_cannot_silence b13_gitattributes_binary_cannot_silence b14_dir_jwe_in_kt_fails
  b1_pat_in_kt_merge_build_fails b5_google_services_key_merge_build_passes
  b10_added_then_removed_merge_build_fails b13_gitattributes_nodiff_merge_build_cannot_silence
  b15_jenkins_merge_posts_on_pr_head b15_other_422_on_merge_only_warns b15_forged_identity_author_merge_posts_on_head b15_linear_posts_on_head
  b15_pending_forgets_a_previous_build_sha b15_api_failure_only_warns b16_stalled_status_post_only_warns
  b17_unresolvable_head_leaves_no_temp_file)

if [ $# -gt 0 ]; then CASES=("$@"); else CASES=("${ALL_CASES[@]}"); fi
for CASE in "${CASES[@]}"; do
  echo "case $CASE"; OUT=""; "case_$CASE"
done
echo "passed $PASS, failed $FAIL${FAILED:+ (${FAILED[*]})}"
[ "$FAIL" = 0 ]
