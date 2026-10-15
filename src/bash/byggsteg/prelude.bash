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

# Sourced (via $PATH) by every step.  Everything the images rely on past this
# point is core bash plus the few busybox applets Alpine ships (date, sed, tr,
# head, base64, sleep), so no jq, ncurses, coreutils, make or GNU grep is needed
# -- smaller images and faster pulls for CI.

set -euo pipefail

# ---------------------------------------------------------------------------
# Shared files exchanged between the pipeline steps (Woodpecker runs every step
# in the same workspace/working directory).
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # used by the steps that source this file
readonly BYGGSTEG_TOKEN_FILE="x-bewaking-byggsteg"
# shellcheck disable=SC2034
readonly BYGGSTEG_LOG_ID_FILE="byggsteg-log-id"
# shellcheck disable=SC2034
readonly BYGGSTEG_SUBMIT_RESPONSE_FILE="byggsteg-submit-job-response.json"
# shellcheck disable=SC2034
readonly BYGGSTEG_LOG_RESPONSE_FILE="byggsteg-log-response.json"

# ---------------------------------------------------------------------------
# Logging
#
# Plain ANSI escapes rather than `tput`, so the images do not need ncurses and
# its terminfo database.  Info goes to stdout, errors to stderr.
# ---------------------------------------------------------------------------

_style_info=$'\033[1m'     # bold
_style_error=$'\033[1;31m' # bold red
_style_reset=$'\033[0m'

_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log_info() {
  printf '%s[INFO][%s] %s%s\n' "${_style_info}" "$(_timestamp)" "$*" "${_style_reset}"
}

log_error() {
  printf '%s[ERROR][%s] %s%s\n' "${_style_error}" "$(_timestamp)" "$*" "${_style_reset}" 1>&2
}

error_exit() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# retry_command <command> [args...]
#
# Runs a command until it succeeds, or fails the step after the attempt limit.
# Tune with BYGGSTEG_RETRY_ATTEMPTS (default 8) and BYGGSTEG_RETRY_INTERVAL
# (seconds, default 4).
# ---------------------------------------------------------------------------

retry_command() {
  local -r attempts_limit="${BYGGSTEG_RETRY_ATTEMPTS:-8}"
  local -r interval_seconds="${BYGGSTEG_RETRY_INTERVAL:-4}"
  local attempt=0

  while ((attempt < attempts_limit)); do
    attempt=$((attempt + 1))

    if "$@"; then
      return 0
    fi

    ((attempt >= attempts_limit)) && break

    log_error "Attempt ${attempt}/${attempts_limit} failed, retrying in ${interval_seconds}s: $*"
    sleep "${interval_seconds}"
  done

  error_exit "Command failed after ${attempts_limit} attempts: $*"
}

# ---------------------------------------------------------------------------
# Minimal JSON readers
#
# Byggsteg answers with a small, flat JSON object, so the handful of fields we
# need are read with bash pattern matching instead of shipping jq (and, with
# it, oniguruma) in the images.  Both print nothing when the key is absent.
# ---------------------------------------------------------------------------

# json_string <key> <file>
json_string() {
  local -r key="$1" file="$2"
  local content
  content="$(<"${file}")"
  if [[ ${content} =~ \"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# json_number <key> <file>
json_number() {
  local -r key="$1" file="$2"
  local content
  content="$(<"${file}")"
  if [[ ${content} =~ \"${key}\"[[:space:]]*:[[:space:]]*(-?[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# json_has_key <key> <file> -- true when KEY appears as a JSON key, whatever
# its value.  Used to tell a real response from whatever else a server (or a
# proxy in front of it) decided to answer with.
json_has_key() {
  local -r key="$1" file="$2"
  local content=""
  if [[ -r "${file}" ]]; then
    content="$(<"${file}")"
  fi
  [[ ${content} =~ \"${key}\"[[:space:]]*: ]]
}

# decode_log_data <base64> -- the decoded text, or the input unchanged when it
# is not valid base64.
decode_log_data() {
  local decoded
  if decoded="$(printf '%s' "$1" | base64 -d 2>/dev/null)"; then
    printf '%s' "${decoded}"
  else
    printf '%s' "$1"
  fi
}

# ---------------------------------------------------------------------------
# resolve_placeholders <template>
#
# Expands %%VAR%% placeholders in a job definition to the value of the matching
# environment variable (Woodpecker exposes the CI context there), without ever
# evaluating the result as shell code.
# ---------------------------------------------------------------------------

resolve_placeholders() {
  local template="$1"
  local resolved_code="$template"
  local placeholder_regex='%%([A-Z0-9_]+)%%'

  while [[ ${resolved_code} =~ ${placeholder_regex} ]]; do
    local placeholder="${BASH_REMATCH[0]}" # e.g. %%CI_REPO_NAME%%
    local var_name="${BASH_REMATCH[1]}"    # e.g. CI_REPO_NAME

    # Indirect expansion; unset variables resolve to the empty string.
    local var_value="${!var_name:-}"

    resolved_code="${resolved_code//"${placeholder}"/"${var_value}"}"
  done

  printf '%s' "${resolved_code}"
}
