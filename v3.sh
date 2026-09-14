#!/usr/bin/env bash
# OpenList one-click installer for Linux systemd servers.
# Based on the layout of the official Alist v3.sh script.

set -u

APP_NAME="OpenList"
BINARY_NAME="openlist"
SERVICE_NAME="openlist"
GH_REPO="v200dd/OpenList"
RELEASE_TAG="${OPENLIST_RELEASE_TAG:-beta}"
GH_PROXY="${OPENLIST_GH_PROXY:-}"
DEFAULT_INSTALL_PATH="/opt/openlist"
INSTALL_PATH="$DEFAULT_INSTALL_PATH"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

info() { printf "%b\n" "${GREEN}${1}${RESET}"; }
warn() { printf "%b\n" "${YELLOW}${1}${RESET}"; }
error() { printf "%b\n" "${RED}${1}${RESET}" >&2; }

usage() {
  cat <<USAGE
$APP_NAME 管理脚本

用法:
  bash $0 install [路径]    安装，默认路径: $DEFAULT_INSTALL_PATH
  bash $0 update            更新
  bash $0 uninstall         卸载
  bash $0 start             启动服务
  bash $0 stop              停止服务
  bash $0 restart           重启服务
  bash $0 status            查看服务状态
  bash $0 password          重置管理员密码
  bash $0                   显示交互菜单

环境变量:
  OPENLIST_RELEASE_TAG      GitHub Release 标签，默认: beta
  OPENLIST_GH_PROXY         GitHub 代理前缀，必须以 / 结尾
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "未找到 $1 命令，请先安装。"
    exit 1
  fi
}

require_root() {
  if [ "$(id -u)" != "0" ]; then
    error "请使用 root 权限运行此命令。"
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    error "未找到 systemctl，此脚本仅支持 systemd Linux。"
    exit 1
  fi
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      error "不支持的平台: $machine。此脚本目前支持 x86_64 和 arm64。"
      exit 1
      ;;
  esac
}

installed_path() {
  local path=""
  if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    path="$(grep '^WorkingDirectory=' "/etc/systemd/system/${SERVICE_NAME}.service" | cut -d= -f2)"
  fi
  if [ -n "$path" ] && [ -f "$path/$BINARY_NAME" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [ -f "$DEFAULT_INSTALL_PATH/$BINARY_NAME" ]; then
    printf '%s\n' "$DEFAULT_INSTALL_PATH"
    return 0
  fi
  return 1
}

download_url() {
  local arch="$1"
  local url="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/openlist-linux-musl-${arch}.tar.gz"
  if [ -n "$GH_PROXY" ]; then
    case "$GH_PROXY" in
      https://*/) url="${GH_PROXY}${url}" ;;
      *) error "OPENLIST_GH_PROXY 必须以 https:// 开头并以 / 结尾。"; exit 1 ;;
    esac
  fi
  printf '%s\n' "$url"
}

download_file() {
  local url="$1"
  local output="$2"
  info "下载地址: $url"
  if ! curl -fL --connect-timeout 10 --retry 3 --retry-delay 3 "$url" -o "$output"; then
    error "下载失败。"
    return 1
  fi
  if [ ! -s "$output" ] || [ "$(head -c 2 "$output" | od -An -t x1 | tr -d ' \n')" != "1f8b" ]; then
    error "下载内容不是有效的 gzip 文件。"
    rm -f "$output"
    return 1
  fi
}

