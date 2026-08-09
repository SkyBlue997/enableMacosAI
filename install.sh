#!/bin/bash
#
# install.sh — RegionSpoof 一键安装器
# 在国行 Mac(Apple Silicon / macOS 27)上开启完整 Apple 智能(端侧 + PCC 云端)。
#
# 用法:
#   sudo ./install.sh             安装(默认)
#   sudo ./install.sh status      查看状态 / 体检
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
  ║ RegionSpoof · 国行 Mac 开启 Apple 智能  (macOS 27) ║
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

# ───────── 状态探测 ─────────
region_is_LL(){ ioreg -ard1 -c IOPlatformExpertDevice 2>/dev/null | plutil -p - 2>/dev/null | grep -q 4c4c2f41; }
kext_loaded(){  kmutil showloaded --no-kernel-components 2>/dev/null | grep -qi regionspoof; }
greymatter(){   /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t" "$ELIG" 2>/dev/null; }
sip_off(){      csrutil status 2>/dev/null | grep -qi disabled; }
amfi_off(){     nvram boot-args 2>/dev/null | grep -q amfi_get_out_of_my_way; }

# ───────── AI 守护进程刷新 ─────────
refresh_ai(){
  info "刷新 Apple 智能守护进程(清掉旧区域缓存)…"
  for d in eligibilityd modelcatalogd modelmanagerd; do
    launchctl kickstart -k "system/com.apple.$d" >/dev/null 2>&1 || true
  done
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

  if ! sip_off; then
    err "SIP 仍开启 —— ad-hoc kext 无法加载。请先关 SIP:"
    hr
    cat <<'EOS'
  1. 苹果菜单 → 关机
  2. 长按电源键,直到出现「正在载入启动选项 / Loading startup options」
  3. 选项(Options)→ 继续 → 选账户 → 输密码
  4. 顶部菜单栏 → 实用工具 → 终端(Terminal)
  5. 输入:  csrutil disable        (按提示 y / 验证身份)
  6. 输入:  reboot
然后重新运行本脚本。
EOS
    exit 1
  fi
  ok "SIP 已关闭(Permissive)"

  # AMFI —— PCC 云端 AI 的命根子;关掉它 PCC 必死
  if amfi_off; then
    warn "boot-args 含 amfi_get_out_of_my_way —— 它会让 SEP 拒绝 PCC 证明,正在移除…"
    local args new
    args="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"
    new="$(printf '%s' "$args" | sed -E 's/amfi_get_out_of_my_way=[0-9]*//g' | xargs || true)"
    if [ -z "$new" ]; then nvram -d boot-args 2>/dev/null || true; else nvram boot-args="$new" 2>/dev/null || true; fi
    AMFI_CHANGED=1
    ok "已移除(重启后 AMFI 恢复,PCC 才可用)"
  else
    ok "AMFI 已启用(PCC 云端可用)"
  fi
}

# ───────── 安装 ─────────
do_install(){
  banner; preflight
  hr; info "复制文件到系统目录"
  rm -rf "$KEXT_DST"; cp -R "$KEXT_SRC" "$KEXT_DST"; chown -R 0:0 "$KEXT_DST"
  ok "kext → $KEXT_DST  (root:wheel)"
  install_daemon

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
    echo "  • PCC 云端(语气改写/图乐园):首次需等模型下完 + 证明池预热几分钟"
    [ "$AMFI_CHANGED" = "1" ] && warn "你刚移除了 amfi boot-arg,请【重启一次】让 PCC 生效。"
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
  printf '  %-14s %s\n' "SIP:"          "$(sip_off && echo "${G}已关(Permissive)${N}" || echo "${R}开启(kext 无法加载)${N}")"
  printf '  %-14s %s\n' "AMFI:"         "$(amfi_off && echo "${R}关闭(PCC 会失效!)${N}" || echo "${G}启用${N}")"
  printf '  %-14s %s\n' "region=LL/A:"  "$(region_is_LL && echo "${G}是${N}" || echo "${R}否(仍是 CH)${N}")"
  printf '  %-14s %s\n' "kext 已加载:"   "$(kext_loaded && echo "${G}是${N}" || echo "${R}否${N}")"
  local gm; gm="$(greymatter)"
  printf '  %-14s %s\n' "GREYMATTER:"   "$([ "$gm" = "4" ] && echo "${G}4(eligible)${N}" || echo "${Y}${gm:-?}(4 才是开启)${N}")"
  printf '  %-14s %s\n' "开机自启:"      "$([ -f "$PLIST_DST" ] && echo "${G}已装${N}" || echo "${Y}未装${N}")"
  [ "${1:-}" = "quiet" ] || hr
}

# ───────── 诊断报告(报 issue 用;纯文本,无颜色,方便整段复制)─────────
do_diagnose(){
  local osv osb model csr ba region gm kb hum
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
  echo "  SIP   : $(sip_off && echo '已关 disabled（正确）' || echo '⚠️ 未完全关闭——ad-hoc kext 加载不了')"
  csr="$(csrutil status 2>/dev/null)"; printf '%s\n' "$csr" | sed 's/^/        /'
  if amfi_off; then echo "  AMFI  : ⚠️ 关闭——PCC 云端必失效！boot-args 里有 amfi_get_out_of_my_way，删掉它"
  else echo "  AMFI  : 启用（正确，PCC 可用）"; fi
  ba="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"; [ -z "$ba" ] && ba='(空)'
  echo "  boot-args: $ba"
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
  echo "  逐项输入状态（值为 2 的那一项 = 没过、就是它卡住的）:"
  /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" "$ELIG" 2>/dev/null \
    | sed 's/^/    /' || echo "    (读不到——eligibilityd 还没算出来，或路径有变)"
  echo

  echo "## 模型资产（端侧+云端都得先下完这些）"
  kb="$( { find /System/Library/AssetsV2 -maxdepth 1 -type d \
           \( -iname '*Generative*' -o -iname '*UAF_FM*' -o -iname '*Visual*' -o -iname '*CodeLM*' -o -iname '*ModelCatalog*' \) \
           -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null; } | awk '{s+=$1} END{print s+0}')"
  if [ "${kb:-0}" -gt 0 ] 2>/dev/null; then
    hum="$(awk -v k="$kb" 'BEGIN{printf "%.1f", k/1024/1024}')"
    echo "  AI 模型总大小: ~${hum}G  （下全约 30G+；明显偏小 = 还在下载，等它下完）"
  else
    echo "  AI 模型总大小: 0 / 未找到 —— 还没下完，或被文件系统保护挡住（部分关 SIP 时会这样）"
  fi
  echo

  echo "## PCC 云端日志（近 3 分钟；只关系语气改写/图乐园/Reframe，端侧功能跟它无关）"
  { log show --last 3m --predicate 'process == "privatecloudcomputed"' 2>/dev/null \
      | grep -iE 'finished successfully|3200[0-9]|RetryAfter|NWError|3205[0-9]|Insufficient inline|32080' \
      | tail -8 | sed 's/^/  /'; } || true
  echo "  （出现 'Ropes request finished successfully' = 云端正常；32001+RetryAfter = 被限流，停手等几小时）"
  echo
  echo "════════════════ 诊断报告结束 ════════════════"
}

# ───────── 入口 ─────────
case "${1:-install}" in
  install)        do_install ;;
  uninstall|remove) do_uninstall ;;
  status|verify|doctor) do_status ;;
  diagnose|report|log) do_diagnose ;;
  *) echo "用法: sudo $0 [install|status|diagnose|uninstall]"; exit 1 ;;
esac
