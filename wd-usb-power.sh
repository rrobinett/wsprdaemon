##########################################################################################################################################################
########## Section which power-cycles a hung or missing RX888 through a per-port power-switching USB hub (uhubctl) ########################################
##########################################################################################################################################################
###
### An RX888 that hangs, or that gets stuck in the FX3 bootloader (04b4:00f3 "WestBridge") because its firmware
### load keeps failing, can today only be recovered by someone at the site pulling its plug: radiod exits at once
### with "no device with serial ...", WD reports the radio as NOT on the USB bus, and the station is silent until
### a person visits (KX4AZ-T, 2026-09-06: dipole RX888 gone since a reboot, third RX888 looping in the bootloader).
###
### If the RX888 hangs off a hub that really switches VBUS per port, WD can pull that plug itself with uhubctl
### (https://github.com/mvp/uhubctl).  Most hubs advertise per-port switching in their descriptors but do not
### actually cut power, so only hubs on uhubctl's tested list work; the ones WD recommends are in wd-usb-power.md.
### A radio plugged straight into the computer can also be cycled if the root hub supports it (some do).
###
### What this file does:
###  - every WD start and every watchdog pass REMEMBERS where each programmed RX888 serial sits on the bus
###    (hub location + port, the '-l' and '-p' uhubctl wants) in ${WD_USB_POWER_MAP_FILE}.  When a radio later
###    vanishes WD still knows which port to cycle, and a radio stuck in the bootloader (whose USB serial is NOT
###    its RX888 serial) is cycled by the port it occupies.
###  - build_ka9q_radio() calls wd_usb_power_recover_rx888 SERIAL before it gives up on a radiod whose RX888
###    serial is not on the bus, and wd_boot_unprogrammed_rx888s() calls wd_usb_power_recover_bootloader_stuck
###    when the firmware loader has not managed to bring a bootloader-mode device up.
###  - the watchdog (wd_usb_power_check) cycles the port of any radiod@ instance that is not running because its
###    RX888 is missing, and restarts that radiod when the radio comes back.  Never more often than
###    WD_USB_POWER_CYCLE_MIN_MINUTES per port, so a dead radio is not hammered.
###  - the watchdog also recovers the OPPOSITE case: a radiod@ that is down while its RX888 IS on the bus, wedged so
###    that it enumerates but never streams.  wd_usb_power_recover_wedged_rx888 stops radiod (so it releases the
###    device), re-enumerates the device through sysfs 'authorized', starts radiod, and only then falls back to a
###    uhubctl power cycle.  Throttled to one attempt per device per WD_USB_REENUM_MIN_MINUTES.
###  - build_ka9q_radio() makes the same attempt when a radiod it just rebuilt will not start.
###  - every restart WD has to perform is recorded in ${WD_USB_RECOVERY_HISTORY_FILE} and reported with a running
###    24 hour / 7 day count, as a WARNING at first and an ERROR once it passes WD_USB_RECOVERY_WARN_PER_DAY a day.
###    A recovery that works is still a fault report: a radio needing one that often has a hardware problem, and
###    silently rescuing it every ten minutes would hide exactly the thing an operator needs to see.  'wd -u' lists it.
###  - 'wd -u' (wd-usb / wdu) shows the RX888s, their ports, which are switchable, and the log;
###    'wd -U SERIAL|PORT|all' cycles by hand.
### A radio on a 480 Mb/s USB 2 port is NEVER cycled: it can not work there, and that is what the operator must fix.
### WD_USB_POWER_CYCLE="no" in wsprdaemon.conf turns the cycling off (the bookkeeping and 'wd -u' still work).

declare WD_USB_POWER_CYCLE=${WD_USB_POWER_CYCLE-yes}
declare WD_USB_POWER_LOG_DIR=${WD_USB_POWER_LOG_DIR-/var/log/wsprdaemon}
declare WD_USB_POWER_LOG_FILE=${WD_USB_POWER_LOG_FILE-${WD_USB_POWER_LOG_DIR}/usb-power.log}
declare WD_USB_POWER_MAP_FILE=${WD_USB_POWER_MAP_FILE-${WD_USB_POWER_LOG_DIR}/rx888-ports.map}   ### lines: SERIAL HUB PORT SPEED LAST_SEEN
declare WD_USB_POWER_OFF_SECS=${WD_USB_POWER_OFF_SECS-5}                    ### uhubctl -d: how long the port stays off
declare WD_USB_POWER_REENUM_SECS=${WD_USB_POWER_REENUM_SECS-25}             ### re-enumeration + firmware load normally take < 10 s
declare WD_USB_PORT_DISABLE=${WD_USB_PORT_DISABLE-yes}                      ### cut the port through sysfs when the hub offers no uhubctl power switching
declare WD_USB_BOTH_HALVES_OFF_SECS=${WD_USB_BOTH_HALVES_OFF_SECS-6}        ### how long BOTH halves of a USB 3 jack stay down
declare WD_USB_OTHER_HALF_WAIT_SECS=${WD_USB_OTHER_HALF_WAIT_SECS-8}        ### how long to watch for the radio re-appearing on the other bus
declare WD_USB_POWER_CYCLE_MIN_MINUTES=${WD_USB_POWER_CYCLE_MIN_MINUTES-10} ### never cycle one port more often than this
declare WD_USB_POWER_CHECK_MINUTES=${WD_USB_POWER_CHECK_MINUTES-2}          ### watchdog throttle (the odd-minute pass is every 2 min anyway)
declare WD_USB_POWER_LAST_CHECK_EPOCH=0
declare WD_USB_POWER_HUB_HINT="see wd-usb-power.md for hubs that really switch power per port (RSHTECH/Rosonway 10-port on the uhubctl list, e.g. https://www.amazon.com/dp/B0DX6KR79L)"
declare WD_USB_RX888_VENDOR="04b4"
declare WD_USB_RX888_PROGRAMMED="00f1"
declare WD_USB_RX888_BOOTLOADER="00f3"

### A DIFFERENT failure from the missing/bootloader radios above, and the one uhubctl can not help with: the RX888 is
### enumerated and answers control traffic (radiod logs its hardware/firmware rev and programs the Si5351 sample rate)
### but never delivers bulk samples, so radiod prints "No rx888 data for 5 seconds, quitting" and then aborts inside
### libusb teardown (SIGABRT/core dump, which systemd reports as "a fatal signal was delivered causing the control
### process to dump core" and build_ka9q_radio() reports as a failed start).  radiod restarts, and fails the same way
### forever -- N6GN3 sat like that for ~30 hours on 2026-09-12/14, ~1600 cycles.
###
### radiod's own recovery can not clear it.  rx888.c calls libusb_reset_device(), which is a USB PORT RESET: the device
### re-enumerates and the kernel RESTORES the previous configuration, deliberately preserving kernel-side state.  On
### N6GN3 that restore itself failed -- "usb 2-1: can't restore configuration #1 (error=-110)" (ETIMEDOUT) -- leaving
### the device half-configured.  De-authorizing it instead makes the kernel tear the usbdev down completely and
### enumerate again from nothing, which cleared the wedge on the first try.  This needs no switchable hub, so it is
### also the ONLY software recovery available on a host whose RX888 sits on a root hub port (N6GN3 again: 'sudo uhubctl'
### there says "No compatible devices detected!").  WD therefore tries re-enumeration FIRST and falls back to a uhubctl
### power cycle only if the radio still will not stream.
### radiod must NOT be holding the device while this happens, hence the stop/toggle/start order below.
declare WD_USB_REENUMERATE=${WD_USB_REENUMERATE-yes}                          ### "no" turns this recovery off
declare WD_USB_REENUM_OFF_SECS=${WD_USB_REENUM_OFF_SECS-3}                    ### how long the device stays de-authorized
declare WD_USB_REENUM_MIN_MINUTES=${WD_USB_REENUM_MIN_MINUTES-10}             ### never re-enumerate one device more often than this
declare WD_USB_REENUM_LOOKBACK_MINUTES=${WD_USB_REENUM_LOOKBACK_MINUTES-15}   ### how far back to look for the wedge signature
declare WD_USB_REENUM_WEDGE_MIN_HITS=${WD_USB_REENUM_WEDGE_MIN_HITS-2}        ### 1 hit is a transient; a wedge repeats every ~12 s
declare WD_USB_REENUM_WEDGE_REGEX="No rx888 data for|usbi_mutex_lock: Assertion"

