#!/bin/bash
#
# pcc-diagnose.sh — read-only Private Cloud Compute health classifier.
# It deliberately prints only status markers, never request payloads or account data.
#
set -uo pipefail

if [ -t 1 ]; then
  G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; B=$'\033[0;34m'; N=$'\033[0m'
else G=''; Y=''; R=''; B=''; N=''; fi

info(){ printf '%s==>%s %s\n' "$B" "$N" "$1"; }
ok(){ printf '%s✓ %s%s\n' "$G" "$1" "$N"; }
warn(){ printf '%s! %s%s\n' "$Y" "$1" "$N"; }
err(){ printf '%s✗ %s%s\n' "$R" "$1" "$N"; }

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [ "$(id -u)" -ne 0 ] && [ -z "${PCC_DIAG_LOG_FILE:-}" ]; then
  exec sudo "$SELF" "$@"
fi

SINCE="${PCC_SINCE:-30m}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since)
      [ "$#" -ge 2 ] || { err "--since 后缺少时间，例如 30m / 2h"; exit 2; }
      SINCE="$2"; shift 2 ;;
    -h|--help)
      echo "用法: sudo $0 [--since 30m]"
      echo "测试夹具: PCC_DIAG_LOG_FILE=/path/to/log $0"
      exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

if ! [[ "$SINCE" =~ ^[0-9]+[smhd]$ ]]; then
  err "无效时间范围: $SINCE（示例: 30m / 2h）"; exit 2
fi

TMP_DIR="$(mktemp -d /tmp/regionspoof-pcc.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
LOG_FILE="$TMP_DIR/combined.log"
CONTEXT_FILE="$TMP_DIR/request-context.log"

if [ -n "${PCC_DIAG_LOG_FILE:-}" ]; then
  cp "$PCC_DIAG_LOG_FILE" "$LOG_FILE"
else
  log show --style compact --info --last "$SINCE" \
    --predicate '(process == "privatecloudcomputed" OR process == "networkserviceproxy" OR process == "generativeexperiencesd")' \
    >"$LOG_FILE" 2>/dev/null || true
fi

timestamp_of(){ printf '%s\n' "$1" | awk '{print $1 " " $2}' | sed 's/[[:space:]]*$//'; }
epoch_of(){
  local stamp
  stamp="$(timestamp_of "$1" | sed -E 's/\.[0-9]+$//')"
  date -j -f '%Y-%m-%d %H:%M:%S' "$stamp" '+%s' 2>/dev/null || echo 0
}
line_number_of_last(){ grep -inE "$1" "$LOG_FILE" 2>/dev/null | tail -1 | cut -d: -f1; }

terminal_line_no="$(line_number_of_last 'Ropes request (finished successfully|failed)')"
terminal_line=""
if [ -n "$terminal_line_no" ]; then
  terminal_line="$(sed -n "${terminal_line_no}p" "$LOG_FILE")"
  context_start=$((terminal_line_no > 300 ? terminal_line_no - 300 : 1))
  sed -n "${context_start},${terminal_line_no}p" "$LOG_FILE" >"$CONTEXT_FILE"
else
  : >"$CONTEXT_FILE"
fi

token_ok_no="$(line_number_of_last 'Received [0-9]+/[0-9]+/[0-9]+ tokens|Token fetch successful')"
token_bad_no="$(line_number_of_last 'no key found in configuration for issuer name|failed to (fetch|get).*tokens|token request failed')"
app_timeout_no="$(line_number_of_last 'workload timed out before completing|GenerativeError Code=5040000')"
app_timeout_line=""
[ -n "$app_timeout_no" ] && app_timeout_line="$(sed -n "${app_timeout_no}p" "$LOG_FILE")"
inline_line="$(grep -iE 'inline nodes ready|totalReceived=' "$CONTEXT_FILE" 2>/dev/null | tail -1)"
inline_total="$(printf '%s\n' "$inline_line" | sed -nE 's/.*totalReceived[=:][[:space:]]*([0-9]+).*/\1/p')"
aks_count="$(grep -icE 'AppleKeyStore|kIOReturnNotPermitted|AKS.*Locked' "$CONTEXT_FILE" 2>/dev/null || true)"
metadata_file="$CONTEXT_FILE"
[ -s "$metadata_file" ] || metadata_file="$LOG_FILE"
use_case="$(grep -ioE 'useCaseIdentifier[=:][[:space:]]*[A-Za-z0-9._-]+' "$metadata_file" 2>/dev/null | tail -1 | sed -E 's/.*[=:][[:space:]]*//')"
client_app="$(grep -ioE 'clientApplicationIdentifier[=:][[:space:]]*com\.apple\.[A-Za-z0-9._-]+' "$metadata_file" 2>/dev/null \
  | sed -E 's/.*[=:][[:space:]]*//' | grep -v '^com\.apple\.suggestd$' | tail -1)"

