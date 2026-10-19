#!/bin/bash
### wd-ft-decode.sh MODE DIRECTORY: decode the FT8 or FT4 files ka9q-radio's pcmrecord writes into DIRECTORY with WSJT-X's
### decoders (ubersdr_wsprd's jt9), one long-running jt9 per band, and print each decode as decode_ft8 (ka9q/ft8_lib)
### prints it, so /var/log/ftX.log and pskreporter-sender go on unchanged.  It replaces decode_ft8 as the ExecStart of
### the ft8-decode / ft4-decode services (see wd_ft_decoder_setup() in ka9q-utils.sh).
###
### Why: at KJ6MKI on 2026-10-18, over 30 minutes and 12 FT8 bands, jt9 -d 2 decoded 14,626 messages where decode_ft8
### decoded 8,590 (8,659 against 5,006 that pskreporter-sender uploads), missing only 56 of decode_ft8's, for ~1.3 s of
### CPU a 15 s file against 48 ms.  And one jt9 per band, fed every period, keeps WSJT-X's callsign hash table and
### a-priori calls from period to period: on 25 periods of 40, 30, 20 and 15 m it decoded 5-8% more than a jt9 per file,
### and left ~80% fewer hashed calls unresolved as <...>.
###
### pcmrecord writes YYYYMMDDTHHMMSSZ_FREQHZ_..wav.tmp and renames it when the period is complete.  Each band's files
### go to that band's 'jt9 --feed' as they appear (and from a scan every WD_FT_SCAN_SECS, for any whose inotify event
### was missed); its decodes come back followed by '<FileDone> PATH N', and are printed then and the file deleted.
### The files are 32-bit float when WD sets radiod's [FT8]/[FT4] channels as it sets [WSPR]'s (encoding float, agc 0,
### gain 0; see ka9q-utils.sh), and jt9 decodes them as they are: at KJ6MKI on 2026-10-18, an hour of 12 FT8 bands,
### raw float decoded 16,477 messages against 16,294 from radiod's AGC'd 16-bit output (+1.1%, SNRs ~1 dB higher), the
### gain all from turning the AGC off (fixed-gain 16-bit: 16,464).  jt9 --feed came with ubersdr_wsprd PR #2; before it,
### jt9_decode -F fed a jt9 -s over WSJT-X's 16-bit shared memory (16,318 decodes against --feed's 16,301 on the same files).
###
### decode_ft8's line: "%4d/%02d/%02d %02d:%02d:%02d %3d %+4.2lf %'.1lf ~ %s" (date and time of the period, its sync
### score, DT, dial + audio frequency in Hz, the message).  Here the third field is jt9's SNR in dB, which
### pskreporter-sender does not upload either; WSJT-X's a1..a7 a-priori markers are removed from the message, and a
### decode WSJT-X marks '?' (a low confidence one) is not printed at all, so it never becomes a spot.

set -u
declare MODE=${1:?usage: $0 ft8|ft4 DIRECTORY}
declare DIRECTORY=${2:?usage: $0 ft8|ft4 DIRECTORY}
declare JT9=${WD_FT_JT9-/usr/local/bin/wd-jt9}
declare DEPTH=${WD_FT_DEPTH-2}
declare FREQ_LOW=${WD_FT_FREQ_LOW-100}
declare FREQ_HIGH=${WD_FT_FREQ_HIGH-4000}
declare SCAN_SECS=${WD_FT_SCAN_SECS-30}
declare RUN_DIR=${WD_FT_RUN_DIR-${DIRECTORY}/.wd-ft-decode}

case ${MODE} in
    ft8) declare JT9_FLAG=-8 ;;
    ft4) declare JT9_FLAG=-5 ;;
    *)   echo "$0: MODE must be ft8 or ft4, not '${MODE}'" >&2; exit 1 ;;
esac
for cmd in ${JT9} inotifywait; do
    command -v ${cmd} > /dev/null || { echo "$0: can't find ${cmd}" >&2; exit 1; }
done
mkdir -p ${RUN_DIR} || exit 1

