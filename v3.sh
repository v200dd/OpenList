#!/usr/bin/env bash
# OpenList one-click installer for Linux systemd servers.
# Based on the layout of the official Alist v3.sh script.

set -u
set -o pipefail

APP_NAME="OpenList"
BINARY_NAME="openlist"
SERVICE_NAME="openlist"
GH_REPO="v200dd/OpenList"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

info() { printf "%b\n" "${GREEN}${1}${RESET}" >&2; }
warn() { printf "%b\n" "${YELLOW}${1}${RESET}" >&2; }
error() { printf "%b\n" "${RED}${1}${RESET}" >&2; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || pwd)"

# Optional KEY=VALUE config. Only OPENLIST_* keys are read; no shell code is executed.
load_env_file() {
  local file key value seen=" "
  local candidates=()
  if [ -n "${OPENLIST_ENV_FILE:-}" ]; then
    candidates+=("$OPENLIST_ENV_FILE")
  fi
  candidates+=("$PWD/v3.env" "$SCRIPT_DIR/v3.env")
  for file in "${candidates[@]}"; do
    [ -f "$file" ] || continue
    case "$seen" in *" $file "*) continue ;; esac
    seen="$seen$file "
    while IFS='=' read -r key value || [ -n "${key:-}" ]; do
      key="$(trim "${key:-}")"
      value="$(trim "${value:-}")"
      value="${value%$'\r'}"
      key="${key#export }"
      key="$(trim "$key")"
      case "$key" in
        ''|'#'*) continue ;;
      esac
      [[ "$key" =~ ^OPENLIST_[A-Z0-9_]+$ ]] || continue
      # Explicit environment variables take priority over config files.
      if printenv "$key" >/dev/null 2>&1; then
        continue
      fi
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
      printf -v "$key" '%s' "$value"
      export "$key"
    done < "$file"
    printf '已加载配置: %s\n' "$file" >&2
  done
}
load_env_file

RELEASE_TAG="${OPENLIST_RELEASE_TAG:-beta}"
GH_PROXY="${OPENLIST_GH_PROXY:-}"
DOWNLOAD_URL="${OPENLIST_DOWNLOAD_URL:-}"
DOWNLOAD_BASE="${OPENLIST_DOWNLOAD_BASE:-}"
# The ZIP mirror contains both architectures and their SHA-256 sidecars.
# An explicitly empty OPENLIST_BUNDLE_URL restores the GitHub Release fallback.
DEFAULT_BUNDLE_URL="https://url.200996.xyz/2DXW"
DEFAULT_BUNDLE_SHA256="2a987ce1dcd5d33bc52a3f0e78723dfe912090feeac09ccf2863e2e4671566ce"
BUNDLE_URL="${OPENLIST_BUNDLE_URL-$DEFAULT_BUNDLE_URL}"
BUNDLE_CHECKSUM="${OPENLIST_BUNDLE_SHA256:-}"
if [ "$BUNDLE_URL" = "$DEFAULT_BUNDLE_URL" ]; then
  BUNDLE_CHECKSUM="${OPENLIST_BUNDLE_SHA256-$DEFAULT_BUNDLE_SHA256}"
fi
PACKAGE_NAME="${OPENLIST_PACKAGE_NAME:-openlist-linux-musl-__ARCH__.tar.gz}"
CHECKSUM="${OPENLIST_SHA256:-}"
CHECKSUM_URL="${OPENLIST_SHA256_URL:-}"
LOCAL_DIR="${OPENLIST_LOCAL_DIR:-$PWD}"
SKIP_LOCAL="${OPENLIST_SKIP_LOCAL:-0}"
DEFAULT_INSTALL_PATH="/opt/openlist"
INSTALL_PATH="${OPENLIST_INSTALL_PATH:-$DEFAULT_INSTALL_PATH}"
SERVICE_FILE="${OPENLIST_SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"

DETECTED_ARCH=""
RESOLVED_URL=""
RESOLVED_BUNDLE=0
FOUND_INSTALL_PATH=""
PREPARED_BINARY=""
EXPECTED_SHA256=""

