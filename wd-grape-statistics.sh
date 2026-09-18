#!/bin/bash

### The PSWS site ids this report covers.  To change the list for your own site, declare WD_PSWS_SITES
### in wsprdaemon.conf -- do NOT edit the list below.  This file is tracked by git, so an edit here is a
### local change to a source file: it collides with the next 'git pull', and has to be merged by hand or
### is silently lost.  GEEKOM-1 was found carrying exactly that edit on 2026-09-18, having added S000155
### (Maasbree) here because there was no way to say it in the config file.  Now there is.
declare WSPRDAEMON_ROOT_DIR=${WSPRDAEMON_ROOT_DIR-~/wsprdaemon}
declare WSPRDAEMON_CONFIG_FILE=${WSPRDAEMON_CONFIG_FILE-${WSPRDAEMON_ROOT_DIR}/wsprdaemon.conf}
[[ -f ${WSPRDAEMON_CONFIG_FILE} ]] && source ${WSPRDAEMON_CONFIG_FILE} > /dev/null 2>&1

if [[ -z "${WD_PSWS_SITES[*]-}" ]]; then
    ### Only the default: whatever wsprdaemon.conf declared above wins
    declare -a WD_PSWS_SITES=( S000042 S000108 S000109 S000110 S000111 S000113 S000114 S000115 S000116 S000117 S000119 S000120 S000121 S000123)
fi

function print-header() {
        if [[ "$1" == "header" ]]; then
                printf "Found ${#date_list[@]} dates in ${#WD_PSWS_SITES[@]} WD GRAPE Sites\n"
        fi
        printf "Date/Site#:"
        local site_id
        for site_id in ${WD_PSWS_SITES[@]}; do
                local site_num="${site_id: -3}"
                printf "  %s" "${site_num}"
        done
        printf "\n"
        if [[ "$1" != "header" ]]; then
                printf "Found ${#date_list[@]} dates in ${#WD_PSWS_SITES[@]} WD GRAPE Sites\n"
        fi

}

function wd-statistics() {
        local site_home_list=(  ${WD_PSWS_SITES[@]/#/..\/} )
        local date_list=( $(find  ${site_home_list[@]} -mindepth 1 -maxdepth 1 -type d -name 'OBS*' -printf "%f\n" 2> /dev/null | sort -u ) )

        print-header "header"
        for obs_date in ${date_list[@]}; do
                printf "${obs_date:3:10}: "
                local site_home
                for site_home in ${site_home_list[@]}; do
                        local dir_size="    "
                        local obs_date_dir=${site_home}/${obs_date}
                        if [[ -d ${obs_date_dir} ]]; then
                                dir_size="$(du -sh ${obs_date_dir} | cut -f 1)"
                        fi
                        printf "%4s " "${dir_size}"
                        #exit 1
                done
                printf "\n"
        done
        print-header "foot"
}

 wd-statistics
