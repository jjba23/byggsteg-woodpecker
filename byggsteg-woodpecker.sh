#!/usr/bin/env sh

# byggsteg-woodpecker

# Copyright © Josep Bigorra <jjbigorra@gmail.com>

# byggsteg-woodpecker is free software: you can redistribute it and/or modify
# it under the terms of the Lesser GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# byggsteg-woodpecker is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# Lesser GNU General Public License for more details.

# You should have received a copy of the Lesser GNU General Public License
# along with byggsteg-woodpecker.  If not, see <https://www.gnu.org/licenses/>.

set -euo;

PLUGIN_POLL_LIMIT=${PLUGIN_POLL_LIMIT:-2048}
PLUGIN_POLL_INTERVAL_SECONDS=${PLUGIN_POLL_INTERVAL_SECONDS:-16}

get_timestamp() {
  date '+%Y-%m-%d %H:%M:%S%:z'
}

log_error() {
  printf "\n[ERROR][%s] %s\n" "$(get_timestamp)" "$1" >&2
}

log_info() {
  printf "\n[INFO][%s] %s\n" "$(get_timestamp)" "$1"
}

poll_for_job_success() {
    while [ "$POLL_COUNT" -lt "$PLUGIN_POLL_LIMIT" ]; do        
        log_info "GET call to $PLUGIN_BYGGSTEG_URL/api/v1/logs/$BYGGSTEG_LOG_ID"      
        curl -s "$PLUGIN_BYGGSTEG_URL/api/v1/logs/$BYGGSTEG_LOG_ID" \
            > byggsteg-log-response.json
        jq . < byggsteg-log-response.json

        POLL_COUNT=$(( POLL_COUNT + 1 ))

        BYGGSTEG_JOB_SUCCEEDED=$(jq -r '.["success"]' < byggsteg-log-response.json)
        BYGGSTEG_JOB_FAILURE=$(jq -r '.["failure"]'  < byggsteg-log-response.json)
        BYGGSTEG_JOB_IN_PROGRESS=$(jq -r '.["in-progress"]'  < byggsteg-log-response.json)

        if [ "$BYGGSTEG_JOB_SUCCEEDED" -eq 1 ]; then
            jq -r '.["log-data"]' < byggsteg-log-response.json
            log_info "Byggsteg job completed successfully!"
            exit 0
        fi

        if [ "$BYGGSTEG_JOB_FAILURE" -eq 1 ]; then
            jq -r '.["log-data"]' < byggsteg-log-response.json
            log_error "Byggsteg job failed!"
            exit 1
        fi      

        if [ "$BYGGSTEG_JOB_IN_PROGRESS" -eq 1 ]; then
            jq -r '.["log-data"]' < byggsteg-log-response.json
            log_info "Byggsteg job in progress... will poll again for status in $PLUGIN_POLL_INTERVAL_SECONDS seconds"
            sleep "$PLUGIN_POLL_INTERVAL_SECONDS"
        fi
    done

    log_error "Reached limit of poll attempts ($POLL_LIMIT), pipeline failed"
    exit 1          
}

main() {
    replaced_string="$PLUGIN_BYGGSTEG_JOB_CODE"

    for placeholder in $(echo "$original_string" | grep -Eo '\$\$[A-Z0-9_]+\$\$' | sort -u); do
        var_name=$(echo "$placeholder" | sed 's/^\$\$//;s/\$\$s$//')
        var_value=$(eval echo "\$$var_name")
        replaced_string=$(echo "$replaced_string" | sed "s#$(echo "$placeholder" | sed 's/\$/\\$/g')#${var_value}#g")
    done

    echo "$replaced_string"

    log_info "POST call to $PLUGIN_BYGGSTEG_URL/api/v1/jobs/manage/submit"
    curl -s "$PLUGIN_BYGGSTEG_URL/api/v1/jobs/manage/submit" \
      -X POST \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$PLUGIN_BYGGSTEG_USERNAME" \
      --data-urlencode "password=$PLUGIN_BYGGSTEG_KEY" \
      --data-urlencode "job-code=$PLUGIN_BYGGSTEG_JOB_CODE" \
          > byggsteg-submit-job-response.json
    jq . < byggsteg-submit-job-response.json

    BYGGSTEG_LOG_ID=$(jq -r '.["log-id"]' < byggsteg-submit-job-response.json)
    log_info "Job created at Byggsteg successfully, log-id: $BYGGSTEG_LOG_ID"

    BYGGSTEG_JOB_SUCCEEDED=0
    BYGGSTEG_JOB_FAILED=0
    BYGGSTEG_JOB_IN_PROGRESS=0
    POLL_COUNT=0
    # start polling for job status until success or limit reached
    poll_for_job_success
}

# Run the main function
main
