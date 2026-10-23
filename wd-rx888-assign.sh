##########################################################################################################################################################
########## 'wd -X': which RX888 (by USB serial) is on which antenna, i.e. which radiod@ instance must open it ############################################
##########################################################################################################################################################
###
### A receiver in RECEIVER_LIST names a stream ("ns-bev-wspr-pcm.local"), the radiod@ conf whose 'data =' line publishes that stream is the
### radiod that makes it, and that conf's 'serial =' line in its [rx888] section is the RX888 it opens.  The last link -- which RX888 is cabled
### to which antenna -- is known only to the person at the site, and nothing checked it: at KX4AZ-T the dipole and N-S Beverage serials were
### written in 2026-08 with the comment "(assumed: random dipole)" and never confirmed.  If two serials are swapped the spots of each antenna
### are uploaded under the other's name, and a radiod with no 'serial =' at all takes whichever RX888 is free, so a reboot can swap them.
###
### 'wd -X'          lists the RX888s on the bus and the local radiod@ instances, and flags missing, duplicate and unclaimed serials
### 'wd -X identify' walks the operator through the radios one at a time: "unplug the RX888 on the <antenna>", the serial which drops off the
###                  bus is that radio's, it is plugged back in, and at the end the confirmed serials are written into the radiod@ confs.
###                  WD and the radiods must be stopped first ('wdz'): WD's watchdog would otherwise try to recover each radio as it is unplugged.
###
### Called from the '-X' fast path in wsprdaemon.sh, which sources wsprdaemon.conf and wd-usb-power.sh first.

declare WD_RX888_ASSIGN_WAIT_SECS=${WD_RX888_ASSIGN_WAIT_SECS-180}          ### how long to wait for the operator to unplug / replug one radio
declare WD_RX888_ASSIGN_BOOT_SECS=${WD_RX888_ASSIGN_BOOT_SECS-20}           ### a replugged radio still in the FX3 bootloader after this gets the udev 'add' replayed

### Echoes the value of 'description =' in the [rx888] section of radiod@$1.conf, without quotes or comment
function wd_rx888_assign_description()
{
    awk '/^[[:space:]]*\[/{f=($0 ~ /^[[:space:]]*\[rx888\]/)} f && /^[[:space:]]*description[[:space:]]*=/{v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]*#.*$/,"",v); gsub(/"/,"",v); print v; exit}' \
        "${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@${1}.conf" 2>/dev/null
}

### Echoes the names of the RECEIVER_LIST KA9Q receivers whose stream radiod@$1.conf publishes, space separated
function wd_rx888_assign_receivers_of()
{
    local conf="${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@${1}.conf" entry
    local -a fields
    for entry in "${RECEIVER_LIST[@]}"; do
        fields=( ${entry} )
        [[ ${fields[0]} == KA9Q* && -n ${fields[1]-} ]] || continue
        grep -qE "^[[:space:]]*(data|status)[[:space:]]*=[[:space:]]*${fields[1]}([[:space:]#]|$)" "${conf}" 2>/dev/null && echo -n "${fields[0]} "
    done
}

