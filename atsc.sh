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


declare AUDIO_EXPECTED_FREQ=1000                  ### When calibrating the SDR against ATSC pilot carriers, tune in USB this many Hz below the carrier
declare ATSC_CHANNEL_VHF_START="7 174000000"      ### The ATSC VHF band starts with Channel 7 
declare ATSC_CHANNEL_VHF_END="13 210000000"
declare ATSC_CHANNEL_UHF_START="14 470000000"     ### The ATSC UHF band starts with Channel 14
declare ATSC_CHANNEL_UHF_END="51 692000000"
declare ATSC_CHANNEL_WIDTH="6000000"              ### ATSC channels are 6 MHz wide
declare ATSC_PILOT_CARRIER_OFFSET=309441          ### The pilot carrier is at 309440.559 Hz above the bottom of the channel.  Round it up to 309441

declare ATSC_PILOT_FREQ_TABLE

function atsc_pilot_freq_table_create() {
    local channel_info=( ${ATSC_CHANNEL_VHF_START} )
    local channel_number=${channel_info[0]}
    local channel_freqency=${channel_info[1]}
    local last_channel_info=( ${ATSC_CHANNEL_VHF_END} )
    local last_channel_number=${last_channel_info[0]}
    local last_channel_frequency=${last_channel_info[1]}
    local table_index=0

    local wd_arg=$(printf "Filling ATSC_PILOT_FREQ_TABLE[] with ATSC channels from #${channel_number} at %d Hz to #${last_channel_number} at %d\n" ${channel_freqency} ${last_channel_frequency})
    wd_logger 2 "${wd_arg}"
    while [[ ${channel_freqency} -le ${last_channel_frequency} ]]; do
        ATSC_PILOT_FREQ_TABLE[${table_index}]="${channel_number} ${channel_freqency}"
        wd_logger 3 "Assigned Ch '${channel_number}' / Freq '${channel_freqency}' to ATSC_PILOT_FREQ_TABLE[${table_index}]"
        (( ++table_index ))
        (( ++channel_number ))
        (( channel_freqency+=${ATSC_CHANNEL_WIDTH} ))
    done
    
    channel_info=( ${ATSC_CHANNEL_UHF_START} )
    channel_number=${channel_info[0]}
    channel_freqency=${channel_info[1]}
    last_channel_info=( ${ATSC_CHANNEL_UHF_END} )
    last_channel_number=${last_channel_info[0]}
    last_channel_frequency=${last_channel_info[1]}

     while [[ ${channel_freqency} -le ${last_channel_frequency} ]]; do
        ATSC_PILOT_FREQ_TABLE[${table_index}]="${channel_number} ${channel_freqency}"
        wd_logger 3 "Assigned Ch '${channel_number}' / Freq '${channel_freqency}' to ATSC_PILOT_FREQ_TABLE[${table_index}]"
        (( ++table_index ))
        (( ++channel_number ))
        (( channel_freqency+=${ATSC_CHANNEL_WIDTH} ))
    done
}

unset ATSC_PILOT_FREQ_TABLE
[[ -z "${ATSC_PILOT_FREQ_TABLE[0]-}" ]] && atsc_pilot_freq_table_create 

