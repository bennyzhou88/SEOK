#!/usr/bin/env bash
# =============================================================================
# SoftEther VPN Server 5.2 一键安装脚本 (源码编译)
#
#   * 自动获取 SoftEtherVPN/SoftEtherVPN 最新 5.x 版本 (目前 5.2.5189)
#   * 支持 x86_64 (AMD/Intel) 与 aarch64 (ARM64)
#   * 支持 Debian/Ubuntu、RHEL/CentOS/Rocky/Alma/Fedora、openSUSE、Arch
#   * 安装 systemd 服务并设置开机自启, 异常退出自动重启
#   * 彻底关闭日志 (防止磁盘被日志撑爆):
#       1. 所有虚拟 HUB 的 security / packet 日志全部 LogDisable
#       2. 日志目录挂载为容量受限的 tmpfs (仅存在于内存, 上限 16MB, 重启即清空)
#          —— 即使以后新建 HUB 默认开启日志, 也绝不可能写满硬盘
#          (server_log 服务器日志在 SoftEther 中无法通过配置关闭, 靠此方式兜底)
#   * 可从旧版 (4.x, /opt/vpnserver, /opt/softether, /usr/local/vpnserver)
#     自动迁移配置, 并清理旧版遗留的巨量日志
#
# 用法:
#   bash install-softether5.sh                 # 交互安装/升级
#   bash install-softether5.sh -y              # 免确认
#   bash install-softether5.sh -v 5.2.5189     # 指定版本 (默认自动取最新)
#   bash install-softether5.sh --uninstall     # 卸载 (保留配置备份)
#
# 环境变量:
#   SE_ADMIN_PASSWORD   已设置服务器管理密码时, 用于关闭日志 (全新安装无需设置)
#   OPEN_FIREWALL=0     不自动放行防火墙端口 (默认: 仅在 ufw/firewalld 已启用时放行)
# =============================================================================
set -Eeuo pipefail

REPO_URL="https://github.com/SoftEtherVPN/SoftEtherVPN.git"
INSTALL_DIR="/opt/softether"          # 程序目录 (bin/ lib/ libexec/)
DB_DIR="/var/lib/softether"           # 配置文件目录 (vpn_server.config)
LOG_DIR="/var/log/softether"          # 日志目录, 运行时挂载为 tmpfs
LOG_TMPFS_SIZE="16m"
SERVICE_NAME="softether-vpnserver"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HELPER_BIN="/usr/local/bin/softether-nolog"
BACKUP_ROOT="/root/softether-backup"
OLD_DIRS=("/opt/vpnserver" "/usr/local/vpnserver")   # 旧版 4.x 常用目录 (仅迁移配置/清理日志)
OPEN_FIREWALL="${OPEN_FIREWALL:-auto}"

ASSUME_YES=0
WANT_VERSION=""
DO_UNINSTALL=0
WORKDIR=""

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
info()   { printf '\033[0;36m[*]\033[0m %s\n' "$*"; }
die()    { red "错误: $*" >&2; exit 1; }

cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; return 0; }
trap cleanup EXIT
trap 'red "脚本在第 $LINENO 行失败 (命令: $BASH_COMMAND)"' ERR

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ----------------------------------------------------------------- 参数解析 --
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    -v|--version) WANT_VERSION="${2:-}"; [[ -n "$WANT_VERSION" ]] || die "-v 需要版本号参数"; shift ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -h|--help) usage ;;
    *) die "未知参数: $1 (使用 -h 查看帮助)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ans
  read -r -p "$1 [y/N] " ans </dev/tty || return 1
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }
has_systemd() { [[ -d /run/systemd/system ]] && have systemctl; }

# --------------------------------------------------------------- 环境检测 ----
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="x86_64 (AMD/Intel)" ;;
    aarch64|arm64) ARCH="aarch64 (ARM64)" ;;
    armv7l|armv8l) ARCH="armv7 (32位 ARM)"; yellow "警告: 32 位 ARM 未经充分测试, 继续尝试编译。" ;;
    i?86)          ARCH="x86 (32位)";       yellow "警告: 32 位 x86 未经充分测试, 继续尝试编译。" ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

