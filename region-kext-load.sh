#!/bin/bash
# Load the region-spoof kext early at boot, then refresh region-cached daemons.
/usr/bin/kmutil load -p /Library/Extensions/RegionSpoof.kext >/dev/null 2>&1
for i in 1 2 3 4 5; do
  /usr/sbin/ioreg -ard1 -c IOPlatformExpertDevice 2>/dev/null | /usr/bin/grep -q '4c4c2f41' && break
  sleep 1
done
# region-info is now LL/A; restart daemons that may have cached CH / CN.
for svc in com.apple.countryd com.apple.eligibilityd com.apple.modelcatalogd com.apple.modelmanagerd; do
  /bin/launchctl kickstart -k system/$svc >/dev/null 2>&1
done
echo "$(date) region-kext-load done"
