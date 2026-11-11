#!/usr/bin/env bash
# Offline regression tests: bash tests/v3_bundle_test.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import gzip
import hashlib
import io
import pathlib
import sys
import tarfile
import zipfile

root = pathlib.Path(sys.argv[1])
packages = {}
for arch in ("amd64", "arm64"):
    binary = b"\x7fELF" + arch.encode()
    (root / (arch + "-expected")).write_bytes(binary)
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as tar:
        item = tarfile.TarInfo("openlist")
        item.size = len(binary)
        item.mode = 0o755
        tar.addfile(item, io.BytesIO(binary))
    packages[arch] = gzip.compress(stream.getvalue())

for name, arches, bad_hash in (
    ("bundle.zip", ("amd64", "arm64"), False),
    ("missing.zip", ("amd64",), False),
    ("bad-inner.zip", ("amd64", "arm64"), True),
):
    with zipfile.ZipFile(root / name, "w", zipfile.ZIP_DEFLATED) as z:
        for arch in arches:
            member = "openlist/openlist-linux-musl-" + arch + ".tar.gz"
            z.writestr(member, packages[arch])
            checksum = "0" * 64 if bad_hash else hashlib.sha256(packages[arch]).hexdigest()
            z.writestr(member + ".sha256", checksum + "  package.tar.gz\n")
        # These entries must never be extracted or executed.
        z.writestr("openlist/v3.sh", "exit 99\n")
        z.writestr("../should-not-exist", "not an installation asset")
PY

export OPENLIST_V3_LIB_ONLY=1
source "$root/v3.sh"
DOWNLOAD_URL=""
DOWNLOAD_BASE=""
LOCAL_DIR="$tmp"
SCRIPT_DIR="$tmp"
SKIP_LOCAL=1
CHECKSUM=""
CHECKSUM_URL=""
BUNDLE_URL="$DEFAULT_BUNDLE_URL"
BUNDLE_CHECKSUM="$DEFAULT_BUNDLE_SHA256"
GH_PROXY=""
DETECTED_ARCH=amd64
passed=0
pass() { printf 'PASS %s\n' "$1"; passed=$((passed + 1)); }

resolve_url "$DETECTED_ARCH"
test "$RESOLVED_URL" = "$DEFAULT_BUNDLE_URL"
test "$RESOLVED_BUNDLE" = 1
pass 'default short-link mirror'

BUNDLE_URL=""
resolve_url "$DETECTED_ARCH"
test "$RESOLVED_URL" = "https://github.com/$GH_REPO/releases/download/$RELEASE_TAG/openlist-linux-musl-amd64.tar.gz"
test "$RESOLVED_BUNDLE" = 0
pass 'explicitly empty bundle enables GitHub fallback'

BUNDLE_URL="$DEFAULT_BUNDLE_URL"
DOWNLOAD_URL='https://example.test/{ARCH}.tar.gz'
resolve_url "$DETECTED_ARCH"
test "$RESOLVED_URL" = 'https://example.test/amd64.tar.gz'
test "$RESOLVED_BUNDLE" = 0
pass 'explicit URL overrides bundle'

DOWNLOAD_URL=""
DOWNLOAD_BASE='https://example.test/files'
resolve_url "$DETECTED_ARCH"
test "$RESOLVED_URL" = 'https://example.test/files/openlist-linux-musl-amd64.tar.gz'
test "$RESOLVED_BUNDLE" = 0
pass 'mirror base overrides bundle'

DOWNLOAD_BASE=""
SKIP_LOCAL=0
touch "$tmp/openlist-linux-musl-amd64.tar.gz"
resolve_url "$DETECTED_ARCH"
test "$RESOLVED_URL" = "file://$tmp/openlist-linux-musl-amd64.tar.gz"
test "$RESOLVED_BUNDLE" = 0
pass 'local package overrides bundle'

for arch in amd64 arm64; do
  DETECTED_ARCH="$arch"
  RESOLVED_BUNDLE=0
  mkdir "$tmp/extract-$arch"
  prepare_binary "file://$tmp/bundle.zip" "$tmp/extract-$arch"
  cmp "$PREPARED_BINARY" "$tmp/$arch-expected"
  test ! -e "$tmp/extract-$arch/openlist/v3.sh"
  test ! -e "$tmp/should-not-exist"
  pass "ZIP selects $arch and ignores unrelated entries"
done

DETECTED_ARCH=amd64
RESOLVED_BUNDLE=1
BUNDLE_CHECKSUM="$(shasum -a 256 "$tmp/bundle.zip" | awk '{print $1}')"
mkdir "$tmp/verified-bundle"
prepare_binary "file://$tmp/bundle.zip" "$tmp/verified-bundle"
cmp "$PREPARED_BINARY" "$tmp/amd64-expected"
pass 'bundle SHA-256 and nested package SHA-256'

BUNDLE_CHECKSUM="$(printf '%064d' 0)"
mkdir "$tmp/bad-outer"
if prepare_binary "file://$tmp/bundle.zip" "$tmp/bad-outer" 2>/dev/null; then
  echo 'FAIL: bad outer SHA-256 accepted' >&2
  exit 1
fi
pass 'bad bundle SHA-256 rejected'

RESOLVED_BUNDLE=0
mkdir "$tmp/bad-inner"
if prepare_binary "file://$tmp/bad-inner.zip" "$tmp/bad-inner" 2>/dev/null; then
  echo 'FAIL: bad nested SHA-256 accepted' >&2
  exit 1
fi
pass 'bad nested package SHA-256 rejected'

DETECTED_ARCH=arm64
mkdir "$tmp/missing"
if prepare_binary "file://$tmp/missing.zip" "$tmp/missing" 2>/dev/null; then
  echo 'FAIL: missing architecture accepted' >&2
  exit 1
fi
pass 'missing architecture rejected'

printf 'TOTAL pass=%d\n' "$passed"