detect_pm() {
  if   have apt-get; then PM=apt
  elif have dnf;     then PM=dnf
  elif have yum;     then PM=yum
  elif have zypper;  then PM=zypper
  elif have pacman;  then PM=pacman
  elif have apk;     then die "Alpine (musl) 暂不支持, 请使用官方 Docker 镜像 softethervpn/vpnserver"
  else die "未识别的包管理器, 仅支持 apt / dnf / yum / zypper / pacman"; fi
}

install_deps() {
  info "安装编译依赖 (包管理器: $PM) ..."
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
      apt-get update -y
      apt-get install -y build-essential cmake pkg-config git ca-certificates curl \
        libssl-dev libsodium-dev libreadline-dev zlib1g-dev iproute2 \
        || die "依赖安装失败"
      apt-get install -y libncurses-dev || apt-get install -y libncurses5-dev
      ;;
    dnf|yum)
      "$PM" install -y gcc gcc-c++ make cmake git ca-certificates curl pkgconf-pkg-config \
        openssl-devel ncurses-devel readline-devel zlib-devel iproute || die "依赖安装失败"
      if ! "$PM" install -y libsodium-devel; then
        yellow "libsodium-devel 不在默认源, 尝试启用 EPEL/CRB ..."
        "$PM" install -y epel-release || true
        have dnf && dnf config-manager --set-enabled crb 2>/dev/null || true
        have dnf && dnf config-manager --set-enabled powertools 2>/dev/null || true
        "$PM" install -y libsodium-devel || die "无法安装 libsodium-devel"
      fi
      ;;
    zypper)
      zypper --non-interactive install -y gcc gcc-c++ make cmake git ca-certificates curl pkg-config \
        libopenssl-devel ncurses-devel readline-devel zlib-devel libsodium-devel iproute2 \
        || die "依赖安装失败"
      ;;
    pacman)
      pacman -Sy --noconfirm --needed base-devel cmake git ca-certificates curl pkgconf \
        openssl ncurses readline zlib libsodium iproute2 || die "依赖安装失败"
      ;;
  esac

  # SoftEther 5.x 需要 CMake >= 3.15
  local cv; cv="$(cmake --version | awk 'NR==1{print $3}')"
  if [[ "$(printf '%s\n3.15\n' "$cv" | sort -V | head -n1)" != "3.15" ]]; then
    die "CMake 版本过低 ($cv < 3.15), 请使用更新的系统 (Ubuntu 20.04+/Debian 10+/EL8+) 或手动安装新版 CMake"
  fi
}

# 编译并行度: 兼顾小内存 VPS (liboqs/OpenSSL 编译较吃内存), 每任务约 1GB
calc_jobs() {
  local cpus mem_mb jobs
  cpus="$(nproc 2>/dev/null || echo 1)"
  mem_mb="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
  jobs=$(( mem_mb / 1024 )); (( jobs < 1 )) && jobs=1; (( jobs > cpus )) && jobs=$cpus
  echo "$jobs"
  if (( mem_mb < 900 )); then
    yellow "可用内存仅 ${mem_mb}MB, 编译可能失败, 建议先添加 swap (fallocate -l 2G /swapfile && mkswap /swapfile && swapon /swapfile)" >&2
  fi
}

# --------------------------------------------------------------- 版本选择 ----
resolve_version() {
  if [[ -n "$WANT_VERSION" ]]; then VERSION="$WANT_VERSION"; return; fi
  info "查询 SoftEtherVPN 最新版本 ..."
  # 标签形如 5.02.5187 / 5.2.5188 / 5.2.5189, 按 build 号 (最后一段) 取最大
  VERSION="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null \
    | awk '{sub("refs/tags/","",$2); print $2}' \
    | grep -E '^5\.0?2\.[0-9]+$' \
    | awk -F. '{print $3" "$0}' | sort -n | tail -n1 | awk '{print $2}')" || true
  [[ -n "$VERSION" ]] || die "无法获取最新版本, 请检查能否访问 github.com, 或用 -v 指定版本 (例: -v 5.2.5189)"
}

# ----------------------------------------------------------- 旧版本处理 ------
stop_old_services() {
  has_systemd || return 0
  local s
  for s in "$SERVICE_NAME" vpnserver softether-vpnserver; do
    if systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "^${s}.service"; then
      systemctl stop "$s" 2>/dev/null || true
      systemctl disable "$s" 2>/dev/null || true
    fi
  done
  # 旧脚本/官方教程创建的单元文件 (与新单元名不同的才删除)
  rm -f /etc/systemd/system/vpnserver.service /lib/systemd/system/vpnserver.service
  systemctl daemon-reload 2>/dev/null || true
}

