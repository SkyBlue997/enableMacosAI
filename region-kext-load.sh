#!/bin/bash
# Load the region-spoof kext early at boot, then refresh region-cached daemons.
# Output goes to /var/log/region-kext.log (see com.local.regionkext.plist).
KEXT=/Library/Extensions/RegionSpoof.kext
ts(){ /bin/date '+%Y-%m-%d %H:%M:%S'; }
region(){
  /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
    | /usr/bin/sed -n 's/.*"region-info" = <\([0-9a-f]\{8\}\).*/\1/p' | /usr/bin/head -1 \
    | /usr/bin/xxd -r -p 2>/dev/null | /usr/bin/tr -cd 'A-Z/'
}

echo "$(ts) region-kext-load start (region=$(region))"
if [ ! -d "$KEXT" ]; then
  echo "$(ts) FAILED: $KEXT not found"
  exit 1
fi

out="$(/usr/bin/kmutil load -p "$KEXT" 2>&1)"; rc=$?
[ -n "$out" ] && printf '%s\n' "$out" | /usr/bin/tail -5 | /usr/bin/sed "s/^/$(ts) kmutil: /"
echo "$(ts) kmutil load exit=$rc"

for i in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(region)" = "LL/A" ] && break
  sleep 1
done

# Restart daemons that may have cached the old region (harmless if region did not change)
for svc in com.apple.eligibilityd com.apple.modelcatalogd com.apple.modelmanagerd; do
  /bin/launchctl kickstart -k system/$svc >/dev/null 2>&1
done

if [ "$(region)" = "LL/A" ]; then
  echo "$(ts) OK: region=LL/A, AI daemons refreshed"
  exit 0
fi
echo "$(ts) FAILED: region is still $(region); kext not loaded (approve it in Privacy & Security, then reboot; or run: sudo ./install.sh diagnose)"
exit 1
