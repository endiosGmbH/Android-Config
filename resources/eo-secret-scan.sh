#!/usr/bin/env bash
# Secret scan for androidPRVerify. Exit 0 = clean, 1 = credentials found, 2 = the scan could not run.
#   eo-secret-scan.sh install <dir>                   pinned gitleaks into <dir>, SHA-256 verified
#   GITLEAKS=<bin> eo-secret-scan.sh scan <target-branch> <config>   run inside the PR checkout
set -uo pipefail

GITLEAKS_VERSION=8.30.1
SHA256_DARWIN_ARM64=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
SHA256_DARWIN_X64=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709

die() { echo "Secret scan: $*" >&2; exit 2; }

install() {
  local dir="${1:?install needs a target dir}" os arch platform sum tarball
  os="$(uname -s)"; arch="$(uname -m)"
  [ "$os" = Darwin ] || die "unsupported OS '$os' (gitleaks is pinned for macOS arm64/x64 only)"
  case "$arch" in
    arm64) platform=darwin_arm64; sum=$SHA256_DARWIN_ARM64 ;;
    x86_64) platform=darwin_x64; sum=$SHA256_DARWIN_X64 ;;
    *) die "unsupported architecture '$arch' (gitleaks is pinned for macOS arm64/x64 only)" ;;
  esac
  tarball="gitleaks_${GITLEAKS_VERSION}_${platform}.tar.gz"
  mkdir -p "$dir" || die "cannot create $dir"
  curl -sSfL -o "$dir/$tarball" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${tarball}" \
    || die "download of $tarball failed"
  if ! (cd "$dir" && echo "$sum  $tarball" | shasum -a 256 -c --status); then
    rm -f "$dir/$tarball"; die "checksum mismatch for $tarball, refusing to run it"
  fi
  tar -xzf "$dir/$tarball" -C "$dir" gitleaks || die "cannot extract gitleaks from $tarball"
  rm -f "$dir/$tarball"
  echo "Secret scan: gitleaks $GITLEAKS_VERSION ($platform) installed, checksum verified"
}

scan() {
  local target="${1:-}" config="${2:?scan needs a config}" ref base net rc tmpl attrs
  : "${GITLEAKS:?GITLEAKS must point at the gitleaks binary}"
  # Fail closed: without the PR's base there is nothing to diff against, so never pass.
  [ -n "$target" ] || die "CHANGE_TARGET is empty, cannot find the PR's base branch"
  ref="origin/$target"
  git rev-parse --verify --quiet "$ref^{commit}" > /dev/null || die "base branch $ref not found in the checkout"
  base="$(git merge-base "$ref" HEAD)" || die "no merge base between $ref and HEAD"
  # A PR built without merging its target is diffed against the merge base instead.
  git merge-base --is-ancestor "$ref" HEAD && base="$ref"
  # Synthetic commit = what the PR would change on the target, incl. merge-resolution content.
  net="$(GIT_AUTHOR_NAME=secret-scan GIT_AUTHOR_EMAIL=secret-scan@invalid \
    GIT_COMMITTER_NAME=secret-scan GIT_COMMITTER_EMAIL=secret-scan@invalid \
    git commit-tree "HEAD^{tree}" -p "$base" -m "secret-scan: net PR diff")" || die "cannot build the net PR diff vs $ref"
  # gitleaks honours a .gitleaksignore in the scanned dir; the PR must not silence itself.
  rm -f .gitleaksignore || die "cannot remove .gitleaksignore"
  # In-tree `-diff`/`binary` would hide patches; info/attributes outranks .gitattributes.
  attrs="$(git rev-parse --git-path info/attributes)" && mkdir -p "$(dirname "$attrs")" \
    && { grep -qxF '* diff' "$attrs" 2>/dev/null || echo '* diff' >> "$attrs"; } || die "cannot force diffs in $attrs"
  # One "path:line rule" per finding; no commit (the net commit is synthetic), never the value.
  tmpl="$(mktemp)" || die "mktemp failed"
  printf '%s' '{{range .}}{{.File}}:{{.StartLine}} {{.RuleID}}{{"\n"}}{{end}}' > "$tmpl"
  "$GITLEAKS" git --config "$config" --redact --no-banner --no-color --exit-code 10 --ignore-gitleaks-allow \
    --report-format template --report-template "$tmpl" --report-path - \
    --log-opts="^$ref HEAD $net" .
  rc=$?
  rm -f "$tmpl"
  case $rc in
    0) echo "Secret scan: no credentials in this PR"; return 0 ;;
    10) echo "Secret scan: this PR adds credentials (listed above as path:line rule, values redacted)."
       echo "Inspect locally with: gitleaks git --redact --config <Android-Config>/resources/eo-gitleaks.toml"
       return 1 ;;
    *) die "gitleaks failed (exit $rc)" ;;
  esac
}

case "${1:-}" in
  install) shift; install "$@" ;;
  scan) shift; scan "$@"; exit $? ;;
  *) die "usage: $0 install <dir> | scan <target-branch> <config>" ;;
esac
