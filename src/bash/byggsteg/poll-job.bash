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

# Prints what Byggsteg recorded for the job: the (base64) log-data, or the raw
# response when there is no log-data to show.
print_job_output() {
  local -r file="$1"
  local log_data
  log_data="$(json_string log-data "${file}")"

  # base64 never needs these escapes; drop them in case the encoder wrapped
  # line breaks, so the payload decodes cleanly.
  log_data="${log_data//\\n/}"
  log_data="${log_data//\\r/}"
  log_data="${log_data//\\t/}"

  if [[ -n "${log_data}" ]]; then
    printf '%s\n' "$(decode_log_data "${log_data}")"
  else
    printf '%s\n' "$(<"${file}")"
  fi
}

# poll_for_job_completion <log-id>
#
# Stays quiet while the job is still running and prints the job output once on
# success or failure.  Tune with PLUGIN_POLL_LIMIT (default 4096) and
# PLUGIN_POLL_INTERVAL_SECONDS (default 8).
poll_for_job_completion() {
  local -r log_id="$1"
  local -r poll_limit="${PLUGIN_POLL_LIMIT:-4096}"
  local -r interval_seconds="${PLUGIN_POLL_INTERVAL_SECONDS:-8}"
  local poll_count=0 success failure

  while ((poll_count < poll_limit)); do
    poll_count=$((poll_count + 1))

    if ! curl --user-agent "jjba23/byggsteg-woodpecker-poll-job" \
      --fail --silent --show-error \
      --output "${BYGGSTEG_LOG_RESPONSE_FILE}" \
      "${PLUGIN_BYGGSTEG_URL}/api/v1/logs/${log_id}"; then
      log_error "Could not fetch Byggsteg job status (poll ${poll_count}/${poll_limit})"
      sleep "${interval_seconds}"
      continue
    fi

    success="$(json_number success "${BYGGSTEG_LOG_RESPONSE_FILE}")"
    failure="$(json_number failure "${BYGGSTEG_LOG_RESPONSE_FILE}")"

    if [[ "${success}" == 1 ]]; then
      print_job_output "${BYGGSTEG_LOG_RESPONSE_FILE}"
      log_info "Byggsteg job succeeded"
      return 0
    fi

    if [[ "${failure}" == 1 ]]; then
      print_job_output "${BYGGSTEG_LOG_RESPONSE_FILE}"
      error_exit "Byggsteg job failed"
    fi

    # A response carrying none of the three status fields is not a status
    # response at all -- an error page, a proxy's, a truncated body -- so it is
    # not something to keep polling: the step fails now, with what came back,
    # rather than burning the whole poll budget on it.
    if ! json_has_key success "${BYGGSTEG_LOG_RESPONSE_FILE}" &&
      ! json_has_key failure "${BYGGSTEG_LOG_RESPONSE_FILE}" &&
      ! json_has_key in-progress "${BYGGSTEG_LOG_RESPONSE_FILE}"; then
      print_job_output "${BYGGSTEG_LOG_RESPONSE_FILE}"
      error_exit "Byggsteg job status response had no success, failure or in-progress field"
    fi

    sleep "${interval_seconds}"
  done

  error_exit "Timed out waiting for Byggsteg job (${poll_limit} polls)"
}

# main -- entrypoint function
#
#   file-inputs: byggsteg-log-id (the log id we will poll for status)
#   settings:    PLUGIN_BYGGSTEG_URL, PLUGIN_POLL_LIMIT,
#                PLUGIN_POLL_INTERVAL_SECONDS
main() {
  : "${PLUGIN_BYGGSTEG_URL:?PLUGIN_BYGGSTEG_URL is required}"

  [[ -r "${BYGGSTEG_LOG_ID_FILE}" ]] ||
    error_exit "missing log-id file: ${BYGGSTEG_LOG_ID_FILE} (run the submit-job step first)"

  local log_id
  log_id="$(<"${BYGGSTEG_LOG_ID_FILE}")"
  [[ -n "${log_id}" ]] || error_exit "empty log-id in ${BYGGSTEG_LOG_ID_FILE}"

  log_info "Waiting for Byggsteg job ${log_id}"

  poll_for_job_completion "${log_id}"
}

# Run the main function
main
