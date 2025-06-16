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

get_timestamp() {
  date '+%Y-%m-%d %H:%M:%S%:z'
}

fg_red="$(tput -T xterm setf 4)"
fg_bold="$(tput -T xterm bold)"
fg_reset="$(tput -T xterm sgr0)"

log_error() {
  printf "\n${fg_red}[ERROR][%s] %s${fg_reset}\n" "$(get_timestamp)" "$1" >&2
}

log_info() {
  printf "\n${fg_bold}[INFO][%s] %s${fg_reset}\n" "$(get_timestamp)" "$1"
}

from_jq() {
    jq_content=$(cat "$2")
    printf "%s" "$jq_content" | jq -r "$1" || true
}

from_jq_base64() {
    jq_content=$(cat "$2")
    printf "%s" "$jq_content" | jq -r "$1" | base64 --decode --ignore-garbage || true
}

retry_command() {
    attempts_limit=${attempts_limit:-8}
    attempts_interval_seconds=${attempts_interval_seconds:-4}
    command_to_retry="$@"

    attempt_count=0
    while [ "$attempt_count" -lt "$attempts_limit" ]; do
        attempt_count=$((attempt_count + 1))
        log_info "Attempt $attempt_count of $attempts_limit: Executing '$command_to_retry'"
        if eval "$command_to_retry"; then
            log_info "Command succeeded on attempt $attempt_count."
            return 0
        else
            log_error "Command failed, retrying in $attempts_interval_seconds seconds..."
            sleep "$attempts_interval_seconds"
        fi
    done

    log_error "Command failed after $attempts_limit attempts."
    return 1
}
