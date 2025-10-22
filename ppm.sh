#!/bin/bash

###  Wsprdaemon:   A robust  decoding and reporting system for  WSPR

###    Copyright (C) 2020-2021  Robert S. Robinett
###
###    This program is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    This program is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###    GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

declare SDR_AUDIO_SPS=12000      ### 'wsprd' wants a 12000 sps audio file
declare SDR_SAMPLE_TIME=2        ### how many seconds to sample

function sdr_measure_error() {
    local ret_string_name=$1
    local soapy_device=$2
    local tuning_frequency=$3
    local center_frequency=$4
    local expected_audio_freq=$5

    wd_logger 3 "tuning to freq ${tuning_frequency} while centered at freq ${center_frequency}" 
    sdrTest -f ${tuning_frequency} -fc ${center_frequency} -usb -device ${soapy_device} -faudio ${SDR_AUDIO_SPS} -timeout ${SDR_SAMPLE_TIME} -file sdraudio.raw > sdrtest.log 2>&1
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 0 "sdrTest -f %s -fc %s -usb -device %s -faudio %s -timeout %s -file sdraudio.raw > sdrtest.log 2>&1 => ERROR %s\ncat sdrtest.log:\n%s\n" \
                "${tuning_frequency}" "${center_frequency}" "${soapy_device}" "${SDR_AUDIO_SPS}" "${SDR_SAMPLE_TIME}" "${ret_code}" "$(cat sdrtest.log)"
        eval "${ret_string_name}='sdrTest failed'"
        return ${ret_code}
    fi
    cat sdraudio.raw | sox -r ${SDR_AUDIO_SPS} -t raw -e s -b 16 -c 1 - -n stat -freq > sdrspectrum.txt 2>&1
    local audio_freq=$(awk '/^[1-9]/ && $2 > 50000' sdrspectrum.txt | sort -k 2,2n | tail -1 | awk '{print $1}')
    audio_freq=${audio_freq//.*/}    ### truncate to an integer freq
    if [[ -z "${audio_freq}" ]]; then
        wd_logger 3 "failed to find a peak audio band > 50000"
        eval "${ret_string_name}='sdrTest failed to find audio peak frequency'"
        return 2
    fi
    local audio_mean_level=$(awk '/RMS.*amplitude/{print $3}' sdrspectrum.txt)
    local audio_error=$(( audio_freq - expected_audio_freq))
    local ppm_error=0
    if [[ ${audio_error} -ne 0 ]]; then
        ppm_error=$( bc <<< "scale=2; ( 1000000/ (${tuning_frequency} / ${audio_error}) )" )
    fi
    eval "${ret_string_name}=${audio_freq}"
    if [[ $(bc <<< "(${audio_mean_level} < 0.15)") -eq 1 ]]; then
         wd_logger 1 "found audio_freq=${audio_freq}, audio_mean_level=${audio_mean_level}, audio_error=${audio_error}. No signal was detected, so returning error = 1"
        return 1
    fi
     wd_logger 3 "found audio_freq=${audio_freq}, audio_mean_level=${audio_mean_level}, audio_error=${audio_error}. A signal was detected, so returning sucess = 0"
    return 0
}

### Tune to $2 then vary the center frequency around $2-$3 expecting an audio tone of $4
function check_offset_accuracy() {
    local test_device=$1                 ### The Soapy device number of the SDR
    local tuning_freq_hz=$2              ### Tune to this freq (e.g. carrier freq in Hz - 1000 
    local center_offset_hz=$3            ### The frequency of the center
    local center_freq_hz=$((tuning_freq_hz - center_offset_hz))
    local expected_audio_freq=$4

     wd_logger 0 "with signal at ${center_freq_hz}, tune device #${test_device} around  ${tuning_freq_hz}, expecting %4d Hz audio at the center tuning\n" ${expected_audio_freq}

    local sample_rate=2000000     ### This is the default for the RTL-SDR

    ### Fill center_offset_hertz_table[] with absolute values in Hz of offset from ${center_offset_hz}
    local center_offset_percent_table=( 1 2 5 10 20 50 )  ### % of ${sample_rate} to try
    local center_offset_percent_table=( -50 -20 -10 -5 -2 0 2 5 10 20 50) ### % of ${center_offset_hz} to try
    local center_offset_hertz_table=()
    local center_offset_hertz_table_index
    for (( center_offset_percent_table_index=0; center_offset_percent_table_index < ${#center_offset_percent_table[@]}; ++center_offset_percent_table_index )); do
        center_offset_hertz_table[${center_offset_percent_table_index}]=$( bc <<< "scale=0;( ${center_offset_hz} - ( ${center_offset_hz} * ${center_offset_percent_table[${center_offset_percent_table_index}]}  / 100 )) " )
         wd_logger 4 "at offset %3d %% == %7d Hz\n"  ${center_offset_percent_table[${center_offset_percent_table_index}]} ${center_offset_hertz_table[${center_offset_percent_table_index}]}
    done

    ### Keep the tuning freq constant while changing the center frequency
    #local table_index
    #for (( table_index=0; table_index < ${#ACCURACY_OFFSET_TABLE[@]}; ++table_index)); do
    #    local test_offset=${ACCURACY_OFFSET_TABLE[${table_index}]}
    local test_frequency=$(( tuning_freq_hz + 0 ))
    local test_expected_audio_freq=$(( expected_audio_freq - 0 ))

    for test_offset in ${center_offset_hertz_table[@]} ; do
        local center_frequency=$(( test_frequency - test_offset))
         wd_logger 3 "test device #${test_device} at test ${test_frequency} / center ${center_frequency}, expecting a %4d Hz audio report\n" ${test_expected_audio_freq}

        local measured_audio_freq='none'
        sdr_measure_error measured_audio_freq ${test_device} ${test_frequency} ${center_frequency} ${expected_audio_freq}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
             wd_logger 0 "sdr_measure_error() => ${ret_code} for test device #${test_device} at center ${center_frequency} / test ${test_frequency}, expecting %4d Hz audio report\n" ${test_expected_audio_freq}
            return ${ret_code}
        fi
        local tuning_error_hz=$(( ${test_expected_audio_freq} - ${measured_audio_freq} ))
        local ppm_error=0
        if [[ ${tuning_error_hz} -ne 0 ]]; then
            ppm_error=$( bc <<< "scale=4; ( 1000000/ (${test_frequency} / ${tuning_error_hz}) )" )
        fi
        if [[ ${ret_code} -eq 0 ]]; then
             wd_logger 0 "device #${test_device} tuned to ${test_frequency}, center ${center_frequency}. Expected %4d Hz audio, measured %4d Hz audio, so tuning is off by %4d Hz = %5.4f ppm\n" \
                ${test_expected_audio_freq} ${measured_audio_freq} ${tuning_error_hz} ${ppm_error}
        else
             wd_logger 0 "device #${test_device} tuned to frequency ${test_frequency} and measured %4d Hz audio, but returned an error\n" ${measured_audio_freq}
        fi
    done
}

declare TUNING_OFFSET_HZ_TABLE=( -500 -200 -100 -50 -20 -10 0 10 20 50 100 200 500 )
declare TUNING_CENTER_OFFSET_HZ=100000      ### Center the SDR at the next freq multiple below the test frequency

### Vary the tuning frequency around $2 while holding the center frequency constant and see how the audio tone matches the expected tone
function check_tuning_accuracy() {
    local test_device=$1
    local signal_frequency=$2
    local expected_audio_freq=$3
    local center_frequency=$(( signal_frequency - (signal_frequency % ${TUNING_CENTER_OFFSET_HZ}) ))

     wd_logger 1 "center device #${test_device} at ${center_frequency} and tune it around frequency ${signal_frequency} expecting %4d Hz audio at the center tuning\n" ${expected_audio_freq}

    local table_index
    for (( table_index=0; table_index < ${#TUNING_OFFSET_HZ_TABLE[@]}; ++table_index)); do
        local test_offset=${TUNING_OFFSET_HZ_TABLE[${table_index}]}
        local test_frequency=$(( signal_frequency + test_offset ))
        local test_expected_audio_freq=$(( expected_audio_freq - test_offset ))
         wd_logger 3 "test device #${test_device} at center ${center_frequency} / test ${test_frequency}, expecting %4d Hz audio report\n" ${test_expected_audio_freq}

        local measured_audio_freq="none"
        sdr_measure_error measured_audio_freq ${test_device} ${test_frequency} ${center_frequency} ${test_expected_audio_freq}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
             wd_logger 0 " sdr_measure_error() => ${ret_code} for test device #${test_device} at center ${center_frequency} / test ${test_frequency}, expecting %4d Hz audio report\n" \
                ${test_expected_audio_freq}
            return ${ret_code}
        fi

        local tuning_error_hz=$(( ${test_expected_audio_freq} - ${measured_audio_freq} ))
        local ppm_error=0
        if [[ ${tuning_error_hz} -ne 0 ]]; then
            ppm_error=$( bc <<< "scale=4; ( 1000000/ (${test_frequency} / ${tuning_error_hz}) )" )
        fi
         wd_logger 0 "device #${test_device} tuned to ${test_frequency}, center ${center_frequency}. Expected %4d Hz audio, measured %4d Hz audio, so tuning is off by %4d Hz = %5.4f ppm\n" \
                ${test_expected_audio_freq} ${measured_audio_freq} ${tuning_error_hz} ${ppm_error}
    done
}

function get_tuning_error_hz() {
    local measured_hz_ret_variable=$1
    local measured_ppm_ret_variable=$2
    local soapy_device=$3
    local tuning_frequency=$4
    local center_frequency=$5
    local test_expected_audio_freq=$6

    wd_logger 3 "center device #${soapy_device} at ${center_frequency} and tune to ${tuning_frequency} expecting audio tone at ${test_expected_audio_freq} hz"
    local measured_audio_freq="none"
    sdr_measure_error measured_audio_freq ${soapy_device} ${tuning_frequency} ${center_frequency} ${test_expected_audio_freq}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
         wd_logger 0 " sdr_measure_error() => ${ret_code} for test device #${soapy_device} at center ${center_frequency} / test ${tuning_frequency}, expecting %4d Hz audio report\n" \
                ${test_expected_audio_freq}
        return 2
    fi

    local tuning_error_hz=$(( - ( ${measured_audio_freq} - ${test_expected_audio_freq} ) ))   ### When oscillator is low, the audio tone will be too high
    local ppm_error=0
    if [[ ${tuning_error_hz} -ne 0 ]]; then
        ppm_error=$( bc <<< "scale=10;( 1000000/ (${tuning_frequency} / ${tuning_error_hz}) )" )
    fi
    eval "${measured_hz_ret_variable}='${measured_audio_freq}'"
    eval "${measured_ppm_ret_variable}='${ppm_error}'"
     wd_logger 2 "centered device #${soapy_device} at ${center_frequency} and tuned to ${tuning_frequency}. Expected %4d Hz audio, measured %4d Hz audio, so tuning is off by %4d Hz = %5.4f ppm\n" \
                ${test_expected_audio_freq} ${measured_audio_freq} ${tuning_error_hz} ${ppm_error}
    return 0
}

### Updates the PPM_FILE which contains lines, each with three fields:
###            EPOCH_TIME  DEVICE PPM_ERROR
function update_ppm_file() {
    local device_number=$1
    local ppm_error=$2
    local epoch_time=$(date +%s)

    touch ${PPM_FILE_PATH}    ### In case it doesn't exist
    local filtered_file=$( awk -v device=${device_number} '$2 != device' ${PPM_FILE_PATH})

    echo "${epoch_time} ${device_number} ${ppm_error}
${filtered_file}"  > ${PPM_FILE_PATH}
    
     wd_logger 2 "saved  device #${device_number} ppm error ${ppm_error} to '${PPM_FILE_PATH}'\n"
    return 0
}

function read_ppm() {
    local ppm_return_var=$1
    local device_number=$1
    local ppm_error
    local epoch_time

    local ppm_line==$( awk -v device=${device_number} '$2 == device' ${PPM_FILE_PATH})

    if [[ -z "${ppm_line}" ]]; then
         wd_logger 0 "can't find a line for device #${device_number} in '${PPM_FILE_PATH}'\n"
        eval "${ppm_return_var} = ''"
        return 1
    fi
    local ppm_line_array=( ${ppm_line} )
    eval "${ppm_return_var} = '${ppm_line_array[2]}'"
     wd_logger 0 "found device #${device_number} ppm error is ${ppm_line_array[2]}"
    return 0
}
             
declare THIS_CMD_FILE_PATH=$(realpath ${0})
declare PPM_FILE_PATH=${THIS_CMD_FILE_PATH/.sh/.ppm}

 ### The -p cmd: Tune device #$1 to ATSC ch #$2, then calculate the ppm error and update the ppm file with the ppm error
function ppm_measure() {
    local soapy_device=$1
    local atsc_channel=$2   ### ATSC channel to use as reference 
    local pilot_carrier_freq
    local measured_audio_hz
    local measured_ppm
    local tuning_offset_hz=${TARGET_AUDIO_TONE_FREQ}

    wd_logger 2 "Tune device #${soapy_device} to ATSC channel #${atsc_channel} and measure the ppm error and record it to ${PPM_FILE_PATH}\n"

    ### Measure the ppm error from the audio tone error from ${atsc_channel}
    get_atsc_ppm_error   pilot_carrier_freq measured_audio_hz measured_ppm ${soapy_device} ${atsc_channel} ${tuning_offset_hz}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
         wd_logger 0 "get_atsc_ppm_error current_ppm ${soapy_device} ${atsc_channel} => ERROR #${ret_code}\n"
        exit 1
    fi
    wd_logger 0 "Tested the ATSC ch #${atsc_channel} pilot carrier which is at ${pilot_carrier_freq} and measured a  ${measured_audio_hz} Hz tone instead of the expected ${TARGET_AUDIO_TONE_FREQ} hz, which equals ${measured_ppm} ppm error\n"
    update_ppm_file   ${soapy_device} ${measured_ppm}
    return 0
}

### Returns the ppm error for device $2 found in ${PPM_FILE_PATH}
function get_ppm_error() {
    local ppm_value_return_var=$1
    local soapy_device=$2

    wd_logger 2 "Return ppm error for #${soapy_device} found in ${PPM_FILE_PATH}\n"

    if [[ ! -f ${PPM_FILE_PATH} ]]; then
        wd_logger 0 "ERROR: ppm file '${PPM_FILE_PATH}' does not exist\n"
        return 1
    fi
    local ppm_value=$( awk -v device=${soapy_device} '$2 == device {print $3}' ${PPM_FILE_PATH})
    
    if [[ -z "${ppm_value}" ]]; then
        wd_logger 0 "ERROR: ppm file '${PPM_FILE_PATH}' doesn't contain a line for device ${soapy_device}\n"
        return 2
    fi
    eval "${ppm_value_return_var}=${ppm_value}"

    wd_logger 2 "found ppm value ${ppm_value} for device #${soapy_device} in '${PPM_FILE_PATH}'\n"
    return 0
}

## The -m cmd:  Tune device #$1 to ATSC ch #$2, then calculate the ppm error. If $4 is present, update that file with the ppm error and return, else validate ppm by tuning to $2 and $3.
function test_ppm_adjust() {
    local soapy_device=$1
    local atsc_channel=$2   ### ATSC channel to use as reference 
    local tuning_offset_hz=${TARGET_AUDIO_TONE_FREQ}

    wd_logger 0 "Tune device #${soapy_device} to ATSC channel #${atsc_channel} and measure the tuning error\n"

    local stored_ppm
    get_ppm_error stored_ppm ${soapy_device}
    local ret_value=$?
    if [[ ${ret_value} -ne 0 ]]; then
        wd_logger 1 "ERROR: get_ppm_error ${soapy_device} stored_ppm => {ret_value}\n"
        return 1
    fi

    local pilot_carrier_freq
    atsc_get_pilot_freq   pilot_carrier_freq ${atsc_channel}
    local ret_value=$?
    if [[ ${ret_value} -ne 0 ]]; then
         wd_logger 1 "ERROR: get_ppm_error ${soapy_device} stored_ppm => {ret_value}\n"
        return 2
    fi

    local ppm_hz_error=$(bc <<< "(${pilot_carrier_freq} * ${stored_ppm}) / 1000000" )                           ### The order of the arguments to 'bc' is important so that the output is rounded to the nearest integer value
    local ppm_calculated_tuning_freq=$(( ${pilot_carrier_freq} - ${TARGET_AUDIO_TONE_FREQ} - ${ppm_hz_error} )) ### i.e. if the audio tone was too high, then there is a negative ppm value, so subtract ppm to get the new tuning freq
 
     wd_logger 2 "So the tuning frequency corrected by the stored ppm is ${ppm_calculated_tuning_freq}\n"

    local center_frequency=$(( ${ppm_calculated_tuning_freq} - ${ATSC_CENTER_OFFSET_HZ} ))

    local measured_audio_hz
    local measured_ppm
    get_tuning_error_hz measured_audio_hz corrected_ppm ${soapy_device} ${ppm_calculated_tuning_freq} ${center_frequency} ${tuning_offset_hz}
    
    local audio_error_hz=$(( ${TARGET_AUDIO_TONE_FREQ} - ${measured_audio_hz} ))
    audio_error_hz=${audio_error_hz#-}     ### This gives us the absolute value of the error
    if [[ ${audio_error_hz} -eq 0 ]]; then
        wd_logger 0 "Success: tested the ATSC ch #${atsc_channel} pilot carrier which is at ${pilot_carrier_freq} by tuning to the adjusted frequency ${ppm_calculated_tuning_freq} which reflects the ${measured_ppm} ppm error, and measured the expected ${TARGET_AUDIO_TONE_FREQ} hz\n"
    else
        wd_logger 0 "Warning: tested the ATSC ch #${atsc_channel} pilot carrier which is at ${pilot_carrier_freq} by tuning to the adjusted frequency ${ppm_calculated_tuning_freq} and measured a ${measured_audio_hz} Hz tone instead of the expected ${TARGET_AUDIO_TONE_FREQ} hz, which equals ${corrected_ppm} ppm error\n"
    fi
   return 0
}  

### Returns the tuning frequency for device ${soapy_device) when that frequency is adjusted by the previously measured ppm error of that device
function get_adjusted_tuning_freq() {
    local adjusted_tuning_freq_ret_variable=$1
    local soapy_device=$2
    local tuning_frequency=$3

     wd_logger 2 "for device #${soapy_device} find the tuning frequency ${tuning_frequency} when it is adjusted for the previously measured ppm error\n"

    local stored_ppm
    get_ppm_error stored_ppm ${soapy_device}
    local ret_value=$?
    if [[ ${ret_value} -ne 0 ]]; then
         wd_logger 0 "ERROR: get_ppm_error ${soapy_device} stored_ppm => ${ret_value}\n"
        return 1
    fi

    local ppm_hz_error=$(bc <<< "(${tuning_frequency} * ${stored_ppm}) / 1000000" )  ### The order of the arguments to 'bc' is important so that the output is rounded to the nearest integer value
    local adjusted_freq=$(( ${tuning_frequency} - ${ppm_hz_error} ))
    eval "${adjusted_tuning_freq_ret_variable}=${adjusted_freq}"

     wd_logger 2 "tuning frequency ${tuning_frequency} of device #${soapy_device} will be adjusted by ppm error ${stored_ppm} to ${adjusted_freq}\n"
    return 0
}

## The -t cmd: print the audio tone detected when device ${soapy_device} is tuned to the ${tuning_frequency}
function test_at_tuning_freq() {
    local soapy_device=$1
    local tuning_frequency=$2
    local adjusted_tuning_freq

     wd_logger 2 "for device #${soapy_device} report the audio tone detected when tuned to frequency ${tuning_frequency} when it is adjusted for the previously measured ppm error\n"

    get_adjusted_tuning_freq   adjusted_tuning_freq ${soapy_device} ${tuning_frequency}
    local ret_value=$?
    if [[ ${ret_value} -ne 0 ]]; then
         wd_logger 0 "ERROR: get_adjusted_tuning_freq ${soapy_device} ${tuning_frequency} => ${ret_value}\n"
        return 1
    fi

    local center_frequency=$(( ${adjusted_tuning_freq} - ${ATSC_CENTER_OFFSET_HZ} ))
    local test_expected_audio_freq=0
   
    local measured_audio_freq="none"
    sdr_measure_error measured_audio_freq ${soapy_device} ${adjusted_tuning_freq} ${center_frequency} ${test_expected_audio_freq}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
         wd_logger 0 " ERROR: sdr_measure_error() => ${ret_code} for test device #${soapy_device} at center ${center_frequency} / adjusted freq  ${ajusted_tuning_frequency}, expecting %4d Hz audio report\n" \
                ${test_expected_audio_freq}
        return 2
    fi

     wd_logger 0 "centered device #${soapy_device} at ${center_frequency} and tuned to ${adjusted_tuning_freq} and detected %4d Hz audio\n" ${measured_audio_freq}
    return 0
}

function test_at_tuning_freq_loop() {
    local soapy_device=$1
    local tuning_frequency=$2

     wd_logger 0 "for device #${soapy_device} find the tuning frequency ${tuning_frequency} when it is adjusted for the previously measured ppm error\n"
    while true; do
        test_at_tuning_freq  ${soapy_device} ${tuning_frequency}
    done
}

### Format is BAND_IN_METERS_OR_CM:TUNING_FREQ_IN_HZ
declare WSPR_BAND_TO_TUNING_FREQ=( 2200:136000 630:474200  160:1836600 80:3568600  61:5287200 60:5364700 40:7038600  30:10138700   22:135539     20:14095600 \
                                   17:18104600 15:21094600 12:24924600 10:28124600 8:40680000 6:50293000 4:70091000 2:144489000 70:432300000  23:1296500000 29:560308000)

function get_wspr_tuning_frequency() {
    local freq_ret_var=$1
    local search_band=$2

    local index
    for (( index=0; index < ${#WSPR_BAND_TO_TUNING_FREQ[@]}; ++index )); do
        local band_freq=( ${WSPR_BAND_TO_TUNING_FREQ[index]/:/ } )
        local band=${band_freq[0]}
        local freq=${band_freq[1]}

        if [[ ${band} -eq ${search_band} ]]; then
            eval "${freq_ret_var}=${freq}"
            return 0
        fi
    done
    eval "${freq_ret_var}='not valid band'"
     wd_logger 0 "ERROR:  can't find band ${search_band}\n"
    return 1
}


