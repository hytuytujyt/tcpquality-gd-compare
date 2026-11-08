#!/usr/bin/env bash
# Low-volume Guangdong Telecom/Mobile IPv4 comparison with guided setup.
set -Eeuo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE="$HERE/runTcpQuality-core.sh"
DEFAULT_DATA_DIR='/root/tcpquality-gd-compare'
DATA_DIR=${TCPQUALITY_GD_DATA_DIR:-$DEFAULT_DATA_DIR}
MODE=${1:-help}
ARG=${2:-}
# The published standalone repository pins CORE_URL to an immutable commit.
CORE_SHA256='733aa259f208836fc0091649dceef126792e228d6cd6f32b3003358ddfa384ed'
CORE_URL='https://raw.githubusercontent.com/hytuytujyt/tcpquality-gd-compare/12b1b56727fc7ad8f89070f94c60087b7c25793a/runTcpQuality-core.sh'
NEXTTRACE_VERSION='1.7.6'
NEXTTRACE_BASE_URL="https://github.com/nxtrace/NTrace-core/releases/download/v$NEXTTRACE_VERSION"
TCPFIT_VERSION='0.5.9'
TCPFIT_SHA256='8331cc40950229a3280ce32406330a85b1a3d21ba398a4db3dc7e25c39783741'
TCPFIT_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/v$TCPFIT_VERSION/tcpfit.sh"
TUNE_RTT=${3:-}
CORE_PID=''
RUN_CSV_TMP=''


usage() {
  cat <<EOF
广东电信/移动低流量前后对比

用法（root）：
  $0 baseline [MiB] 自动准备依赖并设置两轮测试总预算，然后做调优前测试
                    默认 128 MiB（基线+调优后合计）；可设 32-2048 的4倍数
  $0 tune <Mbps> [RTT-ms] 只做 tcpfit 基础调优，例如：$0 tune 200 35
                            RTT 默认 150 ms（固定假设值，不自动测量）
  $0 after          调优后测试（要求已有 baseline 和 tune 记录）
  $0 compare        对比已保存的两轮报告
  $0 setup          只安装/检查依赖、NextTrace Tiny、TcpQuality core 和 tcpfit，不执行测速
  RESET=YES $0 reset 清除本比较记录（不回滚 tcpfit）

测试范围固定：广东电信/移动 IPv4 普通回程、大包回程、VPS→广东单线程下载。
不测联通、IPv6、上传、其他地区、教育网、国际互联、Apple CDN，也不上传报告。
单线程下载总预算可设 32-2048 MiB（基线+调优后两轮合计，必须为4的倍数），默认 128 MiB；四次下载均分，每次另有 10 秒超时。此载荷预算不包含工具安装、协议开销或其他并发流量。
首次 baseline 会提示后自动安装缺少的系统依赖、NextTrace Tiny、TcpQuality core 与 tcpfit。
EOF
}

fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
require_root() { [[ "$(id -u)" == 0 ]] || fail '请以 root 运行。'; }

stop_core() {
  local pid="${CORE_PID:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  CORE_PID=''
}

cleanup_wrapper() {
  stop_core
  [[ -z "${RUN_CSV_TMP:-}" ]] || rm -f -- "$RUN_CSV_TMP"
}

handle_signal() {
  local signal="$1" status="$2"
  trap - INT TERM HUP
  stop_core
  printf '[!] 收到 %s，已请求停止测试并清理本次临时文件。\n' "$signal" >&2
  exit "$status"
}

trap cleanup_wrapper EXIT
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM
trap 'handle_signal HUP 129' HUP

