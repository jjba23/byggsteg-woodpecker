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

set -euo pipefail

get_timestamp() {
  date '+%Y-%m-%d %H:%M:%S%:z'
}

red_text="$(tput -T xterm setf 4)"
bold_text="$(tput -T xterm bold)"
reset_text="$(tput -T xterm sgr0)"

log_error() {
  printf "\n${red_text}[ERROR][%s] %s${reset_text}\n" "$(get_timestamp)" "$1" 1>&2
}

log_info() {
  printf "\n${bold_text}[INFO][%s] %s${reset_text}\n" "$(get_timestamp)" "$1"
}

from_jq() {
  local jq_pattern="${1}"
  local json_file="${2}"
  local jq_content
  jq_content=$(cat "${json_file}")
  printf "%s" "${jq_content}" | jq -r "${jq_pattern}" || true
}

from_jq_base64() {
  local jq_pattern="${1}"
  local json_file="${2}"
  local jq_content
  jq_content=$(cat "${json_file}")
  printf "%s" "${jq_content}" | jq -r "${jq_pattern}" | base64 --decode --ignore-garbage || true
}

retry_command() {
  attempts_limit=${attempts_limit:-8}
  attempts_interval_seconds=${attempts_interval_seconds:-4}
  command_to_retry="$@"

  attempt_count=0
  while [ "${attempt_count}" -lt "${attempts_limit}" ]; do
    attempt_count=$((attempt_count + 1))
    log_info "Attempt ${attempt_count} of ${attempts_limit}: Executing '${command_to_retry}'"
    if eval "${command_to_retry}"; then
      log_info "Command succeeded on attempt ${attempt_count}."
      return 0
    else
      log_error "Command failed, retrying in ${attempts_interval_seconds} seconds..."
      sleep "${attempts_interval_seconds}"
    fi
  done

  error_exit "Command failed after ${attempts_limit} attempts."
}

error_exit() {
  log_error "${1}"
  exit 1
}
