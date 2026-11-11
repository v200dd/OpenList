#!/usr/bin/env bash
# Test download/load/update orchestration without a Docker daemon.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/deployment/data"
python3 - "$tmp" <<'PY'
import gzip, hashlib, io, json, pathlib, sys, tarfile, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root / 'bundle.zip', 'w') as z:
    for arch in ('amd64', 'arm64'):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w') as tar:
            data = json.dumps({'fixture_architecture': arch}).encode()
            item = tarfile.TarInfo('manifest.json')
            item.size = len(data)
            tar.addfile(item, io.BytesIO(data))
        package = 'openlist-docker-beta-' + arch + '.tar.gz'
        data = gzip.compress(stream.getvalue())
        (root / package).write_bytes(data)
        checksum = hashlib.sha256(data).hexdigest() + '  ' + package + '\n'
        (root / (package + '.sha256')).write_text(checksum)
        z.writestr('openlist-docker/' + package, data)
        z.writestr('openlist-docker/' + package + '.sha256', checksum)
PY
cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -e
echo "$*" >> "$DOCKER_TEST_LOG"
if [ "$1" = load ]; then
  tar -xzOf "$3" manifest.json > "$DOCKER_TEST_ARCHIVE"
fi
SH
cat > "$tmp/bin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$DOCKER_TEST_ARCH"
SH
chmod +x "$tmp/bin/docker" "$tmp/bin/uname"
export PATH="$tmp/bin:$PATH"
export DOCKER_TEST_LOG="$tmp/docker.log" DOCKER_TEST_ARCHIVE="$tmp/loaded.json"
export DOCKER_TEST_ARCH=x86_64
printf 'keep-data\n' > "$tmp/deployment/data/marker"
printf 'services:\n  openlist:\n    image: ghcr.nju.edu.cn/v200dd/openlist-git:beta\n' > "$tmp/deployment/compose.yaml"
cp "$tmp/deployment/compose.yaml" "$tmp/expected-compose"
cd "$tmp/deployment"
OPENLIST_DOCKER_URL="file://$tmp/openlist-docker-beta-amd64.tar.gz" bash "$root/docker-v3.sh" update
grep -q 'amd64' "$DOCKER_TEST_ARCHIVE"
grep -q 'up -d --pull never openlist' "$DOCKER_TEST_LOG"
! grep -q '^pull ' "$DOCKER_TEST_LOG"
cmp compose.yaml "$tmp/expected-compose"
test "$(cat data/marker)" = keep-data
echo 'PASS native package loads before update; configuration/data preserved; no registry pull'

export DOCKER_TEST_ARCH=aarch64
checksum="$(shasum -a 256 "$tmp/bundle.zip" | awk '{print $1}')"
: > "$DOCKER_TEST_LOG"
OPENLIST_DOCKER_BUNDLE_URL="file://$tmp/bundle.zip" OPENLIST_DOCKER_SHA256="$checksum" bash "$root/docker-v3.sh" load
grep -q 'arm64' "$DOCKER_TEST_ARCHIVE"
! grep -q '^compose ' "$DOCKER_TEST_LOG"
echo 'PASS ZIP selects ARM64; load-only mode leaves the container unchanged'

: > "$DOCKER_TEST_LOG"
if OPENLIST_DOCKER_BUNDLE_URL="file://$tmp/bundle.zip" OPENLIST_DOCKER_SHA256="$(printf '%064d' 0)" bash "$root/docker-v3.sh" load > "$tmp/bad-sha.log" 2>&1; then
  echo 'FAIL bad checksum accepted' >&2; exit 1
fi
! grep -q '^load ' "$DOCKER_TEST_LOG"
echo 'PASS bad ZIP checksum rejected before Docker load'

: > "$DOCKER_TEST_LOG"
bash "$root/docker-v3.sh" download-url > "$tmp/default-source"
grep -Fxq 'https://url.200996.xyz/PuTW' "$tmp/default-source"
test ! -s "$DOCKER_TEST_LOG"
echo 'PASS built-in domestic short link can be inspected without Docker'

OPENLIST_DOCKER_BUNDLE_URL='' bash "$root/docker-v3.sh" download-url > "$tmp/github-source"
grep -Fxq 'https://github.com/v200dd/OpenList/releases/download/beta/openlist-docker-beta-arm64.tar.gz' "$tmp/github-source"
echo 'PASS explicit empty bundle restores GitHub Release source'