usage() {
  cat <<USAGE
$APP_NAME 管理脚本

用法:
  bash $0 install [路径]    安装，默认路径: $DEFAULT_INSTALL_PATH
  bash $0 update            更新
  bash $0 download-url      查看当前解析出的下载地址
  bash $0 uninstall         卸载
  bash $0 start             启动服务
  bash $0 stop              停止服务
  bash $0 restart           重启服务
  bash $0 status            查看服务状态
  bash $0 password          重置管理员密码
  bash $0                   显示交互菜单

下载地址:
  OPENLIST_DOWNLOAD_URL      完整下载地址；支持 {ARCH} / {TAG}；可指向 ZIP、tar.gz 或裸二进制
  OPENLIST_DOWNLOAD_BASE     镜像目录；自动拼接包名，支持 {ARCH} / {TAG}
  OPENLIST_BUNDLE_URL        整包 ZIP 地址，默认: $DEFAULT_BUNDLE_URL；设为空可使用 GitHub Release
  OPENLIST_BUNDLE_SHA256     整包 ZIP 的 SHA-256；默认镜像内置校验值
  OPENLIST_PACKAGE_NAME      包名模板，默认 openlist-linux-musl-{ARCH}.tar.gz
  OPENLIST_LOCAL_DIR         本机安装包目录，默认当前目录
  OPENLIST_RELEASE_TAG       GitHub Release 标签，默认 beta
  OPENLIST_GH_PROXY          GitHub 代理前缀，须以 http(s):// 开头并以 / 结尾
  OPENLIST_SKIP_LOCAL=1      跳过本机安装包自动识别

校验与配置:
  OPENLIST_SHA256            64 位 SHA-256、校验文件地址或 auto（下载同名 .sha256）
  OPENLIST_SHA256_URL        校验文件地址；内容可带文件名
  OPENLIST_ENV_FILE          额外 KEY=VALUE 配置文件
  OPENLIST_INSTALL_PATH      安装目录；install 的第二个参数优先
  OPENLIST_SERVICE_FILE      systemd 单元文件路径（高级用途）

优先级: OPENLIST_DOWNLOAD_URL > OPENLIST_DOWNLOAD_BASE > 本机安装包 > 整包 ZIP 镜像 > GitHub Release。
自定义地址支持 http://、https://、file://、绝对路径及相对路径。
脚本还会读取当前目录或脚本目录的 v3.env；只读取 OPENLIST_* 键。
默认安装与更新从短链接下载整包，自动选择当前架构；ZIP 解包工具缺失时自动安装 unzip。
把 v3.sh 和二进制一起放到镜像站，也可以通过 v3.env 或环境变量设置其他下载源。
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "未找到 $1 命令，请先安装。"
    return 1
  fi
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    require_command "$cmd" || return 1
  done
}

require_root() {
  if [ "$(id -u)" != "0" ]; then
    error "请使用 root 权限运行此命令。"
    return 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    error "未找到 systemctl，此脚本仅支持 systemd Linux。"
    return 1
  fi
}

require_checksum_tool() {
  if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    return 0
  fi
  error "启用 SHA-256 校验需要 sha256sum 或 shasum，请先安装。"
  return 1
}

detect_arch() {
  local machine
  machine="$(uname -m)" || return 1
  case "$machine" in
    x86_64|amd64) DETECTED_ARCH="amd64" ;;
    aarch64|arm64) DETECTED_ARCH="arm64" ;;
    *)
      error "不支持的平台: ${machine}。此脚本目前支持 x86_64 和 arm64。"
      return 1
      ;;
  esac
  return 0
}

substitute_placeholders() {
  local s="$1"
  s="${s//'__ARCH__'/$DETECTED_ARCH}"
  s="${s//'__TAG__'/$RELEASE_TAG}"
  s="${s//'{ARCH}'/$DETECTED_ARCH}"
  s="${s//'{TAG}'/$RELEASE_TAG}"
  printf '%s' "$s"
}

path_to_file_url() {
  local p="$1" encoded
  encoded="$(printf '%s' "$p" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/\\/%5C/g' -e 's/"/%22/g')" || return 1
  printf 'file://%s\n' "$encoded"
}

