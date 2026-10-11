#!/bin/bash
# perapp-zh.sh v2 — 全局语言保持英文(保住 Apple 智能 / 新 Siri 资格),逐 App 汉化;所有改动记录在案,revert 一键回退。
#
# 用法: ./perapp-zh.sh <阶段>
#   dry-run      只统计,不改任何东西
#   pilot        Finder / Dock / 控制中心 / 菜单栏 → 中文(先小范围验证)
#   apple        /System/Applications 下含简中资源的 Apple 自带 App(跳过 Apple 面板硬排除项与 Siri 相关)
#   shell        Spotlight / 通知中心
#   widgets      桌面 / 通知中心的 WidgetKit 小组件扩展
#   settings     系统设置:面板扩展写中文 + 常驻代理(Dock 单图标、深链接不丢目标)
#   all          = pilot + apple + shell + widgets + settings
#   third-party  /Applications 下含简中资源的第三方 App(范围大,需单独执行)
#   login        登录窗语言(系统级偏好,需要 sudo,需单独执行)
#   status       当前已应用了什么
#   check        复验 Apple 智能资格(需要 sudo 读 eligibility.plist)
#   revert       一键回退以上全部:按记录逐项恢复原值
#
# 环境变量: PERAPP_LANGS="zh-Hans-CN en-CN" 可覆盖自动推导的语言列表(首项决定界面语言)
# 状态 / 备份目录: ~/Library/Application Support/perapp-zh(独立于脚本目录,删仓库也不丢)
set -u
die(){ echo "✗ $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] && die "请不要用 sudo 运行本脚本(它改的是当前用户的偏好;需要提权的步骤会自行调用 sudo)"
[ "$(uname -m)" = arm64 ] || die "仅支持 Apple Silicon(预编译代理为 arm64)"
OSMAJ=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1); [ "${OSMAJ:-0}" -ge 14 ] 2>/dev/null || die "需要 macOS 14 或更新(实测于 macOS 27)"

SP="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/Library/Application Support/perapp-zh"; BK="$STATE/backup"; MANIFEST="$STATE/manifest.txt"
AGENT_LABEL=local.settings-zh-agent; AGENT_APP="$STATE/SettingsZH.app"; LSH="$STATE/lshandler"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"; AGENT_LOG="$HOME/Library/Logs/settings-zh-agent.log"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ELIG=/private/var/db/eligibilityd/eligibility.plist
mkdir -p "$BK/app"

BAN='com.apple.campo|com.apple.siri.launcher|com.apple.Siri|com.apple.SiriNCService'   # 新 Siri 相关:绝不触碰
EXCL='com.apple.systempreferences|com.apple.installer|com.apple.archiveutility|com.apple.AppStore|com.apple.apps.launcher|com.apple.Maps|com.apple.exposelauncher|com.apple.backup.launcher'  # Apple 面板硬排除
SKIP='com.apple.GenerativePlaygroundApp'   # AI 生成类 App:先观察
PILOT="com.apple.finder:0 com.apple.dock:0 com.apple.controlcenter:0 com.apple.systemuiserver:0"
EXTRA="com.apple.Spotlight:0 com.apple.notificationcenterui:1"

# ── 语言列表:首项 zh-Hans-<当前地区>,后接用户现有全局列表(去重)—— 与「语言与地区 → 应用程序」面板写法一致 ──
region(){ local l; l=$(defaults read -g AppleLocale 2>/dev/null | sed 's/@.*//'); case "$l" in *_*) echo "${l##*_}";; esac; }
if [ -n "${PERAPP_LANGS:-}" ]; then LANGS=($PERAPP_LANGS); else
  RG=$(region); LANGS=("zh-Hans${RG:+-$RG}")
  while read -r l; do [ -n "$l" ] && [ "$l" != "${LANGS[0]}" ] && LANGS+=("$l"); done < <(defaults read -g AppleLanguages 2>/dev/null | tr -d '(),"' | awk 'NF{print $1}')
fi
AGENT_LANGS="($(IFS=,; echo "${LANGS[*]}"))"
DONE=0; SKIPPED=0; FAILED=0

