#!/bin/bash
#
# install.sh — RegionSpoof 一键安装器
# 在国行 Mac(Apple Silicon / macOS 27)上开启完整 Apple 智能(端侧 + PCC 云端)。
#
# 用法:
#   sudo ./install.sh             安装(默认)
#   sudo ./install.sh status      查看状态 / 体检
#   sudo ./install.sh diagnose    一键诊断（报 issue 贴这个）
#   sudo ./install.sh pcc         只读诊断 PCC 云端链路
#   sudo ./install.sh uninstall   卸载
#
set -uo pipefail
AMFI_CHANGED=0

# ───────── 输出辅助 ─────────
if [ -t 1 ]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; C=$'\033[0;36m'; W=$'\033[1m'; N=$'\033[0m'
else R=''; G=''; Y=''; B=''; C=''; W=''; N=''; fi
info(){ printf '%s▶%s %s\n' "$B" "$N" "$1"; }
ok(){   printf '%s✅ %s%s\n' "$G" "$1" "$N"; }
warn(){ printf '%s⚠️  %s%s\n' "$Y" "$1" "$N"; }
err(){  printf '%s❌ %s%s\n' "$R" "$1" "$N"; }
die(){  err "$1"; exit 1; }
hr(){   printf '%s────────────────────────────────────────────────────%s\n' "$C" "$N"; }

banner(){
  printf '%s\n' "$C"
  cat <<'EOF'
  ╔════════════════════════════════════════════════════╗
  ║   RegionSpoof · 国行 Mac 开启 Apple 智能  (macOS 27)  ║
  ╚════════════════════════════════════════════════════╝
EOF
  printf '%s' "$N"
}

# ───────── 提权(自动 sudo)─────────
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [ "$(id -u)" -ne 0 ]; then
  info "需要管理员权限,正在用 sudo 重新运行…"
  exec sudo "$SELF" "$@"
fi
DIR="$(dirname "$SELF")"

# ───────── 路径 ─────────
KEXT_SRC="$DIR/RegionSpoof.kext";              KEXT_DST="/Library/Extensions/RegionSpoof.kext"
LOADER_SRC="$DIR/region-kext-load.sh";         LOADER_DST="/usr/local/bin/region-kext-load.sh"
PLIST_SRC="$DIR/com.local.regionkext.plist";   PLIST_DST="/Library/LaunchDaemons/com.local.regionkext.plist"
KEXT_ID="com.local.RegionSpoof";  DAEMON="system/com.local.regionkext"
ELIG="/private/var/db/eligibilityd/eligibility.plist"
PCC_DIAG="$DIR/pcc-diagnose.sh"

