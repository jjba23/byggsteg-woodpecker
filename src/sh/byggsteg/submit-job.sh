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

submit_job_to_byggsteg() {
    curl -s "$PLUGIN_BYGGSTEG_URL/api/v1/jobs/manage/submit" \
      -X POST \
      -H 'content-type: application/x-www-form-urlencoded' \
      -H "x-bewaking-byggsteg: $BYGGSTEG_TOKEN" \
      --data-urlencode "job-code=$BYGGSTEG_JOB_CODE" \
          > byggsteg-submit-job-response.json
}

main() {
    BYGGSTEG_TOKEN=$(cat x-bewaking-byggsteg)
    BYGGSTEG_JOB_CODE="$PLUGIN_BYGGSTEG_JOB_CODE"

    for PLACEHOLDER in $(echo "$PLUGIN_BYGGSTEG_JOB_CODE" | grep -Eo '%%[A-Z0-9_]+%%' | sort -u); do
        VAR_NAME=$(echo "$PLACEHOLDER" | sed 's/^%%//;s/%%$//')
        VAR_VALUE=$(eval echo "\$$VAR_NAME")
        BYGGSTEG_JOB_CODE=$(echo "$BYGGSTEG_JOB_CODE" | sed "s#$(echo "$PLACEHOLDER" | sed 's/%/\\%/g')#${VAR_VALUE}#g")
    done

    log_info "Sending byggsteg job code:"
    echo "$BYGGSTEG_JOB_CODE"

    log_info "POST call to $PLUGIN_BYGGSTEG_URL/api/v1/jobs/manage/submit"
    
    retry_command submit_job_to_byggsteg
    from_jq "." "byggsteg-submit-job-response.json"

    BYGGSTEG_LOG_ID=$(from_jq '.["log-id"]' "byggsteg-submit-job-response.json")
    log_info "Job created at Byggsteg successfully, log-id: $BYGGSTEG_LOG_ID"
    echo "$BYGGSTEG_LOG_ID" > byggsteg-log-id
}

# Run the main function
main
