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
ELIG_DIR="/private/var/db/eligibilityd"
OS_ELIG_DIR="/private/var/db/os_eligibility"
ELIG="$ELIG_DIR/eligibility.plist"
INPUT_ELIG="$ELIG_DIR/eligibility_inputs.plist"
OS_ELIG="$OS_ELIG_DIR/eligibility.plist"
COUNTRYD="/private/var/db/com.apple.countryd/countryCodeCache.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"

# ───────── 状态探测 ─────────
region_is_LL(){ ioreg -ard1 -c IOPlatformExpertDevice 2>/dev/null | plutil -p - 2>/dev/null | grep -q 4c4c2f41; }
kext_loaded(){  kmutil showloaded --no-kernel-components 2>/dev/null | grep -qi regionspoof; }
greymatter(){   "$PLISTBUDDY" -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t" "$ELIG" 2>/dev/null; }
gm_input(){     "$PLISTBUDDY" -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status:$1" "$ELIG" 2>/dev/null; }
sip_off(){      csrutil status 2>/dev/null | grep -qi disabled; }
amfi_off(){     nvram boot-args 2>/dev/null | grep -q amfi_get_out_of_my_way; }

gm_country_stuck(){
  local billing location
  billing="$(gm_input OS_ELIGIBILITY_INPUT_COUNTRY_BILLING)"
  location="$(gm_input OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION)"
  [ "$billing" = "2" ] || [ "$location" = "2" ]
}

# ───────── AI 守护进程刷新 ─────────
refresh_ai(){
  info "刷新 Apple 智能守护进程(清掉旧区域缓存)…"
  for d in countryd eligibilityd modelcatalogd modelmanagerd; do
    launchctl kickstart -k "system/com.apple.$d" >/dev/null 2>&1 || true
  done
}

restart_user_ai(){
  local uid
  uid="${SUDO_UID:-}"
  [ -n "$uid" ] && [ "$uid" != "0" ] || uid="$(stat -f %u /dev/console 2>/dev/null || true)"
  [ -n "$uid" ] || return 0
  for svc in com.apple.intelligenceflowd com.apple.assistantd com.apple.siriactionsd; do
    launchctl kickstart -k "gui/$uid/$svc" >/dev/null 2>&1 || true
  done
}

# macOS 27 上 eligibilityd/countryd 有时会在 region-info 已是 LL/A 后仍沿用旧的
# CN 缓存,表现为 COUNTRY_BILLING / COUNTRY_LOCATION 卡在 2。
unlock_region_state(){
  local p
  for p in "$ELIG" "$INPUT_ELIG" "$OS_ELIG" "$COUNTRYD" \
           "$ELIG_DIR/datastore.data" "$ELIG_DIR/datastore.data-shm" "$ELIG_DIR/datastore.data-wal"; do
    [ -e "$p" ] || continue
    chflags nouchg "$p" >/dev/null 2>&1 || true
    chmod u+rw,g+rw "$p" >/dev/null 2>&1 || true
  done
}

lock_region_state(){
  local p
  [ "${REGIONSPOOF_NO_CACHE_LOCK:-0}" = "1" ] && { warn "按 REGIONSPOOF_NO_CACHE_LOCK=1 跳过缓存文件锁定。"; return; }
  for p in "$ELIG" "$INPUT_ELIG" "$OS_ELIG" "$COUNTRYD"; do
    [ -f "$p" ] || continue
    chmod 444 "$p" >/dev/null 2>&1 || true
    chflags uchg "$p" >/dev/null 2>&1 || true
  done
}

backup_region_state(){
  local stamp dst
  stamp="$(date +%Y%m%d-%H%M%S)"
  dst="$ELIG_DIR/RegionSpoof-backup-$stamp"
  mkdir -p "$dst" >/dev/null 2>&1 || { warn "无法创建备份目录 $dst"; return 1; }
  if [ -f "$ELIG" ]       && ! cp -p "$ELIG"       "$dst/eligibilityd.eligibility.plist" 2>/dev/null; then warn "备份 $ELIG 失败"; return 1; fi
  if [ -f "$INPUT_ELIG" ] && ! cp -p "$INPUT_ELIG" "$dst/eligibilityd.inputs.plist"       2>/dev/null; then warn "备份 $INPUT_ELIG 失败"; return 1; fi
  if [ -f "$OS_ELIG" ]    && ! cp -p "$OS_ELIG"    "$dst/os_eligibility.plist"            2>/dev/null; then warn "备份 $OS_ELIG 失败"; return 1; fi
  if [ -f "$COUNTRYD" ]   && ! cp -p "$COUNTRYD"   "$dst/countryCodeCache.plist"          2>/dev/null; then warn "备份 $COUNTRYD 失败"; return 1; fi
  ok "原始缓存已备份到 $dst"
  return 0
}

stop_region_state_daemons(){
  info "停止 eligibilityd / countryd,避免修复时被马上重写…"
  launchctl bootout system/com.apple.eligibilityd >/dev/null 2>&1 || true
  launchctl bootout system/com.apple.countryd >/dev/null 2>&1 || true
  pkill -9 eligibilityd >/dev/null 2>&1 || true
  pkill -9 countryd >/dev/null 2>&1 || true
}

start_region_state_daemons(){
  launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.countryd.plist >/dev/null 2>&1 || true
  launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.eligibilityd.plist >/dev/null 2>&1 || true
  launchctl kickstart -k system/com.apple.countryd >/dev/null 2>&1 || true
  launchctl kickstart -k system/com.apple.eligibilityd >/dev/null 2>&1 || true
}

set_plist_existing(){
  local plist path val label
  plist="$1"; path="$2"; val="$3"; label="$4"
  [ -f "$plist" ] || return 0
  if "$PLISTBUDDY" -c "Print $path" "$plist" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Set $path $val" "$plist" >/dev/null 2>&1 && printf '    %s = %s\n' "$label" "$val"
  fi
}

ensure_answer(){
  local plist domain val
  plist="$1"; domain="$2"; val="$3"
  [ -f "$plist" ] || return 0
  "$PLISTBUDDY" -c "Print :$domain" "$plist" >/dev/null 2>&1 || \
    "$PLISTBUDDY" -c "Add :$domain dict" "$plist" >/dev/null 2>&1 || return 0
  if "$PLISTBUDDY" -c "Print :$domain:os_eligibility_answer_t" "$plist" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Set :$domain:os_eligibility_answer_t $val" "$plist" >/dev/null 2>&1 || return 0
  else
    "$PLISTBUDDY" -c "Add :$domain:os_eligibility_answer_t integer $val" "$plist" >/dev/null 2>&1 || return 0
  fi
  printf '    %s answer_t = %s\n' "$domain" "$val"
}

set_answer_existing(){
  local plist domain val
  plist="$1"; domain="$2"; val="$3"
  set_plist_existing "$plist" ":$domain:os_eligibility_answer_t" "$val" "$domain answer_t"
}

set_domain_statuses(){
  local domain key
  domain="$1"; shift
  for key in "$@"; do
    set_plist_existing "$ELIG" ":$domain:status:$key" 3 "$domain:$key"
  done
}

repair_eligibility_domains(){
  info "修复 Apple 智能 eligibility 状态…"
  set_domain_statuses OS_ELIGIBILITY_DOMAIN_GREYMATTER \
    OS_ELIGIBILITY_INPUT_COUNTRY_BILLING \
    OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION \
    OS_ELIGIBILITY_INPUT_DEVICE_AND_SIRI_LANGUAGE_MATCH \
    OS_ELIGIBILITY_INPUT_DEVICE_CLASS \
    OS_ELIGIBILITY_INPUT_DEVICE_LANGUAGE \
    OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE \
    OS_ELIGIBILITY_INPUT_DEVICE_SIRI_MODE \
    OS_ELIGIBILITY_INPUT_EXTERNAL_BOOT_DRIVE \
    OS_ELIGIBILITY_INPUT_GENERATIVE_MODEL_SYSTEM \
    OS_ELIGIBILITY_INPUT_SHARED_IPAD \
    OS_ELIGIBILITY_INPUT_SIRI_LANGUAGE

  set_domain_statuses OS_ELIGIBILITY_DOMAIN_FOUNDATION_MODELS \
    OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE

  set_domain_statuses OS_ELIGIBILITY_DOMAIN_AMERICIUM \
    OS_ELIGIBILITY_INPUT_COUNTRY_BILLING \
    OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION \
    OS_ELIGIBILITY_INPUT_DEVICE_AND_SIRI_LANGUAGE_MATCH \
    OS_ELIGIBILITY_INPUT_DEVICE_CLASS \
    OS_ELIGIBILITY_INPUT_DEVICE_LANGUAGE \
    OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE \
    OS_ELIGIBILITY_INPUT_DEVICE_SIRI_MODE \
    OS_ELIGIBILITY_INPUT_EXTERNAL_BOOT_DRIVE \
    OS_ELIGIBILITY_INPUT_HAS_LINWOOD \
    OS_ELIGIBILITY_INPUT_SHARED_IPAD \
    OS_ELIGIBILITY_INPUT_SIRI_LANGUAGE

  set_domain_statuses OS_ELIGIBILITY_DOMAIN_CALCIUM \
    OS_ELIGIBILITY_INPUT_CHINA_CELLULAR \
    OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE

  set_domain_statuses OS_ELIGIBILITY_DOMAIN_DUBNIUM \
    OS_ELIGIBILITY_INPUT_COUNTRY_BILLING \
    OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION \
    OS_ELIGIBILITY_INPUT_DEVICE_AND_SIRI_LANGUAGE_MATCH \
    OS_ELIGIBILITY_INPUT_DEVICE_CLASS \
    OS_ELIGIBILITY_INPUT_DEVICE_LANGUAGE \
    OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE \
    OS_ELIGIBILITY_INPUT_SIRI_LANGUAGE

  set_domain_statuses OS_ELIGIBILITY_DOMAIN_PERSONAL_QA OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE
  set_domain_statuses OS_ELIGIBILITY_DOMAIN_SIRI_WITH_APP_INTENTS OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE
  set_domain_statuses OS_ELIGIBILITY_DOMAIN_FORCED_SHUTTER_SOUND \
    OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION \
    OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE

  for domain in \
    OS_ELIGIBILITY_DOMAIN_GREYMATTER \
    OS_ELIGIBILITY_DOMAIN_FOUNDATION_MODELS \
    OS_ELIGIBILITY_DOMAIN_TERBIUM \
    OS_ELIGIBILITY_DOMAIN_AMERICIUM \
    OS_ELIGIBILITY_DOMAIN_CALCIUM \
    OS_ELIGIBILITY_DOMAIN_DUBNIUM \
    OS_ELIGIBILITY_DOMAIN_PERSONAL_QA \
    OS_ELIGIBILITY_DOMAIN_SIRI_WITH_APP_INTENTS; do
    set_answer_existing "$ELIG" "$domain" 4
  done

  ensure_answer "$OS_ELIG" OS_ELIGIBILITY_DOMAIN_SIRI_MODE 4
  ensure_answer "$OS_ELIG" OS_ELIGIBILITY_DOMAIN_SIRI_MODE_NEEDS_CONSENT 4

  for domain in \
    OS_ELIGIBILITY_DOMAIN_STRONTIUM \
    OS_ELIGIBILITY_DOMAIN_XCODE_LLM \
    OS_ELIGIBILITY_DOMAIN_AI_LABELING \
    OS_ELIGIBILITY_DOMAIN_SWIFT_ASSIST; do
    set_answer_existing "$OS_ELIG" "$domain" 4
  done
}

repair_countryd(){
  local py changed
  [ -f "$COUNTRYD" ] || { warn "未找到 countryd 缓存,跳过地区缓存修复。"; return; }
  py="$(command -v python3 || true)"
  [ -n "$py" ] || { warn "未找到 python3,无法结构化修改 countryd plist。"; return; }
  changed="$("$py" - "$COUNTRYD" <<'PY' 2>/dev/null
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)

changed = 0

def force_us(obj):
    global changed
    if isinstance(obj, dict):
        for key in list(obj.keys()):
            value = obj[key]
            key_name = key.lower() if isinstance(key, str) else ""
            if key_name in ("countrycode", "country_code"):
                if value != "US":
                    changed += 1
                obj[key] = "US"
            else:
                obj[key] = force_us(value)
        return obj
    if isinstance(obj, list):
        for i, value in enumerate(obj):
            obj[i] = force_us(value)
        return obj
    if isinstance(obj, str):
        if obj == "CN":
            changed += 1
            return "US"
        if obj == "CHN":
            changed += 1
            return "USA"
    return obj

data = force_us(data)
with open(path, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

print(changed)
PY
)"
  if [ -n "$changed" ]; then
    ok "countryd 地区缓存已改为 US($changed 处)"
  else
    warn "countryd 缓存未能修改,稍后可重跑 diagnose 看是否仍有 CN。"
  fi
}

repair_region_caches(){
  hr; info "修复 eligibilityd / countryd 旧区域缓存"
  region_is_LL || warn "当前 region-info 还不是 LL/A;建议先批准并加载 kext 后再修复缓存。"
  stop_region_state_daemons
  unlock_region_state
  if ! backup_region_state; then
    start_region_state_daemons
    die "备份失败,已停止修复。"
  fi
  rm -f "$ELIG_DIR/datastore.data" "$ELIG_DIR/datastore.data-shm" "$ELIG_DIR/datastore.data-wal" 2>/dev/null || true
  repair_eligibility_domains
  repair_countryd
  lock_region_state
  start_region_state_daemons
  restart_user_ai
  refresh_ai
  sleep 3
  ok "缓存修复完成。若 GREYMATTER 仍未变 4,请重启后再跑一次 status。"
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
  if region_is_LL && [ "$(greymatter)" != "4" ] && gm_country_stuck; then
    warn "检测到 #26 常见症状: COUNTRY_BILLING / COUNTRY_LOCATION 仍卡在 2,开始修复旧区域缓存…"
    repair_region_caches
  fi
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
  unlock_region_state
  rm -f "$ELIG_DIR/datastore.data" "$ELIG_DIR/datastore.data-shm" "$ELIG_DIR/datastore.data-wal" 2>/dev/null || true
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
  local billing location
  billing="$(gm_input OS_ELIGIBILITY_INPUT_COUNTRY_BILLING)"
  location="$(gm_input OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION)"
  printf '  %-14s %s\n' "BILLING:"      "$([ "$billing" = "3" ] && echo "${G}3${N}" || echo "${Y}${billing:-?}${N}")"
  printf '  %-14s %s\n' "LOCATION:"     "$([ "$location" = "3" ] && echo "${G}3${N}" || echo "${Y}${location:-?}${N}")"
  printf '  %-14s %s\n' "开机自启:"      "$([ -f "$PLIST_DST" ] && echo "${G}已装${N}" || echo "${Y}未装${N}")"
  if [ "$gm" != "4" ] && gm_country_stuck; then
    warn "BILLING / LOCATION 卡在 2,可运行: sudo ./install.sh repair"
  fi
  [ "${1:-}" = "quiet" ] || hr
}

# ───────── 诊断报告(报 issue 用;纯文本,无颜色,方便整段复制)─────────
do_diagnose(){
  local osv osb model csr ba region gm kb hum country_lines
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

  echo "## 国家/地区缓存（countryd）"
  if [ -f "$COUNTRYD" ]; then
    country_lines="$(plutil -p "$COUNTRYD" 2>/dev/null | grep -E '"CN"|"CHN"|"US"|CountryCode' | head -20 || true)"
    if [ -n "$country_lines" ]; then
      printf '%s\n' "$country_lines" | sed 's/^/  /'
    else
      echo "  未发现 CN/US/CountryCode 明显条目"
    fi
  else
    echo "  未找到 $COUNTRYD"
  fi
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
  repair|fix|deepfix) repair_region_caches; do_status ;;
  uninstall|remove) do_uninstall ;;
  status|verify|doctor) do_status ;;
  diagnose|report|log) do_diagnose ;;
  *) echo "用法: sudo $0 [install|repair|status|diagnose|uninstall]"; exit 1 ;;
esac