# ───────── 状态探测 ─────────
region_is_LL(){ ioreg -ard1 -c IOPlatformExpertDevice 2>/dev/null | plutil -p - 2>/dev/null | grep -q 4c4c2f41; }
kext_loaded(){  kmutil showloaded --no-kernel-components 2>/dev/null | grep -qi regionspoof; }
greymatter(){   /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t" "$ELIG" 2>/dev/null; }
sip_fully_off(){ csrutil status 2>/dev/null | grep -qi 'System Integrity Protection status: disabled'; }
sip_allows_kext(){
  local status
  status="$(csrutil status 2>/dev/null)"
  printf '%s\n' "$status" | grep -qi 'System Integrity Protection status: disabled' \
    || printf '%s\n' "$status" | grep -Eqi 'Kext Signing:[[:space:]]*disabled'
}
amfi_bypass_bootarg(){
  nvram boot-args 2>/dev/null \
    | grep -Eq '(^|[[:space:]])amfi_get_out_of_my_way(=[0-9]+)?([[:space:]]|$)'
}
amfi_launch_constraints(){ sysctl -n security.mac.amfi.launch_constraints_enforced 2>/dev/null || echo '?'; }

# 闸门②:本地启动策略未允许第三方 kext(与 SIP 的 kext 豁免相互独立)。
# 直接证据是本次开机的 kernelmanagerd 日志;auxp absent 只是旁证(全新机器也可能 absent)。
auxkc_gate_blocked(){
  kext_loaded && return 1
  region_is_LL && return 1
  local bootsec since
  bootsec="$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')"
  if [ -n "$bootsec" ] && [ "$bootsec" -gt 0 ] 2>/dev/null; then
    since="$(date -r "$bootsec" '+%Y-%m-%d %H:%M:%S')"
    log show --start "$since" --predicate 'process == "kernelmanagerd"' --info 2>/dev/null \
      | grep -q 'auxiliary extensions not allowed'
  else
    log show --last 48h --predicate 'process == "kernelmanagerd"' --info 2>/dev/null \
      | grep -q 'auxiliary extensions not allowed'
  fi
}

# ───────── AI 守护进程刷新 ─────────
refresh_ai(){
  info "刷新 Apple 智能守护进程(清掉旧区域缓存)…"
  for d in eligibilityd modelcatalogd modelmanagerd; do
    launchctl kickstart -k "system/com.apple.$d" >/dev/null 2>&1 || true
  done
}

# ───────── 去 quarantine(zip 下载的文件带此属性时,开机 LaunchDaemon 会被拒绝执行 → 重启后失效)─────────
strip_quarantine(){
  local f
  for f in "$KEXT_DST" "$LOADER_DST" "$PLIST_DST"; do [ -e "$f" ] && xattr -dr com.apple.quarantine "$f" 2>/dev/null; done
  if xattr -lr "$KEXT_DST" "$LOADER_DST" "$PLIST_DST" 2>/dev/null | grep -q com.apple.quarantine; then
    warn "quarantine 属性未能清除,重启后 LaunchDaemon 可能被拒绝执行"
  else ok "已清除 quarantine 属性(避免重启后 LaunchDaemon 被拒)"; fi
}

# ───────── 装/启 LaunchDaemon(开机自动加载)─────────
install_daemon(){
  [ -f "$LOADER_SRC" ] && { cp "$LOADER_SRC" "$LOADER_DST"; chown 0:0 "$LOADER_DST"; chmod 755 "$LOADER_DST"; }
  [ -f "$PLIST_SRC" ]  || { warn "缺少 LaunchDaemon 配置,跳过开机自启(kext 仍可手动加载)"; return; }
  cp "$PLIST_SRC" "$PLIST_DST"; chown 0:0 "$PLIST_DST"; chmod 644 "$PLIST_DST"
  launchctl bootout  "$DAEMON" >/dev/null 2>&1 || true
  launchctl bootstrap system "$PLIST_DST" >/dev/null 2>&1 || true
  ok "LaunchDaemon 已装(每次开机自动加载 kext)"
}

# ───────── 预检 ─────────
preflight(){
  hr; info "环境预检"
  [ "$(uname -m)" = "arm64" ] || die "本方案仅支持 Apple Silicon(arm64)。"
  ok "Apple Silicon · macOS $(sw_vers -productVersion 2>/dev/null)"
  [ -d "$KEXT_SRC" ] || die "找不到 $KEXT_SRC —— 请在项目目录里运行本脚本。"
  ok "项目文件就位"

  if ! sip_allows_kext; then
    err "当前 SIP 配置仍强制 kext 签名 —— ad-hoc kext 无法加载。请在恢复模式只关闭 kext 签名检查:"
    hr
    cat <<'EOS'
  1. 苹果菜单 → 关机
  2. 长按电源键,直到出现「正在载入启动选项 / Loading startup options」
  3. 选项(Options)→ 继续 → 选账户 → 输密码
  4. 顶部菜单栏 → 实用工具 → 终端(Terminal)
  5. 输入:  csrutil enable --without kext
     (如果该系统拒绝这条命令，再用 csrutil disable；前者安全面更小)
  6. 输入:  reboot
然后重新运行本脚本。
EOS
    exit 1
  fi
  if sip_fully_off; then
    warn "SIP 已完整关闭；kext 可以运行，但项目实际只需要 kext 签名豁免。"
    echo "  稳定后可在恢复模式改用: csrutil enable --without kext"
  else
    ok "SIP 已保留，仅关闭 kext 签名检查"
  fi

  # 这里只能可靠识别显式的 AMFI 绕过 boot-arg，不能据此承诺 PCC 一定可用。
  if amfi_bypass_bootarg; then
    warn "boot-args 含 amfi_get_out_of_my_way —— 它会破坏 PCC 所需的安全前提,正在移除…"
    local args new
    args="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"
    new="$(printf '%s' "$args" \
      | sed -E 's/(^|[[:space:]])amfi_get_out_of_my_way(=[0-9]+)?([[:space:]]|$)/ /g' \
      | xargs || true)"
    if [ -z "$new" ]; then nvram -d boot-args 2>/dev/null || true; else nvram boot-args="$new" 2>/dev/null || true; fi
    if amfi_bypass_bootarg; then
      die "无法移除 AMFI 绕过参数；请在恢复模式手动清理 boot-args。"
    fi
    AMFI_CHANGED=1; ok "已移除显式 AMFI 绕过参数（重启后生效）"
  else
    ok "未发现 amfi_get_out_of_my_way 绕过参数"
  fi
}

# ───────── 安装 ─────────
do_install(){
  banner; preflight
  hr; info "复制文件到系统目录"
  rm -rf "$KEXT_DST"; cp -R "$KEXT_SRC" "$KEXT_DST"; chown -R 0:0 "$KEXT_DST"
  ok "kext → $KEXT_DST  (root:wheel)"
  install_daemon
  strip_quarantine

  hr; info "加载 kext"
  if kext_loaded && region_is_LL; then
    ok "kext 已在运行,region-info 已是 LL/A"
  else
    out="$(kmutil load -p "$KEXT_DST" 2>&1 || true)"
    if region_is_LL; then
      ok "kext 加载成功,region-info = LL/A(美版)"
    else
      hr; warn "kext 需要你先手动批准一次(系统安全要求):"
      cat <<'EOS'
  1. 打开「系统设置 → 隐私与安全性」
  2. 拉到最底部 → 找到「com.local.RegionSpoof 被阻止」→ 点 [允许 / Allow]
  3. 重启 Mac
重启后本项目的 LaunchDaemon 会自动加载 kext。若仍未开启,再跑一次本脚本即可。
若设置里根本没有可点的「允许」、重启后 kext 仍未加载 → 多半卡在「本地启动策略」这道
独立闸门:恢复模式 → 启动安全性实用工具 → 降低安全性 → 勾「允许用户管理内核扩展」,
再 csrutil enable --without kext,重启(可能需两次开机)。详见 README 故障排查。
EOS
      [ -n "$out" ] && printf '%s（kmutil 提示:%s）%s\n' "$C" "$(printf '%s' "$out" | tail -1)" "$N"
      exit 0
    fi
  fi

  refresh_ai
  sleep 3   # 给 eligibilityd 重算的时间
  do_status quiet
  hr
  if region_is_LL && [ "$(greymatter)" = "4" ]; then
    ok "${W}Apple 智能已开启!${N}"
    echo "  • 端侧(校对/摘要/Genmoji/写作工具基础项):即刻可用"
    echo "  • PCC 云端是独立链路；请用 'sudo ./install.sh pcc' 验证，资格通过不等于云端必定成功"
    [ "$AMFI_CHANGED" = "1" ] && warn "你刚移除了 AMFI 绕过参数，请【重启一次】再测 PCC。"
  else
    warn "尚未完全就绪 —— 多半还需批准 kext 并重启,或模型仍在下载;稍后用 'sudo ./install.sh status' 复查。"
  fi
  hr
}

# ───────── 卸载 ─────────
do_uninstall(){
  banner; hr; info "卸载 RegionSpoof"
  launchctl bootout "$DAEMON" >/dev/null 2>&1 || true
  rm -f "$PLIST_DST" "$LOADER_DST"
  kmutil unload -b "$KEXT_ID" >/dev/null 2>&1 || true
  rm -rf "$KEXT_DST"
  ok "已移除 kext / LaunchDaemon / 加载脚本"
  refresh_ai
  hr; warn "重启后区域恢复为原始(CH),Apple 智能关闭。SIP 如需恢复:恢复模式里 csrutil enable。"
  hr
}

# ───────── 状态 / 体检 ─────────
do_status(){
  [ "${1:-}" = "quiet" ] || banner
  hr; info "RegionSpoof 状态"
  if sip_fully_off; then
    printf '  %-14s %s\n' "SIP:" "${Y}完整关闭（可用，但豁免过宽）${N}"
  elif sip_allows_kext; then
    printf '  %-14s %s\n' "SIP:" "${G}自定义：允许第三方 kext${N}"
  else
    printf '  %-14s %s\n' "SIP:" "${R}kext 签名检查开启（无法加载）${N}"
  fi
  printf '  %-14s %s\n' "AMFI 绕过:"   "$(amfi_bypass_bootarg && echo "${R}boot-arg 存在${N}" || echo "${G}未发现${N}")"
  printf '  %-14s %s\n' "启动约束:"     "$(amfi_launch_constraints)（只作状态展示，不单独判定 PCC）"
  printf '  %-14s %s\n' "region=LL/A:"  "$(region_is_LL && echo "${G}是${N}" || echo "${R}否(仍是 CH)${N}")"
  printf '  %-14s %s\n' "kext 已加载:"   "$(kext_loaded && echo "${G}是${N}" || echo "${R}否${N}")"
  local gm; gm="$(greymatter)"
  printf '  %-14s %s\n' "GREYMATTER:"   "$([ "$gm" = "4" ] && echo "${G}4(eligible)${N}" || echo "${Y}${gm:-?}(4 才是开启)${N}")"
  printf '  %-14s %s\n' "开机自启:"      "$([ -f "$PLIST_DST" ] && echo "${G}已装${N}" || echo "${Y}未装${N}")"
  [ "${1:-}" = "quiet" ] || hr
}

# ───────── 诊断报告(报 issue 用;纯文本,无颜色,方便整段复制)─────────
do_diagnose(){
  local osv osb model csr ba region gm
  echo "════════════════ RegionSpoof 诊断报告 ════════════════"
  echo "（把从上面这行 ═ 到最底下 ═ 的整段，原样贴进 GitHub issue）"
  echo

  osv="$(sw_vers -productVersion 2>/dev/null)"; osb="$(sw_vers -buildVersion 2>/dev/null)"
  model="$(sysctl -n hw.model 2>/dev/null)"
  echo "## 系统"
  echo "  macOS : ${osv:-?} (${osb:-?})"
  echo "  机型  : ${model:-?}  ($(uname -m))"
  echo

  echo "## 安全状态"
  if sip_fully_off; then
    echo "  SIP   : 完整关闭（kext 可用；项目不需要关闭全部保护）"
  elif sip_allows_kext; then
    echo "  SIP   : 自定义，仅 kext 签名豁免（推荐）"
  else
    echo "  SIP   : ⚠️ kext 签名检查仍开启，ad-hoc kext 加载不了"
  fi
  csr="$(csrutil status 2>/dev/null)"; printf '%s\n' "$csr" | sed 's/^/        /'
  if amfi_bypass_bootarg; then echo "  AMFI boot-arg: ⚠️ 有 amfi_get_out_of_my_way，必须移除后重启"
  else echo "  AMFI boot-arg: 未发现显式绕过（这不等于 PCC 已通过）"; fi
  echo "  AMFI launch constraints: $(amfi_launch_constraints)"
  if auxkc_gate_blocked; then
    echo "  本地启动策略: ⚠️ 未允许第三方 kext（独立于 SIP 的另一道闸门，aux KC 无法激活）"
    echo "          解法: 恢复模式 → 启动安全性实用工具 → 降低安全性 → 勾「允许用户管理内核扩展」，再 csrutil enable --without kext，重启（aux KC 可能需两次开机）"
  else
    echo "  本地启动策略: 未检测到阻塞（kext 已加载/区域已生效，或开机日志无该拦截）"
  fi
  ba="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"; [ -z "$ba" ] && ba='(空)'
  echo "  boot-args: $ba"
  echo "  本地安全策略摘要:"
  bputil -d 2>/dev/null \
    | grep -E 'Security Mode|3rd Party Kexts|System Integrity Protection' \
    | head -8 | sed 's/^/    /' || true
  echo

  echo "## 区域 & kext"
  region="$(ioreg -ard1 -c IOPlatformExpertDevice 2>/dev/null | plutil -p - 2>/dev/null | grep -i region-info | head -1 | sed 's/^ *//')"
  echo "  region-info: ${region:-未读到}"
  echo "    (含 4c4c2f41 = \"LL/A\" 美版✅ ；43482f41 = \"CH/A\" 国行❌，说明 kext 没生效)"
  echo "  kext 已加载: $(kext_loaded && echo '是 ✅' || echo '否 ❌')"
  echo

  echo "## 资格 GREYMATTER（4=已开启，2=未开启）"
  gm="$(greymatter)"
  echo "  answer = ${gm:-未读到}  $([ "$gm" = "4" ] && echo '✅ 已开启' || echo '❌ 没到 4，AI 没真正打开')"
  echo "  逐项输入状态（用于定位；个别输入为 2 不代表域必然失败，以上面的 domain answer 为准）:"
  /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" "$ELIG" 2>/dev/null \
    | sed 's/^/    /' || echo "    (读不到——eligibilityd 还没算出来，或路径有变)"
  echo

  echo "## 语言 & 逐 App 汉化（perapp-zh）"
  local cu cuid cuh pz
  cu="${SUDO_USER:-$(stat -f %Su /dev/console 2>/dev/null)}"; cuid="$(id -u "$cu" 2>/dev/null)"
  cuh="$(dscl . -read "/Users/$cu" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [ -n "$cu" ] && [ -n "$cuh" ]; then
    echo "  用户 $cu 全局 AppleLanguages: $(sudo -u "$cu" defaults read -g AppleLanguages 2>/dev/null | tr -d '\n ' || echo '?')"
    echo "  Siri 语言: $(sudo -u "$cu" defaults read com.apple.assistant.backedup 'Session Language' 2>/dev/null || echo '未设置')"
    echo "    (两者首项须一致且为 AI 支持语言；新 Siri 目前只认英文——系统语言设中文会掉新 Siri，中文界面请走 perapp-zh)"
    pz="$cuh/Library/Application Support/perapp-zh"
    if [ -f "$pz/manifest.txt" ]; then
      echo "  perapp-zh: 已汉化 $(grep -c '' "$pz/manifest.txt" 2>/dev/null) 项；系统设置代理 $(launchctl print "gui/$cuid/local.settings-zh-agent" 2>/dev/null | grep -q 'state = running' && echo '运行中' || echo '未运行')；深链接处理器 $([ -x "$pz/lshandler" ] && sudo -u "$cu" "$pz/lshandler" get x-apple.systempreferences 2>/dev/null || echo '?')"
    else
      echo "  perapp-zh: 未使用（想要中文界面见 perapp-zh/README.md）"
    fi
  else
    echo "  (读不到控制台用户，跳过)"
  fi
  echo

  echo "## PCC 云端分类（只读，不输出请求内容）"
  if [ -x "$PCC_DIAG" ]; then
    "$PCC_DIAG" --since 30m | sed 's/^/  /'
  else
    echo "  缺少或不可执行: $PCC_DIAG"
  fi
  echo
  echo "════════════════ 诊断报告结束 ════════════════"
}

# ───────── 入口 ─────────
case "${1:-install}" in
  install)        do_install ;;
  uninstall|remove) do_uninstall ;;
  status|verify|doctor) do_status ;;
  diagnose|report|log) do_diagnose ;;
  pcc|cloud) shift; exec "$PCC_DIAG" "$@" ;;
  *) echo "用法: sudo $0 [install|status|diagnose|pcc|uninstall]"; exit 1 ;;
esac
