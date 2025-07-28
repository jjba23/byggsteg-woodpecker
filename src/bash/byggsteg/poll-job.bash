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

poll_for_job_success() {
  local poll_count=0
  local job_succeeded=0
  local job_failed=0

  local -r poll_limit=${PLUGIN_POLL_LIMIT:-4096}
  local -r poll_interval_seconds=${PLUGIN_POLL_INTERVAL_SECONDS:-8}
  local -r response_file="byggsteg-log-response.json"

  while ((poll_count < poll_limit)); do
    log_info "Polling job status: GET ${PLUGIN_BYGGSTEG_URL}/api/v1/logs/${byggsteg_log_id}"

    curl --user-agent "jjba23/byggsteg-woodpecker-poll-job" \
      -s "${PLUGIN_BYGGSTEG_URL}/api/v1/logs/${byggsteg_log_id}" \
      >"${response_file}"
    from_jq "." "${response_file}"

    poll_count=$((poll_count + 1))

    job_succeeded=$(from_jq '.["success"]' "${response_file}")

    job_failed=$(from_jq '.["failure"]' "${response_file}")

    if [ "${job_succeeded}" -eq 1 ]; then
      from_jq_base64 '.["log-data"]' "${response_file}"
      log_info "Byggsteg job completed successfully!"
      exit 0
    fi

    if [ "${job_failed}" -eq 1 ]; then
      from_jq_base64 '.["log-data"]' "${response_file}"
      error_exit "Byggsteg job failed!"
    fi

    log_info "Byggsteg job in progress..."
    log_info "Polling in ${poll_interval_seconds} seconds"
    sleep "${poll_interval_seconds}"
  done

  error_exit "Reached limit of poll attempts (${poll_limit}), pipeline failed"
}

# main -- entrypoint function
#
#   file-inputs: byggsteg-log-id (the log UUID we will poll for status)
main() {
  if [[ ! -r "byggsteg-log-id" ]]; then
    error_exit "file doesn't exist: byggsteg-log-id"
  fi

  byggsteg_log_id=$(<byggsteg-log-id)

  # start polling for job status until success or limit reached
  poll_for_job_success
}

# Run the main function
main
