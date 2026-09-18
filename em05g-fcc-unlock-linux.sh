#!/bin/sh
# Quectel EM05-G FCC unlock setup for ThinkPad Z16 Gen 1 (Ubuntu / any ModemManager >= 1.18.8)
#
# Background (extracted from the Windows driver "Quectel Modem Auth Service (EM05G)"
# v5.0.0.17, ModemAuthServiceEM05G.exe): there is no secret key or init string.
# The Windows service just (1) checks the SMBIOS product name is on a Lenovo whitelist
# ("ThinkPad Z16 Gen 1" is on it), (2) queries the modem's radio state over the Quectel
# vendor MBIM device service UUID 11223344-5566-7788-99AA-BBCCDDEEFF11, and (3) if it is
# off (CFUN=4/0) sets it to on (CFUN=1). libmbim implements that exact service as the
# "quectel" service: `mbimcli --quectel-set-radio-state=on`.
#
# ModemManager already ships that as an FCC-unlock script; it only runs if a file/symlink
# named <vid>:<pid> exists in /etc/ModemManager/fcc-unlock.d/. This script creates it for
# whichever EM05-G PID your unit actually has (Windows INF lists 030a/030c for the Z16;
# newer revisions use 0311/0313/0314).
#
# Usage:  sudo sh em05g-fcc-unlock-linux.sh
set -eu

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi

PID=$(lsusb -d 2c7c: 2>/dev/null | sed -n 's/.*ID 2c7c:\([0-9a-f]\{4\}\).*/\1/p' | head -n1)
if [ -z "$PID" ]; then
  echo "No Quectel (2c7c:xxxx) USB device found. Is WWAN enabled in BIOS / not rfkill-blocked?" >&2
  exit 1
fi
echo "Found Quectel modem 2c7c:$PID"

AVAIL=/usr/share/ModemManager/fcc-unlock.available.d/2c7c
DEST=/etc/ModemManager/fcc-unlock.d
mkdir -p "$DEST"

if [ -f "$AVAIL" ]; then
  ln -sf "$AVAIL" "$DEST/2c7c:$PID"
  echo "Linked $AVAIL -> $DEST/2c7c:$PID"
else
  # Older ModemManager (e.g. Ubuntu 22.04's 1.18.6) has no Quectel script; write one.
  cat > "$DEST/2c7c:$PID" <<'EOF'
#!/bin/sh
# Quectel EM05-G FCC unlock: turn the radio on via the Quectel MBIM device service.
[ $# -lt 2 ] && exit 1
shift   # first arg is the D-Bus modem path
for PORT in "$@"; do
  grep -q MBIM "/sys/class/usbmisc/$PORT/device/interface" 2>/dev/null && MBIM_PORT="$PORT"
done
[ -z "${MBIM_PORT:-}" ] && exit 2
exec mbimcli --device="/dev/$MBIM_PORT" --device-open-proxy --quectel-set-radio-state=on
EOF
  chmod 0755 "$DEST/2c7c:$PID"
  echo "Wrote fallback unlock script to $DEST/2c7c:$PID"
fi

chown -R root:root /etc/ModemManager
find /etc/ModemManager -type d -exec chmod 0755 {} +

# Unlock right now too, so you don't have to reboot.
WDM=$(ls /dev/cdc-wdm* 2>/dev/null | head -n1 || true)
if [ -n "$WDM" ] && command -v mbimcli >/dev/null; then
  mbimcli --device="$WDM" --device-open-proxy --quectel-set-radio-state=on || true
fi

systemctl restart ModemManager
echo "Done. Check with:  mmcli -L ; mmcli -m any   (state should no longer be 'locked'/'disabled')"
echo "Then connect:      nmcli connection add type gsm ifname '*' con-name fi apn h2g2   # Google Fi APN"