### A recovery that works is still a fault report: the radio should not have needed one.  WD records every restart it had
### to perform and says how often it is having to do it, so a radio that quietly needs rescuing twice an hour is not
### mistaken for a healthy one.  Rising counts here mean the cable, the power or the radio itself -- not WD.
declare WD_USB_RECOVERY_HISTORY_FILE=${WD_USB_RECOVERY_HISTORY_FILE-${WD_USB_POWER_LOG_DIR}/rx888-recoveries.log}
declare WD_USB_RECOVERY_HISTORY_MAX_LINES=${WD_USB_RECOVERY_HISTORY_MAX_LINES-500}
declare WD_USB_RECOVERY_WARN_PER_DAY=${WD_USB_RECOVERY_WARN_PER_DAY-3}      ### at or above this in 24 h, the WARNING becomes an ERROR

### Debian 13 installs uhubctl in /usr/sbin, which is not on the wsprdaemon user's PATH (the chronyd trap again), so
### never rely on 'command -v uhubctl' alone.  Echoes the binary's path, or nothing.
function wd_usb_power_uhubctl_path()
{
    local p
    for p in "$(command -v uhubctl 2>/dev/null)" /usr/sbin/uhubctl /usr/local/sbin/uhubctl /usr/local/bin/uhubctl /usr/bin/uhubctl; do
        [[ -n ${p} && -x ${p} ]] && { echo "${p}"; return 0; }
    done
    return 1
}

function wd_usb_power_log()
{
    local log_level=$1 log_line=$2
    if (( log_level == 1 )) && ! [[ ${log_line} =~ ^(ERROR|WARNING) ]]; then
        log_level=2                                   ### only ERROR/WARNING reach the terminal at the default verbosity
    fi
    wd_logger ${log_level} "${log_line}"
    (( log_level > 2 )) && return 0
    wd_usb_power_ensure_dir || return 0
    if [[ -f ${WD_USB_POWER_LOG_FILE} ]] && (( $(stat -c %s ${WD_USB_POWER_LOG_FILE} 2>/dev/null || echo 0) > 200000 )); then
        tail -n 200 ${WD_USB_POWER_LOG_FILE} > ${WD_USB_POWER_LOG_FILE}.tmp 2>/dev/null && mv ${WD_USB_POWER_LOG_FILE}.tmp ${WD_USB_POWER_LOG_FILE}
    fi
    printf '%s %b\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${log_line}" 2>/dev/null >> ${WD_USB_POWER_LOG_FILE}
    return 0
}

function wd_usb_power_ensure_dir()
{
    [[ -d ${WD_USB_POWER_LOG_DIR} && -w ${WD_USB_POWER_LOG_DIR} ]] && return 0
    sudo install -d -o "$(id -un)" -g "$(id -gn)" "${WD_USB_POWER_LOG_DIR}" 2>/dev/null
    [[ -w ${WD_USB_POWER_LOG_DIR} ]]
}

### Is there at least one RX888 (programmed or in the bootloader) on this host's USB bus?
function wd_usb_power_rx888_present()
{
    local d
    for d in /sys/bus/usb/devices/*/; do
        [[ -f ${d}/idVendor && $(cat ${d}/idVendor) == "${WD_USB_RX888_VENDOR}" ]] && return 0
    done
    return 1
}

### Install uhubctl (Debian/Ubuntu package) once, only on hosts that have an RX888.  Failure is a WARNING, not fatal.
function wd_usb_power_install()
{
    wd_usb_power_uhubctl_path > /dev/null && return 0
    wd_usb_power_rx888_present || return 0
    [[ ${WD_USB_POWER_CYCLE} == "no" ]] && return 0
    if install_debian_package uhubctl > /dev/null 2>&1 ; then
        wd_usb_power_log 1 "Installed uhubctl, so a hung RX888 behind a power-switching hub can be power cycled"
    else
        wd_usb_power_log 1 "WARNING: could not install uhubctl (no network, or not in this distribution's repository); WD can not power cycle a hung RX888 until it is installed: 'sudo apt install uhubctl' or build it from https://github.com/mvp/uhubctl"
    fi
    return 0
}

### Echoes the uhubctl locations of the hubs on this host that support per-port power switching, one per line ("2-1", "4").
### uhubctl with no arguments lists only such hubs.  Cached for the life of the process: it takes ~1 s and needs sudo.
declare WD_USB_POWER_HUBS_CACHE=""
declare WD_USB_POWER_HUBS_CACHED="no"
function wd_usb_power_switchable_hubs()
{
    if [[ ${WD_USB_POWER_HUBS_CACHED} == "no" ]]; then
        local uhubctl; uhubctl=$( wd_usb_power_uhubctl_path || true )
        if [[ -n ${uhubctl} ]]; then
            WD_USB_POWER_HUBS_CACHE=$( timeout 20 sudo "${uhubctl}" 2>/dev/null | sed -n 's/^Current status for hub \([^ ]*\) .*/\1/p' )
        fi
        WD_USB_POWER_HUBS_CACHED="yes"
    fi
    [[ -n ${WD_USB_POWER_HUBS_CACHE} ]] && echo "${WD_USB_POWER_HUBS_CACHE}"
    return 0
}

function wd_usb_power_hub_is_switchable()
{
    local hub=$1
    [[ -n ${hub} ]] && wd_usb_power_switchable_hubs | grep -qx -- "${hub}"
}

### Given a sysfs usb device name ("2-1.3", "4-2") echoes "HUB PORT" in uhubctl terms: "2-1 3", "4 2".
### A device directly on a root hub has no '.' in its name; its hub is the bus number.
function wd_usb_power_hub_port_of()
{
    local dev=${1##*/}
    dev=${dev%/}
    if [[ ${dev} == *.* ]]; then
        echo "${dev%.*} ${dev##*.}"
    elif [[ ${dev} == *-* ]]; then
        echo "${dev%%-*} ${dev#*-}"
    fi
}

### Echoes the sysfs device name of the RX888 with serial $1 (programmed devices only), or nothing
function wd_usb_power_dev_of_serial()
{
    local want=${1^^} d s
    for d in /sys/bus/usb/devices/*/; do
        [[ -f ${d}/idVendor && $(cat ${d}/idVendor) == "${WD_USB_RX888_VENDOR}" && $(cat ${d}/idProduct) == "${WD_USB_RX888_PROGRAMMED}" ]] || continue
        s=$( tr -d '\n' < ${d}/serial 2>/dev/null ); s=${s^^}
        if [[ ${s} == "${want}" ]]; then d=${d%/}; echo "${d##*/}"; return 0; fi
    done
    return 1
}

