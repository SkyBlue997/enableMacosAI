#!/bin/bash
#
# install.sh — RegionSpoof 一键安装器
# 在国行 Mac(Apple Silicon / macOS 27)上开启完整 Apple 智能(端侧 + PCC 云端)。
#
# 用法:
#   sudo ./install.sh             安装 / 升级(默认;重复运行即升级)
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
info(){ printf '%s==>%s %s\n' "$B" "$N" "$1"; }
ok(){   printf '%s✓ %s%s\n' "$G" "$1" "$N"; }
warn(){ printf '%s! %s%s\n' "$Y" "$1" "$N"; }
err(){  printf '%s✗ %s%s\n' "$R" "$1" "$N"; }
die(){  err "$1"; exit 1; }
hr(){   printf '%s────────────────────────────────────────────────────%s\n' "$C" "$N"; }

banner(){
  printf '%s\n' "$C"
  cat <<'EOF'
  ╔══════════════════════════════════════════════════════════╗
  ║   enableMacosAI · 国行 Mac 开启 Apple 智能  (macOS 27)   ║
  ╚══════════════════════════════════════════════════════════╝
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
LOADER_LOG="/var/log/region-kext.log"

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

# 当前区域码(如 LL/A、CH/A、ZP/A),读不到时输出空
region_code(){
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
    | sed -n 's/.*"region-info" = <\([0-9a-f]\{8\}\).*/\1/p' | head -1 | xxd -r -p 2>/dev/null | tr -cd 'A-Z/'
}
region_label(){ local r; r="$(region_code)"; echo "${r:-未知}"; }

# 当前启动系统的 APFS 卷组
boot_vg(){ diskutil info -plist / 2>/dev/null | plutil -extract APFSVolumeGroupID raw - 2>/dev/null; }

# 带超时运行(防止 bputil 之类的命令卡在交互提示上)
with_timeout(){
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  else "$@"; fi
}
# 本地启动策略。必须用 -v 指定当前卷组:有多个可启动系统(如双系统)时,
# 不带 -v 的 bputil -d 会弹出交互式选卷提示,在脚本里表现为"卡住 / 提前结束"。
bputil_policy(){
  local vg; vg="$(boot_vg)"
  if [ -n "$vg" ]; then with_timeout 20 bputil -d -v "$vg" </dev/null 2>/dev/null
  else with_timeout 20 bputil -d </dev/null 2>/dev/null; fi
}
# 第三方 kext 启动策略(smb2):enabled / disabled / unknown
kext_policy_state(){
  local p; p="$(bputil_policy | grep -E '3rd Party Kexts Status')"
  case "$p" in *Enabled*) echo enabled ;; *Disabled*) echo disabled ;; *) echo unknown ;; esac
}

# kext 指纹(二进制 + Info.plist),用于判断是否需要升级
kext_fingerprint(){
  [ -f "$1/Contents/MacOS/RegionSpoof" ] || return 0
  cat "$1/Contents/MacOS/RegionSpoof" "$1/Contents/Info.plist" 2>/dev/null | shasum -a 256 | cut -c1-16
}