normalize_source() {
  local url="$1"
  case "$url" in
    /*) path_to_file_url "$url" ;;
    ./*) path_to_file_url "$PWD/${url#./}" ;;
    ../*) path_to_file_url "$PWD/$url" ;;
    file://*|http://*|https://*) printf '%s\n' "$url" ;;
    *)
      error "下载地址必须以 http://、https://、file:// 开头，或使用本机路径: $url"
      return 1
      ;;
  esac
}

resolve_url() {
  local arch="$1" url="" base candidate
  RESOLVED_BUNDLE=0
  if [ -n "$DOWNLOAD_URL" ]; then
    url="$DOWNLOAD_URL"
  elif [ -n "$DOWNLOAD_BASE" ]; then
    base="$DOWNLOAD_BASE"
    case "$base" in
      */) ;;
      *) base="$base/" ;;
    esac
    case "$base" in
      /*|./*|../*|file://*|http://*|https://*) ;;
      *) base="$PWD/$base" ;;
    esac
    url="${base}${PACKAGE_NAME}"
  else
    if [ "$SKIP_LOCAL" != "1" ]; then
      for candidate in \
        "$LOCAL_DIR/$PACKAGE_NAME" \
        "$SCRIPT_DIR/$PACKAGE_NAME" \
        "$LOCAL_DIR/$BINARY_NAME" \
        "$SCRIPT_DIR/$BINARY_NAME"
      do
        candidate="$(substitute_placeholders "$candidate")"
        if [ -f "$candidate" ]; then
          url="$candidate"
          info "已发现本机安装包: $candidate"
          break
        fi
      done
    fi
    if [ -z "$url" ] && [ -n "$BUNDLE_URL" ]; then
      url="$BUNDLE_URL"
      RESOLVED_BUNDLE=1
    fi
    if [ -z "$url" ]; then
      url="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/${PACKAGE_NAME}"
      if [ -n "$GH_PROXY" ]; then
        case "$GH_PROXY" in
          http://*/|https://*/) url="${GH_PROXY}${url}" ;;
          *) error "OPENLIST_GH_PROXY 必须以 http:// 或 https:// 开头并以 / 结尾。"; return 1 ;;
        esac
      fi
    fi
  fi
  url="$(substitute_placeholders "$url")"
  case "$url" in
    /*|file://*|http://*|https://*) ;;
    *) url="$PWD/$url" ;;
  esac
  url="$(normalize_source "$url")" || return 1
  RESOLVED_URL="$url"
  return 0
}

find_installed_path() {
  local path=""
  if [ -f "$SERVICE_FILE" ]; then
    path="$(sed -n 's/^WorkingDirectory=//p' "$SERVICE_FILE" | head -n 1)"
    path="$(trim "$path")"
  fi
  if [ -n "$path" ] && [ -f "$path/$BINARY_NAME" ]; then
    FOUND_INSTALL_PATH="$path"
    return 0
  fi
  if [ -f "$INSTALL_PATH/$BINARY_NAME" ]; then
    FOUND_INSTALL_PATH="$INSTALL_PATH"
    return 0
  fi
  return 1
}

download_file() {
  local url="$1" output="$2"
  info "下载地址: $url"
  if ! curl -fL --connect-timeout 10 --retry 3 --retry-delay 3 "$url" -o "$output"; then
    error "下载失败: $url"
    return 1
  fi
  if [ ! -s "$output" ]; then
    error "下载内容为空。"
    rm -f "$output"
    return 1
  fi
  return 0
}

fetch_checksum_file() {
  local src="$1" tmp="$2"
  if ! curl -fL --connect-timeout 10 --retry 3 --retry-delay 3 "$src" -o "$tmp"; then
    error "校验文件下载失败: $src"
    rm -f "$tmp"
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    error "校验文件内容为空: $src"
    rm -f "$tmp"
    return 1
  fi
  return 0
}

resolve_checksum() {
  local source_url="$1" expected="" checksum_url="$CHECKSUM_URL" tmp raw src
  checksum_url="$(substitute_placeholders "$checksum_url")"
  source_url="$(substitute_placeholders "$source_url")"
  if [ -n "$CHECKSUM" ]; then
    if [ "$CHECKSUM" = "auto" ]; then
      [ -z "$checksum_url" ] && checksum_url="${source_url}.sha256"
    elif [[ "$CHECKSUM" =~ ^(https?://|file://|/|\./|\.\./) ]]; then
      [ -z "$checksum_url" ] && checksum_url="$CHECKSUM"
    else
      expected="$CHECKSUM"
    fi
  fi
  if [ -n "$checksum_url" ]; then
    case "$checksum_url" in
      /*|file://*|http://*|https://*) src="$checksum_url" ;;
      *) src="$PWD/$checksum_url" ;;
    esac
    src="$(normalize_source "$src")" || return 1
    tmp="$(mktemp /tmp/openlist.XXXXXX.sha256)" || return 1
    fetch_checksum_file "$src" "$tmp" || return 1
    raw="$(awk 'NF {print $1; exit}' "$tmp")"
    rm -f "$tmp"
    expected="$raw"
  fi
  expected="$(printf '%s' "$expected" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  if [ -z "$expected" ]; then
    EXPECTED_SHA256=""
    return 0
  fi
  if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    error "SHA-256 格式不正确（需要 64 位十六进制）: $expected"
    return 1
  fi
  EXPECTED_SHA256="$expected"
  return 0
}

verify_checksum() {
  local file="$1" source_url="$2" actual
  local -a tool=()
  if [ "$RESOLVED_BUNDLE" = "1" ] && [ -z "$CHECKSUM" ] && [ -z "$CHECKSUM_URL" ]; then
    local CHECKSUM="$BUNDLE_CHECKSUM" CHECKSUM_URL=""
  fi
  resolve_checksum "$source_url" || return 1
  [ -z "$EXPECTED_SHA256" ] && return 0
  require_checksum_tool || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    tool=(sha256sum)
  else
    tool=(shasum -a 256)
  fi
  actual="$("${tool[@]}" "$file" | awk '{print $1; exit}')" || return 1
  if [ "$actual" != "$EXPECTED_SHA256" ]; then
    error "SHA-256 校验失败：期望 ${EXPECTED_SHA256}，实际 ${actual}"
    return 1
  fi
  info "SHA-256 校验通过。"
  return 0
}

ensure_unzip() {
  command -v unzip >/dev/null 2>&1 && return 0
  require_root || return 1
  info "正在安装 ZIP 解包工具 unzip。"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unzip || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y unzip || return 1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y unzip || return 1
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install unzip || return 1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --needed --noconfirm unzip || return 1
  else
    error "未找到 unzip，请安装 ZIP 解包工具后重试。"
    return 1
  fi
  require_command unzip
}

extract_tar_binary() {
  local archive="$1" workdir="$2" binary
  mkdir -p "$workdir/extract" || return 1
  if ! tar -xzf "$archive" -C "$workdir/extract"; then
    error "解压失败，请确认安装包是 OpenList 的 tar.gz 文件。"
    return 1
  fi
  if [ -f "$workdir/extract/$BINARY_NAME" ]; then
    binary="$workdir/extract/$BINARY_NAME"
  else
    binary="$(find "$workdir/extract" -type f -name "$BINARY_NAME" -print 2>/dev/null | head -n 1)"
  fi
  PREPARED_BINARY="$binary"
}

prepare_zip_binary() {
  local archive="$1" workdir="$2" package member="" candidate expected
  ensure_unzip || return 1
  [ -n "$DETECTED_ARCH" ] || detect_arch || return 1
  package="$(substitute_placeholders "$PACKAGE_NAME")"
  unzip -Z1 "$archive" > "$workdir/zip-members" || return 1
  for candidate in "openlist/$package" "$package"; do
    if grep -Fxq "$candidate" "$workdir/zip-members"; then
      member="$candidate"
      break
    fi
  done
  if [ -z "$member" ]; then
    error "ZIP 整包中没有当前架构的安装包: $package"
    return 1
  fi
  info "从 ZIP 整包中提取当前架构: $DETECTED_ARCH"
  # Stream only the requested member; never execute the script inside the ZIP.
  unzip -p "$archive" "$member" > "$workdir/package.tar.gz" || return 1
  if grep -Fxq "$member.sha256" "$workdir/zip-members"; then
    unzip -p "$archive" "$member.sha256" > "$workdir/package.sha256" || return 1
    expected="$(awk 'NF {print $1; exit}' "$workdir/package.sha256")"
    if [ -z "$expected" ]; then
      error "ZIP 整包中当前架构的 SHA-256 校验文件为空。"
      return 1
    fi
    (
      CHECKSUM="$expected"
      CHECKSUM_URL=""
      RESOLVED_BUNDLE=0
      verify_checksum "$workdir/package.tar.gz" "$member"
    ) || return 1
  fi
  extract_tar_binary "$workdir/package.tar.gz" "$workdir"
}

prepare_binary() {
  local url="$1" workdir="$2" archive magic binary binary_magic
  archive="$workdir/download"
  download_file "$url" "$archive" || return 1
  verify_checksum "$archive" "$url" || return 1
  magic="$(head -c 4 "$archive" | od -An -t x1 | tr -d ' \n')"
  case "$magic" in
    1f8b*)
      extract_tar_binary "$archive" "$workdir" || return 1
      binary="$PREPARED_BINARY"
      ;;
    504b0304|504b0506|504b0708)
      prepare_zip_binary "$archive" "$workdir" || return 1
      binary="$PREPARED_BINARY"
      ;;
    7f454c46)
      binary="$workdir/$BINARY_NAME"
      if ! cp "$archive" "$binary"; then
        error "复制二进制失败。"
        return 1
      fi
      ;;
    *)
      error "下载内容不是 ZIP、gzip 压缩包或 ELF 可执行文件（magic: ${magic:-空}）。"
      return 1
      ;;
  esac
  if [ -z "$binary" ] || [ ! -f "$binary" ]; then
    error "安装包中没有找到 ${BINARY_NAME}。"
    return 1
  fi
  binary_magic="$(head -c 4 "$binary" | od -An -t x1 | tr -d ' \n')"
  case "$binary_magic" in
    7f454c46*) ;;
    *)
      error "${BINARY_NAME} 不是有效的 ELF 可执行文件。"
      return 1
      ;;
  esac
  PREPARED_BINARY="$binary"
  return 0
}

install_binary() {
  local binary="$1" tmp="$INSTALL_PATH/$BINARY_NAME.tmp"
  if ! cp "$binary" "$tmp"; then
    error "写入 ${BINARY_NAME} 失败。"
    return 1
  fi
  if ! chmod 755 "$tmp"; then
    error "设置 ${BINARY_NAME} 权限失败。"
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$INSTALL_PATH/$BINARY_NAME"; then
    error "替换 ${BINARY_NAME} 失败。"
    rm -f "$tmp"
    return 1
  fi
  return 0
}

create_service() {
  local service_dir="${SERVICE_FILE%/*}"
  [ "$service_dir" = "$SERVICE_FILE" ] && service_dir="."
  mkdir -p "$service_dir" || return 1
  if ! cat >"$SERVICE_FILE" <<SERVICE
[Unit]
Description=OpenList server
Wants=network.target
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_PATH
ExecStart=$INSTALL_PATH/$BINARY_NAME server
Restart=on-failure
RestartSec=5s
KillMode=process

[Install]
WantedBy=multi-user.target
SERVICE
  then
    error "写入 systemd 服务文件失败。"
    return 1
  fi
  systemctl daemon-reload || return 1
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  return 0
}

install_openlist() {
  require_root || exit 1
  require_systemd || exit 1
  require_commands curl tar awk head od find grep sed mktemp tr cat cp mv chmod mkdir rm id uname || exit 1
  if [ -n "$CHECKSUM" ] || [ -n "$CHECKSUM_URL" ]; then
    require_checksum_tool || exit 1
  fi

  if [ -f "$INSTALL_PATH/$BINARY_NAME" ]; then
    error "$INSTALL_PATH 已安装 OpenList，如需更新请执行: bash $0 update"
    exit 1
  fi

  local tmpdir binary admin_output admin_user admin_password local_ip public_ip
  detect_arch || exit 1
  resolve_url "$DETECTED_ARCH" || exit 1
  tmpdir="$(mktemp -d /tmp/openlist.XXXXXX)" || exit 1
  if ! prepare_binary "$RESOLVED_URL" "$tmpdir"; then
    rm -rf "$tmpdir"
    exit 1
  fi
  binary="$PREPARED_BINARY"
  if ! mkdir -p "$INSTALL_PATH"; then
    error "无法创建安装目录: $INSTALL_PATH"
    rm -rf "$tmpdir"
    exit 1
  fi
  if ! install_binary "$binary"; then
    rm -rf "$tmpdir"
    exit 1
  fi
  rm -rf "$tmpdir"
  create_service || exit 1

  admin_output="$(cd "$INSTALL_PATH" && ./$BINARY_NAME admin random 2>&1 || true)"
  admin_user="$(printf '%s\n' "$admin_output" | sed -n 's/^username:[[:space:]]*//p')"
  admin_password="$(printf '%s\n' "$admin_output" | sed -n 's/^password:[[:space:]]*//p')"
  if ! systemctl restart "$SERVICE_NAME"; then
    error "服务启动失败，请检查: systemctl status $SERVICE_NAME"
    exit 1
  fi

  local_ip=""
  if command -v ip >/dev/null 2>&1; then
    local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  fi
  public_ip="$(curl -fsS4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo 获取失败)"

  info "OpenList 安装成功！"
  echo "  局域网地址: http://${local_ip:-127.0.0.1}:5244/"
  echo "  公网地址:   http://${public_ip}:5244/"
  echo "  安装目录:   $INSTALL_PATH"
  echo "  配置文件:   $INSTALL_PATH/data/config.json"
  echo "  下载地址:   $RESOLVED_URL"
  if [ -n "$admin_user" ] && [ -n "$admin_password" ]; then
    echo "  管理账号:   $admin_user"
    echo "  初始密码:   $admin_password"
  else
    warn "未能自动读取初始密码，可运行: $INSTALL_PATH/$BINARY_NAME admin random"
  fi
  return 0
}