validate_data_dir() {
  local path="$DATA_DIR" part canonical current n home_dir
  local -a parts=() normalized=()
  [[ "$path" == /* ]] || fail 'TCPQUALITY_GD_DATA_DIR 必须是绝对路径。'
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..)
        n=${#normalized[@]}
        (( n == 0 )) || normalized=("${normalized[@]:0:n-1}")
        ;;
      *) normalized+=("$part") ;;
    esac
  done
  local IFS=/
  canonical="/${normalized[*]}"
  home_dir=${HOME%/}
  if [[ "$canonical" != "$DEFAULT_DATA_DIR" ]]; then
    [[ "$canonical" != / && "$canonical" != /root && "$canonical" != /home && "$canonical" != /tmp && "$canonical" != /usr && "$canonical" != /etc && "$canonical" != /var && "$canonical" != /opt && "$canonical" != "$home_dir" ]] || fail "拒绝使用危险数据目录：$canonical"
  fi
  current=''
  for part in "${normalized[@]}"; do
    current+="/$part"
    [[ ! -L "$current" ]] || fail "数据目录路径不能经过符号链接：$current"
  done
  DATA_DIR="$canonical"
}

traffic_bytes() {
  local rx=0 tx=0 iface="$1"
  if [[ -n "$iface" && -r "/sys/class/net/$iface/statistics/rx_bytes" ]]; then
    read -r rx < "/sys/class/net/$iface/statistics/rx_bytes" || rx=0
    read -r tx < "/sys/class/net/$iface/statistics/tx_bytes" || tx=0
  fi
  [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
  [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
  printf '%s\n' "$((rx + tx))"
}

choose_budget_mib() {
  local value="${1:-${TQ_SPEEDTEST_BUDGET_MIB:-}}"
  if [[ -z "$value" && -t 0 ]]; then
    read -r -p '基线+调优后两轮的单线程下载总预算 MiB（32-2048，4的倍数；默认 128）: ' value
  fi
  value=${value:-128}
  [[ "$value" =~ ^[0-9]+$ ]] || fail '总预算须为4的倍数 MiB 整数，范围 32-2048。'
  (( value >= 32 && value <= 2048 && value % 4 == 0 )) || fail '总预算须为4的倍数 MiB 整数，范围 32-2048。'
  printf '%s\n' "$value"
}

compare_reports() {
  local before="$DATA_DIR/baseline.csv" after="$DATA_DIR/after.csv"
  local budget t1 t2 per_run per_carrier
  budget=$(cat "$DATA_DIR/comparison-budget-mib" 2>/dev/null || echo '未记录')
  if [[ "$budget" =~ ^[0-9]+$ ]]; then per_run=$((budget / 2)); per_carrier=$((budget / 4)); else per_run='未记录'; per_carrier='未记录'; fi
  t1=$(cat "$DATA_DIR/baseline.time" 2>/dev/null || echo '未知')
  t2=$(cat "$DATA_DIR/after.time" 2>/dev/null || echo '未知')
  printf '╭──────── TcpQuality 调优前后对比（广东 IPv4）────────╮\n'
  printf '  两轮下载总预算：%s MiB（每轮最多 %s MiB；每运营商每轮最多 %s MiB）\n  基线：%s\n  调优后：%s\n' "$budget" "$per_run" "$per_carrier" "$t1" "$t2"
  awk -F, -v f1="$before" -v f2="$after" '
    function numeric(v) { return v ~ /^-?[0-9]+([.][0-9]+)?$/ }
    function val(v) { return numeric(v) ? sprintf("%.1f", v+0) : (v=="" ? "无结果" : v) }
    function diff(a,b) { return numeric(a) && numeric(b) ? sprintf("%+.1f", (b+0)-(a+0)) : "—" }
    function pct(a,b) { return numeric(a) && numeric(b) && (a+0)!=0 ? sprintf("%+.0f%%", ((b-a)/a)*100) : "—" }
    FILENAME==f1 { stage=1 }
    FILENAME==f2 { stage=2 }
    {
      if (($1=="三网" && $2=="IPv4") || ($1=="IPv4大包" && $2=="IPv4")) {
        isp=$4
        if (isp=="电信" || isp=="移动") {
          kind=($1=="三网" ? "normal" : "large")
          lat[kind,stage,isp]=$11; loss[kind,stage,isp]=$10; route[kind,stage,isp]=$12
        }
      }
      if ($1=="三网单线程速度" && $2=="广东" && ($3=="电信" || $3=="移动")) {
        speed[stage,$3]=$10
        speed_status[stage,$3]=$7
      }
    }
    END {
      for (i=1; i<=2; i++) {
        isp=(i==1 ? "电信" : "移动")
        printf "\n【广东%s】\n", isp
        for (k=1; k<=2; k++) {
          kind=(k==1 ? "normal" : "large")
          label=(k==1 ? "普通回程" : "大包回程")
          a=lat[kind,1,isp]; b=lat[kind,2,isp]
          al=loss[kind,1,isp]; bl=loss[kind,2,isp]
          ar=route[kind,1,isp]; br=route[kind,2,isp]
          printf "  %s：延迟 %s → %s ms（变化 %s ms），丢包 %s%% → %s%%\n", label, val(a), val(b), diff(a,b), val(al), val(bl)
          printf "    线路：%s → %s\n", (ar==""?"无":ar), (br==""?"无":br)
        }
        a=speed[1,isp]; b=speed[2,isp]
        if (speed_status[1,isp]!="OK") a="失败"
        if (speed_status[2,isp]!="OK") b="失败"
        printf "  单线程下载 %s → %s Mbps（%s）\n", val(a), val(b), pct(a,b)
      }
      print "\n注：单线程百分比按调优前为基准；网卡 RX+TX 与商家计费口径可能不同。"
    }
  ' "$before" "$after"
  printf '╰────────────────────────────────────────────────────────╯\n'
}

traffic_value() {
  [[ -s "$1" ]] || return 0
  awk -F= '$1=="rx_tx_delta_bytes" && $2 ~ /^[0-9]+$/ {print $2; found=1; exit} END{if(!found) exit 1}' "$1" 2>/dev/null || true
}

format_bytes() {
  local b="${1:-}"
  [[ "$b" =~ ^[0-9]+$ ]] || { printf '未记录'; return; }
  awk -v b="$b" 'BEGIN {if (b>=1073741824) printf "%.2f GiB", b/1073741824; else if (b>=1048576) printf "%.1f MiB", b/1048576; else if (b>=1024) printf "%.1f KiB", b/1024; else printf "%d B", b}'
}

print_traffic_summary() {
  local setup baseline tune after total measured iface
  setup=$(traffic_value "$DATA_DIR/setup.traffic")
  baseline=$(traffic_value "$DATA_DIR/baseline.traffic")
  tune=$(traffic_value "$DATA_DIR/tune.traffic")
  after=$(traffic_value "$DATA_DIR/after.traffic")
  iface=$(awk -F= '$1=="interface"{print $2; exit}' "$DATA_DIR/after.traffic" 2>/dev/null || true)
  printf '\n====== 流量估算（网卡 RX+TX，非商家账单）======\n'
  printf '工具/依赖准备：  %s\n' "$(format_bytes "$setup")"
  printf '调优前测试：    %s\n' "$(format_bytes "$baseline")"
  printf 'tcpfit 基础调优：%s\n' "$(format_bytes "$tune")"
  printf '调优后测试：    %s\n' "$(format_bytes "$after")"
  if [[ "$baseline" =~ ^[0-9]+$ && "$tune" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
    total=$((baseline + tune + after))
    printf '两次测试+调优： %s\n' "$(format_bytes "$total")"
    if [[ "$setup" =~ ^[0-9]+$ ]]; then
      measured=$((total + setup))
      printf '含工具准备合计：%s\n' "$(format_bytes "$measured")"
    else
      printf '含工具准备合计：未完整记录\n'
    fi
  else
    printf '两次测试+调优：部分阶段未记录，无法准确合计\n'
  fi
  printf '计数网卡：%s；各阶段都可能包含该阶段其他并发流量。商家计费口径可能不同。\n' "${iface:-默认网卡}"
}

os_id() {
  [[ -r /etc/os-release ]] || return 1
  . /etc/os-release
  printf '%s' "${ID:-unknown}"
}

missing_tools() {
  local c
  for c in curl ip nstat nping traceroute awk sha256sum; do
    command -v "$c" >/dev/null 2>&1 || printf '%s\n' "$c"
  done
}

confirm_setup() {
  local missing="$1" need_tcpfit="$2" need_core="$3" need_nexttrace="$4" answer
  printf '\n首次准备需要网络下载/安装：\n'
  [[ -z "$missing" ]] || printf '  系统工具：%s\n' "${missing//$'\n'/, }"
  [[ "$need_nexttrace" == 0 ]] || printf '  官方 NextTrace Tiny v%s（固定发行资产并校验 SHA256）\n' "$NEXTTRACE_VERSION"
  [[ "$need_tcpfit" == 0 ]] || printf '  官方 tcpfit v%s（下载后校验 SHA256；不运行测速）\n' "$TCPFIT_VERSION"
  [[ "$need_core" == 0 ]] || printf '  已固定版本并校验 SHA256 的 TcpQuality core\n'
  if [[ ! -t 0 ]]; then
    [[ "${AUTO_INSTALL:-0}" == 1 ]] || fail '非交互运行时如同意安装，请设置 AUTO_INSTALL=1。'
    return 0
  fi
  read -r -p '继续安装？[y/N] ' answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || fail '已取消；没有开始测试。'
}

install_system_deps() {
  local id="$1" missing="$2"
  [[ -n "$missing" ]] || return 0
  case "$id" in
    debian|ubuntu)
      command -v apt-get >/dev/null 2>&1 || fail '系统识别为 Debian/Ubuntu，但找不到 apt-get。'
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y nmap traceroute iproute2 curl ca-certificates
      ;;
    alpine)
      command -v apk >/dev/null 2>&1 || fail '系统识别为 Alpine，但找不到 apk。'
      apk add --no-cache bash coreutils nmap-nping traceroute iproute2 curl ca-certificates
      ;;
    *) fail "暂不自动安装 $id 的依赖；请手动安装：curl、iproute2(nstat)、nping、traceroute、awk、sha256sum。" ;;
  esac
}

nexttrace_asset() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s|%s\n' nexttrace-tiny_linux_amd64 9f219ba91318a3e1534bd28c661ef8019da42825ed48257035c508962d007271 ;;
    i386|i486|i586|i686) printf '%s|%s\n' nexttrace-tiny_linux_386 5137792b18dc5830834b0e537aea2018f0d8d17c7588c8f7bde691f6bbb03c65 ;;
    aarch64|arm64) printf '%s|%s\n' nexttrace-tiny_linux_arm64 aeab456e2f8aebd62cd1dd2d6458d2ec57b38f5d707e196bab41f999ff898810 ;;
    armv7l|armv7) printf '%s|%s\n' nexttrace-tiny_linux_armv7 deef6df56fcaefd14737859ad545d941cb1bffbf6b02702aba1b9aefad317614 ;;
    armv6l|armv6) printf '%s|%s\n' nexttrace-tiny_linux_armv6 5cdb0fa7b4c0e983342b1867f4e3504cb42ee77b3b4be7eee88ee225f79741e1 ;;
    armv5tel|armv5) printf '%s|%s\n' nexttrace-tiny_linux_armv5 4836257e81051bda91b0545144e34f219c83e2dcded55b8cbacfd768d722beeb ;;
    loongarch64|loong64) printf '%s|%s\n' nexttrace-tiny_linux_loong64 8e55ed498e4d201a1219bf7e2e88c8585ef1aad30f14834caf50ffcb340daf11 ;;
    mips) printf '%s|%s\n' nexttrace-tiny_linux_mips 1a5a1232c4d95032157a9cb55d7be160b2d558b338ed2be71c1537f0d673b538 ;;
    mips64) printf '%s|%s\n' nexttrace-tiny_linux_mips64 5a14549d565ebdb3fd41a9502e3f585c91c67de06f1c6453987b5ef62765d1b9 ;;
    mips64el) printf '%s|%s\n' nexttrace-tiny_linux_mips64le 5be1f7d8d6417f9bcce822544728d61ce89b39de86c53d9edcb29213c526e035 ;;
    mipsel) printf '%s|%s\n' nexttrace-tiny_linux_mipsle fe9b9ca7dc94951fc9d127dba1ddb2eba34a871a3a8deb6e92188b283058037c ;;
    mips-softfloat) printf '%s|%s\n' nexttrace-tiny_linux_mips_softfloat 3784d02451a397c717b8cdf6394a962d5b46c7c24ae9f524a8242186cb3a4d2b ;;
    mipsel-softfloat) printf '%s|%s\n' nexttrace-tiny_linux_mipsle_softfloat 5258defd2e302f31e611885b962a8f9e1110c2f821dcdbbb2ec1ef4bf70efa9c ;;
    ppc64) printf '%s|%s\n' nexttrace-tiny_linux_ppc64 9cb8b75d1bfc089f380602f609f5a3597f00741c821aac1585a6cc44ce48b6b0 ;;
    ppc64le) printf '%s|%s\n' nexttrace-tiny_linux_ppc64le eb99c0849f79ca7afe8e3f0f1b23b474c54bf9a0aadb573021358adb121ae9ec ;;
    riscv64) printf '%s|%s\n' nexttrace-tiny_linux_riscv64 54d9cac41cced1f65336f717aba8ee0d692148f0c97cea727b4a0ebc4d0f9881 ;;
    s390x) printf '%s|%s\n' nexttrace-tiny_linux_s390x 04616c7e7b686cc6171b78e1fd4e8666c8fd4f3dd7191ae273eb1f153ec8463e ;;
    *) return 1 ;;
  esac
}

nexttrace_installed_ok() {
  local asset digest existing
  IFS='|' read -r asset digest < <(nexttrace_asset) || return 1
  existing=$(type -P nexttrace-tiny 2>/dev/null) || return 1
  printf '%s  %s\n' "$digest" "$existing" | sha256sum -c - >/dev/null 2>&1
}

install_nexttrace_tiny() {
  local asset digest tmp target='/usr/local/bin/nexttrace-tiny' existing
  IFS='|' read -r asset digest < <(nexttrace_asset) || fail "不支持的 NextTrace 架构：$(uname -m)"
  nexttrace_installed_ok && return 0
  if existing=$(type -P nexttrace-tiny 2>/dev/null); then
    [[ "$existing" == "$target" ]] || fail "nexttrace-tiny 已安装在 $existing 且校验不匹配；为避免执行未知二进制，请先移走或更新它。"
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/nexttrace-tiny.XXXXXX") || return 1
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 \
    "$NEXTTRACE_BASE_URL/$asset" -o "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  if ! printf '%s  %s\n' "$digest" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f -- "$tmp"; fail "NextTrace Tiny v$NEXTTRACE_VERSION SHA256 校验失败，拒绝安装。"
  fi
  chmod 755 "$tmp"
  "$tmp" --version >/dev/null 2>&1 || { rm -f -- "$tmp"; fail 'NextTrace Tiny 二进制启动检查失败，拒绝安装。'; }
  install -m 755 "$tmp" "$target"
  rm -f -- "$tmp"
  command -v nexttrace-tiny >/dev/null 2>&1
}

install_tcpfit() {
  local tmp
  command -v tcpfit >/dev/null 2>&1 && return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/tcpfit.XXXXXX") || return 1
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "$TCPFIT_URL" -o "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if ! printf '%s  %s\n' "$TCPFIT_SHA256" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tmp"; fail "tcpfit v$TCPFIT_VERSION SHA256 校验失败，拒绝安装。"
  fi
  install -m 755 "$tmp" /usr/local/bin/tcpfit
  rm -f "$tmp"
  command -v tcpfit >/dev/null 2>&1
}

verify_core() {
  [[ -s "$CORE" ]] || fail "TcpQuality core 不存在或为空：$CORE"
  if ! printf '%s  %s\n' "$CORE_SHA256" "$CORE" | sha256sum -c - >/dev/null 2>&1; then
    fail "TcpQuality core SHA256 校验失败，拒绝运行：$CORE"
  fi
}

install_core() {
  local tmp
  if [[ -s "$CORE" ]]; then return 0; fi
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  tmp="$DATA_DIR/runTcpQuality-core.sh.tmp"
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "$CORE_URL" -o "$tmp" || {
    rm -f "$tmp"; fail '下载 TcpQuality core 失败。';
  }
  if ! printf '%s  %s\n' "$CORE_SHA256" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tmp"; fail 'TcpQuality core SHA256 校验失败，已拒绝运行。';
  fi
  mv -f "$tmp" "$DATA_DIR/runTcpQuality-core.sh"
  chmod 600 "$DATA_DIR/runTcpQuality-core.sh"
  CORE="$DATA_DIR/runTcpQuality-core.sh"
}

prepare() {
  local id missing need_tcpfit=0 need_core=0 need_nexttrace=0 setup_iface='' setup_before='' setup_after setup_delta
  require_root
  validate_data_dir
  if [[ -e "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
    fail "数据路径存在但不是目录：$DATA_DIR"
  fi
  mkdir -p "$DATA_DIR"
  [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] || fail "数据路径不是安全目录：$DATA_DIR"
  [[ "$(stat -c %u "$DATA_DIR" 2>/dev/null)" == "$(id -u)" ]] || fail "数据目录必须由当前 root 用户拥有：$DATA_DIR"
  chmod 700 "$DATA_DIR"
  id=$(os_id) || fail '无法读取 /etc/os-release。'
  missing=$(missing_tools || true)
  command -v tcpfit >/dev/null 2>&1 || need_tcpfit=1
  nexttrace_installed_ok || need_nexttrace=1
  [[ -s "$CORE" || -s "$DATA_DIR/runTcpQuality-core.sh" ]] || need_core=1
  local need_components=0
  if [[ "$need_nexttrace" == 1 || "$need_tcpfit" == 1 || "$need_core" == 1 ]]; then
    need_components=1
  fi
  if [[ -n "$missing" || "$need_components" == 1 ]]; then
    confirm_setup "$missing" "$need_tcpfit" "$need_core" "$need_nexttrace"
  fi
  if [[ ( "$MODE" == baseline || "$MODE" == setup ) && ! -e "$DATA_DIR/setup.traffic" ]]; then
    setup_iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)
    setup_before=$(traffic_bytes "$setup_iface")
  fi
  install_system_deps "$id" "$missing"
  local still_missing
  still_missing=$(missing_tools || true)
  [[ -z "$still_missing" ]] || fail "仍缺少系统工具：${still_missing//$'\n'/, }"
  install_nexttrace_tiny || fail '安装或校验 NextTrace Tiny 失败；需要与固定版本匹配的可执行命令 nexttrace-tiny。'
  install_tcpfit || fail '安装 tcpfit 失败。'
  if [[ -s "$DATA_DIR/runTcpQuality-core.sh" ]]; then CORE="$DATA_DIR/runTcpQuality-core.sh"; else install_core; fi
  verify_core
  export TCPQUALITY_NO_AUTO_INSTALL=1
  if [[ -n "$setup_before" ]]; then
    setup_after=$(traffic_bytes "$setup_iface")
    setup_delta=$((setup_after - setup_before))
    (( setup_delta >= 0 )) || setup_delta=0
    printf 'interface=%s\nrx_tx_delta_bytes=%s\n' "${setup_iface:-unknown}" "$setup_delta" > "$DATA_DIR/setup.traffic"
    chmod 600 "$DATA_DIR/setup.traffic"
  fi
  printf '[OK] 系统依赖、NextTrace Tiny、tcpfit 和 TcpQuality core 已就绪。\n'
}

case "$MODE" in
  help|-h|--help) usage; exit 0 ;;
  reset)
    [[ "${RESET:-}" == YES ]] || fail "拒绝清除记录；如确认，运行 RESET=YES $0 reset。此操作不会回滚 tcpfit。"
    validate_data_dir
    [[ -d "$DATA_DIR" ]] || { printf '记录目录不存在：%s\n' "$DATA_DIR"; exit 0; }
    [[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] || fail "数据路径不是安全目录：$DATA_DIR"
    [[ "$(stat -c %u "$DATA_DIR" 2>/dev/null)" == "$(id -u)" ]] || fail "数据目录必须由当前 root 用户拥有：$DATA_DIR"
    for file in \
      "$DATA_DIR/baseline.csv" "$DATA_DIR/after.csv" "$DATA_DIR/baseline.log" "$DATA_DIR/after.log" \
      "$DATA_DIR/baseline.time" "$DATA_DIR/after.time" "$DATA_DIR/baseline.traffic" "$DATA_DIR/after.traffic" \
      "$DATA_DIR/setup.traffic" "$DATA_DIR/tune.traffic" "$DATA_DIR/tune.log" "$DATA_DIR/tune.done" \
      "$DATA_DIR/comparison-budget-mib" "$DATA_DIR/runTcpQuality-core.sh" "$DATA_DIR/runTcpQuality-core.sh.tmp" \
      "$DATA_DIR"/.baseline.csv.* "$DATA_DIR"/.after.csv.*; do
      [[ -e "$file" ]] && rm -f -- "$file"
    done
    printf '已清除 %s 中的比较记录和托管 core；目录及其他文件保留（不会卸载依赖或回滚 tcpfit）。\n' "$DATA_DIR"
    exit 0
    ;;
  compare)
    validate_data_dir
    [[ -s "$DATA_DIR/baseline.csv" && -s "$DATA_DIR/after.csv" ]] || fail "缺少 baseline/after CSV；记录目录：$DATA_DIR"
    compare_reports
    print_traffic_summary
    printf '\n原始报告：%s\n' "$DATA_DIR"
    exit 0
    ;;
  baseline|after|setup|tune) ;;
  *) usage >&2; exit 2 ;;
esac

require_root
validate_data_dir
if [[ "$MODE" != tune && -n "$TUNE_RTT" ]]; then
  fail 'RTT 参数只允许在 tune 模式中使用。'
fi
if [[ "$MODE" == tune ]]; then
  [[ "$ARG" =~ ^[1-9][0-9]{0,5}$ ]] || fail "请提供套餐带宽 Mbps，例如：$0 tune 200。不要留空或使用 auto。"
  if [[ -n "$TUNE_RTT" ]]; then
    [[ "$TUNE_RTT" =~ ^[0-9]{1,4}$ ]] || fail 'RTT 必须是 1-2000 之间的整数毫秒。'
    (( 10#$TUNE_RTT >= 1 && 10#$TUNE_RTT <= 2000 )) || fail 'RTT 必须是 1-2000 之间的整数毫秒。'

    TUNE_RTT=$((10#$TUNE_RTT))
  else
    TUNE_RTT=150
  fi
  [[ -s "$DATA_DIR/baseline.csv" ]] || fail '请先执行 baseline 并保存调优前记录。'
  [[ ! -e "$DATA_DIR/tune.done" ]] || fail '基础调优已记录；拒绝重复执行。需要重做请先备份并重置比较记录。'
elif [[ "$MODE" == baseline ]]; then
  [[ ! -e "$DATA_DIR/baseline.csv" ]] || fail "基线已存在：$DATA_DIR/baseline.csv；拒绝重复测速。"
elif [[ "$MODE" == after ]]; then
  [[ -s "$DATA_DIR/baseline.csv" ]] || fail '请先执行 baseline。'
  [[ -s "$DATA_DIR/tune.done" ]] || fail "请先运行本脚本的 tune <Mbps>；确保基础调优完成后才复测。"
  [[ ! -e "$DATA_DIR/after.csv" ]] || fail "调优后记录已存在：$DATA_DIR/after.csv；拒绝重复测速。"
fi
BUDGET_MIB=''
if [[ "$MODE" == baseline ]]; then
  BUDGET_MIB=$(choose_budget_mib "$ARG")
elif [[ "$MODE" == after ]]; then
  [[ -s "$DATA_DIR/comparison-budget-mib" ]] || fail '缺少基线保存的流量预算；请保留同一份测试记录目录。'
  BUDGET_MIB=$(<"$DATA_DIR/comparison-budget-mib")
  BUDGET_MIB=$(choose_budget_mib "$BUDGET_MIB")
fi
prepare
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [[ "$MODE" == setup ]]; then exit 0; fi
if [[ "$MODE" == baseline ]]; then
  printf '%s\n' "$BUDGET_MIB" > "$DATA_DIR/comparison-budget-mib"
  chmod 600 "$DATA_DIR/comparison-budget-mib"
fi

if [[ "$MODE" == tune ]]; then
  tune_iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)
  tune_before=$(traffic_bytes "$tune_iface")
  printf '[*] 执行 tcpfit 基础调优：proxy，%s Mbps，RTT %s ms；不运行 probe 或 sweep。\n' "$ARG" "$TUNE_RTT"
  tune_rc=0
  tcpfit tune --role proxy --bw "$ARG" --rtt "$TUNE_RTT" >"$DATA_DIR/tune.log" 2>&1 || tune_rc=$?
  tune_after=$(traffic_bytes "$tune_iface")
  tune_bytes=$((tune_after - tune_before))
  (( tune_bytes >= 0 )) || tune_bytes=0
  printf 'interface=%s\nrx_tx_delta_bytes=%s\n' "${tune_iface:-unknown}" "$tune_bytes" > "$DATA_DIR/tune.traffic"
  chmod 600 "$DATA_DIR/tune.traffic"
  if (( tune_rc != 0 )); then
    tail -n 60 "$DATA_DIR/tune.log" >&2 || true
    fail 'tcpfit 基础调优失败；流量计数已保存，但未写入 tune.done。'
  fi
  cat "$DATA_DIR/tune.log"
  printf 'bandwidth_mbps=%s\nrtt_ms=%s\n' "$ARG" "$TUNE_RTT" > "$DATA_DIR/tune.done"
  chmod 600 "$DATA_DIR/tune.log" "$DATA_DIR/tune.done"
  printf '[OK] 基础调优完成；此阶段网卡 RX+TX 增量：%s bytes（含其他并发流量）。\n' "$tune_bytes"
  printf '\n[OK] 现在可运行：%s after\n' "$0"
  exit 0
fi

log="$DATA_DIR/$MODE.log"
csv="$DATA_DIR/$MODE.csv"
RUN_CSV_TMP="$DATA_DIR/.$MODE.csv.$$.tmp"
rm -f -- "$RUN_CSV_TMP"
iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)
before=$(traffic_bytes "$iface")
stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RUN_BUDGET_MIB=$((BUDGET_MIB / 2))
PER_CARRIER_MIB=$((BUDGET_MIB / 4))
export TOS_PROBE_SIZE="${PER_CARRIER_MIB}MiB"
export TOS_TIMEOUT=10
export SPEEDTEST_APPLECDN_ENABLED=0
export TCPQUALITY_TCP_INFO=0
export TCPQUALITY_RETRANS_TRACE=0
export TCPQUALITY_CSV_PATH="$RUN_CSV_TMP"

printf '[%s] 开始广东电信/移动 IPv4 专项测试（%s）\n' "$stamp" "$MODE"
printf '基线+调优后两轮总预算：%s MiB；本轮最多 %s MiB，电信/移动各最多 %s MiB。\n' "$BUDGET_MIB" "$RUN_BUDGET_MIB" "$PER_CARRIER_MIB"
printf '另有每次 10 秒超时；预算只限四个单线程下载对象，不含工具安装、协议开销及其他流量。\n'
printf '默认网卡 RX+TX 计数包含其他并发流量。\n'
bash "$CORE" --gd-proxy-only --no-rank-upload >"$log" 2>&1 &
CORE_PID=$!
core_status=0
wait "$CORE_PID" || core_status=$?
CORE_PID=''
if (( core_status != 0 )); then
  printf '[!] TcpQuality 失败；日志：%s\n' "$log" >&2
  tail -n 50 "$log" >&2 || true
  exit "$core_status"
fi
[[ -s "$RUN_CSV_TMP" ]] || fail "测试结束但找不到本次运行的 CSV；查看 $log"
mv -f -- "$RUN_CSV_TMP" "$csv"
RUN_CSV_TMP=''
after=$(traffic_bytes "$iface")
bytes=$((after - before))
(( bytes >= 0 )) || bytes=0
printf '%s\n' "$stamp" > "$DATA_DIR/$MODE.time"
printf 'interface=%s\nrx_tx_delta_bytes=%s\ncomparison_budget_mib=%s\n' "${iface:-unknown}" "$bytes" "$BUDGET_MIB" > "$DATA_DIR/$MODE.traffic"
chmod 600 "$log" "$csv" "$DATA_DIR/$MODE.time" "$DATA_DIR/$MODE.traffic"
printf '\n已保存 %s 结果：\n  %s\n  %s\n' "$MODE" "$log" "$csv"
printf '测试期间网卡 RX+TX 增量：%s bytes（含其他并发流量）。\n' "$bytes"
if [[ "$MODE" == baseline ]]; then
  printf '下一步：%s tune <套餐带宽Mbps>，例如 %s tune 200。\n' "$0" "$0"
else
  printf '下一步：%s compare\n' "$0"
fi
printf '\n关键输出：\n'
grep -E 'IPv4大包|单线程测速|广东.*(电信|移动)' "$log" | tail -n 35 || true