# 资格文件是否陈旧:被 uchg/schg 锁住(旧教程留下),或长期未更新。陈旧时输出原因,否则返回 1。
ELIG_FILES="/private/var/db/eligibilityd/eligibility.plist /private/var/db/eligibilityd/eligibility_inputs.plist /private/var/db/eligibilityd/datastore.data /private/var/db/eligibilityd/datastore.data-shm /private/var/db/eligibilityd/datastore.data-wal /private/var/db/os_eligibility/eligibility.plist"
elig_locked_files(){
  local f fl
  for f in $ELIG_FILES; do
    [ -e "$f" ] || continue
    fl="$(stat -f %Sf "$f" 2>/dev/null)"
    case "$fl" in *uchg*|*schg*) echo "$f ($fl)" ;; esac
  done
}
elig_stale_reason(){
  [ -f "$ELIG" ] || { echo "资格文件不存在(eligibilityd 还没算出来)"; return 0; }
  local locked m bt
  locked="$(elig_locked_files)"
  if [ -n "$locked" ]; then
    echo "资格文件被 uchg/schg 锁定,eligibilityd 写不进去,读到的是旧值:"
    printf '%s\n' "$locked" | sed 's/^/      /'
    return 0
  fi
  m="$(stat -f %m "$ELIG" 2>/dev/null || echo 0)"
  bt="$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')"
  if [ "${bt:-0}" -gt 0 ] 2>/dev/null && [ "$m" -lt "$bt" ] && [ $(( $(date +%s) - m )) -gt 604800 ]; then
    echo "资格文件最后更新于 $(date -r "$m" '+%Y-%m-%d'),早于本次开机且超过 7 天,可能没有刷新"
    return 0
  fi
  return 1
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
  [ -f "$LOADER_SRC" ] || die "缺少 $LOADER_SRC —— 请在完整的项目目录里运行本脚本。"
  [ -f "$PLIST_SRC" ]  || die "缺少 $PLIST_SRC —— 请在完整的项目目录里运行本脚本。"
  # 干净系统上 /usr/local/bin 往往不存在;不建目录的话 cp 会失败,开机守护进程就会去执行一个不存在的脚本
  mkdir -p "$(dirname "$LOADER_DST")" || die "无法创建 $(dirname "$LOADER_DST")"
  cp "$LOADER_SRC" "$LOADER_DST" && chown 0:0 "$LOADER_DST" && chmod 755 "$LOADER_DST" \
    || die "无法写入 $LOADER_DST"
  cp "$PLIST_SRC" "$PLIST_DST" && chown 0:0 "$PLIST_DST" && chmod 644 "$PLIST_DST" \
    || die "无法写入 $PLIST_DST"
  launchctl bootout  "$DAEMON" >/dev/null 2>&1 || true
  if launchctl bootstrap system "$PLIST_DST" >/dev/null 2>&1 || launchctl print "$DAEMON" >/dev/null 2>&1; then
    ok "LaunchDaemon 已装(每次开机自动加载 kext;日志 $LOADER_LOG)"
  else
    warn "LaunchDaemon 注册失败;重启后需手动运行 sudo $LOADER_DST"
  fi
}

# ───────── 第三方 kext 的两道闸门 ─────────
kext_gate_help(){
  cat <<'EOS'
  这是 SIP 之外的第二道闸门。隐私与安全性里这时通常只有「启用系统扩展… / Enable System Extensions…」
  按钮、找不到 com.local.RegionSpoof 的「允许」。按以下顺序在恢复模式里打开(顺序不能反):
    1. 关机 → 长按电源键进入「选项」→ 菜单栏 实用工具 → 启动安全性实用工具
    2. 选当前系统 → 安全策略 → 选「降低安全性」,勾选
       「允许用户管理来自被认可开发者的内核扩展」→ 好
    3. 同一次恢复模式里,打开 终端,再执行: csrutil enable --without kext
       (第 2 步会重置 SIP 设置,所以这一步必须在它之后)
    4. reboot。kext 首次建 AuxKC 可能要开机两次;之后再运行: sudo ./install.sh
  注意:这样配置后启动策略会显示 Permissive,iPhone / iPad App 在 Mac 上将无法打开(系统限制)。
EOS
}

explain_load_failure(){
  local out="$1" logs
  logs="$(log show --last 5m --style compact \
            --predicate 'process == "kernelmanagerd" OR process == "syspolicyd"' 2>/dev/null \
          | grep -iE 'RegionSpoof|auxiliary extensions' | tail -20)"
  hr
  if [ "$(kext_policy_state)" = "disabled" ] || printf '%s\n%s\n' "$out" "$logs" | grep -qi 'auxiliary extensions not allowed'; then
    warn "kext 加载被启动策略拦住(第三方 kext 未允许):"
    kext_gate_help
  elif printf '%s\n' "$out" | grep -qi 'requires a reboot'; then
    warn "kext 已批准,需要重启后才会加载。重启后再运行: sudo ./install.sh"
  else
    warn "kext 需要你先手动批准一次(系统安全要求):"
    cat <<'EOS'
  1. 打开「系统设置 → 隐私与安全性」,拉到最底部
  2. 看到「com.local.RegionSpoof 被阻止」→ 点 [允许 / Allow];
     只看到「启用系统扩展… / Enable System Extensions…」按钮 → 说明第三方 kext 闸门没开,按
     「sudo ./install.sh」预检给出的恢复模式步骤处理
  3. 重启 Mac(首次可能要重启两次)
重启后本项目的 LaunchDaemon 会自动加载 kext。若仍未开启,再跑一次本脚本即可。
EOS
  fi
  [ -n "$out" ] && printf '%s（kmutil 提示:%s）%s\n' "$C" "$(printf '%s' "$out" | tail -1)" "$N"
}

