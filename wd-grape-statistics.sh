`#!/bin/bash

declare WD_PSWS_SITES=( S000042 S000108 S000109 S000110 S000111 S000113 S000114 S000115 S000116 S000117 S000119 S000120 S000121 S000123)

function wd-statistics() {
        local site_home_list=(  ${WD_PSWS_SITES[@]/#/..\/} )
        local date_list=( $(find  ${site_home_list[@]} -mindepth 1 -maxdepth 1 -type d -name 'OBS*' -printf "%f\n" 2> /dev/null | sort -u ) )

        printf "Found ${#date_list[@]} dates in ${#WD_PSWS_SITES[@]} WD GRAPE Sites\n"
        printf "Date/Site#:"
        local site_id
        for site_id in ${WD_PSWS_SITES[@]}; do
                local site_num="${site_id: -3}"
                printf "  %s" "${site_num}"
        done
        printf "\n"
        for obs_date in ${date_list[@]}; do
                printf "${obs_date:3:10}: "
                local site_home
                for site_home in ${site_home_list[@]}; do
                        local obs_val="****"
                        local obs_date_dir=${site_home}/${obs_date}
                   _date_dir} ]]; then
                                dir_size="$(du -sh ${obs_date_dir} | cut -f 1)"
                        fi
                        printf "%4s " "${dir_size}"
                        #exit 1
                done
                printf "\n"
        done
}

 wd-statistics