### Remember where every programmed RX888 sits now.  One line per serial: SERIAL HUB PORT SPEED LAST_SEEN_UTC
function wd_usb_power_learn_ports()
{
    wd_usb_power_ensure_dir || return 0
    local d s pid speed hp now=$(date -u +%Y-%m-%dT%H:%M:%SZ) tmp="${WD_USB_POWER_MAP_FILE}.tmp"
    [[ -f ${WD_USB_POWER_MAP_FILE} ]] && cp "${WD_USB_POWER_MAP_FILE}" "${tmp}" 2>/dev/null || : > "${tmp}"
    for d in /sys/bus/usb/devices/*/; do
        [[ -f ${d}/idVendor && $(cat ${d}/idVendor) == "${WD_USB_RX888_VENDOR}" && $(cat ${d}/idProduct) == "${WD_USB_RX888_PROGRAMMED}" ]] || continue
        s=$( tr -d '\n' < ${d}/serial 2>/dev/null ); s=${s^^}
        [[ -n ${s} ]] || continue
        speed=$( cat ${d}/speed 2>/dev/null )
        d=${d%/}
        hp=$( wd_usb_power_hub_port_of "${d##*/}" )
        [[ -n ${hp} ]] || continue
        grep -v "^${s} " "${tmp}" > "${tmp}.2" 2>/dev/null; mv "${tmp}.2" "${tmp}"
        echo "${s} ${hp} ${speed:-0} ${now}" >> "${tmp}"
    done
    sort -o "${tmp}" "${tmp}" && mv "${tmp}" "${WD_USB_POWER_MAP_FILE}"
    return 0
}

### Echoes "HUB PORT SPEED LAST_SEEN" remembered for serial $1, or nothing
function wd_usb_power_remembered()
{
    local want=${1^^}
    [[ -f ${WD_USB_POWER_MAP_FILE} ]] || return 1
    awk -v s="${want}" '$1 == s {print $2, $3, $4, $5; exit}' "${WD_USB_POWER_MAP_FILE}"
}

### Has HUB/PORT been cycled in the last WD_USB_POWER_CYCLE_MIN_MINUTES?  0 = yes (too soon)
function wd_usb_power_cycled_recently()
{
    local stamp="${WD_USB_POWER_LOG_DIR}/usb-power.last.${1}-${2}"
    [[ -f ${stamp} ]] || return 1
    local age=$(( $(printf "%(%s)T") - $(stat -c %Y "${stamp}" 2>/dev/null || echo 0) ))
    (( age < WD_USB_POWER_CYCLE_MIN_MINUTES * 60 ))
}

### Cycle HUB PORT.  $3 = what for the log.  Returns 0 after the port is back on and the re-enumeration wait is over,
### 2 when this hub can not switch power, 3 when throttled, 1 when uhubctl failed.
function wd_usb_power_cycle_port()
{
    local hub=$1 port=$2 why=${3:-}
    if [[ ${WD_USB_POWER_CYCLE} == "no" ]]; then
        wd_usb_power_log 1 "WARNING: not power cycling usb hub ${hub} port ${port} (${why}): WD_USB_POWER_CYCLE=no"
        return 2
    fi
    local uhubctl; uhubctl=$( wd_usb_power_uhubctl_path || true )
    if [[ -z ${uhubctl} ]]; then
        wd_usb_power_log 1 "ERROR: can not power cycle usb hub ${hub} port ${port} (${why}): uhubctl is not installed ('sudo apt install uhubctl')"
        return 2
    fi
    if ! wd_usb_power_hub_is_switchable "${hub}"; then
        wd_usb_power_log 1 "ERROR: can not power cycle usb hub ${hub} port ${port} (${why}): that hub does not switch power per port (switchable hubs here: $(wd_usb_power_switchable_hubs | tr '\n' ' ')); ${WD_USB_POWER_HUB_HINT}"
        return 2
    fi
    if wd_usb_power_cycled_recently "${hub}" "${port}"; then
        wd_usb_power_log 2 "usb hub ${hub} port ${port} was cycled less than ${WD_USB_POWER_CYCLE_MIN_MINUTES} minutes ago, not again yet (${why})"
        return 3
    fi
    wd_usb_power_ensure_dir && touch "${WD_USB_POWER_LOG_DIR}/usb-power.last.${hub}-${port}"
    wd_usb_power_log 1 "WARNING: power cycling usb hub ${hub} port ${port} for ${WD_USB_POWER_OFF_SECS} seconds: ${why}"
    local out rc
    out=$( timeout 60 sudo "${uhubctl}" -l "${hub}" -p "${port}" -a cycle -d "${WD_USB_POWER_OFF_SECS}" -r 3 2>&1 ); rc=$?
    if (( rc )); then
        wd_usb_power_log 1 "ERROR: 'sudo uhubctl -l ${hub} -p ${port} -a cycle -d ${WD_USB_POWER_OFF_SECS}' => ${rc}:\n${out}"
        return 1
    fi
    wd_usb_power_log 2 "uhubctl:\n${out}"
    wd_usb_power_log 2 "Waiting up to ${WD_USB_POWER_REENUM_SECS} seconds for the device to re-enumerate and load its firmware"
    return 0
}

### Wait until the programmed RX888 with serial $1 is on the bus, at most WD_USB_POWER_REENUM_SECS.  0 = it is.
function wd_usb_power_wait_for_serial()
{
    local want=${1^^} waited=0
    while (( waited < WD_USB_POWER_REENUM_SECS )); do
        wd_usb_power_dev_of_serial "${want}" > /dev/null && return 0
        sleep 1
        (( ++waited ))
    done
    wd_usb_power_dev_of_serial "${want}" > /dev/null
}

### The RX888 with serial $1 is wanted by a radiod but is not on the bus (or is hung while enumerated, when $2 = "hung").
### Cycle the port it sits on / was last seen on.  0 = the radio is back and programmed.
function wd_usb_power_recover_rx888()
{
    local want=${1^^} mode=${2:-missing} dev hp hub port speed seen
    dev=$( wd_usb_power_dev_of_serial "${want}" || true )
    if [[ -n ${dev} ]]; then
        hp=$( wd_usb_power_hub_port_of "${dev}" ); speed=$( cat /sys/bus/usb/devices/${dev}/speed 2>/dev/null ); seen="now"
    else
        read -r hub port speed seen <<< "$( wd_usb_power_remembered "${want}" || true )"
        hp="${hub:-} ${port:-}"
    fi
    read -r hub port <<< "${hp}"
    if [[ -z ${hub} || -z ${port} ]]; then
        wd_usb_power_log 1 "ERROR: RX888 ${want} is not on the USB bus and WD has never seen it on this host, so it does not know which hub port to power cycle.  Plug it in once and WD will remember its port"
        return 1
    fi
    if (( ${speed:-5000} < 5000 )); then
        wd_usb_power_log 1 "ERROR: RX888 ${want} is (was, at ${seen}) on usb hub ${hub} port ${port}, a ${speed} Mb/s USB 2 port where it can never work; move it to a USB 3 port instead of power cycling it"
        return 1
    fi
    wd_usb_power_cycle_port "${hub}" "${port}" "RX888 ${want} (${mode}; last seen there ${seen}) is wanted by radiod" || return 1
    if wd_usb_power_wait_for_serial "${want}"; then
        wd_usb_power_log 1 "WARNING: RX888 ${want} is back on usb hub ${hub} port ${port} after the power cycle"
        wd_usb_power_learn_ports
        return 0
    fi
    wd_usb_power_log 1 "ERROR: RX888 ${want} did not reappear on usb hub ${hub} port ${port} within ${WD_USB_POWER_REENUM_SECS} seconds of a power cycle; it is unplugged, dead, or on another port"
    return 1
}

