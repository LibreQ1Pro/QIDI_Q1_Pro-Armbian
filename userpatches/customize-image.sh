#!/bin/bash
# QIDI Q1 Pro image on top of Armbian, run in the image chroot; overlay/ is mounted at /tmp/overlay.
# The Klipper stack comes from KIAUH's headless CLI; systemctl and sudo are build-time stand-ins.

set -euo pipefail

OVERLAY=/tmp/overlay
# shellcheck source-path=SCRIPTDIR source=overlay/libreq1pro.conf
. "$OVERLAY/libreq1pro.conf"

U=$PRINTER_USER
HOME_U=/home/$U
export DEBIAN_FRONTEND=noninteractive
APT_INSTALL="apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

log() { echo "[libreq1pro] $*"; }

# Runs a command as the printer user, in its home, with a login-like environment
as_user() {
	runuser -u "$U" -- env HOME="$HOME_U" USER="$U" LOGNAME="$U" TERM=dumb \
		DEBIAN_FRONTEND=noninteractive \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		bash -c "cd ~ && $1"
}

kiauh() {
	as_user "PYTHONPATH=~/kiauh python3 ~/kiauh/kiauh/main.py $*"
}

moonraker_section() {
	local section=$1 body=$2 conf=$HOME_U/printer_data/config/moonraker.conf
	grep -qxF "[$section]" "$conf" && return 0
	printf '\n[%s]\n%s\n' "$section" "$body" >> "$conf"
}

# update_manager NAME PATH ORIGIN [EXTRA LINES]: a git_repo entry of Moonraker's update manager
update_manager() {
	local name=$1 path=$2 origin=$3 extra=${4:-}
	moonraker_section "update_manager $name" "type: git_repo
path: $path
origin: $origin${extra:+
$extra}"
}

# fails the build unless FILE has the exact line LINE
require_line() {
	grep -qxF -- "$2" "$1" || {
		echo "$2 missing in $1" >&2
		exit 1
	}
}

base_system() {
	log "Base packages"
	apt-get update
	# network-manager without recommends: it recommends modemmanager
	$APT_INSTALL --no-install-recommends network-manager
	$APT_INSTALL git sudo curl wget eject dkms python3 python3-venv python3-virtualenv \
		python3-dev python3-pil python3-numpy python3-matplotlib libopenblas-dev \
		ffmpeg polkitd pkexec systemd-timesyncd rsync
	# to build the MCU firmware on the printer: make, gcc/g++ (elf2uf2) and the ARM cross toolchain
	$APT_INSTALL build-essential gcc-arm-none-eabi binutils-arm-none-eabi \
		libnewlib-arm-none-eabi

	log "No netplan: NetworkManager owns every interface"
	apt-get purge -y netplan.io 'libnetplan*' 2>/dev/null || true
	rm -rf /etc/netplan
	systemctl disable systemd-networkd.service systemd-networkd.socket \
		systemd-networkd-wait-online.service 2>/dev/null || true
	systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
	systemctl enable NetworkManager.service systemd-resolved.service systemd-timesyncd.service
}

printer_user() {
	log "User $U ($PRINTER_UID:$PRINTER_GID)"
	if getent passwd "$PRINTER_UID" >/dev/null && [ "$(id -nu "$PRINTER_UID")" != "$U" ]; then
		echo "UID $PRINTER_UID is taken by $(id -nu "$PRINTER_UID")" >&2
		exit 1
	fi
	getent group "$U" >/dev/null || groupadd -g "$PRINTER_GID" "$U"
	id "$U" >/dev/null 2>&1 || useradd -m -u "$PRINTER_UID" -g "$PRINTER_GID" -s /bin/bash "$U"
	echo "$U:$PRINTER_PASSWORD" | chpasswd
	# UARTs (dialout, tty), nmcli (netdev), camera (video), USB drives (plugdev)
	for g in sudo dialout tty netdev video plugdev input render; do
		getent group "$g" >/dev/null || groupadd -r "$g"
		usermod -aG "$g" "$U"
	done

	# The account is preset: no Armbian first-login wizard, no default root password
	rm -f /root/.not_logged_in_yet
	passwd -l root
}

