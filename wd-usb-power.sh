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
declare WD_USB_POWER_CYCLE_MIN_MINUTES=${WD_USB_POWER_CYCLE_MIN_MINUTES-10} ### never cycle one port more often than this
declare WD_USB_POWER_CHECK_MINUTES=${WD_USB_POWER_CHECK_MINUTES-2}          ### watchdog throttle (the odd-minute pass is every 2 min anyway)
declare WD_USB_POWER_LAST_CHECK_EPOCH=0
declare WD_USB_POWER_HUB_HINT="see wd-usb-power.md for hubs that really switch power per port (RSHTECH/Rosonway 10-port on the uhubctl list, e.g. https://www.amazon.com/dp/B0DX6KR79L)"
declare WD_USB_RX888_VENDOR="04b4"
declare WD_USB_RX888_PROGRAMMED="00f1"
declare WD_USB_RX888_BOOTLOADER="00f3"

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
    command -v uhubctl > /dev/null 2>&1 && return 0
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
        if command -v uhubctl > /dev/null 2>&1 ; then
            WD_USB_POWER_HUBS_CACHE=$( timeout 20 sudo uhubctl 2>/dev/null | sed -n 's/^Current status for hub \([^ ]*\) .*/\1/p' )
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
    if ! command -v uhubctl > /dev/null 2>&1 ; then
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
    out=$( timeout 60 sudo uhubctl -l "${hub}" -p "${port}" -a cycle -d "${WD_USB_POWER_OFF_SECS}" -r 3 2>&1 ); rc=$?
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
    s=$( awk -F= '/^[[:space:]]*serial[[:space:]]*=/{v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]#].*$/,"",v); print toupper(v); exit}' "${KA9Q_RADIOD_CONF_DIR}/radiod@${1}.conf" 2>/dev/null )
    [[ -n ${s} && ${s} != FILL_IN* ]] && echo "${s}"
    return 0
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
        [[ -n ${serial} ]] || continue
        wd_usb_power_dev_of_serial "${serial}" > /dev/null && continue          ### the radio is there; radiod being down is something else
        ### One attempt (and one ERROR line if it can not be done) per serial per WD_USB_POWER_CYCLE_MIN_MINUTES, not every 2 minutes
        local stamp="${WD_USB_POWER_LOG_DIR}/usb-power.tried.${serial}"
        if [[ -f ${stamp} ]] && (( $(printf "%(%s)T") - $(stat -c %Y "${stamp}" 2>/dev/null || echo 0) < WD_USB_POWER_CYCLE_MIN_MINUTES * 60 )); then
            continue
        fi
        wd_usb_power_ensure_dir && touch "${stamp}"
        if wd_usb_power_recover_rx888 "${serial}"; then
            if timeout 60 sudo systemctl restart "radiod@${inst}" > /dev/null 2>&1 ; then
                wd_usb_power_log 1 "WARNING: restarted radiod@${inst} now that RX888 ${serial} is back"
            else
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
    if ! command -v uhubctl > /dev/null 2>&1 ; then
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