# ───────── 预检 ─────────
preflight(){
  hr; info "环境预检"
  [ "$(uname -m)" = "arm64" ] || die "本方案仅支持 Apple Silicon(arm64)。"
  ok "Apple Silicon · macOS $(sw_vers -productVersion 2>/dev/null)"
  [ -d "$KEXT_SRC" ] || die "找不到 $KEXT_SRC —— 请在项目目录里运行本脚本。"
  ok "项目文件就位"

  local rc; rc="$(region_code)"
  if [ -n "$rc" ] && [ "$rc" != "CH/A" ] && [ "$rc" != "LL/A" ]; then
    warn "本机区域码是 $rc,不是国行(CH/A)。非国行机型(如港版 ZP/A)通常不需要本项目:"
    echo "  在大陆用不了多半是网络问题,见 README「故障排查」的 PCC 一节。"
    echo "  继续安装会把区域改成 LL/A,一般无害;不想装可 Ctrl+C 退出。"
    sleep 3
  fi

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
  case "$(kext_policy_state)" in
    disabled)
      err "本地启动策略未允许第三方 kext(bputil: 3rd Party Kexts Status: Disabled)。"
      kext_gate_help
      exit 1 ;;
    enabled) ok "启动策略已允许第三方 kext(smb2)" ;;
    *) warn "读不到本地启动策略(bputil),跳过第三方 kext 策略检查" ;;
  esac

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
  local old_fp new_fp upgraded=0 out
  old_fp="$(kext_fingerprint "$KEXT_DST")"; new_fp="$(kext_fingerprint "$KEXT_SRC")"
  if [ -n "$old_fp" ] && [ "$old_fp" = "$new_fp" ]; then
    ok "kext 已是当前版本,无需替换 ($KEXT_DST)"
  else
    [ -n "$old_fp" ] && { upgraded=1; info "检测到不同版本的 kext,准备升级(旧 $old_fp → 新 $new_fp)"; }
    rm -rf "$KEXT_DST"; cp -R "$KEXT_SRC" "$KEXT_DST" || die "复制 kext 失败"
    chown -R 0:0 "$KEXT_DST"
    ok "kext → $KEXT_DST  (root:wheel)"
  fi
  install_daemon
  strip_quarantine

  hr; info "加载 kext"
  if [ "$upgraded" = 1 ] && kext_loaded; then
    out="$(kmutil load -p "$KEXT_DST" 2>&1 || true)"
    warn "旧版 kext 仍在内核中运行;新版本二进制变了,系统会把它当作新扩展:"
    echo "  1. 「系统设置 → 隐私与安全性」里重新点一次 [允许 / Allow](若出现)"
    echo "  2. 重启 Mac(可能要两次);重启后运行 sudo ./install.sh status 确认"
    [ -n "$out" ] && printf '%s（kmutil 提示:%s）%s\n' "$C" "$(printf '%s' "$out" | tail -1)" "$N"
    hr; exit 0
  elif kext_loaded && region_is_LL; then
    ok "kext 已在运行,region-info 已是 LL/A"
  else
    out="$(kmutil load -p "$KEXT_DST" 2>&1 || true)"
    if region_is_LL; then
      ok "kext 加载成功,region-info = LL/A(美版)"
    else
      explain_load_failure "$out"
      exit 0
    fi
  fi

  refresh_ai
  sleep 3   # 给 eligibilityd 重算的时间
  do_status quiet
  hr
  local stale; stale="$(elig_stale_reason)"
  if [ -n "$stale" ]; then
    warn "资格结果不可信:$stale"
    echo "  处理方法见 README「资格文件被锁定」一节。"
  elif region_is_LL && [ "$(greymatter)" = "4" ]; then
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
  printf '  %-14s %s\n' "region=LL/A:"  "$(region_is_LL && echo "${G}是${N}" || echo "${R}否(当前 $(region_label))${N}")"
  printf '  %-14s %s\n' "kext 已加载:"   "$(kext_loaded && echo "${G}是${N}" || echo "${R}否${N}")"
  local gm; gm="$(greymatter)"
  local stale; stale="$(elig_stale_reason)"
  if [ -n "$stale" ]; then
    printf '  %-14s %s\n' "GREYMATTER:"   "${Y}${gm:-?}(不可信:资格文件陈旧,见 README「资格文件被锁定」)${N}"
  else
    printf '  %-14s %s\n' "GREYMATTER:"   "$([ "$gm" = "4" ] && echo "${G}4(eligible)${N}" || echo "${Y}${gm:-?}(4 才是开启)${N}")"
  fi
  if [ -f "$PLIST_DST" ] && [ -x "$LOADER_DST" ]; then
    printf '  %-14s %s\n' "开机自启:"      "${G}已装${N}"
  elif [ -f "$PLIST_DST" ]; then
    printf '  %-14s %s\n' "开机自启:"      "${R}LaunchDaemon 在,但加载脚本 $LOADER_DST 缺失(重跑 sudo ./install.sh)${N}"
  else
    printf '  %-14s %s\n' "开机自启:"      "${Y}未装${N}"
  fi
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
    echo "  SIP   : ! kext 签名检查仍开启，ad-hoc kext 加载不了"
  fi
  csr="$(csrutil status 2>/dev/null)"; printf '%s\n' "$csr" | sed 's/^/        /'
  if amfi_bypass_bootarg; then echo "  AMFI boot-arg: ! 有 amfi_get_out_of_my_way，必须移除后重启"
  else echo "  AMFI boot-arg: 未发现显式绕过（这不等于 PCC 已通过）"; fi
  echo "  AMFI launch constraints: $(amfi_launch_constraints)"
  ba="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"; [ -z "$ba" ] && ba='(空)'
  echo "  boot-args: $ba"
  echo "  本地安全策略摘要（当前启动卷组 $(boot_vg)）:"
  local bp; bp="$(bputil_policy)"
  if [ -n "$bp" ]; then
    printf '%s\n' "$bp" \
      | grep -E 'Security Mode|3rd Party Kexts|\(aux[pir]\)|System Integrity Protection|Kernel CTRR' \
      | head -10 | sed 's/^/    /'
    echo "    (aux[pir] 三项都在 = AuxKC 已建好；只有 auxp 没有 auxi/auxr = 批准了但 AuxKC 没建成)"
  else
    echo "    (bputil 无输出或超时)"
  fi
  echo

  echo "## 区域 & kext"
  region="$(ioreg -ard1 -c IOPlatformExpertDevice 2>/dev/null | plutil -p - 2>/dev/null | grep -i region-info | head -1 | sed 's/^ *//')"
  echo "  region-info: ${region:-未读到}"
  echo "    (含 4c4c2f41 = \"LL/A\" 美版✓ ；43482f41 = \"CH/A\" 国行✗，说明 kext 没生效)"
  echo "  当前区域码: $(region_label)"
  echo "  kext 已加载: $(kext_loaded && echo '是 ✓' || echo '否 ✗')"
  echo "  开机加载脚本: $([ -x "$LOADER_DST" ] && echo '在' || echo "缺失 ✗ ($LOADER_DST)")；LaunchDaemon: $([ -f "$PLIST_DST" ] && echo '在' || echo '缺失')"
  if [ -f "$LOADER_LOG" ]; then
    echo "  最近一次开机加载日志:"
    tail -6 "$LOADER_LOG" | sed 's/^/    /'
  fi
  echo

  echo "## 资格 GREYMATTER（4=已开启，2=未开启）"
  gm="$(greymatter)"
  echo "  answer = ${gm:-未读到}  $([ "$gm" = "4" ] && echo '✓ 已开启' || echo '✗ 没到 4，AI 没真正打开')"
  local stale; stale="$(elig_stale_reason)"
  if [ -n "$stale" ]; then
    echo "  ! 以下数值不可信：$stale"
  else
    echo "  资格文件更新时间: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$ELIG" 2>/dev/null)（未锁定）"
  fi
  echo "  逐项输入状态（用于定位；个别输入为 2 不代表域必然失败，以上面的 domain answer 为准）:"
  /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" "$ELIG" 2>/dev/null \
    | grep -v 'OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION' \
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