function atsc_get_pilot_freq() {
    local ret_string_name=$1
    local atsc_channel_number=$2

    local atsc_channel_info_max_index=${#ATSC_PILOT_FREQ_TABLE[@]}
    local atsc_channel_info_index=0

    while [[ ${atsc_channel_info_index} -lt ${atsc_channel_info_max_index} ]]; do
        local channel_info=( ${ATSC_PILOT_FREQ_TABLE[${atsc_channel_info_index}]} )
        channel_number=${channel_info[0]}
        channel_freqency=${channel_info[1]}
        if [[ ${channel_number} -eq ${atsc_channel_number} ]]; then
            ### Tune to 1000 Hz below the pilot carrier frequency
            local pilot_frequency=$(( ${channel_freqency} + ${ATSC_PILOT_CARRIER_OFFSET} ))
             wd_logger 3 "found ATSC channel #${channel_info[@]} in table, its pilot frequency is ${pilot_frequency}"
            eval "${ret_string_name}=${pilot_frequency}"
            return 0
        fi
        (( ++atsc_channel_info_index ))
    done
     wd_logger 3 "ERROR: ${atsc_channel_number} is not a valid ATSC channel number"
    eval "${ret_string_name}='${atsc_channel_number} is not a valid channel number'"
    return  1
}

function test_tuning() {
    local channel_pilot_frequency
    local channel_number
    for channel_number in 13 29 2; do
        if channel_pilot_frequency=$(atsc_get_pilot_tuning_freq ${channel_number}) ; then
             wd_logger 0 "found channel #${channel_number} has pilot carrier at ${channel_pilot_frequency} hz"
        else
             wd_logger 0 " ERROR: channel #${channel_number} not a valid ATSC channel number"
        fi
    done
}

declare SFO_ATSC_CHANNEL_LIST=( 7 13 19 27 29 30 33 38 39 40 41 43 44)
declare SOAPY_DEVICE_LIST=( 0 )
declare ATSC_PILOT_AUDIO_EXPECTED=1441       ### Tune this many Hz below the pilot frequency and expect an audio tone of this frequency in Hz

### Tunes 1440 Hz below the pilot carriers, records 2 seconds of audio, then runs 'sox -n stat -freq' to see how much the audio frequency differs from 1440 Hz.
function atsc_scan() {
    local soapy_device=$1
    local index 
    for (( index=0 ; index<${#SFO_ATSC_CHANNEL_LIST[@]}; index++)); do
        local channel_number=${SFO_ATSC_CHANNEL_LIST[${index}]}
        local atsc_pilot_frequency=""
        atsc_get_pilot_freq atsc_pilot_frequency ${channel_number} 
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
             wd_logger 0 "ERROR: atsc_get_pilot_tuning_freq  ${channel_number} not valid: ${atsc_pilot_frequency}"
            continue
        fi
        local test_expected_audio_freq=${ATSC_PILOT_AUDIO_EXPECTED}
        local tuning_frequency=$(( atsc_pilot_frequency - ${test_expected_audio_freq} ))
        local center_frequency=$(( atsc_pilot_frequency - (atsc_pilot_frequency % ${TUNING_CENTER_OFFSET_HZ}) ))

        wd_logger 3 "receive ch #${channel_number} at ${atsc_pilot_frequency} by tuning to freq ${tuning_frequency}"
        local measured_audio_freq="none"
        sdr_measure_error measured_audio_freq ${soapy_device} ${tuning_frequency} ${center_frequency} ${test_expected_audio_freq}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
             wd_logger 0 " sdr_measure_error() => ${ret_code} for test device #${soapy_device} at center ${center_frequency} / test ${tuning_frequency}, expecting %4d Hz audio report\n" \
                ${test_expected_audio_freq}
            continue
        fi

        local tuning_error_hz=$(( ${test_expected_audio_freq} - ${measured_audio_freq} ))
        local ppm_error=0
        if [[ ${tuning_error_hz} -ne 0 ]]; then
            ppm_error=$( bc <<< "scale=4; ( 1000000/ (${tuning_frequency} / ${tuning_error_hz}) )" )
        fi
         wd_logger 0 "device #${soapy_device} tuned to ATSC channel #%2d pilot carrier at ${tuning_frequency}, center ${center_frequency}. Expected %4d Hz audio, measured %4d Hz audio, so tuning is off by %4d Hz = %5.4f ppm\n" \
                ${channel_number} ${test_expected_audio_freq} ${measured_audio_freq} ${tuning_error_hz} ${ppm_error}
    done
}

declare ATSC_CENTER_OFFSET_HZ=100000     ### For ATSC pilot carrier measurements, set the center 100 kHz below the pilot carrier frequecy
function get_atsc_ppm_error() {
    local pilot_carrier_freq_ret_variable=$1
    local measured_audio_hz_ret_variable=$2
    local measured_ppm_ret_variable=$3
    local soapy_device=$4
    local channel_number=$5
    local tuning_offset_hz=$6

     wd_logger 2 "get ppm error for device #${soapy_device} tuned to the pilot carrier of ATSC channel #${channel_number} offset by ${tuning_offset_hz} hz"
    
    local atsc_pilot_frequency=""
    atsc_get_pilot_freq atsc_pilot_frequency ${channel_number}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
         wd_logger 0 "ERROR: atsc_get_pilot_tuning_freq  ${channel_number} not valid: ${atsc_pilot_frequency}"
        return 1
    fi
    eval "${pilot_carrier_freq_ret_variable}='${atsc_pilot_frequency}'"   ### Return this value to the calling function

    local tuning_frequency=$(( atsc_pilot_frequency - ${tuning_offset_hz} ))
    local center_frequency=$(( ${atsc_pilot_frequency} - ${ATSC_CENTER_OFFSET_HZ} ))
     wd_logger 3 "receive ch #${channel_number} at ${atsc_pilot_frequency} by tuning to freq ${tuning_frequency}"
    
    get_tuning_error_hz ${measured_audio_hz_ret_variable} ${measured_ppm_ret_variable} ${soapy_device} ${tuning_frequency} ${center_frequency} ${tuning_offset_hz}
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
         wd_logger 0 "ERROR: get_tuning_error_hz ${measured_audio_hz_ret_variable} ${measured_ppm_ret_variable} ${soapy_device} ${tuning_frequency} ${center_frequency} ${tuning_offset_hz} => ${ret_code}"
        return 1
    fi

     wd_logger 2 "get_tuning_error_hz ${measured_audio_hz_ret_variable} ${measured_ppm_ret_variable} ${soapy_device} ${tuning_frequency} ${center_frequency} ${tuning_offset_hz} was successful"
    return 0
}

declare TARGET_AUDIO_TONE_FREQ=1500       ### When tuning is compensated for oscillator error, this is the audio tone in Hertz we expect

function show_atsc_ppm_loop() {
    local soapy_device=$1
    local atsc_channel=$2
    local tuning_offset_hz=${TARGET_AUDIO_TONE_FREQ}  ### audio tone frequency in Hz we expect when tuned this many Hz below the pilot carrier of this ATSC channel
    local pilot_carrier_freq        ### returned tuning frequency in Hz of the ATSC channel's pilot carrier
    local mesasured_audio_hz        ### returned audio tone in Hz when tuned ${tuning_offset} below that pilot carrier
    local measured_ppm              ### returned ppm error

     wd_logger 0 "testing device #${soapy_device} on ATSC channel #${atsc_channel}\n"
    while true; do
        get_atsc_ppm_error pilot_carrier_freq measured_audio_hz measured_ppm ${soapy_device} ${atsc_channel} ${tuning_offset_hz}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
             wd_logger 0 "get_atsc_ppm_error current_ppm ${soapy_device} ${atsc_channel} => ERROR #${ret_code}\n"
        else
             wd_logger 0 "testing ATSC ch #${atsc_channel} which has pilot carrier at ${pilot_carrier_freq} and measured ${measured_audio_hz} Hz == ${measured_ppm} ppm error\n"
        fi
        sleep 1
    done
}