update_openlist() {
  require_root || exit 1
  require_systemd || exit 1
  require_commands curl tar awk head od find grep sed mktemp tr cat cp mv chmod mkdir rm id uname || exit 1
  if [ -n "$CHECKSUM" ] || [ -n "$CHECKSUM_URL" ]; then
    require_checksum_tool || exit 1
  fi

  find_installed_path || {
    error "未找到已安装的 OpenList。"
    exit 1
  }
  INSTALL_PATH="$FOUND_INSTALL_PATH"

  local tmpdir binary backup
  detect_arch || exit 1
  resolve_url "$DETECTED_ARCH" || exit 1
  tmpdir="$(mktemp -d /tmp/openlist.XXXXXX)" || exit 1
  # 先完成下载、校验与解压，全部成功后再停服务，避免下载失败导致服务中断。
  if ! prepare_binary "$RESOLVED_URL" "$tmpdir"; then
    rm -rf "$tmpdir"
    exit 1
  fi
  binary="$PREPARED_BINARY"

  systemctl stop "$SERVICE_NAME" || true
  backup="$(mktemp /tmp/openlist.XXXXXX.bak)" || {
    systemctl start "$SERVICE_NAME" || true
    rm -rf "$tmpdir"
    exit 1
  }
  if ! cp -p "$INSTALL_PATH/$BINARY_NAME" "$backup"; then
    error "备份当前程序失败。"
    systemctl start "$SERVICE_NAME" || true
    rm -f "$backup"
    rm -rf "$tmpdir"
    exit 1
  fi
  if ! install_binary "$binary"; then
    mv -f "$backup" "$INSTALL_PATH/$BINARY_NAME" || true
    systemctl start "$SERVICE_NAME" || true
    rm -rf "$tmpdir"
    exit 1
  fi
  if ! systemctl restart "$SERVICE_NAME"; then
    error "服务启动失败，正在恢复原程序。"
    mv -f "$backup" "$INSTALL_PATH/$BINARY_NAME" || true
    systemctl start "$SERVICE_NAME" || true
    rm -rf "$tmpdir"
    exit 1
  fi
  rm -f "$backup"
  rm -rf "$tmpdir"
  info "OpenList 更新完成。"
  info "下载地址: $RESOLVED_URL"
  return 0
}