### Echoes this host's RX888 radiod@ instances, one per line, sorted.  A conf counts when it has an [rx888] section and its unit is enabled,
### in any state but inactive, or publishes a stream RECEIVER_LIST uses.  /etc/radio may also hold ka9q-radio's stock sample confs, which
### are none of those (see wd_mdns_unit_for_stream(): one of them silenced PE0MJX for five days).
function wd_rx888_assign_instances()
{
    local conf inst state
    for conf in ${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@*.conf ; do
        [[ -f ${conf} ]] && grep -q '^[[:space:]]*\[rx888\]' "${conf}" || continue
        inst=${conf##*/radiod@}; inst=${inst%.conf}
        state=$( systemctl is-active "radiod@${inst}" 2>/dev/null )
        if systemctl is-enabled --quiet "radiod@${inst}" 2>/dev/null || [[ -n ${state} && ${state} != "inactive" ]] || [[ -n $( wd_rx888_assign_receivers_of "${inst}" ) ]]; then
            echo "${inst}"
        fi
    done | sort
}

### Echoes "DEV SPEED" for every programmed RX888 on the bus, one line per radio, keyed by upper-case serial: "SERIAL DEV SPEED"
function wd_rx888_assign_present()
{
    local d s
    for d in /sys/bus/usb/devices/*/; do
        [[ -f ${d}/idVendor && $(< ${d}/idVendor) == "${WD_USB_RX888_VENDOR}" && $(< ${d}/idProduct) == "${WD_USB_RX888_PROGRAMMED}" ]] || continue
        s=$( tr -d '\n' < ${d}/serial 2>/dev/null ); d=${d%/}
        echo "${s^^} ${d##*/} $(cat ${d}/speed 2>/dev/null)"
    done | sort
}

function wd_rx888_assign_bootloader_count()
{
    lsusb -d ${WD_USB_RX888_VENDOR}:${WD_USB_RX888_BOOTLOADER} 2>/dev/null | wc -l
}

### 'wd -X': the inventory.  Returns 1 if anything needs the operator's attention.
function wd_rx888_assign_show()
{
    local -a instances=( $( wd_rx888_assign_instances ) )
    local present line serial dev speed inst want state desc rx claimed rc=0
    local -A owner_of=() count_of=()
    present=$( wd_rx888_assign_present )

    for inst in "${instances[@]}"; do
        want=$( wd_usb_power_serial_of_instance "${inst}" )
        [[ -n ${want} ]] || continue
        owner_of[${want}]+="${owner_of[${want}]:+,}${inst}"
        count_of[${want}]=$(( ${count_of[${want}]:-0} + 1 ))
    done

    echo "RX888s on the USB bus:"
    if [[ -z ${present} ]]; then
        echo "  none"
    else
        printf "  %-18s %-8s %-10s %s\n" "SERIAL" "USB" "SPEED" "OPENED BY"
        while read -r serial dev speed; do
            printf "  %-18s %-8s %-10s %s\n" "${serial}" "${dev}" "${speed} Mb/s" "${owner_of[${serial}]:-(no radiod conf names this serial)}"
        done <<< "${present}"
    fi
    (( $( wd_rx888_assign_bootloader_count ) )) && echo "  plus $( wd_rx888_assign_bootloader_count ) RX888(s) still in the FX3 bootloader (no firmware yet, so no serial)"
    echo
    echo "Local radiod@ instances:"
    if (( ! ${#instances[@]} )); then
        echo "  none"
        return 0
    fi
    printf "  %-14s %-10s %-18s %-8s %-36s %s\n" "INSTANCE" "STATE" "SERIAL" "ON BUS" "ANTENNA (its 'description =')" "RECEIVERS"
    for inst in "${instances[@]}"; do
        want=$( wd_usb_power_serial_of_instance "${inst}" )
        state=$( systemctl is-active "radiod@${inst}" 2>/dev/null )
        desc=$( wd_rx888_assign_description "${inst}" )
        rx=$( wd_rx888_assign_receivers_of "${inst}" ); rx=${rx% }
        if [[ -z ${want} ]]; then
            dev="-"
        else
            dev=$( wd_usb_power_dev_of_serial "${want}" || echo "NO" )
        fi
        printf "  %-14s %-10s %-18s %-8s %-36s %s\n" "${inst}" "${state:-unknown}" "${want:-(none)}" "${dev}" "${desc:-?}" "${rx:--}"
    done
    echo

    local -a problems=()
    for inst in "${instances[@]}"; do
        want=$( wd_usb_power_serial_of_instance "${inst}" )
        if [[ -z ${want} ]]; then
            (( ${#instances[@]} > 1 )) && problems+=( "radiod@${inst} has no 'serial =' line, so it opens whichever RX888 is free: a reboot can swap antennas" )
        else
            wd_usb_power_dev_of_serial "${want}" > /dev/null || problems+=( "radiod@${inst} wants RX888 ${want}, which is not on the USB bus" )
            ### Reported once, by the first instance (sorted) that names it, whether or not that radio is on the bus
            (( ${count_of[${want}]} > 1 )) && [[ ${owner_of[${want}]} == ${inst},* ]] \
                && problems+=( "RX888 ${want} is named by more than one radiod: ${owner_of[${want}]}" )
        fi
        grep -q '^[^#]*serial[[:space:]]*=.*assumed' "${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@${inst}.conf" 2>/dev/null \
            && problems+=( "radiod@${inst}'s serial is marked 'assumed' in its conf: it was never confirmed" )
    done
    if [[ -n ${present} ]]; then
        while read -r serial dev speed; do
            [[ -z ${owner_of[${serial}]-} ]] && (( ${#instances[@]} > 1 )) && problems+=( "RX888 ${serial} on usb ${dev} is not named by any radiod conf" )
            (( ${speed:-0} < 5000 )) && problems+=( "RX888 ${serial} on usb ${dev} is at only ${speed} Mb/s, so radiod will not open it: 'wd -R' re-trains it to USB 3" )
        done <<< "${present}"
    fi
    if (( ${#problems[@]} )); then
        echo "Needs attention:"
        printf "  - %s\n" "${problems[@]}"
        echo "'wd -X identify' confirms which RX888 is on which antenna by having you unplug them one at a time."
        rc=1
    else
        echo "Every local radiod names its own RX888 and every RX888 is on the bus."
    fi
    return ${rc}
}

### Wait until a serial in "$1" (space separated) leaves the bus and echo it.  Returns 2 if the operator typed s(kip), 3 for q(uit), 1 on timeout.
function wd_rx888_assign_wait_for_unplug()
{
    local before=" $1 " now serial ans waited=0
    while (( waited < WD_RX888_ASSIGN_WAIT_SECS * 4 )); do
        now=" $( wd_rx888_assign_present | awk '{print $1}' | tr '\n' ' ' ) "
        for serial in ${before}; do
            if [[ ${now} != *" ${serial} "* ]]; then
                echo "${serial}"
                return 0
            fi
        done
        read -r -t 0.25 ans
        case $? in
            0)  [[ ${ans,,} == s* ]] && return 2
                [[ ${ans,,} == q* ]] && return 3 ;;
            1)  sleep 0.25 ;;               ### stdin at end of file returns at once, which would end the wait in a blink
        esac
        (( ++waited ))
    done
    return 1
}

### Wait until RX888 $1 is back on the bus, programmed.  Replays the udev 'add' that loads its firmware if it sits in the bootloader.
function wd_rx888_assign_wait_for_replug()
{
    local serial=$1 waited=0 kicked="no"
    while (( waited < WD_RX888_ASSIGN_WAIT_SECS )); do
        wd_usb_power_dev_of_serial "${serial}" > /dev/null && return 0
        if [[ ${kicked} == "no" ]] && (( waited >= WD_RX888_ASSIGN_BOOT_SECS && $( wd_rx888_assign_bootloader_count ) )); then
            echo "    it is still in the FX3 bootloader after ${waited} s, so replaying the udev 'add' event that loads its firmware"
            sudo udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=${WD_USB_RX888_VENDOR} --attr-match=idProduct=${WD_USB_RX888_BOOTLOADER}
            kicked="yes"
        fi
        sleep 1
        (( ++waited ))
    done
    wd_usb_power_dev_of_serial "${serial}" > /dev/null
}

### Set radiod@$1's serial to $2.  The [rx888] section's commented-out alternative 'serial =' lines go too: with the binding confirmed they are
### only a way to swap the radios back by mistake.  The conf is backed up first; nothing is written when nothing changes.
function wd_rx888_assign_write_serial()
{
    local inst=$1 serial=$2 how=${3:-unplugged} conf="${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@${1}.conf" tmp
    local note="# confirmed by 'wd -X identify' $(date -u +%Y-%m-%dT%H:%MZ): unplugging this RX888 took it off the bus"
    [[ ${how} == "eliminated" ]] && note="# set by 'wd -X identify' $(date -u +%Y-%m-%dT%H:%MZ): the only RX888 left after every other radio was confirmed by unplugging it"
    tmp=$( mktemp ) || return 1
    ### Does the [rx888] section already have an active 'serial =' line?  If so it is replaced where it is; if not, the new line goes
    ### right after 'description =' (else 'device =', else the section header), where an operator reading the conf looks for it
    local has_serial=0
    awk '/^[[:space:]]*\[/{f=($0 ~ /^[[:space:]]*\[rx888\]/)} f && /^[[:space:]]*serial[[:space:]]*=/{found=1} END{exit !found}' "${conf}" && has_serial=1
    awk -v line="serial = ${serial}    ${note}" '
        /^[[:space:]]*\[/ { sect = ($0 ~ /^[[:space:]]*\[rx888\]/); print; next }
        sect && /^[[:space:]]*#[[:space:]]*serial[[:space:]]*=/ { next }
        sect && /^[[:space:]]*serial[[:space:]]*=/ { if (!done) { print line; done=1 } ; next }
        { print }
    ' "${conf}" > "${tmp}"
    if (( ! has_serial )); then
        ### Second pass: put the line after the last anchor seen in the [rx888] section
        local anchor_line
        anchor_line=$( awk '/^[[:space:]]*\[/{f=($0 ~ /^[[:space:]]*\[rx888\]/); if (f) a=NR; next} f && /^[[:space:]]*(device|description)[[:space:]]*=/{a=NR} END{print a}' "${tmp}" )
        awk -v n="${anchor_line}" -v line="serial = ${serial}    ${note}" '{print} NR==n{print line}' "${tmp}" > "${tmp}.2" && mv "${tmp}.2" "${tmp}"
    fi
    if cmp -s "${tmp}" "${conf}" ; then
        rm -f "${tmp}"
        return 0
    fi
    local backup="${conf}.bak-wd-X-$(date -u +%Y%m%d-%H%M%S)"
    if ! sudo cp -p "${conf}" "${backup}" || ! sudo cp "${tmp}" "${conf}" ; then      ### cp onto the existing file keeps its owner and mode
        echo "  ERROR: could not write ${conf}; it is unchanged"
        rm -f "${tmp}"
        return 1
    fi
    rm -f "${tmp}"
    echo "  radiod@${inst}: serial = ${serial}   (old conf saved as ${backup})"
    return 0
}

### Ask a yes/no question on the terminal.  $2 is the default ("y" or "n").
function wd_rx888_assign_ask()
{
    local prompt=$1 default=$2 ans
    printf '%s ' "${prompt}"            ### not 'read -p': that prints nothing unless stdin is a terminal
    read -r ans
    [[ -t 0 ]] || echo
    ans=${ans:-${default}}
    [[ ${ans,,} == y* ]]
}

### 'wd -X identify'
function wd_rx888_assign_identify()
{
    local -a instances=( $( wd_rx888_assign_instances ) )
    local inst unit present_serials serial dev speed desc rx rc
    local -A found=() taken=() how=()

    if (( ! ${#instances[@]} )); then
        echo "This host has no RX888 radiod@ confs, so there is nothing to identify."
        return 0
    fi
    if systemctl is-active --quiet wsprdaemon 2>/dev/null ; then
        echo "WD is running, and its watchdog would try to recover each radio as you unplug it.  Stop it first with 'wdz', then run 'wd -X identify' again."
        return 1
    fi
    local -a running=()
    for inst in "${instances[@]}"; do
        systemctl is-active --quiet "radiod@${inst}" && running+=( "radiod@${inst}" )
    done
    if (( ${#running[@]} )); then
        echo "${running[*]} still running.  Stop them first with 'wdz' (it stops every radiod), then run 'wd -X identify' again."
        return 1
    fi
    present_serials=$( wd_rx888_assign_present | awk '{print $1}' | tr '\n' ' ' )
    if [[ -z ${present_serials// } ]]; then
        echo "No programmed RX888 is on the USB bus.  'wd -u' shows what is there."
        return 1
    fi
    echo "This identifies which RX888 is on which antenna.  For each radiod you will unplug the USB cable of ONE RX888; the serial that"
    echo "drops off the bus is the one that radiod must open.  Plug it straight back in when asked.  Type s+Enter to skip a radio, q+Enter to stop."
    echo "RX888s on the bus now: ${present_serials}"

    local -i i
    for (( i = 0; i < ${#instances[@]}; ++i )); do
        inst=${instances[i]}
        desc=$( wd_rx888_assign_description "${inst}" )
        rx=$( wd_rx888_assign_receivers_of "${inst}" ); rx=${rx% }
        local -a left=()
        for serial in ${present_serials}; do [[ -z ${taken[${serial}]-} ]] && left+=( "${serial}" ); done
        echo
        echo "radiod@${inst}: antenna '${desc:-?}'${rx:+, receivers ${rx}}, now set to $( wd_usb_power_serial_of_instance "${inst}" | grep . || echo "no serial" )"
        if (( ${#left[@]} == 1 && i == ${#instances[@]} - 1 && ${#found[@]} == ${#instances[@]} - 1 )); then
            ### Every other radio was confirmed by unplugging it, so the one left can only be this one
            if wd_rx888_assign_ask "  Every other RX888 is accounted for, so this must be ${left[0]}.  Take it without unplugging? [Y/n]" y ; then
                found[${inst}]=${left[0]}; taken[${left[0]}]=${inst}; how[${inst}]="eliminated"
                continue
            fi
        fi
        while true; do
            echo "  Unplug the USB cable of the RX888 connected to '${desc:-radiod@${inst}}' now.  Waiting up to ${WD_RX888_ASSIGN_WAIT_SECS} s ..."
            serial=$( wd_rx888_assign_wait_for_unplug "${left[*]}" ); rc=$?
            (( rc == 2 )) && { echo "  skipped radiod@${inst}"; break; }
            (( rc == 3 )) && { echo "  stopped"; i=${#instances[@]}; break; }
            (( rc == 1 )) && { echo "  nothing came off the bus; skipped radiod@${inst}"; break; }
            echo "  RX888 ${serial} came off the bus, so it is the radio on '${desc:-radiod@${inst}}'.  Plug it back in now ..."
            if wd_rx888_assign_wait_for_replug "${serial}" ; then
                read -r serial dev speed <<< "$( wd_rx888_assign_present | grep "^${serial} " )"
                echo "  RX888 ${serial} is back on usb ${dev} at ${speed} Mb/s"
                (( ${speed:-0} < 5000 )) && echo "  WARNING: below SuperSpeed, radiod will not open it at ${speed} Mb/s.  'wd -R' re-trains it."
            else
                echo "  WARNING: RX888 ${serial} did not come back within ${WD_RX888_ASSIGN_WAIT_SECS} s.  It is still recorded for radiod@${inst}; check its cable before starting radiod."
            fi
            found[${inst}]=${serial}; taken[${serial}]=${inst}
            break
        done
    done

    echo
    if (( ! ${#found[@]} )); then
        echo "No RX888 was identified, so no conf was changed."
        return 1
    fi
    echo "Result:"
    printf "  %-14s %-18s %-18s %s\n" "INSTANCE" "WAS" "CONFIRMED" ""
    local was changes=0
    for inst in "${instances[@]}"; do
        [[ -n ${found[${inst}]-} ]] || { printf "  %-14s %-18s %-18s %s\n" "${inst}" "$( wd_usb_power_serial_of_instance "${inst}" | grep . || echo "-" )" "(not checked)" ""; continue; }
        was=$( wd_usb_power_serial_of_instance "${inst}" )
        if [[ ${was} == "${found[${inst}]}" ]]; then
            printf "  %-14s %-18s %-18s %s\n" "${inst}" "${was}" "${found[${inst}]}" "unchanged"
        else
            printf "  %-14s %-18s %-18s %s\n" "${inst}" "${was:--}" "${found[${inst}]}" "<== CHANGES"
            (( ++changes ))
        fi
    done
    if ! wd_rx888_assign_ask "Write the confirmed serials into the radiod@ confs? [y/N]" n ; then
        echo "Nothing written."
        return 1
    fi
    for inst in "${!found[@]}"; do
        wd_rx888_assign_write_serial "${inst}" "${found[${inst}]}" "${how[${inst}]:-unplugged}"
    done
    ### A radiod not checked this time may still name a serial just given to another one
    for inst in "${instances[@]}"; do
        [[ -n ${found[${inst}]-} ]] && continue
        serial=$( wd_usb_power_serial_of_instance "${inst}" )
        [[ -n ${serial} && -n ${taken[${serial}]-} ]] && echo "  WARNING: radiod@${inst} (not checked) still names ${serial}, which is now radiod@${taken[${serial}]}'s.  Run 'wd -X identify' for it too."
    done
    wd_usb_power_learn_ports > /dev/null 2>&1
    echo
    if wd_rx888_assign_ask "Start ${instances[*]/#/radiod@} now? [Y/n]" y ; then
        for inst in "${instances[@]}"; do
            timeout 60 sudo systemctl start "radiod@${inst}" > /dev/null 2>&1 && echo "  started radiod@${inst}" || echo "  ERROR: radiod@${inst} did not start: $(systemctl status radiod@${inst} --no-pager -n 2 2>&1 | tail -n 1)"
        done
    fi
    echo "Start WD again with 'wda' when you are ready."
    return 0
}

function wd_rx888_assign_cmd()
{
    case ${1:-} in
        "")              wd_rx888_assign_show ;;
        i|identify)      wd_rx888_assign_identify ;;
        *)               echo "Usage: wd -X [identify]"; return 1 ;;
    esac
}