BUILD_SUDO_PID=
stop_build_sudo() {
	if [ -n "$BUILD_SUDO_PID" ]; then
		kill "$BUILD_SUDO_PID" 2>/dev/null || true
		wait "$BUILD_SUDO_PID" 2>/dev/null || true
		BUILD_SUDO_PID=
	fi
	rm -f /tmp/libreq1pro-sudo.sock /usr/local/sbin/sudo
}

build_shims() {
	# A server left running would keep the chroot busy when Armbian unmounts it
	trap stop_build_sudo EXIT
	install -m 755 "$OVERLAY/build/build-sudo.py" /usr/local/sbin/sudo
	/usr/local/sbin/sudo --serve &
	BUILD_SUDO_PID=$!
	for _ in $(seq 50); do
		[ -S /tmp/libreq1pro-sudo.sock ] && break
		sleep 0.2
	done
	as_user "sudo true"

	# /usr/local/sbin is before /usr/bin in PATH, also in sudo's
	cat > /usr/local/sbin/systemctl <<- 'EOF'
		#!/bin/sh
		# build-time systemctl: no systemd runs in the chroot
		for arg in "$@"; do
			case $arg in
			-*) continue ;;
			start | stop | restart | try-restart | reload | reload-or-restart | daemon-reload | daemon-reexec | reboot | poweroff)
				exit 0 ;;
			is-active) echo inactive; exit 3 ;;
			*) break ;;
			esac
		done
		exec /usr/bin/systemctl "$@"
	EOF
	chmod 755 /usr/local/sbin/systemctl
}

install_kiauh_stack() {
	log "KIAUH"
	as_user "git clone --depth 1 -b $KIAUH_BRANCH $KIAUH_REPO ~/kiauh"
	# kiauh.cfg: the Klipper fork instead of Klipper3d/klipper, the web UI ports
	python3 -I - "$HOME_U/kiauh/default.kiauh.cfg" "$HOME_U/kiauh/kiauh.cfg" \
		"$KLIPPER_REPO, $KLIPPER_BRANCH" "$MAINSAIL_PORT" "$FLUIDD_PORT" <<- 'PY'
		import re, sys
		src, dst, repo, mainsail, fluidd = sys.argv[1:]
		s = open(src).read()
		s = re.sub(r"(\[klipper\][^\[]*?repositories:\n)(    .*\n)+",
		           lambda m: m.group(1) + "    " + repo + "\n", s, count=1)
		s = re.sub(r"(\[mainsail\]\nport: )\d+", lambda m: m.group(1) + mainsail, s)
		s = re.sub(r"(\[fluidd\]\nport: )\d+", lambda m: m.group(1) + fluidd, s)
		open(dst, "w").write(s)
	PY
	chown "$U:$U" "$HOME_U/kiauh/kiauh.cfg"
	grep -qF "    $KLIPPER_REPO" "$HOME_U/kiauh/kiauh.cfg"

	log "Klipper (KIAUH)"
	kiauh install klipper --count 1

	log "Input shaping: NumPy in klippy-env"
	# shellcheck disable=SC2088 # ~ expands in the user's shell
	as_user "~/klippy-env/bin/pip install --no-cache-dir numpy"
	# shellcheck disable=SC2088
	as_user "~/klippy-env/bin/python -c 'import numpy'"

	log "Printer config"
	as_user "mkdir ~/QIDI_Q1_Pro"
	as_user "git clone -b $PRINTER_CONFIG_BRANCH $PRINTER_CONFIG_REPO ~/QIDI_Q1_Pro/config"
	# copies, not links: Klipper writes SAVE_CONFIG into printer.cfg
	as_user "cp ~/QIDI_Q1_Pro/config/klipper/printer.cfg ~/QIDI_Q1_Pro/config/klipper/gcode_macro.cfg ~/printer_data/config/"
	as_user "git clone $PRINTER_FIRMWARE_REPO ~/QIDI_Q1_Pro/firmware"
	as_user "git clone $PRINTER_STOCK_FIRMWARE_REPO ~/QIDI_Q1_Pro/stock-firmware"
	as_user "touch ~/printer_data/config/saved_variables.cfg"
	as_user "git clone -b $KATAPULT_BRANCH $KATAPULT_REPO ~/katapult"

	log "Moonraker (KIAUH)"
	sed "s|^klippy_uds_address: .*|klippy_uds_address: $HOME_U/printer_data/comms/klippy.sock|" \
		"$OVERLAY/moonraker.conf" > "$HOME_U/printer_data/config/moonraker.conf"
	chown "$U:$U" "$HOME_U/printer_data/config/moonraker.conf"
	kiauh install moonraker
	# allowed services for Moonraker's machine control (its defaults + librescreen)
	as_user "{ cat ~/moonraker/moonraker/assets/default_allowed_services; echo librescreen; } > ~/printer_data/moonraker.asvc"

	log "Mainsail :$MAINSAIL_PORT (KIAUH)"
	kiauh install mainsail --port "$MAINSAIL_PORT"
	if [ "$INSTALL_FLUIDD" = yes ]; then
		log "Fluidd :$FLUIDD_PORT (KIAUH)"
		kiauh install fluidd --port "$FLUIDD_PORT"
	fi
	rm -f /etc/nginx/sites-enabled/default
}

