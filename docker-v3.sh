#!/usr/bin/env bash
# Download a Docker image archive, load it locally, and update only OpenList.
set -euo pipefail

action="${1:-install}"
case "$action" in
  install|update|load|download-url) ;;
  *) echo '用法: bash docker-v3.sh [install|update|load|download-url]' >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo '镜像包安装目前支持 AMD64 和 ARM64。' >&2; exit 1 ;;
esac
tag="${OPENLIST_DOCKER_TAG:-beta}"
package="openlist-docker-${tag}-${arch}.tar.gz"
DEFAULT_BUNDLE_URL='https://url.200996.xyz/PuTW'
DEFAULT_BUNDLE_SHA256='0e7d7fd7deeb05da8089d433c0079711340dbffe6c802c8ae1fbce294a42184e'
default_bundle=""
[ "$tag" != beta ] || default_bundle="$DEFAULT_BUNDLE_URL"
# Explicit URLs override the built-in mirror. An empty bundle restores GitHub downloads.
bundle="${OPENLIST_DOCKER_BUNDLE_URL-$default_bundle}"
url="${OPENLIST_DOCKER_URL:-${bundle:-https://github.com/v200dd/OpenList/releases/download/${tag}/${package}}}"
url="${url//\{ARCH\}/$arch}"
url="${url//\{TAG\}/$tag}"
checksum="${OPENLIST_DOCKER_SHA256:-auto}"
if [ "$url" = "$DEFAULT_BUNDLE_URL" ] && [ -z "${OPENLIST_DOCKER_SHA256:-}" ] && [ -z "${OPENLIST_DOCKER_SHA256_URL:-}" ]; then
  checksum="$DEFAULT_BUNDLE_SHA256"
fi
if [ "$action" = download-url ]; then
  printf '%s\n' "$url"
  exit 0
fi
for command in docker curl tar awk mktemp uname; do
  command -v "$command" >/dev/null || { echo "未找到命令: $command" >&2; exit 1; }
done
docker info >/dev/null
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() {
  curl -fL --retry 3 --connect-timeout 10 "$1" -o "$2"
}
verify() {
  local file="$1" expected="$2" actual
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { echo '镜像包 SHA-256 格式错误。' >&2; return 1; }
  if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v shasum >/dev/null; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    echo '请先安装 sha256sum 或 shasum。' >&2; return 1
  fi
  test "$actual" = "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" || { echo '镜像包 SHA-256 校验失败。' >&2; return 1; }
  echo '镜像包 SHA-256 校验通过。'
}

ensure_unzip() {
  command -v unzip >/dev/null && return 0
  [ "$(id -u)" = 0 ] || { echo '自动安装 unzip 需要以 root 运行脚本。' >&2; return 1; }
  echo '正在安装 ZIP 解包工具 unzip。'
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unzip
  elif command -v dnf >/dev/null; then
    dnf install -y unzip
  elif command -v yum >/dev/null; then
    yum install -y unzip
  elif command -v apk >/dev/null; then
    apk add --no-cache unzip
  elif command -v zypper >/dev/null; then
    zypper --non-interactive install unzip
  elif command -v pacman >/dev/null; then
    pacman -S --needed --noconfirm unzip
  else
    echo '请安装 unzip 解包工具后重试。' >&2; return 1
  fi
  command -v unzip >/dev/null
}

echo "正在下载 Docker 镜像包，架构: $arch"
fetch "$url" "$work/download"
if [ "$checksum" = auto ]; then
  fetch "${OPENLIST_DOCKER_SHA256_URL:-${url}.sha256}" "$work/checksum"
  checksum="$(awk 'NF {print $1; exit}' "$work/checksum")"
fi
verify "$work/download" "$checksum"

magic="$(head -c 4 "$work/download" | od -An -tx1 | tr -d ' \n')"
case "$magic" in
  504b0304)
    ensure_unzip
    unzip -Z1 "$work/download" > "$work/members"
    member=""
    for candidate in "$package" "openlist-docker/$package"; do
      if grep -Fxq "$candidate" "$work/members"; then member="$candidate"; break; fi
    done
    test -n "$member" || { echo "整包中未找到当前架构镜像: $package" >&2; exit 1; }
    unzip -p "$work/download" "$member" > "$work/image.tar.gz"
    unzip -p "$work/download" "$member.sha256" > "$work/image.sha256"
    verify "$work/image.tar.gz" "$(awk 'NF {print $1; exit}' "$work/image.sha256")"
    image_archive="$work/image.tar.gz"
    ;;
  1f8b*) image_archive="$work/download" ;;
  *) echo '下载内容应为 Docker 镜像 tar.gz 或包含镜像包的 ZIP。' >&2; exit 1 ;;
esac

echo '正在导入 Docker 镜像。'
docker load --input "$image_archive"
image="ghcr.nju.edu.cn/v200dd/openlist-git:beta"
docker image inspect "$image" --format '后端: {{index .Config.Labels "org.opencontainers.image.revision"}}；前端: {{index .Config.Labels "org.opencontainers.image.frontend.version"}}'
[ "$action" != load ] || exit 0
docker compose version >/dev/null

compose="${OPENLIST_COMPOSE_FILE:-}"
if [ -z "$compose" ]; then
  for candidate in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    if [ -f "$candidate" ]; then compose="$candidate"; break; fi
  done
fi
if [ -z "$compose" ]; then
  compose=docker-compose.yml
  cat > "$compose" <<'YAML'
services:
  openlist:
    image: ghcr.nju.edu.cn/v200dd/openlist-git:beta
    pull_policy: never
    container_name: openlist
    restart: unless-stopped
    ports:
      - "5244:5244"
    volumes:
      - ./data:/opt/openlist/data
    environment:
      - TZ=Asia/Shanghai
      - UMASK=022
    user: "0:0"
YAML
fi
test -f "$compose" || { echo "未找到 Compose 配置: $compose" >&2; exit 1; }
# Keep existing configuration/data and do not pull an older image from a registry.
docker compose -f "$compose" up -d --pull never openlist
echo 'OpenList 已更新，原数据目录继续保留。'