### When this jt9 has them (ubersdr_wsprd PR #3) and WD_FT_FAST="yes" (the default): measured FFT plans (-w 2) and, for
### FT8, the decoded signals' subtraction smoothed at 300 S/s (--fast-subtract).  At KJ6MKI on 2026-10-18, 504 periods of
### 12 FT8 bands: 7,050 decodes against 7,051 for 172 CPU-s against 294 (-41%); on ubersdr's FT8 test recordings, at
### every depth, WSJT-X's decodes but for one in two runs.  An older jt9 would take --fast-subtract for an unknown
### option, print its usage and exit, so it is asked first.
declare -a JT9_OPTS=()
if [[ ${WD_FT_FAST-yes} == "yes" ]] && ${JT9} -h 2>&1 | grep -q -- '--fast-subtract'; then
    JT9_OPTS=(-w 2)
    [[ ${MODE} == ft8 ]] && JT9_OPTS+=(--fast-subtract)
fi
### Measured plans take jt9 ~20 s to make, and it saves them (jt9_wisdom.dat) only when it ends normally, which a band's
### --feed jt9 never does: so they are made once here, by a jt9 decoding the first file to arrive, kept in RUN_DIR, and
### copied into each band's directory before its jt9 starts.
declare WISDOM=${RUN_DIR}/jt9_wisdom.dat
plan_wisdom() {
    local path=$1 dir=${RUN_DIR}/plan.d
    rm -rf ${dir}; mkdir -p ${dir}
    echo "$(date -u +%FT%TZ) making the measured FFT plans (${JT9_OPTS[*]}) on ${path##*/}" >&2
    ( cd ${dir} && ${JT9} ${JT9_FLAG} -a . -t . -d ${DEPTH} -L ${FREQ_LOW} -H ${FREQ_HIGH} -x b "${JT9_OPTS[@]}" ${path} > /dev/null 2>&1 )
    if [[ -s ${dir}/jt9_wisdom.dat ]]; then
        mv ${dir}/jt9_wisdom.dat ${WISDOM}
        echo "$(date -u +%FT%TZ) made ${WISDOM}" >&2
    else
        echo "$(date -u +%FT%TZ) no jt9_wisdom.dat from that run: each band's jt9 makes its own plans" >&2
    fi
    rm -rf ${dir}
}

