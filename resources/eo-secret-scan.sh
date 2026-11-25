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

case "${1:-}" in
  install) shift; install "$@" ;;
  *) die "usage: $0 install <dir> | scan <target-branch> <config>" ;;
esac
