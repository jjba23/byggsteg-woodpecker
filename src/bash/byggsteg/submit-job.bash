#!/usr/bin/env bash

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

. "prelude.bash"

submit_job_to_byggsteg() {
  curl --user-agent "jjba23/byggsteg-woodpecker-submit-job" \
    --fail -s "${PLUGIN_BYGGSTEG_URL}/api/v1/jobs/manage/submit" \
    -X POST \
    -H 'content-type: application/x-www-form-urlencoded' \
    -H "x-bewaking-byggsteg: ${byggsteg_token}" \
    --data-urlencode "job-code=${byggsteg_job_code}" \
    >byggsteg-submit-job-response.json
}

# main -- entrypoint function
#
#    file-inputs:  x-bewaking-token (the Byggsteg auth token to be used)
#    file-outputs: byggsteg-log-id (the job's log UUID we will poll for status)
#                  byggsteg-submit-job-response.json (the response body of submitting a job)
main() {
  if [[ ! -f "x-bewaking-byggsteg" ]]; then
    error_exit "file doesn't exist: x-bewaking-byggsteg"
  fi

  local byggsteg_token
  byggsteg_token=$(cat x-bewaking-byggsteg)

  local byggsteg_job_code="${PLUGIN_BYGGSTEG_JOB_CODE}"

  for var_placeholder in $(echo "$PLUGIN_BYGGSTEG_JOB_CODE" | grep -Eo '%%[A-Z0-9_]+%%' | sort -u); do
    var_name=$(echo "$var_placeholder" | sed 's/^%%//;s/%%$//')
    var_value=$(eval echo "\$$var_name")
    byggsteg_job_code=$(echo "$byggsteg_job_code" | sed "s#$(echo "$var_placeholder" | sed 's/%/\\%/g')#${var_value}#g")
  done

  log_info "Sending byggsteg job code:"
  echo "${byggsteg_job_code}"

  log_info "POST call to ${PLUGIN_BYGGSTEG_URL}/api/v1/jobs/manage/submit"

  retry_command submit_job_to_byggsteg
  from_jq "." "byggsteg-submit-job-response.json"

  local byggsteg_log_id
  byggsteg_log_id=$(from_jq '.["log-id"]' "byggsteg-submit-job-response.json")

  log_info "Job created at Byggsteg successfully, log-id: ${byggsteg_log_id}"
  echo "${byggsteg_log_id}" >byggsteg-log-id
}

# Run the main function
main
