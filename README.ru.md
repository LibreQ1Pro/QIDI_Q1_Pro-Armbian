# Образ Armbian для QIDI Q1 Pro

[English](README.md) · Русский

Armbian (Debian 13 trixie) для материнской платы QIDI Q1 Pro.

## Что есть в образе

| Компонент | Что в образе |
|---|---|
| Пользователь | `mks` (UID/GID 1000), пароль `makerbase`, группы `sudo dialout tty netdev video plugdev` |
| Сеть | Только NetworkManager (без netplan, networkd и ifupdown); `netdev` может пользоваться `nmcli` без root (polkit) |
| Klipper | [LibreQ1Pro/klipper](https://github.com/LibreQ1Pro/klipper), ставится через KIAUH: `~/klipper`, `~/klippy-env`, `~/printer_data` |
| Moonraker | через KIAUH; `moonraker.asvc` дополнительно разрешает `librescreen` |
| Веб-интерфейс | Mainsail на порту 80, Fluidd на порту 81 (nginx) |
| KIAUH | `~/kiauh`, `kiauh.cfg` использует форк Klipper |
| Конфиг принтера | `printer.cfg`, `gcode_macro.cfg` из [LibreQ1Pro/QIDI_Q1_Pro-Config](https://github.com/LibreQ1Pro/QIDI_Q1_Pro-Config) (клон в `~/QIDI_Q1_Pro/config`); `~/katapult` |
| LibreScreen | `~/LibreScreen`, `librescreen.service`, правило polkit и автомонтирование USB (накопители монтируются в `~/printer_data/gcodes/<имя>`) |
| KlipperScreen | форк [LibreQ1Pro/KlipperScreen](https://github.com/LibreQ1Pro/KlipperScreen) на Wayland: drop-in заставляет `KlipperScreen.service` запускать labwc с `screen.py` на USB-дисплее gud-esp32s3 (`USB-1`), поворот задаётся в `~/.config/labwc/autostart` |
| Таймлапс, камера | moonraker-timelapse + FFmpeg; crowsnest на `/dev/webcam` (`70-webcam.rules`; /dev/video0 — это видеодекодер SoC), `crowsnest.conf` из репозитория конфигурации принтера |
| Wi-Fi | `aic8800-firmware` + `aic8800-usb-dkms` из форка [LibreQ1Pro/aic8800](https://github.com/LibreQ1Pro/aic8800) (DKMS, собираются под ядро образа) |
| Файл Wi-Fi | `/boot/libreq1pro-wifi.txt`, см. [Wi-Fi без экрана](#wi-fi-без-экрана) |
| UART | `console=display`; нет getty на `ttyS0-2`; uart1 включён в DTS `qidi-x6` для дисплея, без DMA (оверлей `libreq1pro-uart1-nodma`); `99-q1pro-serial.rules`; нет ModemManager/brltty |
| Прошивки MCU | инструменты для сборки Klipper и Katapult на самом принтере (`build-essential`, `gcc-arm-none-eabi`, `libnewlib-arm-none-eabi`), см. [LibreQ1Pro/QIDI_Q1_Pro-Firmware](https://github.com/LibreQ1Pro/QIDI_Q1_Pro-Firmware); образы и `flash.sh` в `~/QIDI_Q1_Pro/firmware`, оригинальные прошивки QIDI в `~/QIDI_Q1_Pro/stock-firmware` |

## Загрузка с USB

Как в [LibreQ1Pro/QIDI_Q1_Pro-Recovery-Boot](https://github.com/LibreQ1Pro/QIDI_Q1_Pro-Recovery-Boot)
для стоковой прошивки: если на USB-накопителе есть система (`extlinux/extlinux.conf` или
`boot.scr` в `/` или `/boot/` раздела 1 или 2), принтер грузится с него, иначе с eMMC. Используйте
порты USB 2.0 на материнской плате. Без загрузочного накопителя загрузка занимает примерно на
3 секунды дольше (светодиоды, включение питания USB и сканирование).

`overlay/usb-first.cmd` ставится перед `boot.cmd` Armbian; `boot.scr` накопителя запускается с
`rk3328-qidi-x6.dtb` (или `rk3328-mkspi.dtb`) этого накопителя. Переменная `usb_checked`, живущая
только в RAM, заставляет скрипт пропустить сканирование USB, если она уже установлена или сам
скрипт загружен с USB, поэтому накопитель с этим же образом грузит свою систему, а не зацикливается.

Светодиоды на материнской плате показывают те же сигналы, что и QIDI_Q1_Pro-Recovery-Boot:

| Этап | Светодиоды |
|---|---|
| Загрузочный скрипт запущен | все светодиоды один раз быстро мигают |
| Загрузка с eMMC | горит зелёный, жёлтый мигает 3 раза |
| Загрузка с флешки | горит синий, жёлтый мигает 3 раза |
| Ошибка загрузки | синий и зелёный быстро мигают, затем остаётся гореть только синий |

## Wi-Fi без экрана

Загрузочный раздел имеет файловую систему FAT, поэтому его откроет любая ОС. После записи образа
отредактируйте на нём `libreq1pro-wifi.txt`:

```
SSID="My network"
PASSWORD="my password"
#COUNTRY=US        # необязательно, 2 буквы
#HIDDEN=yes        # необязательно
```

`libreq1pro-wifi.service` читает файл при каждой загрузке и создаёт или обновляет подключение
NetworkManager `libreq1pro-wifi` (WPA-PSK, либо открытая сеть без пароля); чтобы удалить его,
очистите `SSID`. Остальные подключения не затрагиваются, а без файла ничего не происходит. Пароль
хранится открытым текстом и виден всем, кто может открыть загрузочный раздел.

## Файлы

```
build.sh                    клонирует Armbian на коммите ARMBIAN_REF и запускает compile.sh
ARMBIAN_REF                 коммит armbian/build, на котором собирает CI
.github/workflows/          CI: собирает образ по тегам `v*` (или вручную) и прикрепляет его к релизу
userpatches/
├── config-libreq1pro.conf  плата, релиз, ветка ядра, консоль
├── bootenv/rockchip64.txt  значения armbianEnv.txt по умолчанию (console=display, cpuidle.off=1, fbcon=font:6x10)
├── customize-image.sh      всё, что ставится поверх Armbian (в chroot)
├── extensions/             пустой brostrend-aic8800-dkms: отключает собственный драйвер aic8800 платы
└── overlay/
    ├── libreq1pro.conf     пользователь, репозитории, порты, необязательные части
    ├── moonraker.conf      шаблон KIAUH, секции update_manager дописываются при сборке
    ├── build/build-sudo.py замена sudo на время сборки (setuid в chroot не работает)
    ├── usb-first.cmd       этап загрузки с USB, ставится перед boot.cmd Armbian
    ├── libreq1pro-wifi.txt шаблон Wi-Fi, копируется в /boot (скрипт и unit лежат в rootfs/)
    ├── KlipperScreen.service.d/10-labwc.conf   drop-in: unit запускает labwc с screen.py
    ├── labwc/              autostart (поворот) и rc.xml (привязка тача), копируются в ~/.config/labwc
    ├── libreq1pro-uart1-nodma.dts   оверлей: uart1 без DMA (компилируется в /boot/overlay-user)
    └── rootfs/             файлы, копируемые в / как есть
```

## Локальная сборка

```sh
./build.sh                                   # клонирует Armbian в ./armbian_build
ARMBIAN_DIR=../armbian_build ./build.sh      # или использует готовый checkout как есть
```

Образ лежит в `armbian_build/output/images/`. Чтобы перейти на более новый Armbian, меняйте
`ARMBIAN_REF` вместе с закреплённым ядром `KERNELBRANCH` в `userpatches/config-libreq1pro.conf`
(патчи Armbian перестают применяться, когда выходит следующий релиз ядра).

## Известные ограничения

- Менеджер обновлений Moonraker принимает Klipper только из Klipper3d/klipper и показывает форк
  как недопустимый. Обновляйте Klipper через KIAUH (`~/kiauh/kiauh.sh`), он использует форк из `kiauh.cfg`.
- U-Boot до старта Linux всё ещё печатает в `ttyS2` (`stdout-path` в device tree).
- KlipperScreen работает на дисплее GUD (`USB-1`) через drop-in `KlipperScreen.service.d/10-labwc.conf`
  (`labwc -S screen.py` в unit установщика). labwc использует все выходы, поэтому монитор на HDMI
  тоже получит изображение. Ориентация: `wlr-randr --output USB-1 --transform` в
  `overlay/labwc/autostart`; тач следует за выходом (`labwc/rc.xml`).
- Конфиги Xorg в `rootfs/etc/X11/xorg.conf.d/` нужны для бэкенда X11 (`BACKEND=X` в установщике
  KlipperScreen); с Wayland их никто не читает.
- Гашение экрана: KlipperScreen выключает панель через `wlopm`, когда запускается его скринсейвер,
  и включает обратно по касанию, закрывающему его (`use_dpms = True` в `KlipperScreen.conf`). Это
  патч к `screen.py` / `screensaver.py` форка; в оригинале на Wayland рисуется только чёрный квадрат.
- `/var/log` хранится в RAM (ramlog Armbian).
- **Открытая проблема: перезагрузка может зависнуть.** На тестовом принтере `reboot` (в том числе
  кнопка в Mainsail) часто оставляет плату «мёртвой», пока не отключат питание; холодные включения
  всегда работали (22 из 22), обычные перезагрузки не удались 14 раз подряд, а даже `sysrq b`
  не срабатывает примерно в половине случаев. Исключены: Wi-Fi, USB, звук и драйверы криптографии,
  отдельные сервисы, масштабирование частоты DDR, перезапуск через PMIC, износ eMMC. Где именно
  зависает (до U-Boot, в U-Boot или в ядре), пока не найдено. До исправления перезапускайте
  принтер выключением и включением питания.
- Консоль на дисплее 480x272 использует маленький шрифт ядра 6x10 (`fbcon=font:6x10`: 80x27 символов
  вместо 60x17); у `console-setup` пустые `FONTFACE`/`FONTSIZE`, чтобы он не переключался на больший.
- Ядро работает с `cpuidle.off=1` (`bootenv/rockchip64.txt`, проверяется при сборке): процессоры
  используют только обычный `WFI`, без глубокого состояния PSCI `cpu-sleep`. С ним тестовый принтер
  дважды замирал на часы без единой записи в логе (стоковое ядро 5.16 так не делало). Предположение,
  не доказанное: потеря пробуждения у программного широковещательного устройства `bc_hrtimer`, когда
  все процессоры в глубоком состоянии. Без него принтер проработал больше суток без зависаний;
  длинные печати ещё проверяются. Цена: чуть выше энергопотребление в простое.
- UART экрана (`uart1`, `ttyS1`) работает без DMA: с DMA в device tree `qidi-x6` прошивка экрана
  (`flash.sh display`, 921600 бод) случайно останавливала UART, и Klipper терял оба MCU. Оверлей
  `libreq1pro-uart1-nodma` (`bootenv/rockchip64.txt`, проверяется при сборке) убирает у него каналы
  DMA; UART MCU сохраняют свои. С ним 10 из 10 прошивок экрана прошли успешно, без него — ни одной.
  Причина не доказана: device tree `mkspi` не зависает, как и `qidi-x6` только с включённым SPI0;
  если выключить SPI0 на `mkspi`, зависание возвращается. Похоже на побочный эффект распределения
  каналов общего контроллера DMA.