install_timelapse() {
	log "moonraker-timelapse"
	as_user "git clone $TIMELAPSE_REPO ~/moonraker-timelapse"
	# what its install.sh does, without the prompts
	as_user "ln -sf ~/moonraker-timelapse/component/timelapse.py ~/moonraker/moonraker/components/timelapse.py"
	as_user "grep -qxF 'moonraker/components/timelapse.py' ~/moonraker/.git/info/exclude || echo 'moonraker/components/timelapse.py' >> ~/moonraker/.git/info/exclude"
	as_user "ln -sf ~/moonraker-timelapse/klipper_macro/timelapse.cfg ~/printer_data/config/timelapse.cfg"
	moonraker_section "timelapse" ""
	# shellcheck disable=SC2088 # Moonraker expands the ~
	update_manager timelapse "~/moonraker-timelapse" "$TIMELAPSE_REPO" "primary_branch: main
managed_services: klipper moonraker"
}

install_crowsnest() {
	log "crowsnest"
	as_user "git clone $CROWSNEST_REPO ~/crowsnest"
	# its unattended mode (as in MainsailOS); adds its own update_manager entry
	(cd "$HOME_U/crowsnest" && BASE_USER=$U CROWSNEST_UNATTENDED=1 CROWSNEST_SKIP_REBOOT_PROMPT=1 \
		CROWSNEST_ADD_CROWSNEST_MOONRAKER=1 make install)
	# the camera settings come with the printer config (device /dev/webcam, from 70-webcam.rules)
	as_user "cp ~/QIDI_Q1_Pro/config/klipper/crowsnest.conf ~/printer_data/config/crowsnest.conf"
	grep -q '^device: /dev/webcam' "$HOME_U/printer_data/config/crowsnest.conf" || {
		echo "crowsnest.conf from the printer config has no 'device: /dev/webcam' line" >&2
		exit 1
	}
	moonraker_section "webcam Webcam" "service: mjpegstreamer
stream_url: /webcam/?action=stream
snapshot_url: /webcam/?action=snapshot
aspect_ratio: 16:9"
}