show_download_source() {
  detect_arch || return 1
  resolve_url "$DETECTED_ARCH" || return 1
  info "当前架构: $DETECTED_ARCH"
  info "下载地址: $RESOLVED_URL"
  printf '%s\n' "$RESOLVED_URL"
  if [ -n "$CHECKSUM" ] || [ -n "$CHECKSUM_URL" ] ||
    { [ "$RESOLVED_BUNDLE" = "1" ] && [ -n "$BUNDLE_CHECKSUM" ]; }; then
    if require_checksum_tool >/dev/null 2>&1; then
      info "SHA-256 校验: 已启用"
    else
      warn "SHA-256 校验: 已设置但本机缺少校验命令"
    fi
  else
    warn "SHA-256 校验: 未设置"
  fi
  return 0
}

uninstall_openlist() {
  require_root || exit 1
  require_systemd || exit 1
  find_installed_path || {
    error "未找到已安装的 OpenList。"
    exit 1
  }
  INSTALL_PATH="$FOUND_INSTALL_PATH"
  read -r -p "卸载将删除程序和 $INSTALL_PATH/data 数据，是否继续？[y/N]: " choice
  case "${choice:-n}" in
    y|Y)
      systemctl stop "$SERVICE_NAME" || true
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
      rm -rf "$INSTALL_PATH"
      rm -f "$SERVICE_FILE"
      systemctl daemon-reload
      info "OpenList 已卸载。"
      ;;
    *)
      info "已取消卸载。"
      ;;
  esac
  return 0
}

