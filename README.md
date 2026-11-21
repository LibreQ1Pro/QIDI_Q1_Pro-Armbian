# QIDI Q1 Pro Armbian image

English · [Русский](README.ru.md)

Armbian (Debian 13 trixie) for the motherboard in the QIDI Q1 Pro.

## What is in the image

| Component | What the image has |
|---|---|
| User | `mks` (UID/GID 1000), password `makerbase`, groups `sudo dialout tty netdev video plugdev` |
| Network | NetworkManager only (no netplan, networkd or ifupdown); `netdev` may use `nmcli` without root (polkit) |
| Klipper | [LibreQ1Pro/klipper](https://github.com/LibreQ1Pro/klipper), installed by KIAUH: `~/klipper`, `~/klippy-env`, `~/printer_data` |
| Moonraker | by KIAUH; `moonraker.asvc` also allows `librescreen` |
| Web UI | Mainsail on port 80, Fluidd on port 81 (nginx) |
| KIAUH | `~/kiauh`, `kiauh.cfg` uses the Klipper fork |
| Printer config | `printer.cfg`, `gcode_macro.cfg` from [LibreQ1Pro/QIDI_Q1_Pro-Config](https://github.com/LibreQ1Pro/QIDI_Q1_Pro-Config) (clone in `~/QIDI_Q1_Pro/config`); `~/katapult` |
| LibreScreen | `~/LibreScreen`, `librescreen.service`, polkit rule and USB automount (drives are mounted in `~/printer_data/gcodes/<name>`) |
| KlipperScreen | [LibreQ1Pro/KlipperScreen](https://github.com/LibreQ1Pro/KlipperScreen) fork on Wayland: a drop-in makes `KlipperScreen.service` run labwc with `screen.py`, on the gud-esp32s3 USB display (`USB-1`), rotated in `~/.config/labwc/autostart` |
| Timelapse, camera | moonraker-timelapse + FFmpeg; crowsnest on `/dev/webcam` (`70-webcam.rules`; /dev/video0 is the SoC video decoder), `crowsnest.conf` from the printer config repository |
| Wi-Fi | `aic8800-firmware` + `aic8800-usb-dkms` from the [LibreQ1Pro/aic8800](https://github.com/LibreQ1Pro/aic8800) fork (DKMS, built for the image kernel) |
| Wi-Fi file | `/boot/libreq1pro-wifi.txt`, see [Wi-Fi without a screen](#wi-fi-without-a-screen) |
| UARTs | `console=display`; no getty on `ttyS0-2`; uart1 enabled in the `qidi-x6` DTS for the display, without DMA (`libreq1pro-uart1-nodma` overlay); `99-q1pro-serial.rules`; no ModemManager/brltty |
| MCU firmware | toolchain to build Klipper and Katapult on the printer (`build-essential`, `gcc-arm-none-eabi`, `libnewlib-arm-none-eabi`), see [LibreQ1Pro/QIDI_Q1_Pro-Firmware](https://github.com/LibreQ1Pro/QIDI_Q1_Pro-Firmware); images and `flash.sh` in `~/QIDI_Q1_Pro/firmware`, QIDI's originals in `~/QIDI_Q1_Pro/stock-firmware` |

## Booting from USB

Like [LibreQ1Pro/QIDI_Q1_Pro-Recovery-Boot](https://github.com/LibreQ1Pro/QIDI_Q1_Pro-Recovery-Boot)
on the stock firmware: if a USB drive has a system on it (an `extlinux/extlinux.conf` or
`boot.scr` in `/` or `/boot/` of partition 1 or 2), the printer boots from it, otherwise from
the eMMC. Use the USB 2.0 ports of the mainboard. Without a bootable drive, booting takes about
3 seconds longer (LEDs, USB power-up and scan).

`overlay/usb-first.cmd` is put in front of Armbian's `boot.cmd`; a drive's `boot.scr` is booted
with that drive's `rk3328-qidi-x6.dtb` (or `rk3328-mkspi.dtb`). The RAM-only variable `usb_checked` makes the script skip
the USB scan when it was already set or when the script itself came from USB, so a drive with
this same image boots its own system instead of looping.

The mainboard LEDs show the same signals as QIDI_Q1_Pro-Recovery-Boot:

| Stage | LEDs |
|---|---|
| Boot script started | all LEDs blink quickly once |
| Booting from the eMMC | green, yellow blinks 3 times |
| Booting from the flash drive | blue, yellow blinks 3 times |
| Boot failed | blue and green flash fast, then only blue stays on |

## Wi-Fi without a screen

The boot partition is FAT, so any OS can open it. After writing the image, edit `libreq1pro-wifi.txt` on it:

```
SSID="My network"
PASSWORD="my password"
#COUNTRY=US        # optional, 2 letters
#HIDDEN=yes        # optional
```

`libreq1pro-wifi.service` reads the file at every boot and creates or updates the NetworkManager
connection `libreq1pro-wifi` (WPA-PSK, or open without a password); clear `SSID` to remove it.
Other connections are not touched, and without the file nothing happens. The password is plain
text, readable by anyone who can open the boot partition.

## Files

```
build.sh                    clones Armbian at ARMBIAN_REF and runs compile.sh
ARMBIAN_REF                 the armbian/build commit CI builds with
.github/workflows/          CI: builds the image on `v*` tags (or by hand) and attaches it to the release
userpatches/
├── config-libreq1pro.conf  board, release, kernel branch, console
├── bootenv/rockchip64.txt  armbianEnv.txt defaults (console=display, cpuidle.off=1, fbcon=font:6x10)
├── customize-image.sh      everything installed on top of Armbian (in the chroot)
├── extensions/             empty brostrend-aic8800-dkms: turns off the board's own aic8800 driver
└── overlay/
    ├── libreq1pro.conf     user, repositories, ports, optional parts
    ├── moonraker.conf      KIAUH's template, update_manager sections are appended at build time
    ├── build/build-sudo.py build-time stand-in for sudo (setuid does not work in the chroot)
    ├── usb-first.cmd       USB boot stage put in front of Armbian's boot.cmd
    ├── libreq1pro-wifi.txt Wi-Fi template copied to /boot (script and unit are in rootfs/)
    ├── KlipperScreen.service.d/10-labwc.conf   drop-in: the unit runs labwc with screen.py
    ├── labwc/              autostart (rotation) and rc.xml (touch mapping), copied to ~/.config/labwc
    ├── libreq1pro-uart1-nodma.dts   overlay: uart1 without DMA (compiled into /boot/overlay-user)
    └── rootfs/             files copied into / as they are
```

## Build locally

```sh
./build.sh                                   # clones Armbian into ./armbian_build
ARMBIAN_DIR=../armbian_build ./build.sh      # or uses an existing checkout as it is
```

The image is in `armbian_build/output/images/`. To move to a newer Armbian, change `ARMBIAN_REF`
together with the kernel pin `KERNELBRANCH` in `userpatches/config-libreq1pro.conf` (Armbian's
patches stop applying when the kernel release moves on).

## Known limitations

- Moonraker's update manager accepts Klipper only from Klipper3d/klipper and shows the fork as
  invalid. Update Klipper with KIAUH (`~/kiauh/kiauh.sh`), which uses the fork from `kiauh.cfg`.
- U-Boot still prints to `ttyS2` (`stdout-path` in the device tree) before Linux starts.
- KlipperScreen runs on the GUD display (`USB-1`) through the drop-in `KlipperScreen.service.d/10-labwc.conf`
  (`labwc -S screen.py` in the installer's unit). labwc uses all outputs, so a monitor on HDMI gets one too.
  Orientation: `wlr-randr --output USB-1 --transform` in `overlay/labwc/autostart`; the touch follows
  the output (`labwc/rc.xml`).
- The Xorg configs in `rootfs/etc/X11/xorg.conf.d/` are for the X11 backend (`BACKEND=X` in the
  KlipperScreen installer); nothing reads them with Wayland.
- Screen blanking: KlipperScreen powers the panel off with `wlopm` when its screensaver starts and
  on with the touch that closes it (`use_dpms = True` in `KlipperScreen.conf`). This is a patch to
  `screen.py` / `screensaver.py` of the fork; upstream only draws a black box on Wayland.
- `/var/log` stays in RAM (Armbian ramlog).
- **Open problem: reboot can hang.** On the test printer `reboot` (also Mainsail's button) often
  leaves the board dead until its power is cut; cold power-ups always worked (22 of 22), normal
  reboots failed 14 times in a row, and even `sysrq b` fails about half of the time. Ruled out:
  Wi-Fi, USB, sound and crypto drivers, single services, DDR frequency scaling, a restart through
  the PMIC, eMMC wear. Where it hangs (before U-Boot, in U-Boot or in the kernel) is not found.
  Until then, restart the printer by switching its power off and on.
- The 480x272 console uses the kernel's 6x10 font (`fbcon=font:6x10`: 80x27 characters instead of
  60x17); `console-setup` has an empty `FONTFACE`/`FONTSIZE` so it does not switch to a bigger one.
- The kernel runs with `cpuidle.off=1` (`bootenv/rockchip64.txt`, checked at build time): CPUs use
  only plain `WFI`, not the PSCI `cpu-sleep` deep state. With it the test printer twice froze for
  hours with no log entry (the stock 5.16 kernel never did). Suspected, not proven: a lost wake-up
  of the software `bc_hrtimer` broadcast device while all CPUs are in the deep state. Without it the
  printer ran over a day without a freeze; long prints are still being watched. Cost: slightly
  higher idle power.
- The screen UART (`uart1`, `ttyS1`) runs without DMA: with DMA on the `qidi-x6` device tree,
  flashing the screen (`flash.sh display`, 921600 baud) stalled the UART at random and Klipper lost
  both MCUs. The overlay `libreq1pro-uart1-nodma` (`bootenv/rockchip64.txt`, checked at build time)
  removes its DMA channels; the MCU UARTs keep theirs. 10 of 10 screen flashes worked with it, none
  without. The cause is not proven: the `mkspi` device tree does not stall, and neither does
  `qidi-x6` with only SPI0 enabled; switching SPI0 off on `mkspi` brings the stall back. It looks
  like a side effect of how the shared DMA controller's channels are assigned.
