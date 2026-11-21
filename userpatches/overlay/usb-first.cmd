# libreq1pro: usb-first
# Boots a system from a USB drive if there is one, else continues with this one.
# usb_checked (RAM only) stops a USB image carrying this script from scanning USB again forever.

# LEDs: RK805 (I2C1, 0x18) register 0x52 = ${led}; bit0: 0 blue, 1 green; bit1: 0 yellow on.
# Needs CONFIG_CMD_I2C and CONFIG_CMD_REGULATOR (config-libreq1pro.conf).
if i2c dev 1; then setenv led_ok 1; else setenv led_ok 0; fi
setenv led_set 'if test "${led_ok}" = 1; then i2c mw 0x18 0x52 ${led}; fi'
setenv led_blink 'for led_i in ${led_count}; do setenv led ${led_a}; run led_set; sleep ${led_t}; setenv led ${led_b}; run led_set; sleep ${led_t}; done; setenv led ${led_end}; run led_set'
setenv led_usb 'setenv led_a 00; setenv led_b 02; setenv led_t 0.2; setenv led_count "1 2 3"; setenv led_end 00; run led_blink'
setenv led_emmc 'setenv led_a 03; setenv led_b 01; setenv led_t 0.2; setenv led_count "1 2 3"; setenv led_end 00; run led_blink'
setenv led_error 'setenv led_a 00; setenv led_b 01; setenv led_t 0.08; setenv led_count "1 2 3 4 5 6 7 8 9 10 11 12"; setenv led_end 02; run led_blink'

if test "${devtype}" != "usb" && test "${usb_checked}" != "1"; then
	setenv usb_checked 1
	setenv self_devtype ${devtype}
	setenv self_devnum ${devnum}
	setenv self_bootpart ${distro_bootpart}
	setenv self_prefix ${prefix}
	setenv self_fdtfile ${fdtfile}

	for led_r in 01 03 02 00; do
		sleep 0.1
		setenv led ${led_r}
		run led_set
	done

	regulator dev vcc_host1_5v && regulator enable
	sleep 1
	usb start

	for usb_n in 0 1 2 3; do
		for usb_p in 1 2; do
			for usb_pre in / /boot/; do
				if test -e usb ${usb_n}:${usb_p} ${usb_pre}extlinux/extlinux.conf; then
					echo "Booting USB ${usb_n}:${usb_p} ${usb_pre}extlinux/extlinux.conf"
					run led_usb
					sysboot usb ${usb_n}:${usb_p} any ${pxefile_addr_r} ${usb_pre}extlinux/extlinux.conf
					echo "USB boot failed"
					run led_error
				fi
				if test -e usb ${usb_n}:${usb_p} ${usb_pre}boot.scr; then
					echo "Booting USB ${usb_n}:${usb_p} ${usb_pre}boot.scr"
					setenv devtype usb
					setenv devnum ${usb_n}
					setenv distro_bootpart ${usb_p}
					setenv prefix ${usb_pre}
					if test -e usb ${usb_n}:${usb_p} ${usb_pre}dtb/rockchip/rk3328-qidi-x6.dtb; then
						setenv fdtfile rockchip/rk3328-qidi-x6.dtb
					elif test -e usb ${usb_n}:${usb_p} ${usb_pre}dtb/rockchip/rk3328-mkspi.dtb; then
						setenv fdtfile rockchip/rk3328-mkspi.dtb
					fi
					run led_usb
					load usb ${usb_n}:${usb_p} ${pxefile_addr_r} ${usb_pre}boot.scr
					source ${pxefile_addr_r}
					echo "USB boot failed"
					run led_error
				fi
			done
		done
	done

	echo "No system on USB, booting ${self_devtype} ${self_devnum}:${self_bootpart}"
	setenv devtype ${self_devtype}
	setenv devnum ${self_devnum}
	setenv distro_bootpart ${self_bootpart}
	setenv prefix ${self_prefix}
	setenv fdtfile ${self_fdtfile}
	run led_emmc
fi

