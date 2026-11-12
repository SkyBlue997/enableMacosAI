#!/bin/bash
# Load the region-spoof kext, then refresh daemons after the region has changed.
# Also used by install.sh -- keep the refresh procedure in one place.
# Boot output goes to /var/log/region-kext.log.

ts(){ /bin/date '+%Y-%m-%d %H:%M:%S'; }
region(){
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
    | /usr/bin/sed -n 's/.*"region-info" = <\([0-9a-f]\{8\}\).*/\1/p' | /usr/bin/head -1 \
    | /usr/bin/xxd -r -p 2>/dev/null | /usr/bin/tr -cd 'A-Z/'
}
eligibility_pid(){ /usr/bin/pgrep -x eligibilityd 2>/dev/null | /usr/bin/head -1; }
eligibility_stamp(){
  /usr/bin/stat -f '%i:%m:%c:%z' /private/var/db/eligibilityd/eligibility.plist 2>/dev/null
}
eligibility_answer(){
  /usr/libexec/PlistBuddy -c 'Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t' \
    /private/var/db/eligibilityd/eligibility.plist 2>/dev/null
}
eligibility_locked_files(){
  local file flags
  for file in /private/var/db/eligibilityd/* /private/var/db/os_eligibility/eligibility.plist; do
    [ -e "$file" ] || continue
    flags="$(/usr/bin/stat -f %Sf "$file" 2>/dev/null)"
    case "$flags" in *uchg*|*schg*) printf '%s (%s)\n' "$file" "$flags" ;; esac
  done
}
eligibility_term(){ /usr/bin/killall -TERM eligibilityd; }
eligibility_notify(){ /usr/bin/notifyutil -p AFLanguageCodeDidChangeDarwinNotification; }

refresh_eligibility(){
  local old_pid pid before stamp answer='' locked out i refreshed=0
  locked="$(eligibility_locked_files)"
  if [ -n "$locked" ]; then
    printf '%s FAILED: eligibility files are locked; unlock them first:\n%s\n' "$(ts)" "$locked"
    return 1
  fi
  before="$(eligibility_stamp)"
  old_pid="$(eligibility_pid)"
  if [ -n "$old_pid" ]; then
    echo "$(ts) eligibilityd: sending TERM to pid=$old_pid"
    # kickstart -k can be denied by SIP even when TERM is allowed.
    if ! out="$(eligibility_term 2>&1)"; then
      echo "$(ts) eligibilityd TERM: $out"
      # A concurrent normal exit is harmless; a surviving old process is not.
      if [ "$(eligibility_pid)" = "$old_pid" ]; then
        echo "$(ts) FAILED: cannot terminate eligibilityd"
        return 1
      fi
    fi
    # Do not deliver the notification to the old process while it is exiting.
    for ((i=0; i<10; i++)); do
      [ "$(eligibility_pid)" != "$old_pid" ] && break
      sleep 1
    done
    if [ "$(eligibility_pid)" = "$old_pid" ]; then
      echo "$(ts) FAILED: eligibilityd did not exit within 10 seconds"
      return 1
    fi
  fi

  # eligibilityd is demand-launched, not unconditionally KeepAlive.
  # Its LaunchEvents subscribes to this notification; no language setting is changed.
  if ! out="$(eligibility_notify 2>&1)"; then
    echo "$(ts) FAILED: eligibilityd wake notification: $out"
    return 1
  fi
  for ((i=0; i<30; i++)); do
    pid="$(eligibility_pid)"
    stamp="$(eligibility_stamp)"
    answer="$(eligibility_answer)"
    refreshed=0
    if [ -n "$pid" ] && [ "$pid" != "$old_pid" ] && [ -n "$stamp" ] && [ "$stamp" != "$before" ]; then
      case "$answer" in ''|*[!0-9]*) ;; *) refreshed=1 ;; esac
    fi
    [ "$refreshed" = 1 ] && [ "$answer" = 4 ] && break
    sleep 1
  done
  if [ "$refreshed" != 1 ]; then
    echo "$(ts) FAILED: no new eligibilityd process with an updated eligibility file within 30 seconds (pid=${pid:-none}, GREYMATTER=${answer:-unknown}); do not trust the old plist"
    return 1
  fi
  echo "$(ts) eligibilityd refreshed: pid=$pid, GREYMATTER=$answer"
  if [ "$answer" != 4 ]; then
    echo "$(ts) WARNING: fresh eligibility is not 4; inspect GREYMATTER inputs with sudo ./install.sh diagnose"
  fi
}

refresh_region_daemons(){
  local rc=0 svc out
  refresh_eligibility || rc=$?
  for svc in com.apple.modelcatalogd com.apple.modelmanagerd; do
    if ! out="$(/bin/launchctl kickstart -k "system/$svc" 2>&1)"; then
      printf '%s WARNING: %s refresh failed: %s\n' "$(ts)" "$svc" "$out"
    fi
  done
  return "$rc"
}

run_refresh(){
  # Installation bootstraps the LaunchDaemon and also refreshes directly.
  # Serialize both paths so one cannot kill the other's newly started daemon.
  # -k retains the lock inode; the OS releases the actual lock on process exit.
  /usr/bin/lockf -k -t 60 /var/run/region-kext-refresh.lock \
    /bin/bash -c 'source "$1"; refresh_region_daemons' region-kext-refresh "${BASH_SOURCE[0]}"
}

region_loader_main(){
  local kext=/Library/Extensions/RegionSpoof.kext out rc i answer
  echo "$(ts) region-kext-load start (region=$(region))"
  if [ ! -d "$kext" ]; then
    echo "$(ts) FAILED: $kext not found"
    return 1
  fi
  out="$(/usr/bin/kmutil load -p "$kext" 2>&1)"; rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | /usr/bin/tail -5 | /usr/bin/sed "s/^/$(ts) kmutil: /"
  echo "$(ts) kmutil load exit=$rc"
  for ((i=0; i<10; i++)); do
    [ "$(region)" = LL/A ] && break
    sleep 1
  done
  if [ "$(region)" != LL/A ]; then
    echo "$(ts) FAILED: region is still $(region); kext not effective (run: sudo ./install.sh diagnose)"
    return 1
  fi
  if ! run_refresh; then
    echo "$(ts) FAILED: region=LL/A, but eligibility refresh was not verified"
    return 1
  fi
  answer="$(eligibility_answer)"
  if [ "$answer" != 4 ]; then
    echo "$(ts) WARNING: region=LL/A, GREYMATTER=${answer:-unknown}; Apple Intelligence eligibility is not ready"
    return 2
  fi
  echo "$(ts) OK: region=LL/A, GREYMATTER=4"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ "$(/usr/bin/id -u)" = 0 ] || { echo 'Run with sudo.' >&2; exit 1; }
  case "${1:-}" in
    '') region_loader_main ;;
    --refresh-only) run_refresh ;;
    *) echo "Usage: sudo $0 [--refresh-only]" >&2; exit 1 ;;
  esac
fi