store_db=""
available_nodes=""
bundle_count=""
prefetch_stalled=0
prefetch_age=0
if [ -z "${PCC_DIAG_LOG_FILE:-}" ] && command -v sqlite3 >/dev/null 2>&1; then
  store_db="$(lsof -c privatecloudcomputed -Fn 2>/dev/null | sed -n 's/^n//p' \
    | grep -m1 '/attestationstore_v3/db.sqlite$' || true)"
  if [ -n "$store_db" ]; then
    available_nodes="$(sqlite3 -readonly "$store_db" 'SELECT count(*) FROM ZAVAILABLENODE;' 2>/dev/null || true)"
    bundle_count="$(sqlite3 -readonly "$store_db" 'SELECT count(*) FROM ZNODEBUNDLE;' 2>/dev/null || true)"
  fi
fi

prefetch_start_no="$(line_number_of_last 'executing prefetch request, prewarm=')"
prefetch_end_no="$(line_number_of_last 'PrefetchRequest.*(finished|completed|failed|cancelled|stored|inserted)')"
if [ -n "$prefetch_start_no" ] && [ -n "$available_nodes" ] && [ "$available_nodes" -eq 0 ] 2>/dev/null \
   && { [ -z "$prefetch_end_no" ] || [ "$prefetch_end_no" -lt "$prefetch_start_no" ]; }; then
  prefetch_line="$(sed -n "${prefetch_start_no}p" "$LOG_FILE")"
  prefetch_epoch="$(epoch_of "$prefetch_line")"
  now_epoch="$(date '+%s')"
  if [ "$prefetch_epoch" -gt 0 ] 2>/dev/null && [ "$now_epoch" -ge "$prefetch_epoch" ] 2>/dev/null; then
    prefetch_age=$((now_epoch - prefetch_epoch))
    [ "$prefetch_age" -ge 120 ] && prefetch_stalled=1
  fi
fi

echo "════════════════ PCC 云端只读诊断 ════════════════"
echo "  系统: macOS $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
echo "  窗口: 最近 $SINCE"
[ -n "$client_app" ] && echo "  调用应用: $client_app"
[ -n "$use_case" ] && echo "  用例: $use_case"
[ -n "$available_nodes" ] && echo "  本地证明池: available=$available_nodes, bundles=${bundle_count:-?}"
echo

if [ -z "$terminal_line_no" ]; then
  warn "没有发现已结束的 PCC 请求（NO_RECENT_REQUEST）"
  echo "  请只触发一次不含隐私内容的联网 AI 操作，等待约 60 秒，再运行本命令。"
elif printf '%s\n' "$terminal_line" | grep -qi 'finished successfully'; then
  terminal_epoch="$(epoch_of "$terminal_line")"
  app_timeout_epoch="$(epoch_of "$app_timeout_line")"
  if [ -n "$app_timeout_no" ] && [ "$app_timeout_no" -lt "$terminal_line_no" ] \
     && [ "$terminal_epoch" -ge "$app_timeout_epoch" ] \
     && [ $((terminal_epoch - app_timeout_epoch)) -le 120 ]; then
    err "分类: CALLER_TIMEOUT_PCC_LATE（PCC 成功，但调用应用已先超时）"
    echo "  应用超时: $(timestamp_of "$app_timeout_line")"
    echo "  PCC 完成:  $(timestamp_of "$terminal_line")"
    echo "  这只能证明 PCC 基础链路最终可用，不能算端到端功能成功。"
  else
    ok "最近一次 PCC 请求成功（HEALTHY）"
    echo "  时间: $(timestamp_of "$terminal_line")"
    echo "  这证明该时刻的中继、令牌、证明验证和 PCC 服务端链路全部可用。"
  fi
