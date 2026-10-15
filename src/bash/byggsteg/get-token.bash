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

# Authenticates to Byggsteg and stores the returned "bewaking" token.
# Returns non-zero so retry_command can retry on network/HTTP problems.
get_token_byggsteg() {
  local headers line name
  local token=""

  headers="$(curl --user-agent "jjba23/byggsteg-woodpecker-get-token" \
    --fail --silent --show-error --include \
    --request POST \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode "email=${PLUGIN_BYGGSTEG_EMAIL}" \
    --data-urlencode "password=${PLUGIN_BYGGSTEG_PASSWORD}" \
    "${PLUGIN_BYGGSTEG_URL}/api/v1/login")" || return 1

  # Header names are case-insensitive -- a server may answer with
  # `X-Bewaking-Byggsteg:' -- so fold the name before comparing it, and never
  # the value: the value is the token, and it is case-sensitive.
  while IFS= read -r line; do
    line="${line%$'\r'}"
    name="${line%%:*}"
    if [[ "${name,,}" == "x-bewaking-byggsteg" ]]; then
      token="${line#*:}"
      token="${token#"${token%%[![:space:]]*}"}" # drop leading blanks
      break
    fi
  done <<<"${headers}"

  if [[ -z "${token}" ]]; then
    log_error "Byggsteg login answered without an x-bewaking-byggsteg token"
    return 1
  fi

  printf '%s' "${token}" >"${BYGGSTEG_TOKEN_FILE}"
}

# main -- entrypoint function
#
#   settings:     PLUGIN_BYGGSTEG_URL, PLUGIN_BYGGSTEG_EMAIL,
#                 PLUGIN_BYGGSTEG_PASSWORD
#   file-outputs: x-bewaking-byggsteg (the Byggsteg auth token to be used)
main() {
  : "${PLUGIN_BYGGSTEG_URL:?PLUGIN_BYGGSTEG_URL is required}"
  : "${PLUGIN_BYGGSTEG_EMAIL:?PLUGIN_BYGGSTEG_EMAIL is required}"
  : "${PLUGIN_BYGGSTEG_PASSWORD:?PLUGIN_BYGGSTEG_PASSWORD is required}"

  log_info "Requesting Byggsteg token: POST ${PLUGIN_BYGGSTEG_URL}/api/v1/login"

  retry_command get_token_byggsteg

  log_info "Byggsteg token stored in ${BYGGSTEG_TOKEN_FILE}"
}

# Run the main function
main