# ── 基础判定 ──
bid(){ defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null; }
has_zh(){ ls "$1/Contents/Resources" 2>/dev/null | grep -qE '^(zh_CN|zh-Hans)\.lproj$'; }
sandboxed(){ codesign -d --entitlements - "$1" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; }
banned(){ echo "$1" | grep -qE "^($BAN)$"; }
excluded(){ echo "$1" | grep -qE "^($EXCL)$"; }
siri_like(){ echo "$1" | grep -qiE 'siri|campo|intelligence|generative'; }
domain(){ if [ "$2" = 1 ]; then echo "$HOME/Library/Containers/$1/Data/Library/Preferences/$1"; else echo "$1"; fi; }
esc(){ printf '%s' "$1" | sed 's/\./\\./g'; }
registered(){ defaults read -g ApplePerAppLanguageSelectionBundleIdentifiers 2>/dev/null | grep -q "\"$1\""; }
is_absent(){ [ "$(head -c 6 "$1" 2>/dev/null)" = ABSENT ]; }

# ── 备份(每项只在第一次记录;记不到原值就记 ABSENT,回退时删除该键)──
backup_registry(){ [ -e "$BK/registry" ] || { defaults read -g ApplePerAppLanguageSelectionBundleIdentifiers > "$BK/registry" 2>/dev/null || echo ABSENT > "$BK/registry"; }; }
restore_registry(){ [ -f "$BK/registry" ] || return 0
  if is_absent "$BK/registry"; then defaults delete -g ApplePerAppLanguageSelectionBundleIdentifiers 2>/dev/null; echo "  ↺ 面板登记表已删除(原本不存在)"
  else defaults write -g ApplePerAppLanguageSelectionBundleIdentifiers "$(cat "$BK/registry")" && echo "  ↺ 面板登记表已还原"; fi; }
backup_login(){ [ -e "$BK/login-langs" ] && return 0; local out
  if out=$(sudo defaults read /Library/Preferences/.GlobalPreferences AppleLanguages 2>&1); then printf '%s\n' "$out" > "$BK/login-langs"
  elif echo "$out" | grep -q 'does not exist'; then echo ABSENT > "$BK/login-langs"
  else echo "  ✗ 读不到系统级偏好(sudo 失败?):$out"; return 1; fi; }
restore_login(){ [ -f "$BK/login-langs" ] || return 0
  if is_absent "$BK/login-langs"; then sudo defaults delete /Library/Preferences/.GlobalPreferences AppleLanguages 2>/dev/null; echo "  ↺ 登录窗语言已删除(原本不存在)"
  else sudo defaults write /Library/Preferences/.GlobalPreferences AppleLanguages "$(cat "$BK/login-langs")" && echo "  ↺ 登录窗语言已还原"; fi; }
backup_handler(){ [ -e "$BK/urlhandler" ] && return 0; local h; h=$("$LSH" get x-apple.systempreferences 2>/dev/null)
  if [ -z "$h" ] || [ "$h" = "$AGENT_LABEL" ] || [ "$h" = "(none)" ]; then h=com.apple.systempreferences; fi; echo "$h" > "$BK/urlhandler"; }

# ── 逐 App 写入 / 恢复 ──
set_lang(){ # $1=bundle id  $2=沙盒(0/1)  [$3=noreg:不登记到面板]
  [ -z "$1" ] && return 0
  if banned "$1"; then echo "  ✗ 拒绝 $1(Siri 相关)"; return 0; fi
  backup_registry
  if [ "$2" = 1 ] && [ ! -d "$HOME/Library/Containers/$1" ]; then echo "  ↷ 跳过 $1(沙盒容器不存在=从未运行,首次运行后再加)"; SKIPPED=$((SKIPPED+1)); return 0; fi
  local d v; d="$(domain "$1" "$2")"; [ "$2" = 1 ] && mkdir -p "$(dirname "$d")"
  if [ ! -e "$BK/app/$1.langs" ]; then if v=$(defaults read "$d" AppleLanguages 2>/dev/null); then printf '%s\n' "$v" > "$BK/app/$1.langs"; else echo ABSENT > "$BK/app/$1.langs"; fi; fi
  if defaults write "$d" AppleLanguages -array "${LANGS[@]}" 2>/dev/null; then
    [ "${3:-}" = noreg ] || registered "$1" || defaults write -g ApplePerAppLanguageSelectionBundleIdentifiers -array-add "$1"
    grep -q "^$(esc "$1")|" "$MANIFEST" 2>/dev/null || echo "$1|$2" >> "$MANIFEST"
    echo "  ✓ $1 → ${LANGS[0]}$([ "$2" = 1 ] && echo '(容器路径)')"; DONE=$((DONE+1))
  else echo "  ✗ 写入失败 $1"; FAILED=$((FAILED+1)); fi
}
restore_lang(){ local d b; d="$(domain "$1" "$2")"; b="$BK/app/$1.langs"
  if [ -f "$b" ] && ! is_absent "$b"; then
    if defaults write "$d" AppleLanguages "$(cat "$b")" 2>/dev/null; then echo "  ↺ $1 恢复为原有 per-app 语言"; return 0; fi
    echo "  ! $1 原值写回失败,改为删除"; fi
  if defaults read "$d" AppleLanguages >/dev/null 2>&1; then
    if defaults delete "$d" AppleLanguages 2>/dev/null; then echo "  ↺ $1 已还原"; return 0; else echo "  ✗ $1 删除失败"; return 1; fi
  else echo "  · $1 已无 per-app 语言"; return 0; fi
}
apply_list(){ local a id; while read -r a; do id=$(bid "$a"); [ -z "$id" ] && continue; banned "$id" && continue
  echo "$id" | grep -qE "^($SKIP)$" && { echo "  ↷ 跳过 $id(AI 生成类,先观察)"; SKIPPED=$((SKIPPED+1)); continue; }
  [ "$1" = skipexcl ] && excluded "$id" && continue
  if sandboxed "$a"; then set_lang "$id" 1; else set_lang "$id" 0; fi; done; }