# 找到现有配置文件并备份; 设置全局 OLD_CONFIG
backup_and_migrate_config() {
  OLD_CONFIG=""
  local d
  for d in "$DB_DIR" "$INSTALL_DIR" "${OLD_DIRS[@]}"; do   # INSTALL_DIR 为旧脚本布局
    if [[ -f "$d/vpn_server.config" ]]; then
      OLD_CONFIG="$d/vpn_server.config"
      local bk; bk="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$bk"
      cp -a "$d/vpn_server.config" "$bk/"
      [[ -d "$d/backup.vpn_server.config" ]] && cp -a "$d/backup.vpn_server.config" "$bk/"
      green "已备份现有配置: $bk (来自 $d)"
      break
    fi
  done
}

# 清理旧版遗留的大量日志 (这正是撑爆磁盘的元凶)
purge_old_logs() {
  local d freed=0 sz
  for d in "$INSTALL_DIR" "$DB_DIR" "${OLD_DIRS[@]}" "$LOG_DIR"; do
    [[ -d "$d" ]] || continue
    for sub in server_log security_log packet_log debug_log secure_nat_log; do
      if [[ -d "$d/$sub" && ! -L "$d/$sub" ]] && ! mountpoint -q "$d/$sub" 2>/dev/null; then
        sz="$(du -sm "$d/$sub" 2>/dev/null | awk '{print $1}')"; freed=$(( freed + ${sz:-0} ))
        rm -rf "${d:?}/$sub"
      fi
    done
  done
  (( freed > 0 )) && green "已清理旧日志, 释放约 ${freed} MB 磁盘空间"
  return 0
}