install_klipperscreen() {
	log "KlipperScreen (Wayland, labwc)"
	as_user "git clone $KLIPPERSCREEN_REPO ~/KlipperScreen"
	# installer answers: Wayland, no compositor of its own (wrong DRM device, no rotation), keep our NetworkManager
	as_user "SERVICE=Y BACKEND=W COMPOSITOR=none NETWORK=n START=0 ~/KlipperScreen/scripts/KlipperScreen-install.sh"
	# labwc runs screen.py through a drop-in of the installer's unit; rotation and touch are in ~/.config/labwc
	apt-get install -y labwc wlr-randr wlopm
	install -d /etc/systemd/system/KlipperScreen.service.d
	sed "s|@HOME@|$HOME_U|g" "$OVERLAY/KlipperScreen.service.d/10-labwc.conf" > /etc/systemd/system/KlipperScreen.service.d/10-labwc.conf
	install -d -o "$U" -g "$U" "$HOME_U/.config" "$HOME_U/.config/labwc"
	install -m 644 -o "$U" -g "$U" "$OVERLAY/labwc/autostart" "$OVERLAY/labwc/rc.xml" "$HOME_U/.config/labwc/"
	# use_dpms: the screensaver powers the panel off (wlopm); KlipperScreen's own settings go below
	as_user "install -d ~/printer_data/config && printf '[main]\\nuse_dpms = True\\n\\n' > ~/printer_data/config/KlipperScreen.conf"
	update_manager KlipperScreen "$HOME_U/KlipperScreen" "$KLIPPERSCREEN_REPO" "managed_services: KlipperScreen
env: $HOME_U/.KlipperScreen-env/bin/python
requirements: $HOME_U/KlipperScreen/scripts/KlipperScreen-requirements.txt
install_script: $HOME_U/KlipperScreen/scripts/KlipperScreen-install.sh"
}

install_librescreen() {
	local dir=$HOME_U/$LIBRESCREEN_DIR c
	log "LibreScreen in $dir"
	as_user "git clone -b $LIBRESCREEN_BRANCH $LIBRESCREEN_REPO $dir"
	c=$dir/contrib

	# its README's install steps, with the paths of this image
	sed -e "s|^User=.*|User=$U|" -e "s|/home/mks/librescreen|$dir|g" -e "s|/home/mks/|$HOME_U/|g" \
		-e 's|^SupplementaryGroups=.*|SupplementaryGroups=dialout netdev|' \
		"$c/systemd/librescreen.service" > /etc/systemd/system/librescreen.service
	sed "s|subject.user == \"mks\"|subject.user == \"$U\"|" \
		"$c/systemd/50-librescreen.rules" > /etc/polkit-1/rules.d/50-librescreen.rules
	install -m 755 "$c/usb-automount/librescreen-usb-mount" /usr/local/sbin/
	install -m 644 "$c/usb-automount/librescreen-usb-mount@.service" /etc/systemd/system/
	install -m 644 "$c/usb-automount/99-librescreen-usb.rules" /etc/udev/rules.d/
	sed "s|^LIBRESCREEN_USER=.*|LIBRESCREEN_USER=$U|" \
		"$c/usb-automount/librescreen-usb.default" > /etc/default/librescreen-usb
	# ReadWritePaths= must exist when the service starts
	as_user "mkdir -p ~/.local/share/librescreen"
	systemctl enable librescreen.service

	update_manager librescreen "$dir" "$LIBRESCREEN_REPO" "primary_branch: $LIBRESCREEN_BRANCH
managed_services: librescreen"
}

install_aic8800() {
	local d url kdir kver built=0
	log "AIC8800 USB Wi-Fi (DKMS)"
	d=$(mktemp -d)
	for url in $AIC8800_DEBS; do
		(cd "$d" && curl -fsSLO "$url")
	done
	$APT_INSTALL "$d"/*.deb
	rm -rf "$d"
	# build for the image's kernel, not the build host's (uname -r)
	for kdir in /lib/modules/*/; do
		kver=$(basename "$kdir")
		[ -e "$kdir/build" ] || continue
		dkms autoinstall -k "$kver"
		find "/lib/modules/$kver/updates" -name 'aic8800*.ko*' | grep -q . || {
			echo "aic8800: no module built for $kver" >&2
			exit 1
		}
		built=1
	done
	[ "$built" = 1 ] || {
		echo "aic8800: no kernel headers in the image (INSTALL_HEADERS=yes?)" >&2
		exit 1
	}
}