apple_apps(){ for a in /System/Applications/*.app /System/Applications/Utilities/*.app; do has_zh "$a" && echo "$a"; done; }
third_apps(){ for a in /Applications/*.app; do has_zh "$a" && echo "$a"; done; }
pane_appexes(){ local x; for x in /System/Library/ExtensionKit/Extensions/*.appex; do defaults read "$x/Contents/Info" EXAppExtensionAttributes 2>/dev/null | grep -q 'com.apple.Settings.extension.ui' && echo "$x"; done; }
kill_panes(){ pane_appexes | while read -r x; do pkill -f "/$(basename "$x")/" 2>/dev/null; done; }
quit_settings(){ pgrep -xq "System Settings" || return 0; osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq "System Settings" || return 0; sleep 0.5; done; pkill -x "System Settings" 2>/dev/null; }
restart_shell(){ killall Finder Dock ControlCenter SystemUIServer 2>/dev/null; echo "  · Finder / Dock / 菜单栏已重启以应用"; }
summary(){ echo "  合计:成功 $DONE,跳过 $SKIPPED,失败 $FAILED"; }

# ── 系统设置常驻代理 ──
install_agent(){
  echo "── 常驻代理(拦截无参启动 → 带 -AppleLanguages 重开;接管 x-apple.systempreferences 深链接)──"
  [ -d "$SP/SettingsZH.app" ] && { rm -rf "$AGENT_APP"; cp -R "$SP/SettingsZH.app" "$AGENT_APP"; }
  [ -f "$SP/lshandler" ] && cp -f "$SP/lshandler" "$LSH"
  if [ ! -x "$AGENT_APP/Contents/MacOS/SettingsZH" ] || [ ! -x "$LSH" ]; then
    command -v swiftc >/dev/null 2>&1 || { echo "  ✗ 缺少预编译的 SettingsZH.app / lshandler,且没有 swiftc(装 Xcode Command Line Tools 后重试)"; return 1; }
    echo "  · 从源码编译代理…"; mkdir -p "$AGENT_APP/Contents/MacOS"
    swiftc -O -target arm64-apple-macos14.0 -o "$AGENT_APP/Contents/MacOS/SettingsZH" "$SP/settings-zh-agent.swift" || return 1
    cp -f "$SP/SettingsZH-Info.plist" "$AGENT_APP/Contents/Info.plist" || return 1
    swiftc -O -target arm64-apple-macos14.0 -o "$LSH" "$SP/lshandler.swift" || return 1
    codesign -fs - "$AGENT_APP" >/dev/null 2>&1
  fi
  xattr -dr com.apple.quarantine "$AGENT_APP" "$LSH" 2>/dev/null
  "$LSREG" -f "$AGENT_APP" >/dev/null 2>&1
  backup_handler
  local exe; exe=$(printf '%s' "$AGENT_APP/Contents/MacOS/SettingsZH" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key><array><string>$exe</string></array>
  <key>EnvironmentVariables</key><dict><key>SETTINGS_ZH_LANGS</key><string>$AGENT_LANGS</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null; pkill -x SettingsZH 2>/dev/null; sleep 0.5
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" || { echo "  ✗ launchctl bootstrap 失败"; return 1; }
  sleep 1.5
  if launchctl print "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null | grep -q 'state = running'; then echo "  ✓ 代理已常驻(登录自启,KeepAlive;日志 $AGENT_LOG)"; else echo "  ✗ 代理未运行,请看 $AGENT_LOG"; return 1; fi
  "$LSH" set x-apple.systempreferences "$AGENT_LABEL" >/dev/null 2>&1
  if [ "$("$LSH" get x-apple.systempreferences 2>/dev/null)" = "$AGENT_LABEL" ]; then echo "  ✓ 深链接处理器已接管(权限弹窗 / Spotlight 的「打开系统设置」也是中文并落到目标面板)"
  else echo "  ✗ 深链接处理器设置失败(深链接会打开默认面板)"; return 1; fi
}
remove_agent(){
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null; rm -f "$AGENT_PLIST"; pkill -x SettingsZH 2>/dev/null
  if [ -x "$LSH" ]; then local h; h=$(cat "$BK/urlhandler" 2>/dev/null); [ -z "$h" ] && h=com.apple.systempreferences
    "$LSH" set x-apple.systempreferences "$h" >/dev/null 2>&1; echo "  ↺ 深链接处理器 → $("$LSH" get x-apple.systempreferences 2>/dev/null)"; fi
  [ -d "$AGENT_APP" ] && "$LSREG" -u "$AGENT_APP" >/dev/null 2>&1; echo "  ↺ 常驻代理已卸载"
}

check(){
  echo "── 资格复验(应仍为 3/3/3 与 4/4;需要 sudo 读 eligibility.plist)──"
  local st; st=$(sudo /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" "$ELIG" 2>/dev/null) || { echo "  · 读取失败(未授权 sudo 或文件不存在),跳过"; return 0; }
  echo "$st" | grep -E 'LANGUAGE|MATCH' | sed 's/^ */  /'
  local D; for D in GREYMATTER AMERICIUM; do printf "  %-10s answer=%s\n" "$D" "$(sudo /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_$D:os_eligibility_answer_t" "$ELIG" 2>/dev/null)"; done
}
status(){
  echo "语言列表: ${LANGS[*]}   代理参数: $AGENT_LANGS"
  echo "全局 AppleLanguages(必须保持英文在前): $(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n ')   Siri: $(defaults read com.apple.assistant.backedup 'Session Language' 2>/dev/null || echo 未设置)"
  echo "已汉化条目: $(grep -c '' "$MANIFEST" 2>/dev/null || echo 0)   manifest: $MANIFEST"
  echo "备份: 登记表 $([ -e "$BK/registry" ] && echo 有 || echo 无) / 登录窗 $([ -e "$BK/login-langs" ] && echo 有 || echo 无) / 深链接处理器 $([ -e "$BK/urlhandler" ] && echo 有 || echo 无) / per-app 原值 $(ls "$BK/app" 2>/dev/null | wc -l | tr -d ' ') 份"
  echo "代理: $(launchctl print "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null | grep -q 'state = running' && echo 运行中 || echo 未安装/未运行)   深链接处理器: $([ -x "$LSH" ] && "$LSH" get x-apple.systempreferences 2>/dev/null || echo '?')"
  echo "已归档回退记录: $(ls -d "$STATE"/reverted-* 2>/dev/null | wc -l | tr -d ' ') 次"
}
usage(){ sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  dry-run)
    echo "【语言列表】 ${LANGS[*]}(地区来自 AppleLocale=$(defaults read -g AppleLocale 2>/dev/null);可用 PERAPP_LANGS 覆盖)"
    echo "【pilot 系统外壳】 ${PILOT//:0/}"
    n=0; s=0; xl=""; bl=""
    while read -r a; do id=$(bid "$a"); [ -z "$id" ] && continue
      if banned "$id"; then bl="$bl $(basename "$a" .app)"; continue; fi
      if excluded "$id"; then xl="$xl $(basename "$a" .app)"; continue; fi
      if sandboxed "$a"; then s=$((s+1)); else n=$((n+1)); fi; done < <(apple_apps)
    echo "【apple 自带 App】 非沙盒 $n 个(直接写域)+ 沙盒 $s 个(写容器路径)"
    echo "   跳过·Apple 面板硬排除:$xl"; echo "   ✗禁止·Siri 相关:$bl"
    echo "【shell】 ${EXTRA//:[01]/}"
    echo "【widgets】 $(find /System/Applications /System/Library/CoreServices /Applications -maxdepth 7 -name '*.appex' 2>/dev/null | while read -r x; do defaults read "$x/Contents/Info" NSExtension 2>/dev/null | grep -q 'com.apple.widgetkit-extension' && has_zh "$x" && echo x; done | wc -l | tr -d ' ') 个 WidgetKit 小组件扩展含简中"
    echo "【settings】 $(pane_appexes | while read -r x; do has_zh "$x" && echo x; done | wc -l | tr -d ' ') 个系统设置面板扩展含简中 + 常驻代理"
    echo "【third-party】 $(third_apps | wc -l | tr -d ' ') 个第三方 App 含简中(需单独执行)"
    echo "【login】 登录窗 → ${LANGS[*]}(系统级,需 sudo,需单独执行)"
    echo "【当前全局(必须保持)】 $(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n ')  Siri=$(defaults read com.apple.assistant.backedup 'Session Language' 2>/dev/null || echo 未设置)" ;;
  pilot)  for e in $PILOT; do set_lang "${e%:*}" "${e#*:}"; done; restart_shell; summary; check ;;
  apple)  apply_list skipexcl < <(apple_apps); summary; check ;;
  shell)  for e in $EXTRA; do set_lang "${e%:*}" "${e#*:}"; done; killall Spotlight NotificationCenter 2>/dev/null; summary; check ;;
  third-party) apply_list keep < <(third_apps); summary; check ;;
  login)  sudo -n true 2>/dev/null || echo "  (写系统级偏好需要管理员密码)"; backup_login || exit 1
          if sudo defaults write /Library/Preferences/.GlobalPreferences AppleLanguages -array "${LANGS[@]}"; then echo "  ✓ 登录窗 → ${LANGS[0]}(原值已备份)"; else echo "  ✗ 写入失败"; FAILED=1; fi; check ;;
  widgets) find /System/Applications /System/Library/CoreServices /Applications -maxdepth 7 -name '*.appex' 2>/dev/null | while read -r x; do
            defaults read "$x/Contents/Info" NSExtension 2>/dev/null | grep -q 'com.apple.widgetkit-extension' || continue; has_zh "$x" || continue; id=$(bid "$x"); [ -n "$id" ] && echo "$id"; done | sort -u > "$STATE/widgets.ids"
          while read -r id; do siri_like "$id" && { echo "  ✗ 跳过 $id"; continue; }; set_lang "$id" 1 noreg; done < "$STATE/widgets.ids"
          killall chronod NotificationCenter 2>/dev/null; summary; check ;;
  settings)
    echo "── 系统设置面板扩展(容器域,eligibilityd 不读)──"
    while read -r x; do has_zh "$x" || continue; id=$(bid "$x"); [ -z "$id" ] && continue; siri_like "$id" && { echo "  ✗ 跳过 $id"; continue; }
      set_lang "$id" 1 noreg >/dev/null; done < <(pane_appexes); kill_panes; echo "  ✓ 面板扩展已写入(已记入 manifest)"
    install_agent || FAILED=$((FAILED+1)); quit_settings; summary; check
    echo "  提示:Dock 里请钉真正的「系统设置」(单图标);任何入口打开都会是中文" ;;
  all) for s in pilot apple shell widgets settings; do echo "════ $s ════"; bash "$0" "$s" || FAILED=$((FAILED+1)); done
       echo "(third-party 与 login 影响面大 / 需 sudo,请按需单独执行)" ;;
  status) status ;;
  check)  check ;;
  revert)
    echo "── 回退 per-app 语言 ──"; n=0; rf=0
    if [ -f "$MANIFEST" ]; then while IFS='|' read -r id sb; do [ -z "$id" ] && continue; n=$((n+1)); restore_lang "$id" "$sb" || rf=$((rf+1)); done < "$MANIFEST"; echo "  处理 $n 项,失败 $rf"
    else echo "  · 无 manifest(未应用过或已回退)"; fi
    echo "── 回退全局项 ──"; restore_registry; restore_login || rf=$((rf+1)); remove_agent; quit_settings; kill_panes
    killall Finder Dock ControlCenter SystemUIServer Spotlight NotificationCenter chronod 2>/dev/null; echo "  · Finder / Dock / 菜单栏 / 通知中心已重启以应用"
    if [ "$rf" = 0 ]; then ts=$(date +%Y%m%d-%H%M%S); mkdir -p "$STATE/reverted-$ts"; [ -f "$MANIFEST" ] && mv "$MANIFEST" "$STATE/reverted-$ts/"
      mv "$BK" "$STATE/reverted-$ts/backup"; mkdir -p "$BK/app"; echo "  ✓ 已全部回退;记录归档到 $STATE/reverted-$ts"
    else FAILED=$rf; echo "  ✗ $rf 项失败;manifest 与备份原样保留,处理后可重跑 revert"; fi
    check ;;
  *) usage; exit 1 ;;
esac
[ "$FAILED" = 0 ]