### Cycle every device that is sitting in the FX3 bootloader on a SuperSpeed port (the firmware load has failed repeatedly).
### 0 = none left in the bootloader afterwards.
function wd_usb_power_recover_bootloader_stuck()
{
    local d dev speed hub port did=0
    for d in /sys/bus/usb/devices/*/; do
        [[ -f ${d}/idVendor && $(cat ${d}/idVendor) == "${WD_USB_RX888_VENDOR}" && $(cat ${d}/idProduct) == "${WD_USB_RX888_BOOTLOADER}" ]] || continue
        speed=$( cat ${d}/speed 2>/dev/null ); d=${d%/}; dev=${d##*/}
        if (( ${speed:-0} < 5000 )); then
            wd_usb_power_log 2 "The bootloader-mode device at usb ${dev} is on a ${speed} Mb/s USB 2 port; power cycling can not help it"
            continue
        fi
        read -r hub port <<< "$( wd_usb_power_hub_port_of "${dev}" )"
        wd_usb_power_cycle_port "${hub}" "${port}" "device at usb ${dev} is stuck in the FX3 bootloader (04b4:00f3)" && did=1
    done
    (( did )) || return 1
    sleep "${WD_USB_POWER_REENUM_SECS}"
    ! lsusb -d ${WD_USB_RX888_VENDOR}:${WD_USB_RX888_BOOTLOADER} > /dev/null 2>&1
}

### Echoes the upper-case RX888 serial configured in ${KA9Q_RADIOD_CONF_DIR}/radiod@$1.conf, or nothing (also for FILL_IN placeholders)
function wd_usb_power_serial_of_instance()
{
    local s
    s=$( awk -F= '/^[[:space:]]*serial[[:space:]]*=/{v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]#].*$/,"",v); print toupper(v); exit}' "${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@${1}.conf" 2>/dev/null )
    [[ -n ${s} && ${s} != FILL_IN* ]] && echo "${s}"
    return 0
}