uart1_overlay() {
	log "uart1 without DMA (display UART)"
	$APT_INSTALL device-tree-compiler
	mkdir -p /boot/overlay-user
	dtc -@ -I dts -O dtb -o /boot/overlay-user/libreq1pro-uart1-nodma.dtbo \
		"$OVERLAY/libreq1pro-uart1-nodma.dts"
	chmod 644 /boot/overlay-user/libreq1pro-uart1-nodma.dtbo
	# it must apply to the board's device tree and leave uart1 without a tx/rx DMA channel
	local dtb tmp
	dtb=$(find /boot -name rk3328-qidi-x6.dtb | head -n 1)
	[ -n "$dtb" ] || { echo "rk3328-qidi-x6.dtb not found in /boot" >&2; exit 1; }
	tmp=$(mktemp)
	fdtoverlay -i "$dtb" -o "$tmp" /boot/overlay-user/libreq1pro-uart1-nodma.dtbo
	[ "$(fdtget "$tmp" /serial@ff120000 dma-names)" = "tx-off rx-off" ] || {
		echo "the uart1 overlay did not take the DMA channels away from uart1" >&2
		exit 1
	}
	[ "$(fdtget "$tmp" /serial@ff110000 dma-names)" = "tx rx" ] || {
		echo "the uart1 overlay changed the DMA of another UART" >&2
		exit 1
	}
	rm -f "$tmp"
	# the setting is in bootenv/rockchip64.txt
	require_line /boot/armbianEnv.txt user_overlays=libreq1pro-uart1-nodma
}

system_tweaks() {
	log "System tweaks"
	# the overlay belongs to the build host's user: copy it as root
	cp -r --no-preserve=mode,ownership "$OVERLAY/rootfs/." /
	# --no-preserve=mode drops the exec bit: the only executable file in the overlay
	chmod 755 /usr/local/sbin/libreq1pro-wifi
	# Wi-Fi from a file on the FAT boot partition (for Windows users)
	install -m 644 "$OVERLAY/libreq1pro-wifi.txt" /boot/libreq1pro-wifi.txt
	systemctl enable libreq1pro-wifi.service
	systemctl mask serial-getty@ttyS0.service serial-getty@ttyS1.service serial-getty@ttyS2.service
	# set in bootenv/rockchip64.txt, checked so an Armbian default change cannot undo them
	require_line /boot/armbianEnv.txt console=display
	require_line /boot/armbianEnv.txt "extraargs=cpuidle.off=1 fbcon=font:6x10"
	# console-setup would switch to its own (bigger) font after the kernel's: leave the font alone
	sed -i 's/^FONTFACE=.*/FONTFACE=""/; s/^FONTSIZE=.*/FONTSIZE=""/' /etc/default/console-setup
	apt-get purge -y modemmanager brltty 2>/dev/null || true
}

usb_first_boot() {
	log "USB first boot"
	# Armbian builds boot.scr from boot.cmd when it writes the image
	[ -f /boot/boot.cmd ] || {
		echo "/boot/boot.cmd not found" >&2
		exit 1
	}
	grep -qF '# libreq1pro: usb-first' /boot/boot.cmd && return 0
	# booti only returns when it fails
	{
		cat "$OVERLAY/usb-first.cmd" /boot/boot.cmd
		printf '\necho "Boot failed"\nrun led_error\n'
	} > /boot/boot.cmd.new
	mv /boot/boot.cmd.new /boot/boot.cmd
}

cleanup() {
	log "Cleanup"
	stop_build_sudo
	rm -f /usr/local/sbin/systemctl
	chown -R "$U:$U" "$HOME_U"
	as_user "rm -rf ~/.cache ~/.bash_history"
	apt-get autoremove -y
	apt-get clean
}

main() {
	base_system
	printer_user
	build_shims
	install_kiauh_stack
	install_timelapse
	if [ "$INSTALL_CROWSNEST" = yes ]; then install_crowsnest; fi
	if [ "$INSTALL_KLIPPERSCREEN" = yes ]; then install_klipperscreen; fi
	install_librescreen
	install_aic8800
	uart1_overlay
	system_tweaks
	usb_first_boot
	cleanup
	log "Done"
}

main "$@"