# --------------------------------------------------------------- 编译安装 ----
build_and_install() {
  WORKDIR="$(mktemp -d /var/tmp/softether-build.XXXXXX)"
  info "下载 SoftEtherVPN $VERSION 源码 (含子模块) ..."
  git clone --depth 1 --branch "$VERSION" --recurse-submodules --shallow-submodules \
    "$REPO_URL" "$WORKDIR/src" || die "下载源码失败 (版本号 $VERSION 是否存在?)"

  local jobs; jobs="$(calc_jobs)"
  local fail_log="/var/tmp/softether-build-fail.log"
  info "配置 (CMake) ..."
  cmake -S "$WORKDIR/src" -B "$WORKDIR/src/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DSE_DBDIR="$DB_DIR" \
    -DSE_LOGDIR="$LOG_DIR" >"$WORKDIR/cmake.log" 2>&1 \
    || { cp "$WORKDIR/cmake.log" "$fail_log"; tail -n 30 "$fail_log"; die "CMake 配置失败 (完整日志: $fail_log)"; }

  info "编译中 (并行 $jobs 个任务, 视机器性能需数分钟) ..."
  cmake --build "$WORKDIR/src/build" -j"$jobs" >"$WORKDIR/make.log" 2>&1 \
    || { cp "$WORKDIR/make.log" "$fail_log"; tail -n 40 "$fail_log"; die "编译失败 (完整日志: $fail_log)"; }

  info "安装到 $INSTALL_DIR ..."
  # 旧脚本 (4.x) 把文件直接放在 /opt/softether 顶层, 配置已备份, 清掉旧布局
  if [[ -f "$INSTALL_DIR/vpnserver" || -f "$INSTALL_DIR/vpn_server.config" ]]; then
    rm -rf "$INSTALL_DIR"
  fi
  cmake --install "$WORKDIR/src/build" >"$WORKDIR/install.log" 2>&1 \
    || { tail -n 20 "$WORKDIR/install.log"; die "安装失败"; }
  [[ -x "$INSTALL_DIR/libexec/softether/vpnserver/vpnserver" && -x "$INSTALL_DIR/libexec/softether/vpncmd/vpncmd" ]] \
    || die "安装后未找到 vpnserver / vpncmd"
  rm -rf "$INSTALL_DIR/include" "$INSTALL_DIR/lib/cmake" "$INSTALL_DIR/lib/pkgconfig" "$INSTALL_DIR"/lib/*.a
  # 不安装 bridge / client, 减少体积
  rm -rf "$INSTALL_DIR/libexec/softether/vpnbridge" "$INSTALL_DIR/libexec/softether/vpnclient" \
         "$INSTALL_DIR/bin/vpnbridge" "$INSTALL_DIR/bin/vpnclient"
  ln -sf "$INSTALL_DIR/bin/vpncmd" /usr/local/bin/vpncmd

  mkdir -p "$DB_DIR"; chmod 700 "$DB_DIR"
  # 迁移旧配置 (4.x -> 5.x 配置向前兼容)
  if [[ -n "${OLD_CONFIG:-}" && "$OLD_CONFIG" != "$DB_DIR/vpn_server.config" ]]; then
    cp -a "$OLD_CONFIG" "$DB_DIR/vpn_server.config"
    local ob; ob="$(dirname "$OLD_CONFIG")/backup.vpn_server.config"
    [[ -d "$ob" ]] && cp -a "$ob" "$DB_DIR/"
    green "已迁移旧配置到 $DB_DIR/vpn_server.config"
  fi
}

# ------------------------------------------------------------ systemd 服务 ---
install_service() {
  has_systemd || { yellow "未检测到 systemd, 跳过服务安装。手动前台运行: cd $DB_DIR && $INSTALL_DIR/bin/vpnserver execsvc (注意先自行把 $LOG_DIR 挂载为 tmpfs)"; return 0; }
  info "创建 systemd 服务并设置开机自启 ..."
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=SoftEther VPN Server 5 (logging disabled)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DB_DIR
# 日志目录 -> 内存 tmpfs, 容量封顶, 永远写不满硬盘
ExecStartPre=/bin/sh -c 'mkdir -p $LOG_DIR; mountpoint -q $LOG_DIR || mount -t tmpfs -o size=$LOG_TMPFS_SIZE,mode=0700,nosuid,nodev,noexec tmpfs $LOG_DIR'
ExecStartPre=-/bin/sh -c 'modprobe tun 2>/dev/null; true'
ExecStart=$INSTALL_DIR/libexec/softether/vpnserver/vpnserver execsvc
ExecStopPost=-/bin/sh -c 'umount $LOG_DIR 2>/dev/null; true'
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
# 不把标准输出/错误写入 journal
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  sleep 3
  systemctl is-active --quiet "$SERVICE_NAME" \
    || die "服务启动失败, 请执行: systemctl status $SERVICE_NAME"
  green "服务已启动并设置为开机自启: $SERVICE_NAME"
}

# ------------------------------------------------------- 关闭所有 HUB 日志 ---
install_nolog_helper() {
  cat >"$HELPER_BIN" <<EOF
#!/usr/bin/env bash
# 关闭 SoftEther 所有虚拟 HUB 的 security / packet 日志 (新建 HUB 后可再次运行)
# 已设置管理密码时: SE_ADMIN_PASSWORD=xxx softether-nolog
set -u
VPNCMD="$INSTALL_DIR/bin/vpncmd"
PW="\${SE_ADMIN_PASSWORD:-}"
run() { "\$VPNCMD" localhost:5555 /SERVER /PASSWORD:"\$PW" "\$@" 2>&1; }

hubs="\$(run /CSV /CMD HubList | tr -d '\r' | awk -F, 'NR>1 && \$1!="" {print \$1}')"
if [[ -z "\$hubs" ]]; then
  echo "未获取到 HUB 列表 (服务未运行或管理密码不正确?)" >&2; exit 1
fi
while IFS= read -r h; do
  for t in security packet; do
    if run /ADMINHUB:"\$h" /CMD LogDisable "\$t" | grep -q "completed successfully"; then
      echo "HUB \$h: \$t 日志已关闭"
    else
      echo "HUB \$h: \$t 日志关闭失败" >&2
    fi
  done
done <<<"\$hubs"
EOF
  chmod 755 "$HELPER_BIN"
}

disable_logs() {
  info "关闭所有虚拟 HUB 的日志 ..."
  local i
  for i in $(seq 1 20); do          # 等待服务就绪
    "$INSTALL_DIR/bin/vpncmd" localhost:5555 /SERVER /PASSWORD:"${SE_ADMIN_PASSWORD:-}" \
      /CMD ServerInfoGet >/dev/null 2>&1 && break
    sleep 1
  done
  if SE_ADMIN_PASSWORD="${SE_ADMIN_PASSWORD:-}" "$HELPER_BIN"; then
    green "所有 HUB 日志已关闭"
  else
    yellow "自动关闭 HUB 日志失败 (可能已设置管理密码)。请执行: SE_ADMIN_PASSWORD='你的密码' softether-nolog"
  fi
}

# ------------------------------------------------------------ 系统/防火墙 ----
tune_system() {
  info "开启 IPv4 转发 (持久化) ..."
  echo "net.ipv4.ip_forward = 1" >/etc/sysctl.d/99-softether.conf
  sysctl -q -p /etc/sysctl.d/99-softether.conf >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
}

open_firewall() {
  [[ "$OPEN_FIREWALL" == "0" ]] && return 0
  local tcp=(443 992 1194 5555) udp=(500 1701 4500 1194) p
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "放行 ufw 端口 ..."
    for p in "${tcp[@]}"; do ufw allow "$p"/tcp >/dev/null; done
    for p in "${udp[@]}"; do ufw allow "$p"/udp >/dev/null; done
  elif have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    info "放行 firewalld 端口 ..."
    for p in "${tcp[@]}"; do firewall-cmd --permanent --add-port="$p"/tcp >/dev/null; done
    for p in "${udp[@]}"; do firewall-cmd --permanent --add-port="$p"/udp >/dev/null; done
    firewall-cmd --reload >/dev/null
  else
    yellow "未检测到已启用的 ufw/firewalld, 未修改防火墙。云服务器请在安全组放行: TCP 443/992/1194/5555, UDP 500/1701/4500/1194"
  fi
}

# ------------------------------------------------------------------- 卸载 ----
do_uninstall() {
  confirm "确定卸载 SoftEther VPN Server? (配置会先备份到 $BACKUP_ROOT)" || exit 0
  backup_and_migrate_config
  stop_old_services
  rm -f "$SERVICE_FILE" "$HELPER_BIN" /usr/local/bin/vpncmd /etc/sysctl.d/99-softether.conf
  mountpoint -q "$LOG_DIR" 2>/dev/null && umount "$LOG_DIR" || true
  rm -rf "$INSTALL_DIR" "$LOG_DIR" "$DB_DIR"
  has_systemd && systemctl daemon-reload || true
  green "卸载完成。配置备份位于 $BACKUP_ROOT"
  exit 0
}

# ------------------------------------------------------------------- 主流程 --
main() {
  [[ $DO_UNINSTALL -eq 1 ]] && do_uninstall
  detect_arch
  detect_pm
  resolve_version

  echo
  green "SoftEther VPN Server $VERSION  |  架构: $ARCH  |  系统: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  echo "  将从源码编译并安装到 $INSTALL_DIR, 全部日志关闭。已有配置会先备份并保留。"
  confirm "是否继续?" || { echo "已取消"; exit 0; }

  install_deps
  backup_and_migrate_config
  stop_old_services
  purge_old_logs
  build_and_install
  tune_system
  install_nolog_helper
  install_service
  has_systemd && disable_logs || true
  open_firewall

  echo
  green "================ 安装完成 ================"
  echo "版本     : SoftEther VPN Server $VERSION"
  echo "程序目录 : $INSTALL_DIR"
  echo "配置文件 : $DB_DIR/vpn_server.config"
  echo "服务管理 : systemctl {status|restart|stop} $SERVICE_NAME  (已开机自启)"
  echo "命令行管理: vpncmd   (或用 Windows 版 SoftEther VPN Server Manager 连接 5555 端口)"
  echo "日志     : 已关闭; 日志目录 $LOG_DIR 为 ${LOG_TMPFS_SIZE} 内存盘, 不占硬盘"
  echo "新建 HUB 后: 运行 softether-nolog 再次关闭其日志"
  yellow "重要: 请立即设置管理员密码 (vpncmd -> ServerPasswordSet), 默认密码为空!"
  [[ -n "${OLD_CONFIG:-}" ]] && echo "旧配置备份: $BACKUP_ROOT"
}

main
