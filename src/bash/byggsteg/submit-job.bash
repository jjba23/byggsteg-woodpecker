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

# Asks Byggsteg to take the job.  Only the request is retried: whether the
# answer can be used is decided once, after the transport has succeeded.
submit_job_to_byggsteg() {
  local -r token="$1" job_code="$2"

  curl --user-agent "jjba23/byggsteg-woodpecker-submit-job" \
    --fail --silent --show-error \
    --output "${BYGGSTEG_SUBMIT_RESPONSE_FILE}" \
    --request POST \
    --header 'content-type: application/x-www-form-urlencoded' \
    --header "x-bewaking-byggsteg: ${token}" \
    --data-urlencode "job-code=${job_code}" \
    "${PLUGIN_BYGGSTEG_URL}/api/v1/jobs/manage/submit" || return 1
}

# main -- entrypoint function
#
#   file-inputs:  x-bewaking-byggsteg (the Byggsteg auth token to be used)
#   settings:     PLUGIN_BYGGSTEG_URL, PLUGIN_BYGGSTEG_JOB_CODE
#   file-outputs: byggsteg-log-id (the job's log id we will poll for status)
#                 byggsteg-submit-job-response.json (the submit response body)
main() {
  : "${PLUGIN_BYGGSTEG_URL:?PLUGIN_BYGGSTEG_URL is required}"
  : "${PLUGIN_BYGGSTEG_JOB_CODE:?PLUGIN_BYGGSTEG_JOB_CODE is required}"

  [[ -r "${BYGGSTEG_TOKEN_FILE}" ]] ||
    error_exit "missing token file: ${BYGGSTEG_TOKEN_FILE} (run the get-token step first)"

  local token job_code
  token="$(<"${BYGGSTEG_TOKEN_FILE}")"
  job_code="$(resolve_placeholders "${PLUGIN_BYGGSTEG_JOB_CODE}")"

  log_info "Submitting Byggsteg job: POST ${PLUGIN_BYGGSTEG_URL}/api/v1/jobs/manage/submit"

  retry_command submit_job_to_byggsteg "${token}" "${job_code}"

  # The request went through; what it answered is checked now.  A log-id that
  # is missing, empty, or the word "null" -- a non-JSON body, a body without
  # the field, a JSON null -- means Byggsteg did not take the job, so the step
  # fails with the answer printed rather than passing on nothing.
  local log_id
  log_id="$(json_string log-id "${BYGGSTEG_SUBMIT_RESPONSE_FILE}")"
  if [[ -z "${log_id}" || "${log_id}" == "null" ]]; then
    log_error "Byggsteg submit response carried no log-id:"
    printf '%s\n' "$(<"${BYGGSTEG_SUBMIT_RESPONSE_FILE}")"
    error_exit "Byggsteg did not accept the job"
  fi

  printf '%s' "${log_id}" >"${BYGGSTEG_LOG_ID_FILE}"

  log_info "Byggsteg job submitted (log-id: ${log_id})"
  printf '%s\n' "$(<"${BYGGSTEG_SUBMIT_RESPONSE_FILE}")"
}

# Run the main function
main
