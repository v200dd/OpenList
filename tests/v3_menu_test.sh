#!/usr/bin/env bash
# Verify unified menu routing and isolation without installing services or running Docker.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export OPENLIST_V3_LIB_ONLY=1
source "$root/v3.sh"
clear() { :; }

native_url="$DEFAULT_BUNDLE_URL"
native_checksum="$DEFAULT_BUNDLE_SHA256"
test "$(docker_openlist download-url)" = 'https://url.200996.xyz/PuTW'
test "$DEFAULT_BUNDLE_URL" = "$native_url"
test "$DEFAULT_BUNDLE_SHA256" = "$native_checksum"
echo 'PASS Docker source inspection preserves native download settings'

docker_openlist() { printf 'DISPATCH docker %s\n' "$*"; }
install_openlist() { printf 'DISPATCH native install %s\n' "$INSTALL_PATH"; }
update_openlist() { echo 'DISPATCH native update'; }

for action in install update load download-url; do
  test "$(main docker "$action")" = "DISPATCH docker $action"
done
echo 'PASS all Docker command actions route through the unified entry'

for pair in '10 install' '11 update' '12 download-url'; do
  read -r selection action <<< "$pair"
  output="$(main <<< "$selection")"
  [[ "$output" == *"DISPATCH docker $action"* ]]
done
echo 'PASS menu Docker installation, update and source selections'

test "$(main install /tmp/openlist-menu-fixture)" = 'DISPATCH native install /tmp/openlist-menu-fixture'
test "$(main update)" = 'DISPATCH native update'
[[ "$(main <<< '1')" == *'DISPATCH native install'* ]]
[[ "$(main <<< '2')" == *'DISPATCH native update'* ]]
echo 'PASS existing native commands and menu selections are preserved'

if main <<< '99' >/dev/null 2>&1; then
  echo 'FAIL invalid menu selection succeeded' >&2
  exit 1
fi
echo 'PASS invalid menu selection returns failure'
