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
echo 'All eligibility refresh fixtures passed.'
