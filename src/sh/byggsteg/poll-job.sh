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

. "prelude.sh"

poll_for_job_success() {
    while [ "$POLL_COUNT" -lt "$PLUGIN_POLL_LIMIT" ]; do        
        log_info "GET call to $PLUGIN_BYGGSTEG_URL/api/v1/logs/$BYGGSTEG_LOG_ID"      
        curl -s "$PLUGIN_BYGGSTEG_URL/api/v1/logs/$BYGGSTEG_LOG_ID" \
            > byggsteg-log-response.json
        from_jq "." "byggsteg-log-response.json"

        POLL_COUNT=$(( POLL_COUNT + 1 ))

        BYGGSTEG_JOB_SUCCEEDED=$(from_jq '.["success"]' "byggsteg-log-response.json")
        BYGGSTEG_JOB_FAILED=$(from_jq '.["failure"]' "byggsteg-log-response.json")
        BYGGSTEG_JOB_IN_PROGRESS=$(from_jq '.["in-progress"]' "byggsteg-log-response.json")

        if [ "$BYGGSTEG_JOB_SUCCEEDED" -eq 1 ]; then
            from_jq_base64 '.["log-data"]' "byggsteg-log-response.json"
            log_info "Byggsteg job completed successfully!"
            exit 0
        fi

        if [ "$BYGGSTEG_JOB_FAILED" -eq 1 ]; then
            from_jq_base64 '.["log-data"]' "byggsteg-log-response.json"
            log_error "Byggsteg job failed!"
            exit 1
        fi      

        if [ "$BYGGSTEG_JOB_IN_PROGRESS" -eq 1 ]; then
            log_info "Byggsteg job in progress... will poll again for status in $PLUGIN_POLL_INTERVAL_SECONDS seconds"
            sleep "$PLUGIN_POLL_INTERVAL_SECONDS"
        fi
    done

    log_error "Reached limit of poll attempts ($POLL_LIMIT), pipeline failed"
    exit 1          
}

main() {
    BYGGSTEG_LOG_ID=$(cat byggsteg-log-id)
    BYGGSTEG_JOB_SUCCEEDED=0
    BYGGSTEG_JOB_FAILED=0
    BYGGSTEG_JOB_IN_PROGRESS=0
    POLL_COUNT=0
    # start polling for job status until success or limit reached
    poll_for_job_success
}

# Run the main function
main
