#!/bin/bash
# Offline regression tests: never signal or notify actual system services.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/regionspoof-refresh-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

run_case(){
  local scenario="$1" expected_rc="$2" expected_text="$3"
  (
    source "$ROOT/region-kext-load.sh"
    CASE_DIR="$TMP_DIR/$scenario"
    mkdir "$CASE_DIR"
    TICK=0
    ts(){ echo TEST; }
    sleep(){ TICK=$((TICK + 1)); }
    eligibility_locked_files(){
      if [ "$scenario" = locked ]; then echo 'eligibility.plist (uchg)'; fi
    }
    eligibility_pid(){
      if [ -f "$CASE_DIR/notified" ]; then
        [ "$scenario" = no_respawn ] || echo 202
      elif [ -f "$CASE_DIR/term" ]; then
        if [ "$scenario" = term_ignored ] || { [ "$scenario" = delayed_exit ] && [ "$TICK" -lt 2 ]; }; then
          echo 101
        fi
      elif [ "$scenario" != already_stopped ]; then
        echo 101
      fi
      return 0
    }
    eligibility_term(){
      if [ "$scenario" = term_denied ]; then echo 'Operation not permitted' >&2; return 1; fi
      touch "$CASE_DIR/term"
    }
    eligibility_notify(){
      # A wake event sent before TERM completes would be consumed by the old PID.
      if [ "$(eligibility_pid)" = 101 ]; then echo 'notification sent too early' >&2; return 1; fi
      if [ "$scenario" = notify_failed ]; then echo 'notification denied' >&2; return 1; fi
      touch "$CASE_DIR/notified"
    }
    eligibility_stamp(){
      if [ -f "$CASE_DIR/notified" ] && [ "$scenario" != stale_file ]; then echo new-file; else echo old-file; fi
    }
    eligibility_answer(){
      if [ "$scenario" = still_ineligible ]; then echo 2; else echo 4; fi
    }
    rc=0
    refresh_eligibility >"$CASE_DIR/output" 2>&1 || rc=$?
    if [ "$rc" != "$expected_rc" ] || ! grep -q "$expected_text" "$CASE_DIR/output"; then
      echo "FAIL: $scenario (exit=$rc, expected=$expected_rc, text=$expected_text)"
      cat "$CASE_DIR/output"
      exit 1
    fi
    case "$scenario" in
      locked|already_stopped) [ ! -f "$CASE_DIR/term" ] ;;
    esac
    case "$scenario" in
      locked|term_denied|term_ignored) [ ! -f "$CASE_DIR/notified" ] ;;
    esac
    echo "PASS: $scenario"
  )
}

run_case normal 0 'eligibilityd refreshed: pid=202, GREYMATTER=4'
run_case already_stopped 0 'eligibilityd refreshed: pid=202, GREYMATTER=4'
run_case delayed_exit 0 'eligibilityd refreshed: pid=202, GREYMATTER=4'
run_case term_denied 1 'FAILED: cannot terminate'
run_case term_ignored 1 'FAILED: eligibilityd did not exit'
run_case notify_failed 1 'FAILED: eligibilityd wake notification'
run_case no_respawn 1 'FAILED: no new eligibilityd process'
run_case stale_file 1 'do not trust the old plist'
run_case locked 1 'FAILED: eligibility files are locked'
run_case still_ineligible 0 'WARNING: fresh eligibility is not 4'
run_model_case(){
  local scenario="$1" name="$2" sig="$3" expected_rc="$4" expected_text="$5"
  (
    source "$ROOT/region-kext-load.sh"
    CASE_DIR="$TMP_DIR/model-$scenario"
    mkdir "$CASE_DIR"
    ts(){ echo TEST; }
    sleep(){ :; }
    daemon_pid(){
      if [ "$scenario" = not_running ]; then return 0; fi
      if [ -f "$CASE_DIR/stopped" ]; then
        case "$scenario" in
          no_change) echo 101 ;;
          on_demand) ;;
          *) echo 202 ;;
        esac
      else
        echo 101
      fi
    }
    daemon_kickstart(){
      touch "$CASE_DIR/kickstart"
      case "$scenario" in
        kick_ok|no_change) touch "$CASE_DIR/stopped" ;;
        *) echo 'Operation not permitted while System Integrity Protection is engaged' >&2; return 150 ;;
      esac
    }
    daemon_signal(){
      echo "$1" >>"$CASE_DIR/signals"
      if [ "$scenario" = signal_denied ]; then echo 'Operation not permitted' >&2; return 1; fi
      touch "$CASE_DIR/stopped"
    }
    rc=0
    refresh_model_daemon "$name" "com.apple.$name" "$sig" >"$CASE_DIR/output" 2>&1 || rc=$?
    if [ "$rc" != "$expected_rc" ] || ! grep -q "$expected_text" "$CASE_DIR/output"; then
      echo "FAIL: model $scenario (exit=$rc, expected=$expected_rc, text=$expected_text)"
      cat "$CASE_DIR/output"
      exit 1
    fi
    # modelcatalogd hangs on TERM, so it must never receive it.
    if [ "$name" = modelcatalogd ] && grep -qx TERM "$CASE_DIR/signals" 2>/dev/null; then
      echo "FAIL: model $scenario sent TERM to modelcatalogd"; exit 1
    fi
    case "$scenario" in
      kick_ok|not_running|no_change) [ ! -f "$CASE_DIR/signals" ] ;;
    esac
    [ "$scenario" != not_running ] || [ ! -f "$CASE_DIR/kickstart" ]
    echo "PASS: model $scenario ($name)"
  )
}

run_model_case kick_ok modelcatalogd KILL 0 'refreshed via kickstart -k: pid=101 -> 202'
run_model_case kick_denied_kill modelcatalogd KILL 0 'refreshed via SIGKILL: pid=101 -> 202'
run_model_case kick_denied_term modelmanagerd TERM 0 'refreshed via SIGTERM: pid=101 -> 202'
run_model_case on_demand modelmanagerd TERM 0 'starts on demand'
run_model_case not_running modelcatalogd KILL 0 'not running'
run_model_case signal_denied modelmanagerd TERM 1 'NOTE: modelmanagerd: SIGTERM failed'
run_model_case no_change modelcatalogd KILL 1 'NOTE: modelcatalogd still pid=101'

# Model daemon failures must not change the overall result, which follows eligibilityd only.
(
  source "$ROOT/region-kext-load.sh"
  refresh_eligibility(){ return 0; }
  refresh_model_daemon(){ return 1; }
  refresh_region_daemons >/dev/null 2>&1 || { echo 'FAIL: model daemon failure changed the result'; exit 1; }
  refresh_eligibility(){ return 1; }
  if refresh_region_daemons >/dev/null 2>&1; then echo 'FAIL: eligibility failure was hidden'; exit 1; fi
  echo 'PASS: overall result follows eligibilityd only'
)
echo 'All eligibility and model daemon refresh fixtures passed.'