### The band decoders' output goes through this into our stdout (the service's /var/log/ftX.log).  A file's decodes
### come before its '<FileDone> PATH N', so they are held until then, when PATH gives their date.
### jt9 line:  HHMMSS SNR DT AUDIO_HZ ~|+ MESSAGE [a1..a7|?]     (FT8 marks '~', FT4 '+')
convert() {
    local dial_hz=$1
    awk -v dial=${dial_hz} '
        $1 ~ /^[0-9][0-9][0-9][0-9][0-9][0-9]$/ && ($5 == "~" || $5 == "+") {
            msg = $0
            sub(/^[^~+]*[~+] +/, "", msg)                     # the message: everything after the marker
            sub(/ +$/, "", msg)
            if (msg ~ / [?]$/) next                           # WSJT-X: a low confidence decode, never a spot
            sub(/ +a[0-9]$/, "", msg)                         # WSJT-X: decoded with a-priori information
            gsub(/  +/, " ", msg)
            n++; hms[n] = $1; snr[n] = $2; dt[n] = $3; hz[n] = $4; text[n] = msg
            next
        }
        /^<FileDone> / {
            name = $2; sub(/.*\//, "", name)                  # YYYYMMDDTHHMMSSZ_FREQ_...
            day = substr(name, 1, 4) "/" substr(name, 5, 2) "/" substr(name, 7, 2)
            for (i = 1; i <= n; i++)
                printf "%s %s:%s:%s %3d %+4.2f %.1f ~ %s\n", day, substr(hms[i], 1, 2), substr(hms[i], 3, 2), substr(hms[i], 5, 2),
                       snr[i], dt[i], dial + hz[i], text[i]
            n = 0
            fflush()
            system("rm -f \"" $2 "\"")                       # as decode_ft8 does
        }
    '
}

### Start (or restart) the band's decoder: a 'jt9 --feed' reading file names from a FIFO the feeder holds open
declare -A BAND_FD=() BAND_PID=()
start_band() {
    local hz=$1 path=$2 fifo=${RUN_DIR}/${hz}.in
    rm -f ${fifo}; mkfifo ${fifo} || return 1
    ### jt9 keeps decoded.txt and jt9_wisdom.dat in its -a and -t directory: one for each band.  '-x b': no "his call";
    ### "my call" is jt9's K1ABC.  The period's UTC comes from pcmrecord's file name.
    mkdir -p ${RUN_DIR}/${hz}.d
    if [[ " ${JT9_OPTS[*]} " == *" -w 2 "* ]]; then
        [[ -s ${WISDOM} ]] || plan_wisdom ${path}
        [[ -s ${WISDOM} ]] && cp ${WISDOM} ${RUN_DIR}/${hz}.d/jt9_wisdom.dat
    fi
    ( cd ${RUN_DIR}/${hz}.d && ${JT9} ${JT9_FLAG} -a . -t . -d ${DEPTH} -L ${FREQ_LOW} -H ${FREQ_HIGH} -x b "${JT9_OPTS[@]}" --feed < ${fifo} 2> ${RUN_DIR}/${hz}.err | convert ${hz} ) &
    BAND_PID[${hz}]=$!
    exec {fd}> ${fifo}
    BAND_FD[${hz}]=${fd}
    echo "$(date -u +%FT%TZ) started a ${MODE^^} decoder for ${hz} Hz (depth ${DEPTH}, ${FREQ_LOW}-${FREQ_HIGH} Hz${JT9_OPTS[*]:+, ${JT9_OPTS[*]}})" >&2
}

declare -A QUEUED=()
queue_file() {
    local path=$1
    local name=${path##*/}
    [[ ${name} =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T[0-9]{6}Z_([0-9]+)_.*\.wav$ ]] || return 0
    [[ -n ${QUEUED[${name}]-} ]] && return 0
    QUEUED[${name}]=1
    local hz=${BASH_REMATCH[4]}
    if [[ -z ${BAND_PID[${hz}]-} ]] || ! kill -0 ${BAND_PID[${hz}]} 2> /dev/null; then
        [[ -n ${BAND_FD[${hz}]-} ]] && exec {BAND_FD[${hz}]}>&-
        start_band ${hz} ${path} || return 1
    fi
    echo "${path}" >&${BAND_FD[${hz}]}
}

### Missed events, and files already there at start: anything complete (not .tmp) that is not yet queued
scan() {
    local f
    for f in ${DIRECTORY}/*.wav; do
        [[ -f ${f} ]] && queue_file ${f}
    done
    (( ${#QUEUED[@]} > 5000 )) && QUEUED=()      ### names are unique per period; forget old ones now and then
    ### keep each band's stderr log from growing without end
    local err
    for err in $(find ${RUN_DIR} -maxdepth 1 -name '*.err' -size +1M 2> /dev/null); do
        : > ${err}
    done
}

trap 'for hz in ${!BAND_PID[@]}; do kill ${BAND_PID[${hz}]} 2> /dev/null; done; exit 0' TERM INT
### One inotifywait for our whole life: pcmrecord renames each finished period's .tmp to its .wav (moved_to)
exec {inotify_fd}< <(inotifywait -m -q -e moved_to -e close_write --format '%f' ${DIRECTORY})
scan
declare last_scan=${SECONDS} name rc
while true; do
    if read -t ${SCAN_SECS} -r -u ${inotify_fd} name; then
        [[ ${name} == *.wav ]] && queue_file ${DIRECTORY}/${name}
    else
        rc=$?
        if (( rc <= 128 )); then
            echo "$(date -u +%FT%TZ) inotifywait on ${DIRECTORY} ended, so exiting for systemd to restart us" >&2
            exit 1
        fi
    fi
    if (( SECONDS - last_scan >= SCAN_SECS )); then
        scan
        last_scan=${SECONDS}
    fi
done
