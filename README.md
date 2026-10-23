# ThinkPad Z16 Gen 1 — WWAN LTE on Linux (Quectel EM05-G / Fibocom L860-GL-16)

Getting the built-in WWAN modem (Google Fi / T-Mobile) working on Linux on a
Lenovo ThinkPad Z16 Gen 1. The modem enumerates on Linux but won't
register/connect until it is "FCC unlocked".

**Lenovo shipped the Z16 Gen 1 with one of two different modems.** Check which
one you have first, because the unlock is completely different:

```sh
lsusb -d 2c7c:                       # Quectel EM05-G  -> USB 2c7c:030a/030c/0311/0313/0314
lspci -nn | grep -i 'Cellular\|7560'  # Fibocom L860-GL-16 -> PCI "Intel XMM7560" [8086:7560]
```

- **Quectel EM05-G** (USB): the next section, [`em05g-fcc-unlock-linux.sh`](em05g-fcc-unlock-linux.sh).
- **Fibocom L860-GL-16** (PCIe, shows up as *Intel XMM7560 LTE Advanced Pro Modem*):
  skip to [Fibocom L860-GL-16 variant](#fibocom-l860-gl-16-variant-intel-xmm7560-pci-80867560).

## Quectel EM05-G variant (USB 2c7c:xxxx)

### What the Windows driver actually does (so nothing needs porting)

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

### Fix on Linux

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

#### Manual equivalent

```sh
lsusb -d 2c7c:
sudo mbimcli --device=/dev/cdc-wdm0 --device-open-proxy --quectel-set-radio-state=on
sudo ln -sf /usr/share/ModemManager/fcc-unlock.available.d/2c7c \
            /etc/ModemManager/fcc-unlock.d/2c7c:030a      # use your PID
sudo systemctl restart ModemManager
```

#### Connecting to Google Fi

```sh
mmcli -L
mmcli -m any                     # state should be 'registered'/'enabled', not 'locked'
nmcli connection add type gsm ifname '*' con-name fi apn h2g2
nmcli connection up fi
```

Google Fi's APN is `h2g2` (T-Mobile native SIMs use `fast.t-mobile.com`).

#### Troubleshooting

- `mmcli -m any` says `fcc-locked` → the `fcc-unlock.d` entry name doesn't match your
  PID, or ModemManager < 1.18.8 (no Quectel script; the fallback in the script handles this).
- Modem missing entirely → check `rfkill list` and that WWAN is enabled in BIOS.
- Fails to reconnect after suspend → `sudo mkdir -p /run/pppd/lock` (known MM quirk).
- Raw radio state: `sudo mbimcli -d /dev/cdc-wdm0 -p --quectel-query-radio-state`.

## Fibocom L860-GL-16 variant (Intel XMM7560, PCI 8086:7560)

Tested 2026-10-23 on Debian sid (kernel 7.2, ModemManager 1.24.2, GNOME 51)
with a Google Fi SIM. Worked in Windows out of the box; on Linux it needs an
FCC unlock that nobody ships by default.

### Symptoms

- `lspci -nn` shows `Cellular controller/modem [0d40]: Intel Corporation XMM7560
  LTE Advanced Pro Modem [8086:7560]`; the kernel `iosm` driver creates
  `/dev/wwan0at0`, `/dev/wwan0at1`, `/dev/wwan0mbim0` and a `wwan0` netdev.
- `mmcli -m any` sees the modem and the SIM but stays `state: disabled`,
  `power state: low`, and enabling fails with
  `couldn't update power state: Invalid transition`.
- `sudo mbimcli -d /dev/wwan0mbim0 -p --intel-query-fcc-lock` says
  `FCC lock status: locked`.
- ModemManager's debug log shows it looking for
  `/etc/ModemManager/fcc-unlock.d/8086:7560`, which doesn't exist: upstream
  ModemManager ships no unlock script for this card.

### Why Lenovo's own tool doesn't help

Lenovo's [`lenovo-wwan-unlock`](https://github.com/lenovo/lenovo-wwan-unlock)
refuses to unlock when the SIM is from a US carrier (Google Fi / T-Mobile
310260 included), and per the disassembly in the project below its L860 code
path is never reached on the Z13/Z16 family anyway.

### Fix on Linux

The [twh/wwan-unlock](https://github.com/twh/wwan-unlock) project has a
clean-room reimplementation of the unlock: a ~300 line POSIX shell script that
reads a challenge over the modem's AT port (`AT+GTFCCLOCKGEN`), answers it with
a SHA-256 of the machine's SMBIOS model id (`AT+GTFCCLOCKVER=<n>`), and returns
so ModemManager can power the radio on. No vendor binaries run.

```sh
sudo apt install modemmanager libmbim-utils libqmi-utils
git clone https://github.com/twh/wwan-unlock
sudo install -m0755 wwan-unlock/modules/8086:7560/fcc-unlock.sh \
                    /etc/ModemManager/fcc-unlock.d/8086:7560
sudo systemctl enable --now ModemManager
sudo systemctl restart ModemManager
```

(`sudo ./install.sh --no-sar` in that repo does the same plus a little
bookkeeping; without `--no-sar` it also installs Lenovo's closed SAR
libraries, which aren't needed to get online.)

ModemManager runs the dispatcher automatically on boot, resume and modem
reset, so this is a one-time install. Then connect as usual:

```sh
nmcli connection add type gsm ifname '*' con-name "Google Fi" gsm.apn h2g2 connection.autoconnect yes
nmcli connection up "Google Fi"
mmcli -m any      # state: connected, operator name: T-Mobile, access tech: lte
```

### Verifying / troubleshooting

```sh
sudo journalctl -t fcc-unlock-fibocom -b              # should end in "FCC unlock: SUCCESS"
sudo mbimcli -d /dev/wwan0mbim0 -p --intel-query-fcc-lock   # FCC lock status: unlocked
```

- The first one or two unlock attempts after a cold start may log
  `no challenge, reply:` while the modem is still waking up; ModemManager
  retries and it succeeds within a few seconds. The `Invalid transition`
  warnings in the ModemManager log stop once the radio is up.
- If you installed ModemManager *after* booting, its udev rules haven't tagged
  the already-existing ports and `mmcli -L` says `No modems were found`
  (debug log: `port wwan0mbim0 not candidate`). Either reboot or:
  `sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=wwan --subsystem-match=net && sudo mmcli --scan-modems`.
- `rfkill list` should show `tpacpi_wwan_sw` unblocked; the BIOS WWAN setting
  must be enabled.

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
- https://github.com/twh/wwan-unlock (clean-room FCC unlock for the L860-GL-16 / 8086:7560 and others)
- https://github.com/lenovo/lenovo-wwan-unlock (Lenovo's official tool; no US SIMs)
- https://wiki.gentoo.org/wiki/Fibocom_L860-GL-16