service_action() {
  require_root || exit 1
  require_systemd || exit 1
  find_installed_path || {
    error "未找到已安装的 OpenList。"
    exit 1
  }
  systemctl "$1" "$SERVICE_NAME"
}

reset_password() {
  require_root || exit 1
  find_installed_path || {
    error "未找到已安装的 OpenList。"
    exit 1
  }
  INSTALL_PATH="$FOUND_INSTALL_PATH"
  echo "1、生成随机密码"
  echo "2、设置新密码"
  read -r -p "请选择 [1-2]: " choice
  case "$choice" in
    1) (cd "$INSTALL_PATH" && ./$BINARY_NAME admin random) ;;
    2)
      read -r -p "请输入新密码: " password
      if [ -z "$password" ]; then
        error "密码不能为空。"
        exit 1
      fi
      (cd "$INSTALL_PATH" && ./$BINARY_NAME admin set "$password")
      ;;
    *) error "无效选择。" && exit 1 ;;
  esac
  return 0
}

show_menu() {
  command -v clear >/dev/null 2>&1 && clear
  echo "欢迎使用 OpenList 管理脚本"
  echo
  echo "1、安装 OpenList"
  echo "2、更新 OpenList"
  echo "3、卸载 OpenList"
  echo "4、查看状态"
  echo "5、重置密码"
  echo "6、启动 OpenList"
  echo "7、停止 OpenList"
  echo "8、重启 OpenList"
  echo "9、查看当前下载地址"
  echo "0、退出脚本"
  echo
  read -r -p "请输入选项 [0-9]: " choice
  case "$choice" in
    1) install_openlist ;;
    2) update_openlist ;;
    3) uninstall_openlist ;;
    4) service_action status ;;
    5) reset_password ;;
    6) service_action start ;;
    7) service_action stop ;;
    8) service_action restart ;;
    9) show_download_source ;;
    0) exit 0 ;;
    *) error "无效选项。" ;;
  esac
}

main() {
  if [ "$#" -eq 0 ]; then
    show_menu
  elif [ "$1" = "install" ]; then
    if [ "$#" -ge 2 ]; then
      INSTALL_PATH="${2%/}"
    fi
    install_openlist
  elif [ "$1" = "update" ]; then
    update_openlist
  elif [ "$1" = "download-url" ] || [ "$1" = "source" ]; then
    show_download_source
  elif [ "$1" = "uninstall" ]; then
    uninstall_openlist
  elif [ "$1" = "start" ] || [ "$1" = "stop" ] || [ "$1" = "restart" ] || [ "$1" = "status" ]; then
    service_action "$1"
  elif [ "$1" = "password" ]; then
    reset_password
  elif [ "$1" = "help" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
  else
    usage
    exit 1
  fi
}

if [ "${OPENLIST_V3_LIB_ONLY:-0}" != "1" ]; then
  main "$@"
fi
