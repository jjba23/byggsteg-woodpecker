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

log_error() {
  printf "\n[ERROR][%s] %s\n" "$(get_timestamp)" "$1" >&2
}

log_info() {
  printf "\n[INFO][%s] %s\n" "$(get_timestamp)" "$1"
}

from_jq() {
    JQ_FILE_CONTENT=$(cat "$2")
    printf "%s" "$JQ_FILE_CONTENT" | jq -r "$1" || true
}

from_jq_base64() {
    JQ_FILE_CONTENT=$(cat "$2")
    printf "%s" "$JQ_FILE_CONTENT" | jq -r "$1" | base64 --decode --ignore-garbage || true
}

retry_command() {
    ATTEMPTS_LIMIT=${ATTEMPTS_LIMIT:-8}
    ATTEMPTS_INTERVAL_SECONDS=${ATTEMPTS_INTERVAL_SECONDS:-4}
    COMMAND_TO_RETRY="$@"

    ATTEMPT_COUNT=0
    while [ "$ATTEMPT_COUNT" -lt "$ATTEMPTS_LIMIT" ]; do
        ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
        log_info "Attempt $ATTEMPT_COUNT of $ATTEMPTS_LIMIT: Executing '$COMMAND_TO_RETRY'"
        if eval "$COMMAND_TO_RETRY"; then
            log_info "Command succeeded on attempt $ATTEMPT_COUNT."
            return 0
        else
            log_error "Command failed, retrying in $ATTEMPTS_INTERVAL_SECONDS seconds..."
            sleep "$ATTEMPTS_INTERVAL_SECONDS"
        fi
    done

    log_error "Command failed after $ATTEMPTS_LIMIT attempts."
    return 1
}