### Echoes the sysfs usb device ("2-1") of the RX888 that radiod@$1 uses, or nothing.
### Most confs name a serial, but a single-radio site often has no 'serial =' line at all and that instance then gets
### whatever RX888 is on the bus (N6GN3, 2026-09-14 -- keying recovery off the serial alone skipped that host entirely).
### Only resolve the serial-less case when it is unambiguous: exactly one conf without a serial AND exactly one
### programmed RX888 present.  Otherwise WD would be guessing which radio belongs to which radiod.
function wd_usb_power_dev_of_instance()
{
    local inst=$1 serial conf other d
    serial=$( wd_usb_power_serial_of_instance "${inst}" )
    if [[ -n ${serial} ]]; then
        wd_usb_power_dev_of_serial "${serial}"
        return
    fi
    local -a noserial=() present=()
    for conf in ${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@*.conf ; do
        [[ -f ${conf} ]] || continue
        other=${conf##*/radiod@}; other=${other%.conf}
        [[ -z $( wd_usb_power_serial_of_instance "${other}" ) ]] && noserial+=( "${other}" )
    done
    (( ${#noserial[@]} == 1 )) || return 1
    for d in /sys/bus/usb/devices/*/; do
        [[ -f ${d}/idVendor && $(cat ${d}/idVendor) == "${WD_USB_RX888_VENDOR}" && $(cat ${d}/idProduct) == "${WD_USB_RX888_PROGRAMMED}" ]] || continue
        d=${d%/}; present+=( "${d##*/}" )
    done
    (( ${#present[@]} == 1 )) || return 1
    echo "${present[0]}"
}

### Has this usb device been re-enumerated in the last WD_USB_REENUM_MIN_MINUTES?  0 = yes (too soon)
function wd_usb_power_reenum_recently()
{
    local stamp="${WD_USB_POWER_LOG_DIR}/usb-reenum.last.${1//\//_}"
    [[ -f ${stamp} ]] || return 1
    local age=$(( $(printf "%(%s)T") - $(stat -c %Y "${stamp}" 2>/dev/null || echo 0) ))
    (( age < WD_USB_REENUM_MIN_MINUTES * 60 ))
}

### Force a full re-enumeration of sysfs usb device $1 ("2-1") by de-authorizing and re-authorizing it.  $2 = what for the log.
### NOTHING may have the device open while this runs.  0 = done, 1 = a sysfs write failed, 2 = can not / turned off.
function wd_usb_power_reenumerate_dev()
{
    local dev=$1 why=${2:-} authorized="/sys/bus/usb/devices/${1}/authorized" out rc
    if [[ ${WD_USB_REENUMERATE} == "no" ]]; then
        wd_usb_power_log 1 "WARNING: not re-enumerating usb device ${dev} (${why}): WD_USB_REENUMERATE=no"
        return 2
    fi
    if [[ ! -f ${authorized} ]]; then
        wd_usb_power_log 1 "ERROR: can not re-enumerate usb device ${dev} (${why}): ${authorized} does not exist"
        return 2
    fi
    wd_usb_power_ensure_dir && touch "${WD_USB_POWER_LOG_DIR}/usb-reenum.last.${dev//\//_}"   ### also stamped by the caller; harmless, and covers a direct call
    wd_usb_power_log 1 "WARNING: re-enumerating usb device ${dev}: de-authorizing it for ${WD_USB_REENUM_OFF_SECS} seconds, then re-authorizing: ${why}"
    out=$( echo 0 | timeout 20 sudo tee "${authorized}" 2>&1 >/dev/null ); rc=$?
    if (( rc )); then
        wd_usb_power_log 1 "ERROR: 'echo 0 | sudo tee ${authorized}' => ${rc}: ${out}"
        return 1
    fi
    sleep ${WD_USB_REENUM_OFF_SECS}
    out=$( echo 1 | timeout 20 sudo tee "${authorized}" 2>&1 >/dev/null ); rc=$?
    if (( rc )); then
        ### Leaving a device de-authorized takes it off the bus until someone re-authorizes it or the host reboots, so say so loudly
        wd_usb_power_log 1 "ERROR: 'echo 1 | sudo tee ${authorized}' => ${rc}: ${out}.  usb device ${dev} is still DE-AUTHORIZED and will stay off the bus: run 'echo 1 | sudo tee ${authorized}' by hand"
        return 1
    fi
    return 0
}

### Is radiod@$1 failing with the wedged-RX888 signature (enumerated, but no samples) rather than for some other reason?
### The USB 3 / USB 2 duality of an RX888, and why a recovery has to cut BOTH halves of the jack.
###
### An RX888 in a USB 3 socket is reachable through two root hubs: the SuperSpeed half (bus 2 on a typical
### xHCI host) and the High-speed half (bus 1).  They are the same physical jack.  Take down only the
### SuperSpeed port and the radio does NOT leave the bus -- it re-appears on the OTHER bus at 480 Mb/s with
### an EMPTY serial, back in bootloader state, and radiod then refuses it outright:
###     found rx888 ... USB speed: High (480 Mb/s): not at least Super
###     rx888_usb_init() failed
### Worse, that 480 Mb/s reading trips the "never cycle a radio on a USB 2 port" rule this file applies
### elsewhere, so WD would write the radio off as an operator cabling problem when its own recovery is what
### put it there.  Seen at UCI-Silo on 2026-09-17: its root hub offers no uhubctl power switching at all
### ("No compatible devices detected"), so the only remote lever was the sysfs port, and cutting just the
### SuperSpeed half left radiod refusing the radio.  Cutting both halves together and re-enabling gave
###     usb 2-6: new SuperSpeed USB device number 3 ... SerialNumber: 0009002109C7221C
### and radiod came up with its full thread set immediately.
###
### sysfs path of the PORT a device hangs off, whose 'disable' takes the port down (1) and up (0).
### The port DIRECTORY is named differently depending on whether the port belongs to a root hub or to
### an external hub, and getting this wrong silently loses the only recovery lever a host without a
### power-switching hub has:
### Root-hub child '2-6'   -> /sys/bus/usb/devices/2-0:1.0/usb2-port6/disable    ('usb<bus>-port<n>')
### Behind a hub '2-6.3'   -> /sys/bus/usb/devices/2-6:1.0/2-6-port3/disable     ('<parent>-port<n>')
### Only the root hub's ports carry the 'usb' prefix -- the kernel names an external hub's ports after
### the hub device itself.  Building every path as 'usb<bus>-port<n>' therefore resolved nothing for any
### RX888 behind a hub, and wd_usb_power_cut_both_halves() gave up on it as if the host had no lever at
### all.  Found at ON5KQ 2026-09-18, whose two RX888s sit one per kind: rx2 on root-hub port 4-1 (which
### worked) and rx1 on port 1 of a GenesysLogic USB3.1 hub at 2-1 (which did not).
function wd_usb_power_port_disable_path()
{
    local dev=${1##*/} bus parent port portdir
    dev=${dev%/}
    [[ -n ${dev} && ${dev} == *-* ]] || return 1
    bus=${dev%%-*}
    if [[ ${dev} == *.* ]]; then
        parent=${dev%.*}; port=${dev##*.}; portdir="${parent}-port${port}"
    else
        parent="${bus}-0"; port=${dev#*-}; portdir="usb${bus}-port${port}"
    fi
    local path="/sys/bus/usb/devices/${parent}:1.0/${portdir}/disable"
    [[ -f ${path} ]] || return 1
    echo "${path}"
}

### Every RX888 currently on the bus below SuperSpeed -- i.e. sitting on the USB 2 half of its jack
function wd_usb_power_rx888_devs_below_superspeed()
{
    local d dev
    for d in /sys/bus/usb/devices/*/ ; do
        [[ -f ${d}/idVendor && -f ${d}/idProduct ]] || continue
        [[ $(< ${d}/idVendor) == "04b4" && $(< ${d}/idProduct) == "00f1" ]] || continue
        (( $(cat ${d}/speed 2>/dev/null || echo 0) < 5000 )) || continue
        dev=${d%/}; echo "${dev##*/}"
    done
}

### Cut both halves of the jack this device sits on, then bring them back.  Returns 0 only if the radio
### comes back at SuperSpeed carrying ${serial}.
function wd_usb_power_cut_both_halves()
{
    local dev=$1 serial=${2^^} why=${3:-} rc
    if [[ ${WD_USB_PORT_DISABLE} == "no" ]]; then
        wd_usb_power_log 1 "WARNING: not cutting the port of usb device ${dev} (${why}): WD_USB_PORT_DISABLE=no"
        return 2
    fi
    local ss_path other_path="" other_dev=""
    ss_path=$( wd_usb_power_port_disable_path "${dev}" ) || {
        wd_usb_power_log 1 "ERROR: no sysfs port 'disable' for usb device ${dev}, so its port can not be cut (${why})"
        return 2
    }
    wd_usb_power_log 1 "WARNING: cutting the port of usb device ${dev} through ${ss_path} for ${WD_USB_BOTH_HALVES_OFF_SECS} seconds: ${why}"
    local before_list after_dev
    before_list=" $( wd_usb_power_rx888_devs_below_superspeed | tr '\n' ' ' )"
    if ! echo 1 | timeout 20 sudo tee "${ss_path}" > /dev/null 2>&1 ; then
        wd_usb_power_log 1 "ERROR: 'echo 1 | sudo tee ${ss_path}' failed, so the port was not cut"
        return 1
    fi
    ### Follow the radio: if it drops onto the USB 2 half of the same jack, that half has to come down too,
    ### or it will simply stay there at 480 Mb/s where radiod will not have it.
    local waited=0
    while (( waited < WD_USB_OTHER_HALF_WAIT_SECS )); do
        sleep 1; (( ++waited ))
        for after_dev in $( wd_usb_power_rx888_devs_below_superspeed ); do
            [[ ${before_list} == *" ${after_dev} "* ]] && continue
            other_dev=${after_dev}
            break 2
        done
    done
    if [[ -n ${other_dev} ]]; then
        if other_path=$( wd_usb_power_port_disable_path "${other_dev}" ) ; then
            wd_usb_power_log 1 "WARNING: RX888 fell back onto the USB 2 half of its jack as usb ${other_dev} at $(cat /sys/bus/usb/devices/${other_dev}/speed 2>/dev/null) Mb/s, so cutting that half too through ${other_path}"
            echo 1 | timeout 20 sudo tee "${other_path}" > /dev/null 2>&1 || \
                wd_usb_power_log 1 "ERROR: 'echo 1 | sudo tee ${other_path}' failed, so only the SuperSpeed half is down"
        else
            wd_usb_power_log 1 "ERROR: RX888 fell back to usb ${other_dev} but that port has no sysfs 'disable', so both halves can not be cut"
        fi
    fi
    sleep ${WD_USB_BOTH_HALVES_OFF_SECS}
    ### SuperSpeed half back first, so the radio negotiates USB 3 rather than settling for USB 2
    echo 0 | timeout 20 sudo tee "${ss_path}" > /dev/null 2>&1
    rc=$?
    if [[ -n ${other_path} ]]; then
        echo 0 | timeout 20 sudo tee "${other_path}" > /dev/null 2>&1 || \
            wd_usb_power_log 1 "ERROR: 'echo 0 | sudo tee ${other_path}' failed: the USB 2 half of this jack is still DISABLED.  Re-enable it with 'echo 0 | sudo tee ${other_path}'"
    fi
    if (( rc )); then
        wd_usb_power_log 1 "ERROR: 'echo 0 | sudo tee ${ss_path}' failed: usb port ${dev} is still DISABLED and the radio will stay off the bus.  Re-enable it with 'echo 0 | sudo tee ${ss_path}'"
        return 1
    fi
    if [[ ${serial} != "UNKNOWN" && -n ${serial} ]] && ! wd_usb_power_wait_for_serial "${serial}" ; then
        wd_usb_power_log 1 "ERROR: RX888 ${serial} did not return within ${WD_USB_POWER_REENUM_SECS} seconds of both halves of its jack being re-enabled"
        return 1
    fi
    local back_dev back_speed=""
    back_dev=$( wd_usb_power_dev_of_serial "${serial}" 2>/dev/null || true )
    [[ -n ${back_dev} ]] && back_speed=$(cat /sys/bus/usb/devices/${back_dev}/speed 2>/dev/null)
    if [[ -n ${back_speed} ]] && (( back_speed < 5000 )); then
        wd_usb_power_log 1 "ERROR: RX888 ${serial} came back on usb ${back_dev} at only ${back_speed} Mb/s, so radiod will refuse it.  Both halves of its jack were cut, so this is the cable or the socket, not a stuck personality"
        return 1
    fi
    wd_usb_power_log 1 "RX888 ${serial} is back on usb ${back_dev:-?} at ${back_speed:-?} Mb/s after both halves of its jack were cut"
    return 0
}

function wd_usb_power_radiod_is_wedged()
{
    local inst=$1 hits
    hits=$( journalctl -u "radiod@${inst}" --since "-${WD_USB_REENUM_LOOKBACK_MINUTES} minutes" --no-pager 2>/dev/null | grep -c -E "${WD_USB_REENUM_WEDGE_REGEX}" )
    (( ${hits:-0} >= WD_USB_REENUM_WEDGE_MIN_HITS ))
}

### Record that WD had to restart radiod@$1 to get its RX888 working, and say how often that is now happening.
### $1 instance, $2 sysfs dev, $3 serial, $4 method ("re-enumerate"/"power cycle"), $5 outcome ("recovered"/"failed").
### Counts are per INSTANCE, over the last 24 hours and 7 days, so one loud radio does not hide behind a quiet one.
function wd_usb_power_record_recovery()
{
    local inst=$1 dev=$2 serial=$3 method=$4 outcome=$5
    local now; now=$(printf "%(%s)T")
    wd_usb_power_ensure_dir || return 0
    ### TAB separated: 'method' is a phrase ("power cycle", "re-enumerate and power cycle"), so whitespace fields would split it
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${now}" "${inst}" "${dev}" "${serial}" "${method}" "${outcome}" \
        >> "${WD_USB_RECOVERY_HISTORY_FILE}" 2>/dev/null || return 0
    if (( $(wc -l < "${WD_USB_RECOVERY_HISTORY_FILE}" 2>/dev/null || echo 0) > WD_USB_RECOVERY_HISTORY_MAX_LINES )); then
        tail -n "${WD_USB_RECOVERY_HISTORY_MAX_LINES}" "${WD_USB_RECOVERY_HISTORY_FILE}" > "${WD_USB_RECOVERY_HISTORY_FILE}.tmp" 2>/dev/null \
            && mv "${WD_USB_RECOVERY_HISTORY_FILE}.tmp" "${WD_USB_RECOVERY_HISTORY_FILE}"
    fi
    local day week first
    day=$(  awk -F'\t' -v s=$(( now - 86400  )) -v i="${inst}" '$3 == i && $2 >= s' "${WD_USB_RECOVERY_HISTORY_FILE}" 2>/dev/null | wc -l )
    week=$( awk -F'\t' -v s=$(( now - 604800 )) -v i="${inst}" '$3 == i && $2 >= s' "${WD_USB_RECOVERY_HISTORY_FILE}" 2>/dev/null | wc -l )
    first=$( awk -F'\t' -v i="${inst}" '$3 == i {print $1; exit}' "${WD_USB_RECOVERY_HISTORY_FILE}" 2>/dev/null )
    local what="WD had to ${method} RX888 ${serial} (usb ${dev}) and restart radiod@${inst}"
    [[ ${outcome} == "recovered" ]] || what="WD tried to ${method} RX888 ${serial} (usb ${dev}) to get radiod@${inst} running and could not"
    if (( day >= WD_USB_RECOVERY_WARN_PER_DAY )); then
        ### Loud on purpose: at this rate the radio is not working, WD is just papering over it between decode cycles
        wd_usb_power_log 1 "ERROR: ${what}.  That is ${day} restarts in the last 24 hours (${week} in 7 days, first recorded ${first:-now}).  A radio needing this often has a hardware fault -- check its USB cable, its power supply and which port it is on; 'wd -u' lists the history"
    else
        wd_usb_power_log 1 "WARNING: ${what}.  Restarts needed so far: ${day} in the last 24 hours, ${week} in 7 days.  If this keeps rising the radio's cable, power or port is the thing to fix, not WD"
    fi
    return 0
}

### radiod@$1 can not get samples out of RX888 $2, which IS on the bus.  Stop radiod so it releases the device, force a full
### re-enumeration, then start radiod again.  Falls back to a uhubctl power cycle if the radio still will not stream.
### 0 = radiod is running again, 3 = throttled, 1 = still broken.
function wd_usb_power_recover_wedged_rx888()
{
    local inst=$1 serial=${2^^} dev
    dev=$( wd_usb_power_dev_of_instance "${inst}" || true )
    if [[ -z ${dev} ]]; then
        wd_usb_power_log 2 "radiod@${inst} has no RX888 WD can point at on this bus, so this is the missing-radio case, not a wedged one"
        return 1
    fi
    [[ -n ${serial} ]] || serial=$( tr -d '\n' < /sys/bus/usb/devices/${dev}/serial 2>/dev/null )
    serial=${serial:-unknown}
    if wd_usb_power_reenum_recently "${dev}"; then
        wd_usb_power_log 2 "usb device ${dev} (RX888 ${serial}) was re-enumerated less than ${WD_USB_REENUM_MIN_MINUTES} minutes ago, not again yet"
        return 3
    fi
    ### Stamp the ATTEMPT, not the successful re-enumeration: an attempt that bails out early (WD_USB_REENUMERATE=no, no
    ### 'authorized' file, radiod will not stop) must still be throttled, or the watchdog repeats it -- and repeats its
    ### ERROR line -- every WD_USB_POWER_CHECK_MINUTES.
    wd_usb_power_ensure_dir && touch "${WD_USB_POWER_LOG_DIR}/usb-reenum.last.${dev//\//_}"
    ### radiod holds an open libusb handle on the device, and its own libusb_reset_device() on that handle is exactly what
    ### fails to clear this.  Stop the unit first -- and stop, not restart, so systemd's Restart=always does not race us
    ### back onto the device while it is de-authorized.
    if ! timeout 60 sudo systemctl stop "radiod@${inst}" > /dev/null 2>&1 ; then
        wd_usb_power_log 1 "ERROR: 'systemctl stop radiod@${inst}' failed, so WD will not de-authorize ${dev} underneath it"
        return 1
    fi
    local waited=0
    while (( waited < 20 )) && ! [[ $(systemctl is-active "radiod@${inst}" 2>/dev/null) == "inactive" || $(systemctl is-active "radiod@${inst}" 2>/dev/null) == "failed" ]]; do
        sleep 1
        (( ++waited ))
    done
    wd_usb_power_reenumerate_dev "${dev}" "radiod@${inst} gets no samples from RX888 ${serial}, which is enumerated on ${dev}"
    local reenum_rc=$?
    if (( reenum_rc == 0 )) && wd_usb_power_wait_for_serial "${serial}"; then
        wd_usb_power_learn_ports
        if timeout 60 sudo systemctl start "radiod@${inst}" > /dev/null 2>&1 ; then
            wd_usb_power_record_recovery "${inst}" "${dev}" "${serial}" "re-enumerate" "recovered"
            return 0
        fi
        wd_usb_power_log 1 "ERROR: radiod@${inst} still will not start after RX888 ${serial} was re-enumerated on ${dev}"
    elif (( reenum_rc == 0 )); then
        wd_usb_power_log 1 "ERROR: RX888 ${serial} did not come back within ${WD_USB_POWER_REENUM_SECS} seconds of being re-authorized on ${dev}"
    fi
    ### De-authorizing the device was not enough.  Next strongest lever that does not need a switchable hub:
    ### take the jack itself down through sysfs -- both halves of it, see wd_usb_power_cut_both_halves().
    ### This is the only remote option at all on a host whose root hub uhubctl will not drive.
    if wd_usb_power_cut_both_halves "${dev}" "${serial}" "radiod@${inst} gets no samples from RX888 ${serial} and re-enumerating it did not help" ; then
        wd_usb_power_learn_ports
        if timeout 60 sudo systemctl start "radiod@${inst}" > /dev/null 2>&1 ; then
            wd_usb_power_record_recovery "${inst}" "${dev}" "${serial}" "cut both halves" "recovered"
            return 0
        fi
        wd_usb_power_log 1 "ERROR: radiod@${inst} still will not start after both halves of RX888 ${serial}'s jack were cut"
    fi
    ### Still stuck.  Now really pull the plug, if this radio is on a hub that switches power.
    if [[ ${serial} != "unknown" ]] && wd_usb_power_recover_rx888 "${serial}" hung ; then
        if timeout 60 sudo systemctl start "radiod@${inst}" > /dev/null 2>&1 ; then
            wd_usb_power_record_recovery "${inst}" "${dev}" "${serial}" "power cycle" "recovered"
            return 0
        fi
    fi
    ### Do not leave the receiver stopped just because WD could not fix it: put it back under systemd's Restart=always
    timeout 60 sudo systemctl start "radiod@${inst}" > /dev/null 2>&1 || true
    wd_usb_power_record_recovery "${inst}" "${dev}" "${serial}" "re-enumerate and power cycle" "failed"
    wd_usb_power_log 1 "ERROR: RX888 ${serial} (radiod@${inst}, usb ${dev}) is enumerated but delivers no samples, and neither re-enumerating it nor power cycling its port fixed that.  Its cable, its power, or the radio itself needs a look"
    return 1
}

### Watchdog: a radiod@ instance that is enabled but not running because its RX888 is missing gets its port cycled and is restarted.
function wd_usb_power_check()
{
    local now=$(printf "%(%s)T")
    (( now - WD_USB_POWER_LAST_CHECK_EPOCH < WD_USB_POWER_CHECK_MINUTES * 60 )) && return 0
    WD_USB_POWER_LAST_CHECK_EPOCH=${now}
    [[ ${KA9Q_RUNS_ONLY_REMOTELY-no} == "yes" ]] && return 0
    wd_usb_power_learn_ports
    local conf inst serial
    for conf in ${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@*.conf ; do
        [[ -f ${conf} ]] || continue
        inst=${conf##*/radiod@}; inst=${inst%.conf}
        systemctl is-active --quiet "radiod@${inst}" 2>/dev/null && continue
        systemctl is-enabled --quiet "radiod@${inst}" 2>/dev/null || continue     ### never bring up a receiver the site chose to leave stopped
        serial=$( wd_usb_power_serial_of_instance "${inst}" )
        ### The radio IS on the bus.  Until 2026-09-14 WD stopped here ("radiod being down is something else") -- but the
        ### commonest way for a present radio to keep radiod down is the wedge described at the top of this file, and that
        ### is precisely the case uhubctl can not reach on a root-hub host.  Recover it, and only it: any OTHER reason
        ### radiod is down is still none of this file's business.
        if wd_usb_power_dev_of_instance "${inst}" > /dev/null ; then
            if wd_usb_power_radiod_is_wedged "${inst}" ; then
                wd_usb_power_recover_wedged_rx888 "${inst}" "${serial}"
            fi
            continue
        fi
        [[ -n ${serial} ]] || continue     ### no serial in its conf and no radio WD can attribute to it: nothing to power cycle
        ### One attempt (and one ERROR line if it can not be done) per serial per WD_USB_POWER_CYCLE_MIN_MINUTES, not every 2 minutes
        local stamp="${WD_USB_POWER_LOG_DIR}/usb-power.tried.${serial}"
        if [[ -f ${stamp} ]] && (( $(printf "%(%s)T") - $(stat -c %Y "${stamp}" 2>/dev/null || echo 0) < WD_USB_POWER_CYCLE_MIN_MINUTES * 60 )); then
            continue
        fi
        wd_usb_power_ensure_dir && touch "${stamp}"
        if wd_usb_power_recover_rx888 "${serial}"; then
            if timeout 60 sudo systemctl restart "radiod@${inst}" > /dev/null 2>&1 ; then
                wd_usb_power_record_recovery "${inst}" "$( wd_usb_power_dev_of_serial "${serial}" || echo "-" )" "${serial}" "power cycle" "recovered"
            else
                wd_usb_power_record_recovery "${inst}" "$( wd_usb_power_dev_of_serial "${serial}" || echo "-" )" "${serial}" "power cycle" "failed"
                wd_usb_power_log 1 "ERROR: radiod@${inst} failed to start after RX888 ${serial} came back: $(systemctl status radiod@${inst} --no-pager -n 3 2>&1 | tail -n 3)"
            fi
        fi
    done
    return 0
}

### Called from wd-setup.sh at every wd command
function wd_usb_power_setup()
{
    [[ ${KA9Q_RUNS_ONLY_REMOTELY-no} == "yes" ]] && return 0
    wd_usb_power_rx888_present || return 0
    if [[ " $* " =~ " -a " || " $* " =~ " -A " ]]; then
        wd_usb_power_install
    fi
    wd_usb_power_learn_ports
    return 0
}

### 'wd -u': what is on the bus, where, and can WD switch it
function wd_usb_power_show()
{
    local hubs d pid serial speed dev hp hub port sw inst conf state
    hubs=$( wd_usb_power_switchable_hubs | tr '\n' ' ' )
    if ! wd_usb_power_uhubctl_path > /dev/null ; then
        echo "uhubctl is not installed, so WD can not power cycle any port ('sudo apt install uhubctl')"
    elif [[ -z ${hubs} ]]; then
        echo "No hub on this host switches power per port, so WD can not power cycle a hung RX888."
        echo "  ${WD_USB_POWER_HUB_HINT}"
    else
        echo "Hubs that switch power per port (uhubctl -l): ${hubs}"
    fi
    echo
    printf "%-18s %-8s %-6s %-8s %-6s %-12s %s\n" "RX888 serial" "usb dev" "Mb/s" "hub" "port" "switchable" "radiod instance (state)"
    for d in /sys/bus/usb/devices/*/; do
        [[ -f ${d}/idVendor && $(cat ${d}/idVendor) == "${WD_USB_RX888_VENDOR}" ]] || continue
        pid=$( cat ${d}/idProduct ); serial=$( tr -d '\n' < ${d}/serial 2>/dev/null ); speed=$( cat ${d}/speed 2>/dev/null ); d=${d%/}; dev=${d##*/}
        read -r hub port <<< "$( wd_usb_power_hub_port_of "${dev}" )"
        sw="no"; [[ " ${hubs} " == *" ${hub} "* ]] && sw="yes"
        [[ ${pid} == "${WD_USB_RX888_BOOTLOADER}" ]] && serial="(bootloader 00f3)"
        inst=""
        for conf in ${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@*.conf ; do
            [[ -f ${conf} ]] || continue
            [[ $( wd_usb_power_serial_of_instance "$( basename ${conf#*radiod@} .conf )" ) == "${serial^^}" ]] || continue
            inst=${conf##*/radiod@}; inst=${inst%.conf}
            state=$( systemctl is-active "radiod@${inst}" 2>/dev/null ); inst="${inst} (${state})"
            break
        done
        if [[ -z ${inst} && ${pid} == "${WD_USB_RX888_PROGRAMMED}" ]]; then
            ### No conf names this serial.  If exactly one radiod conf has no serial= line, that one gets whatever RX888 is there
            local -a noserial=()
            for conf in ${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@*.conf ; do
                [[ -f ${conf} ]] || continue
                [[ -z $( wd_usb_power_serial_of_instance "$( basename ${conf#*radiod@} .conf )" ) ]] && noserial+=( "$( basename ${conf#*radiod@} .conf )" )
            done
            if (( ${#noserial[@]} == 1 )); then
                inst="${noserial[0]} ($(systemctl is-active radiod@${noserial[0]} 2>/dev/null), no serial= in its conf)"
            fi
        fi
        (( ${speed:-0} < 5000 )) && inst="${inst} USB 2 PORT: move to USB 3"
        printf "%-18s %-8s %-6s %-8s %-6s %-12s %s\n" "${serial}" "${dev}" "${speed}" "${hub}" "${port}" "${sw}" "${inst}"
    done
    echo
    echo "Configured radiod instances whose RX888 is NOT on the bus:"
    local any=0
    for conf in ${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@*.conf ; do
        [[ -f ${conf} ]] || continue
        inst=${conf##*/radiod@}; inst=${inst%.conf}
        serial=$( wd_usb_power_serial_of_instance "${inst}" ) || true
        [[ -n ${serial} ]] || continue
        wd_usb_power_dev_of_serial "${serial}" > /dev/null && continue
        any=1
        local seen; seen=$( wd_usb_power_remembered "${serial}" || true )
        echo "  radiod@${inst} ($(systemctl is-active radiod@${inst} 2>/dev/null)) wants ${serial}; last seen: ${seen:-never}${seen:+  [HUB PORT Mb/s WHEN]}"
    done
    (( any )) || echo "  none"
    echo
    echo "Configured radiod instances whose RX888 IS on the bus but which are not running:"
    any=0
    for conf in ${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@*.conf ; do
        [[ -f ${conf} ]] || continue
        inst=${conf##*/radiod@}; inst=${inst%.conf}
        systemctl is-active --quiet "radiod@${inst}" 2>/dev/null && continue
        dev=$( wd_usb_power_dev_of_instance "${inst}" || true )
        [[ -n ${dev} ]] || continue
        serial=$( wd_usb_power_serial_of_instance "${inst}" )
        serial=${serial:-$( tr -d '\n' < /sys/bus/usb/devices/${dev}/serial 2>/dev/null )}
        any=1
        if wd_usb_power_radiod_is_wedged "${inst}" ; then
            echo "  radiod@${inst} ($(systemctl is-active radiod@${inst} 2>/dev/null)): RX888 ${serial} is enumerated on ${dev} but delivers no samples."
            echo "      WD recovers this by re-enumerating ${dev}; by hand: sudo systemctl stop radiod@${inst} && echo 0 | sudo tee /sys/bus/usb/devices/${dev}/authorized && sleep 3 && echo 1 | sudo tee /sys/bus/usb/devices/${dev}/authorized && sudo systemctl start radiod@${inst}"
        else
            echo "  radiod@${inst} ($(systemctl is-active radiod@${inst} 2>/dev/null)): RX888 ${serial} is on the bus at ${dev}, so radiod is down for some other reason; 'journalctl -u radiod@${inst} -n 50'"
        fi
    done
    (( any )) || echo "  none"
    echo
    echo "Restarts WD has had to perform to keep a radio working:"
    if [[ -s ${WD_USB_RECOVERY_HISTORY_FILE} ]]; then
        local now; now=$(printf "%(%s)T")
        awk -F'\t' -v d=$(( now - 86400 )) -v w=$(( now - 604800 )) '
            { n[$3]++; if ($2 >= w) week[$3]++; if ($2 >= d) day[$3]++; if (!($3 in first)) first[$3] = $1; last[$3] = $1 " (" $6 ", " $7 ")" }
            END { for (i in n) printf "  radiod@%-22s %3d in 24 h  %3d in 7 d  %4d total since %s   last: %s\n", i, day[i], week[i], n[i], first[i], last[i] }
        ' "${WD_USB_RECOVERY_HISTORY_FILE}" | sort
        echo "  A radio that needs these repeatedly has a hardware fault -- its USB cable, its power supply, or the port it is on."
        echo "  Full history: ${WD_USB_RECOVERY_HISTORY_FILE}"
    else
        echo "  none -- no radio on this host has ever needed WD to restart it"
    fi
    echo
    if [[ -f ${WD_USB_POWER_LOG_FILE} ]]; then
        echo "Last lines of ${WD_USB_POWER_LOG_FILE}:"
        tail -n 10 "${WD_USB_POWER_LOG_FILE}"
    fi
    return 0
}

### 'wd -U SERIAL|HUB:PORT|all': cycle by hand, ignoring the per-port throttle
function wd_usb_power_cycle_cmd()
{
    local what=$1 serial hub port rc=0
    WD_USB_POWER_CYCLE_MIN_MINUTES=0
    case ${what} in
        all)
            [[ -f ${WD_USB_POWER_MAP_FILE} ]] || { echo "No RX888 has been seen on this host yet"; return 1; }
            wd_usb_power_learn_ports
            while read -r serial hub port _; do
                echo "Cycling RX888 ${serial} on hub ${hub} port ${port}"
                wd_usb_power_recover_rx888 "${serial}" hung || rc=1
            done < "${WD_USB_POWER_MAP_FILE}"
            ;;
        *:*)
            hub=${what%%:*}; port=${what##*:}
            wd_usb_power_cycle_port "${hub}" "${port}" "requested by 'wd -U ${what}'" || rc=1
            ;;
        *)
            wd_usb_power_recover_rx888 "${what}" hung || rc=1
            ;;
    esac
    return ${rc}
}
