# ThinkPad Z16 Gen 1 — Quectel EM05-G LTE on Linux

Getting the built-in Quectel EM05-G WWAN modem (Google Fi / T-Mobile) working on
Ubuntu on a Lenovo ThinkPad Z16 Gen 1. The modem enumerates on Linux but won't
register/connect until it is "FCC unlocked".

## What the Windows driver actually does (so nothing needs porting)

I pulled apart the Windows 11 driver package for this
(`DriverStore\FileRepository\modemauthserviceem05g.inf_amd64_9289d7ba7cc489ad`,
"Quectel Modem Auth Service (EM05G)" v5.0.0.17, `ModemAuthServiceEM05G.exe`).
Extracted files/strings are in [`windows-driver-extract/`](windows-driver-extract/).

There is **no secret key, challenge/response or AT init string**. The service:

1. Checks the SMBIOS product name against a whitelist of Lenovo models
   (`ThinkPad Z16 Gen 1` is on it — see `platform-modem-whitelist.txt`) and that
   the modem is one of `USB\VID_2C7C&PID_030A / 030C / 0311 / 0313 / 0314`.
2. Checks an "isFccMode" flag read from SMBIOS.
3. Opens the Quectel vendor MBIM device service
   `UUID 11223344-5566-7788-99AA-BBCCDDEEFF11`, queries the radio state (CFUN),
   and if it is 0/4 sets CFUN=1 ("SET MBIM FUN SUCCESS").

libmbim already implements that exact vendor service as the `quectel` MBIM service,
and ModemManager already ships an FCC-unlock script that calls it. The only thing
"missing" on a stock Ubuntu install is that the unlock script is **opt-in**: it only
runs if a file named `<vid>:<pid>` exists in `/etc/ModemManager/fcc-unlock.d/`.

## Fix on Linux

```sh
git clone https://github.com/NickHirras/z16-em05g-linux-wwan
cd z16-em05g-linux-wwan
sudo apt install modemmanager libmbim-utils   # already present on Ubuntu desktop
sudo sh em05g-fcc-unlock-linux.sh
```

The script:

- finds the modem's actual PID with `lsusb -d 2c7c:` (Z16 units shipped with
  `2c7c:030a` or `030c`; newer EM05-G revisions report `0311/0313/0314`),
- symlinks `/usr/share/ModemManager/fcc-unlock.available.d/2c7c` to
  `/etc/ModemManager/fcc-unlock.d/2c7c:<pid>` (or writes an equivalent script if your
  ModemManager is too old to ship one, e.g. Ubuntu 22.04's 1.18.6),
- runs the unlock immediately (`mbimcli --quectel-set-radio-state=on`) and restarts
  ModemManager.

### Manual equivalent

```sh
lsusb -d 2c7c:
sudo mbimcli --device=/dev/cdc-wdm0 --device-open-proxy --quectel-set-radio-state=on
sudo ln -sf /usr/share/ModemManager/fcc-unlock.available.d/2c7c \
            /etc/ModemManager/fcc-unlock.d/2c7c:030a      # use your PID
sudo systemctl restart ModemManager
```

### Connecting to Google Fi

```sh
mmcli -L
mmcli -m any                     # state should be 'registered'/'enabled', not 'locked'
nmcli connection add type gsm ifname '*' con-name fi apn h2g2
nmcli connection up fi
```

Google Fi's APN is `h2g2` (T-Mobile native SIMs use `fast.t-mobile.com`).

### Troubleshooting

- `mmcli -m any` says `fcc-locked` → the `fcc-unlock.d` entry name doesn't match your
  PID, or ModemManager < 1.18.8 (no Quectel script; the fallback in the script handles this).
- Modem missing entirely → check `rfkill list` and that WWAN is enabled in BIOS.
- Fails to reconnect after suspend → `sudo mkdir -p /run/pppd/lock` (known MM quirk).
- Raw radio state: `sudo mbimcli -d /dev/cdc-wdm0 -p --quectel-query-radio-state`.

## Files

| Path | What |
|---|---|
| `em05g-fcc-unlock-linux.sh` | One-shot setup script for Linux |
| `windows-driver-extract/ModemAuthServiceEM05G.inf` | Windows driver INF (hardware IDs, service definition) |
| `windows-driver-extract/platform-modem-whitelist.txt` | Lenovo model → modem PID table embedded in the Windows service |
| `windows-driver-extract/relevant-strings.txt` | Strings from the .exe showing the CFUN/MBIM logic |
| `windows-driver-extract/SHA256SUMS` | Hash of the Quectel .exe (signed vendor binary, not redistributed here) |

## References

- https://foundata.com/en/blog/2024/quectel-em05-g-thinkpad-t14-gen4-fedora-linux/
- https://konifay.io/blog/2024-0001-quectel/
- https://wiki.archlinux.org/title/Lenovo_ThinkPad_T14_(AMD)_Gen_3
- Ubuntu bug #1998111 "Quectel EM05-G not being unlocked"