else
  echo "  最近请求: 失败 ($(timestamp_of "$terminal_line"))"
  # 32001 必须是独立的数字,避免命中时间戳、PID、十六进制 ID 里恰好含 32001 的片段
  if grep -qiE '(^|[^0-9A-Fa-f])32001([^0-9A-Fa-f]|$)|RetryAfter' "$CONTEXT_FILE"; then
    err "分类: RATE_LIMITED（Apple 服务端限流）"
    echo "  停止重复点击，等 RetryAfter 指定时间；日志没有时间时至少等数小时。"
  elif grep -qiE 'NWError[^0-9]*Code[=:][[:space:]]*89|32057|32080|Insufficient inline' "$CONTEXT_FILE" \
       || { [ -n "$inline_total" ] && [ "$inline_total" -lt 2 ]; }; then
    err "分类: RELAY_OR_INLINE_TIMEOUT（中继/内联证明交付不完整）"
    [ -n "$inline_total" ] && echo "  本次收到的内联证明节点: $inline_total"
    echo "  这是请求到 Apple 隐私中继后的交付超时，不等于 region、GREYMATTER 或端侧模型失效。"
    echo "  不要删除证明库；确认令牌状态后，再只重试一次。"
  elif grep -qiE 'AttestationStoreError|attestation store.*empty|no available attestation' "$CONTEXT_FILE"; then
    err "分类: ATTESTATION_CACHE_MISS（本地证明缓存未命中）"
    echo "  守护进程应从服务端接收内联节点并回填；先等待，不要直接删库。"
  else
    err "分类: PCC_REQUEST_FAILED（未命中已知模式）"
    echo "  请运行 sudo ./install.sh diagnose，并附上本段分类结果。"
  fi
fi

if [ -n "$available_nodes" ] && [ "$available_nodes" -eq 0 ] 2>/dev/null; then
  warn "本地可复用证明池仍为空；下一次调用需要依赖内联证明，容易超过应用超时。"
fi
if [ "$prefetch_stalled" -eq 1 ]; then
  warn "后台证明预取已持续 ${prefetch_age}s 且证明池仍为空（PREFETCH_STALLED）"
  echo "  预取请求本身卡在中继/服务端流上；删除本地数据库不会修复这条链路。"
fi

echo
if [ -n "$token_ok_no" ] && { [ -z "$token_bad_no" ] || [ "$token_ok_no" -gt "$token_bad_no" ]; }; then
  token_line="$(sed -n "${token_ok_no}p" "$LOG_FILE")"
  ok "隐私中继令牌最近一次状态为已补充 ($(timestamp_of "$token_line"))"
  if [ -n "$terminal_line_no" ] && [ "$token_ok_no" -gt "$terminal_line_no" ]; then
    echo "  注意: 令牌是在最近失败之后补充的；现在值得只重试一次。"
  fi
elif [ -n "$token_bad_no" ]; then
  token_line="$(sed -n "${token_bad_no}p" "$LOG_FILE")"
  warn "隐私中继令牌仍未就绪 ($(timestamp_of "$token_line"))"
else
  warn "窗口内没有明确的令牌补充记录"
fi

if [ "${aks_count:-0}" -gt 0 ] 2>/dev/null; then
  warn "同一请求附近出现 AppleKeyStore/AKS 拒绝记录 ($aks_count 条)"
  echo "  该记录只作旁证：macOS 27 Beta 4 的成功请求也可能伴随同类记录，不能单独判定根因。"
fi

echo "════════════════ 诊断结束（未修改系统）════════════════"