create_service() {
  cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE
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
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

install_openlist() {
  require_root
  require_systemd
  require_command curl
  require_command tar

  if [ -f "$INSTALL_PATH/$BINARY_NAME" ]; then
    error "$INSTALL_PATH 已安装 OpenList，如需更新请执行: bash $0 update"
    exit 1
  fi

  local arch archive extract_dir url
  arch="$(detect_arch)"
  archive="$(mktemp /tmp/openlist.XXXXXX.tar.gz)"
  extract_dir="$(mktemp -d /tmp/openlist.XXXXXX)"
  url="$(download_url "$arch")"

  if ! download_file "$url" "$archive"; then
    rm -f "$archive"
    rm -rf "$extract_dir"
    exit 1
  fi

  if ! tar -xzf "$archive" -C "$extract_dir"; then
    error "解压失败。"
    rm -f "$archive"
    rm -rf "$extract_dir"
    exit 1
  fi
  rm -f "$archive"

  if [ ! -f "$extract_dir/$BINARY_NAME" ]; then
    error "安装包中没有找到 $BINARY_NAME。"
    rm -rf "$extract_dir"
    exit 1
  fi

  mkdir -p "$INSTALL_PATH" || {
    error "无法创建安装目录: $INSTALL_PATH"
    rm -rf "$extract_dir"
    exit 1
  }
  mv "$extract_dir/$BINARY_NAME" "$INSTALL_PATH/$BINARY_NAME"
  rm -rf "$extract_dir"
  chmod 755 "$INSTALL_PATH/$BINARY_NAME"

  create_service

  local admin_output admin_user admin_password local_ip public_ip
  admin_output="$(cd "$INSTALL_PATH" && ./$BINARY_NAME admin random 2>&1 || true)"
  admin_user="$(printf '%s\n' "$admin_output" | sed -n 's/^username:[[:space:]]*//p')"
  admin_password="$(printf '%s\n' "$admin_output" | sed -n 's/^password:[[:space:]]*//p')"

  systemctl restart "$SERVICE_NAME"
  local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  public_ip="$(curl -fsS4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo 获取失败)"

  info "OpenList 安装成功！"
  echo "  局域网地址: http://${local_ip:-127.0.0.1}:5244/"
  echo "  公网地址:   http://${public_ip}:5244/"
  echo "  安装目录:   $INSTALL_PATH"
  echo "  配置文件:   $INSTALL_PATH/data/config.json"
  if [ -n "$admin_user" ] && [ -n "$admin_password" ]; then
    echo "  管理账号:   $admin_user"
    echo "  初始密码:   $admin_password"
  else
    warn "未能自动读取初始密码，可运行: $INSTALL_PATH/$BINARY_NAME admin random"
  fi
}

update_openlist() {
  require_root
  require_systemd
  require_command curl
  require_command tar

  INSTALL_PATH="$(installed_path)" || {
    error "未找到已安装的 OpenList。"
    exit 1
  }

  local arch archive url backup
  arch="$(detect_arch)"
  archive="$(mktemp /tmp/openlist.XXXXXX.tar.gz)"
  backup="$(mktemp /tmp/openlist.XXXXXX.bak)"
  url="$(download_url "$arch")"

  systemctl stop "$SERVICE_NAME"
  cp "$INSTALL_PATH/$BINARY_NAME" "$backup" || {
    error "备份当前程序失败。"
    systemctl start "$SERVICE_NAME"
    exit 1
  }

  if ! download_file "$url" "$archive"; then
    mv "$backup" "$INSTALL_PATH/$BINARY_NAME"
    systemctl start "$SERVICE_NAME"
    exit 1
  fi

  if ! tar -xzf "$archive" -C "$INSTALL_PATH"; then
    mv "$backup" "$INSTALL_PATH/$BINARY_NAME"
    systemctl start "$SERVICE_NAME"
    rm -f "$archive"
    exit 1
  fi
  rm -f "$archive" "$backup"
  chmod 755 "$INSTALL_PATH/$BINARY_NAME"

  systemctl restart "$SERVICE_NAME"
  info "OpenList 更新完成。"
}

uninstall_openlist() {
  require_root
  require_systemd

  INSTALL_PATH="$(installed_path)" || {
    error "未找到已安装的 OpenList。"
    exit 1
  }

  read -r -p "卸载将删除程序和 $INSTALL_PATH/data 数据，是否继续？[y/N]: " choice
  case "${choice:-n}" in
    y|Y)
      systemctl stop "$SERVICE_NAME" || true
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
      rm -rf "$INSTALL_PATH"
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload
      info "OpenList 已卸载。"
      ;;
    *)
      info "已取消卸载。"
      ;;
  esac
}

service_action() {
  require_root
  require_systemd
  INSTALL_PATH="$(installed_path)" || {
    error "未找到已安装的 OpenList。"
    exit 1
  }
  systemctl "$1" "$SERVICE_NAME"
}

reset_password() {
  require_root
  INSTALL_PATH="$(installed_path)" || {
    error "未找到已安装的 OpenList。"
    exit 1
  }

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
}

show_menu() {
  clear
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
  echo "0、退出脚本"
  echo
  read -r -p "请输入选项 [0-8]: " choice
  case "$choice" in
    1)
      INSTALL_PATH="$DEFAULT_INSTALL_PATH"
      install_openlist
      ;;
    2) update_openlist ;;
    3) uninstall_openlist ;;
    4) service_action status ;;
    5) reset_password ;;
    6) service_action start ;;
    7) service_action stop ;;
    8) service_action restart ;;
    0) exit 0 ;;
    *) error "无效选项。" ;;
  esac
}

if [ "$#" -eq 0 ]; then
  show_menu
elif [ "$1" = "install" ]; then
  if [ "$#" -ge 2 ]; then
    INSTALL_PATH="${2%/}"
  fi
  install_openlist
elif [ "$1" = "update" ]; then
  update_openlist
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
