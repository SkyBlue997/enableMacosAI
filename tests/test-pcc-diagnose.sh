#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAG="$ROOT/pcc-diagnose.sh"
TMP_DIR="$(mktemp -d /tmp/regionspoof-pcc-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

run_case(){
  local name="$1" expected="$2" fixture="$TMP_DIR/$1.log" output="$TMP_DIR/$1.out"
  shift 2
  printf '%s\n' "$@" >"$fixture"
  PCC_DIAG_LOG_FILE="$fixture" "$DIAG" >"$output"
  grep -q "$expected" "$output" || {
    echo "FAIL: $name (expected $expected)"
    cat "$output"
    exit 1
  }
  echo "PASS: $name"
}

run_case healthy HEALTHY \
  '2026-07-22 13:43:52.000 Df privatecloudcomputed Ropes request finished successfully'

run_case caller_timeout CALLER_TIMEOUT_PCC_LATE \
  '2026-07-22 13:43:16.000 Df generativeexperiencesd useCaseIdentifier=summarization.summarizeMailMessageOnDemand clientApplicationIdentifier=com.apple.mail' \
  '2026-07-22 13:43:48.000 E generativeexperiencesd GenerativeError Code=5040000 workload timed out before completing' \
  '2026-07-22 13:43:52.000 Df privatecloudcomputed Ropes request finished successfully'

run_case inline_timeout RELAY_OR_INLINE_TIMEOUT \
  '2026-07-22 18:09:14.000 Df generativeexperiencesd useCaseIdentifier=summarization.summarizeMailMessageOnDemand clientApplicationIdentifier=com.apple.mail' \
  '2026-07-22 18:09:59.000 Df privatecloudcomputed inline nodes ready totalReceived=1, selected=1' \
  '2026-07-22 18:10:07.000 E privatecloudcomputed Ropes request failed Error Domain=Network.NWError Code=89' \
  '2026-07-22 18:14:18.000 Df networkserviceproxy Token fetch successful for "Apple"'
grep -q '失败之后补充' "$TMP_DIR/inline_timeout.out"

run_case rate_limited RATE_LIMITED \
  '2026-07-22 18:00:00.000 E privatecloudcomputed RetryAfterDate error 32001' \
  '2026-07-22 18:00:01.000 E privatecloudcomputed Ropes request failed'

run_case rate_limited_code RATE_LIMITED \
  '2026-07-22 18:00:00.000 E privatecloudcomputed Ropes error code=32001' \
  '2026-07-22 18:00:01.000 E privatecloudcomputed Ropes request failed'

# 32001 只是更长数字 / ID 的一部分时,不应判为限流
run_case not_rate_limited_substring PCC_REQUEST_FAILED \
  '2026-07-22 18:00:00.000 E privatecloudcomputed requestID=8a132001f7 pid=1320015' \
  '2026-07-22 18:00:01.000 E privatecloudcomputed Ropes request failed'

run_case cache_miss ATTESTATION_CACHE_MISS \
  '2026-07-22 18:00:00.000 E privatecloudcomputed AttestationStoreError store is empty' \
  '2026-07-22 18:00:01.000 E privatecloudcomputed Ropes request failed'

run_case no_request NO_RECENT_REQUEST \
  '2026-07-22 18:00:00.000 Df networkserviceproxy Token fetch successful for "Apple"'

echo 'All PCC classifier fixtures passed.'
