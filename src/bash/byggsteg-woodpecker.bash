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

# The bridge from a Woodpecker pipeline to a Byggsteg deployment: one image,
# one script, one step per call.
#
#   byggsteg-woodpecker get-token    sign in, and keep the token
#   byggsteg-woodpecker submit-job   hand Byggsteg a job, keep its log id
#   byggsteg-woodpecker poll-job     follow that log, and pass or fail the build
#   byggsteg-woodpecker all          the three, in that order, in one step
#
# It speaks the JSON API under /api/v2: POST /api/v2/login, POST /api/v2/jobs
# and GET /api/v2/logs/<log-id>.  Everything it needs past bash is in busybox
# (date, sleep), which is why the image is Alpine with curl added and nothing
# else: no jq, no ncurses, no coreutils, and a pull that stays small.
#
# Two rules the whole script follows, because a CI step that fails is read by
# someone who is not at a terminal:
#
#   * every failure says what was attempted, what came back, and what Byggsteg
#     said about it -- the API answers its refusals with {"error": "..."}, and
#     that sentence is printed rather than the status code alone;
#   * a failure that asking again cannot change (a 401, a 403, a 404) is not
#     retried, so a red build says why at once instead of after the backoff.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants: the files the steps exchange through the workspace, and the
# endpoints of the API they speak.
#
# Woodpecker runs every step of a pipeline in one working directory, so the
# workspace is the interface between the three steps: get-token leaves a token,
# submit-job leaves a log id, poll-job reads it and leaves the output.
# ---------------------------------------------------------------------------

readonly BYGGSTEG_TOKEN_FILE="x-bewaking-byggsteg"
readonly BYGGSTEG_LOG_ID_FILE="byggsteg-log-id"
readonly BYGGSTEG_LOGIN_RESPONSE_FILE="byggsteg-login-response.json"
readonly BYGGSTEG_SUBMIT_RESPONSE_FILE="byggsteg-submit-job-response.json"
readonly BYGGSTEG_LOG_RESPONSE_FILE="byggsteg-log-response.json"
readonly BYGGSTEG_LOG_OUTPUT_FILE="byggsteg-job-output.txt"

readonly BYGGSTEG_LOGIN_PATH="/api/v2/login"
readonly BYGGSTEG_SUBMIT_PATH="/api/v2/jobs"
readonly BYGGSTEG_LOGS_PATH="/api/v2/logs"

# How a step function answers, so that retry_command can tell a failure that
# may pass from one that will not.
readonly BYGGSTEG_OK=0
readonly BYGGSTEG_RETRYABLE=1
readonly BYGGSTEG_PERMANENT=2

# The status of the last http_request, and the file its answer's headers went
# to.  The headers are kept out of the workspace: the only one the steps read is
# the sign-in answer's token, and it is read as soon as it arrives.
BYGGSTEG_HTTP_STATUS=""
BYGGSTEG_HTTP_HEADER_FILE=""

# require_headers_file -- a scratch file for the next answer's headers, made
# once and reused.  It is removed when the step ends, whatever it ends with.
require_headers_file() {
  if [[ -z "${BYGGSTEG_HTTP_HEADER_FILE}" ]]; then
    BYGGSTEG_HTTP_HEADER_FILE="$(mktemp "${TMPDIR:-/tmp}/byggsteg-headers.XXXXXXXX")"
  fi
}

# ---------------------------------------------------------------------------
# Logging
#
# Plain ANSI escapes rather than `tput', so the image does not need ncurses and
# its terminfo database.  Info and debug go to stdout, warnings and errors to
# stderr, and every line carries a level and a UTC timestamp so a CI log can be
# searched for the ones that matter.
#
# Debug logging is off unless BYGGSTEG_DEBUG says otherwise, so a pipeline stays
# quiet by default and can be made loud for one build with BYGGSTEG_DEBUG=1.
# ---------------------------------------------------------------------------

_style_info=$'\033[1m'     # bold
_style_warn=$'\033[1;33m'  # bold yellow
_style_error=$'\033[1;31m' # bold red
_style_debug=$'\033[0;36m' # cyan
_style_reset=$'\033[0m'

_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_emit_log() {
  local -r style="$1" level="$2" stream="$3"
  shift 3
  printf '%s[%s][%s] %s%s\n' "${style}" "${level}" "$(_timestamp)" "$*" "${_style_reset}" >&"${stream}"
}

log_debug() {
  case "${BYGGSTEG_DEBUG:-}" in
    '' | 0 | false | no | off) return 0 ;;
  esac
  _emit_log "${_style_debug}" "DEBUG" 1 "$@"
}

log_info() {
  _emit_log "${_style_info}" "INFO" 1 "$@"
}

log_warn() {
  _emit_log "${_style_warn}" "WARN" 2 "$@"
}

log_error() {
  _emit_log "${_style_error}" "ERROR" 2 "$@"
}

error_exit() {
  log_error "$*"
  exit 1
}

# A failure nobody planned for -- an unset variable, a write that did not
# happen -- would otherwise leave the build red with no explanation but bash's
# own one-liner.  This says where it happened and what was being run, once.
_on_unexpected_failure() {
  local -r status="$1" line="$2" command="$3"
  log_error "Unexpected failure (exit ${status}) at line ${line}: ${command}"
}
trap '_on_unexpected_failure "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

# Whatever the step ends with, it leaves nothing behind in the workspace but
# the files the next step reads.
_on_exit() {
  if [[ -n "${BYGGSTEG_HTTP_HEADER_FILE:-}" ]]; then
    rm -f "${BYGGSTEG_HTTP_HEADER_FILE}"
  fi
}
trap _on_exit EXIT

# ---------------------------------------------------------------------------
# Settings, addresses and workspace values
# ---------------------------------------------------------------------------

# require_setting <name> -- the step cannot run without it.
require_setting() {
  local -r name="$1"
  if [[ -z "${!name:-}" ]]; then
    error_exit "${name} is required (set it in the step's settings)"
  fi
}

# require_url -- PLUGIN_BYGGSTEG_URL, as an address curl can be given.  A
# setting written without a scheme is a mistake worth catching here rather than
# in curl's answer.
require_url() {
  require_setting PLUGIN_BYGGSTEG_URL
  if [[ ! ${PLUGIN_BYGGSTEG_URL} =~ ^https?://[^[:space:]]+$ ]]; then
    error_exit "PLUGIN_BYGGSTEG_URL must be an http:// or https:// address, not '${PLUGIN_BYGGSTEG_URL}'"
  fi
}

# byggsteg_url <path> -- the address of PATH on the deployment, without the
# doubled slash a URL written with a trailing one would otherwise produce.
byggsteg_url() {
  printf '%s%s' "${PLUGIN_BYGGSTEG_URL%/}" "$1"
}

# require_positive_integer <value> <setting> -- fails unless the value is a
# whole number above zero.  A poll limit of "lots" is a pipeline that never
# ends, and a timeout of "30s" is a curl that refuses to start.
require_positive_integer() {
  local -r value="$1" setting="$2"
  if [[ ! ${value} =~ ^[1-9][0-9]*$ ]]; then
    error_exit "${setting} must be a positive whole number, not '${value}'"
  fi
}

# read_file <file> -- what FILE holds, or nothing when it is not there (or
# cannot be read).  Always succeeds, so it is safe in a command substitution.
read_file() {
  local content=""
  if [[ -r "$1" ]]; then
    content="$(<"$1")" || content=""
  fi
  printf '%s' "${content}"
}

# require_workspace_file <file> <what to do about it> -- a file a previous step
# should have left for this one, and that should hold something.
require_workspace_file() {
  local -r file="$1" hint="$2"
  [[ -r "${file}" ]] || error_exit "missing ${file} (${hint})"
  [[ -s "${file}" ]] || error_exit "empty ${file} (${hint})"
}

# validate_tuning -- the variables that tune every call, checked once at the
# start rather than in the middle of the first request.
validate_tuning() {
  require_positive_integer "${BYGGSTEG_RETRY_ATTEMPTS:-8}" BYGGSTEG_RETRY_ATTEMPTS
  require_positive_integer "${BYGGSTEG_RETRY_INTERVAL:-4}" BYGGSTEG_RETRY_INTERVAL
  require_positive_integer "${BYGGSTEG_CONNECT_TIMEOUT:-10}" BYGGSTEG_CONNECT_TIMEOUT
  require_positive_integer "${BYGGSTEG_REQUEST_TIMEOUT:-120}" BYGGSTEG_REQUEST_TIMEOUT
}

# ---------------------------------------------------------------------------
# Retrying, and what is worth retrying
# ---------------------------------------------------------------------------

# retry_command <command> [args...]
#
# Runs a command until it succeeds, or fails the step when the answer says
# asking again would not change it, or after the attempt limit.  Tune with
# BYGGSTEG_RETRY_ATTEMPTS (default 8) and BYGGSTEG_RETRY_INTERVAL (seconds,
# default 4).
retry_command() {
  local -r attempts_limit="${BYGGSTEG_RETRY_ATTEMPTS:-8}"
  local -r interval_seconds="${BYGGSTEG_RETRY_INTERVAL:-4}"
  local attempt=0 status=0

  while ((attempt < attempts_limit)); do
    attempt=$((attempt + 1))

    status=0
    "$@" || status=$?

    if ((status == BYGGSTEG_OK)); then
      return 0
    fi

    if ((status == BYGGSTEG_PERMANENT)); then
      error_exit "$1 failed, and asking again would not change the answer"
    fi

    if ((attempt >= attempts_limit)); then
      error_exit "$1 failed after ${attempts_limit} attempts"
    fi

    log_info "Attempt ${attempt}/${attempts_limit} failed, retrying in ${interval_seconds}s"
    sleep "${interval_seconds}"
  done
}

# ---------------------------------------------------------------------------
# HTTP
#
# One helper for every call, so that no step has to remember how a failure is
# read: the answer's status is kept, the body is kept for the caller (and for
# whoever reads the workspace afterwards), and a refusal is logged with what
# Byggsteg said about it.
#
# Every failure of the JSON API is an object with an `error' in it, so a 403 is
# printed as "the token does not hold byggsteg:job-create" rather than as a
# number; a failure that is not that shape -- an HTML page from a proxy in
# front of the deployment -- is printed as the status alone.
# ---------------------------------------------------------------------------

# json_error_suffix <file> -- ": <what Byggsteg said>", or nothing at all.
json_error_suffix() {
  local message
  message="$(json_string error "$1")"
  if [[ -n "${message}" ]]; then
    printf ': %s' "${message}"
  fi
}

# http_request <method> <url> <body-file> [curl arguments...]
#
# Calls Byggsteg once.  The answer's body is written to BODY-FILE (and kept
# there, which is what makes the workspace readable afterwards) and its headers
# to a scratch file; what is returned is BYGGSTEG_OK, or BYGGSTEG_RETRYABLE /
# BYGGSTEG_PERMANENT for a failure, having logged why.
http_request() {
  local -r method="$1" url="$2" body_file="$3"
  shift 3

  require_headers_file

  local code
  if ! code="$(curl \
    --silent --show-error \
    --user-agent "${BYGGSTEG_USER_AGENT:-jjba23/byggsteg-woodpecker}" \
    --connect-timeout "${BYGGSTEG_CONNECT_TIMEOUT:-10}" \
    --max-time "${BYGGSTEG_REQUEST_TIMEOUT:-120}" \
    --request "${method}" \
    --dump-header "${BYGGSTEG_HTTP_HEADER_FILE}" \
    --output "${body_file}" \
    --write-out '%{http_code}' \
    "$@" \
    "${url}")"; then
    BYGGSTEG_HTTP_STATUS="000"
    log_error "${method} ${url}: no answer -- the server could not be reached (network, DNS or timeout)"
    return "${BYGGSTEG_RETRYABLE}"
  fi

  BYGGSTEG_HTTP_STATUS="${code}"

  case "${code}" in
    2[0-9][0-9])
      log_debug "${method} ${url}: HTTP ${code}"
      return "${BYGGSTEG_OK}"
      ;;
    408 | 425 | 429 | 5[0-9][0-9])
      # Worth asking again: the deployment is busy, throttling or broken, and
      # has said nothing about the request itself.
      log_error "${method} ${url}: HTTP ${code}$(json_error_suffix "${body_file}")"
      return "${BYGGSTEG_RETRYABLE}"
      ;;
    *)
      # A 4xx: the answer is about the request -- a bad token, a permission not
      # held, a log that is not there -- and will be the same next time.
      log_error "${method} ${url}: HTTP ${code}$(json_error_suffix "${body_file}")"
      return "${BYGGSTEG_PERMANENT}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Minimal JSON readers
#
# Byggsteg answers with small JSON objects, so the handful of fields these steps
# need are read with bash pattern matching instead of shipping jq (and, with
# it, oniguruma) in the image.  Every reader prints nothing when the key is
# absent, which is what lets a step tell an answer it can use from one it
# cannot.
#
# The readers are key-based rather than path-based: the documents read here
# carry no two keys of the same name with different values, so `status' is a
# run's status and `text' is its output whatever object they sit in.
# ---------------------------------------------------------------------------

# json_raw_string <key> <file> -- the value of KEY as it is written in the
# answer, escapes and all.  What ends the value is the first quote that is not
# escaped, so a job's output -- which is full of quotes and newlines -- does not
# end it early.  Read through json_string unless the escapes are wanted.
json_raw_string() {
  local -r key="$1" file="$2"
  local content rest
  [[ -r "${file}" ]] || return 0
  content="$(<"${file}")"

  [[ ${content} == *"\"${key}\""* ]] || return 0
  rest="${content#*\""${key}"\"}"

  if [[ ${rest} =~ ^[[:space:]]*:[[:space:]]*\"(([^\"\\]|\\.)*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# json_unescape <escaped> -- the text a JSON string body stands for: `\n' and
# `\t' become the characters they spell, `\"' and `\\' the characters they
# quote, and `\uXXXX' the character it names.  A literal backslash in the text
# is parked before the escapes are read, so a job that printed `\n' does not
# come back with a line break in it.
json_unescape() {
  local text="$1"
  text="${text//\\\\/$'\001'}"
  text="${text//\\\"/\"}"
  text="${text//\\\//\/}"
  text="$(printf '%b' "${text}")"
  printf '%s' "${text//$'\001'/\\}"
}

# json_string <key> <file> -- the value of KEY as text.
json_string() {
  local escaped
  escaped="$(json_raw_string "$1" "$2")"
  if [[ -z "${escaped}" ]]; then
    return 0
  fi
  json_unescape "${escaped}"
}

# json_number <key> <file>
json_number() {
  local -r key="$1" file="$2"
  local content
  [[ -r "${file}" ]] || return 0
  content="$(<"${file}")"
  if [[ ${content} =~ \"${key}\"[[:space:]]*:[[:space:]]*(-?[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# json_bool <key> <file> -- true or false, and nothing when the key is absent.
json_bool() {
  local -r key="$1" file="$2"
  local content
  [[ -r "${file}" ]] || return 0
  content="$(<"${file}")"
  if [[ ${content} =~ \"${key}\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# json_has_key <key> <file> -- true when KEY appears as a JSON key, whatever
# its value.  Used to tell a real answer from whatever else a server (or a
# proxy in front of it) decided to answer with, and to tell an output that came
# with the answer from one left out because it had not changed.
json_has_key() {
  local -r key="$1" file="$2"
  local content=""
  if [[ -r "${file}" ]]; then
    content="$(<"${file}")"
  fi
  [[ ${content} =~ \"${key}\"[[:space:]]*: ]]
}

# print_response <file> -- an answer, printed as it came, for a failure whose
# cause is in the answer rather than in the status.
print_response() {
  local content
  content="$(read_file "$1")"
  if [[ -n "${content}" ]]; then
    printf '%s\n' "${content}"
  fi
}

# format_epoch <seconds> -- seconds since 1970 as a UTC timestamp, or the
# number itself when date cannot read it.
format_epoch() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$1"
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

# ===========================================================================
# get-token
#
# Signs in to the deployment and keeps the token the answer carries.
# ===========================================================================

# token_from_headers <header-file> -- the x-bewaking-byggsteg token a sign-in
# answer carries, or nothing when it carries none.
#
# Header names are case-insensitive -- a server may answer with
# `X-Bewaking-Byggsteg:' -- so the name is folded before it is compared, and
# never the value: the value is the token, and it is case-sensitive.
token_from_headers() {
  local -r file="$1"
  local line name token=""

  [[ -r "${file}" ]] || return 0

  while IFS= read -r line; do
    line="${line%$'\r'}"
    name="${line%%:*}"
    if [[ "${name,,}" == "x-bewaking-byggsteg" ]]; then
      token="${line#*:}"
      token="${token#"${token%%[![:space:]]*}"}" # drop leading blanks
      printf '%s' "${token}"
      return 0
    fi
  done <"${file}"
}

# sign_in -- one attempt at signing in; answers BYGGSTEG_OK, or what
# http_request said about the answer.
sign_in() {
  local status=0

  http_request POST "$(byggsteg_url "${BYGGSTEG_LOGIN_PATH}")" \
    "${BYGGSTEG_LOGIN_RESPONSE_FILE}" \
    --header 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode "email=${PLUGIN_BYGGSTEG_EMAIL}" \
    --data-urlencode "password=${PLUGIN_BYGGSTEG_PASSWORD}" || status=$?

  ((status == BYGGSTEG_OK)) || return "${status}"

  # Version 2 answers the token twice: in the body, and in the
  # x-bewaking-byggsteg header every call that takes one sends.  Read the
  # header first -- it is what a script written against /api/v1 read -- and
  # fall back to the body, so an answer carrying either is used.
  local token
  token="$(token_from_headers "${BYGGSTEG_HTTP_HEADER_FILE}")"
  if [[ -z "${token}" ]]; then
    token="$(json_string token "${BYGGSTEG_LOGIN_RESPONSE_FILE}")"
  fi

  if [[ -z "${token}" ]]; then
    log_error "Signed in, but the answer carried no token (HTTP ${BYGGSTEG_HTTP_STATUS}):"
    print_response "${BYGGSTEG_LOGIN_RESPONSE_FILE}"
    # An answer we cannot use is not one that asking again improves.
    return "${BYGGSTEG_PERMANENT}"
  fi

  printf '%s' "${token}" >"${BYGGSTEG_TOKEN_FILE}"

  # What the session is worth, when the answer says: a build that fails later
  # because the token expired is easier to read when the expiry was on screen.
  local username expires_at
  username="$(json_string username "${BYGGSTEG_LOGIN_RESPONSE_FILE}")"
  expires_at="$(json_number expires-at "${BYGGSTEG_LOGIN_RESPONSE_FILE}")"
  if [[ -n "${username}" ]]; then
    log_debug "Signed in as ${username}"
  fi
  if [[ -n "${expires_at}" ]]; then
    log_debug "The token goes stale at $(format_epoch "${expires_at}")"
  fi

  return "${BYGGSTEG_OK}"
}

# get_token -- the step.
#
#   settings:     BYGGSTEG_URL, BYGGSTEG_EMAIL, BYGGSTEG_PASSWORD
#   file-outputs: x-bewaking-byggsteg (the token), byggsteg-login-response.json
get_token() {
  require_url
  require_setting PLUGIN_BYGGSTEG_EMAIL
  require_setting PLUGIN_BYGGSTEG_PASSWORD

  log_info "Signing in to Byggsteg: POST $(byggsteg_url "${BYGGSTEG_LOGIN_PATH}")"
  log_debug "Signing in as ${PLUGIN_BYGGSTEG_EMAIL}"

  retry_command sign_in

  log_info "Byggsteg token stored in ${BYGGSTEG_TOKEN_FILE}"
}

# ===========================================================================
# submit-job
#
# Hands Byggsteg a job definition and keeps the id of the log its output will
# arrive in.
# ===========================================================================

# submit_job_request <token> <job-code> -- one attempt at submitting.
#
# Only the request is retried: whether the answer can be used is decided once,
# after it has been asked for.  The body is form-encoded because a job is Lisp
# -- quotes, newlines and commas -- and a form body carries all of them as they
# are, where a JSON one would have to escape them into a second dialect.
submit_job_request() {
  local -r token="$1" job_code="$2"
  local status=0

  http_request POST "$(byggsteg_url "${BYGGSTEG_SUBMIT_PATH}")" \
    "${BYGGSTEG_SUBMIT_RESPONSE_FILE}" \
    --header 'content-type: application/x-www-form-urlencoded' \
    --header "x-bewaking-byggsteg: ${token}" \
    --data-urlencode "job-code=${job_code}" || status=$?

  return "${status}"
}

# submit_job -- the step.
#
#   file-inputs:  x-bewaking-byggsteg
#   settings:     BYGGSTEG_URL, BYGGSTEG_JOB_CODE
#   file-outputs: byggsteg-log-id, byggsteg-submit-job-response.json
submit_job() {
  require_url
  require_setting PLUGIN_BYGGSTEG_JOB_CODE

  require_workspace_file "${BYGGSTEG_TOKEN_FILE}" "run the get-token step first"

  local token job_code
  token="$(read_file "${BYGGSTEG_TOKEN_FILE}")"
  job_code="$(resolve_placeholders "${PLUGIN_BYGGSTEG_JOB_CODE}")"

  log_info "Submitting Byggsteg job: POST $(byggsteg_url "${BYGGSTEG_SUBMIT_PATH}")"
  log_debug "Job code: ${job_code}"

  retry_command submit_job_request "${token}" "${job_code}"

  # Version 2 answers a queued run with the run itself and the log its output
  # will arrive in: {"run": {..., "log-id": ...}, "log": {...}}.  A log-id that
  # is missing, empty, or the word "null" -- a non-JSON body, a body without the
  # field, a run whose log row is gone -- leaves nothing to follow, so the step
  # fails with the answer printed rather than passing on a pipeline nobody can
  # poll.
  local log_id run_id
  log_id="$(json_string log-id "${BYGGSTEG_SUBMIT_RESPONSE_FILE}")"

  if [[ -z "${log_id}" || "${log_id}" == "null" ]]; then
    log_error "Byggsteg queued no run with a log to follow (HTTP ${BYGGSTEG_HTTP_STATUS}):"
    print_response "${BYGGSTEG_SUBMIT_RESPONSE_FILE}"
    error_exit "Byggsteg did not accept the job"
  fi

  printf '%s' "${log_id}" >"${BYGGSTEG_LOG_ID_FILE}"

  run_id="$(json_string run-id "${BYGGSTEG_SUBMIT_RESPONSE_FILE}")"

  local detail="log-id ${log_id}"
  if [[ -n "${run_id}" ]]; then
    detail="${detail}, run-id ${run_id}"
  fi

  log_info "Byggsteg job queued: ${detail}"
  log_debug "Answer: $(read_file "${BYGGSTEG_SUBMIT_RESPONSE_FILE}")"
}

# ===========================================================================
# poll-job
#
# Follows the log of a run until it has finished, then prints what Byggsteg
# recorded for it and passes or fails the build accordingly.
# ===========================================================================

# require_view -- the reading of the output to ask for: `rendered' (what a
# terminal would have been left with, the default) or `raw' (what the command
# wrote, its control characters spelled out).
require_view() {
  case "${PLUGIN_POLL_VIEW:-rendered}" in
    rendered | raw) ;;
    *) error_exit "PLUGIN_POLL_VIEW must be 'rendered' or 'raw', not '${PLUGIN_POLL_VIEW}'" ;;
  esac
}

# fetch_log_status <log-id> <have> -- one reading of the run's log.
#
# HAVE is the length of the output the last reading carried, which is the
# number the API compares against the log's own: an answer to a `have' that is
# still the log's length says nothing has changed and leaves the text out
# rather than sending it again.  Returns what http_request said, so a 4xx is
# not mistaken for a poll that may yet succeed.
fetch_log_status() {
  local -r log_id="$1"
  local -r view="${PLUGIN_POLL_VIEW}"
  local url
  local status=0

  url="$(byggsteg_url "${BYGGSTEG_LOGS_PATH}/${log_id}")?view=${view}"
  if [[ -n "${2:-}" ]]; then
    url="${url}&have=${2}"
  fi

  http_request GET "${url}" "${BYGGSTEG_LOG_RESPONSE_FILE}" || status=$?

  return "${status}"
}

# keep_job_output -- the output this reading carried, kept for printing once.
#
# The answer leaves the text out when it has not changed since the last
# reading, so what arrives is not appended to anything: the file holds the last
# whole reading of the output, whatever length it had when it was sent.
keep_job_output() {
  if ! json_has_key text "${BYGGSTEG_LOG_RESPONSE_FILE}"; then
    return 0
  fi
  json_string text "${BYGGSTEG_LOG_RESPONSE_FILE}" >"${BYGGSTEG_LOG_OUTPUT_FILE}"
}

# print_job_output -- what Byggsteg recorded, printed exactly once.
print_job_output() {
  local output
  output="$(read_file "${BYGGSTEG_LOG_OUTPUT_FILE}")"

  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  else
    log_debug "Byggsteg recorded no output for this job"
  fi
}

# poll_log <log-id> -- follow one log until it says the run has finished.
#
# Stays quiet while the run is still going.  Tune with PLUGIN_POLL_LIMIT
# (default 4096), PLUGIN_POLL_INTERVAL_SECONDS (default 8) and
# PLUGIN_POLL_VIEW (rendered, the default, or raw).
poll_log() {
  local -r log_id="$1"
  local -r poll_limit="${PLUGIN_POLL_LIMIT:-4096}"
  local -r interval_seconds="${PLUGIN_POLL_INTERVAL_SECONDS:-8}"
  local poll_count=0 have="" status run_status length failures=0

  while ((poll_count < poll_limit)); do
    poll_count=$((poll_count + 1))

    status=0
    fetch_log_status "${log_id}" "${have}" || status=$?

    if ((status == BYGGSTEG_PERMANENT)); then
      # A 4xx is an answer, not a hiccup: the log is not there.  Polling on
      # would only run out the clock on a build that is already lost.
      error_exit "Byggsteg will not answer for log ${log_id} (HTTP ${BYGGSTEG_HTTP_STATUS}); giving up"
    fi

    if ((status == BYGGSTEG_RETRYABLE)); then
      failures=$((failures + 1))
      log_warn "Could not read the job's status (poll ${poll_count}/${poll_limit}, ${failures} in a row); trying again in ${interval_seconds}s"
      sleep "${interval_seconds}"
      continue
    fi

    # A newer reading of the output: keep it, and remember its length so the
    # next poll can be answered with "nothing has changed" instead of the text.
    keep_job_output
    length="$(json_number length "${BYGGSTEG_LOG_RESPONSE_FILE}")"
    if [[ -n "${length}" ]]; then
      have="${length}"
    fi

    run_status="$(json_string status "${BYGGSTEG_LOG_RESPONSE_FILE}")"

    case "${run_status}" in
      succeeded)
        print_job_output
        log_info "Byggsteg job succeeded (log ${log_id}, ${poll_count} polls)"
        return 0
        ;;
      failed)
        print_job_output
        error_exit "Byggsteg job failed (log ${log_id})"
        ;;
      running | queued)
        log_debug "Byggsteg job is ${run_status} (poll ${poll_count}/${poll_limit})"
        ;;
      *)
        # An answer carrying no run status is not a status answer at all -- an
        # error page, a proxy's, a truncated body -- so it is not something to
        # keep polling: the step fails now, with what came back.
        log_error "Byggsteg answered HTTP ${BYGGSTEG_HTTP_STATUS} without a run status:"
        print_response "${BYGGSTEG_LOG_RESPONSE_FILE}"
        error_exit "Byggsteg job status could not be read"
        ;;
    esac

    sleep "${interval_seconds}"
  done

  print_job_output
  error_exit "Timed out waiting for Byggsteg job (${poll_limit} polls of ${interval_seconds}s; log ${log_id})"
}

# poll_job -- the step.
#
#   file-inputs:  byggsteg-log-id
#   settings:     BYGGSTEG_URL, POLL_LIMIT, POLL_INTERVAL_SECONDS, POLL_VIEW
#   file-outputs: byggsteg-job-output.txt, byggsteg-log-response.json
poll_job() {
  require_url
  require_positive_integer "${PLUGIN_POLL_LIMIT:-4096}" PLUGIN_POLL_LIMIT
  require_positive_integer "${PLUGIN_POLL_INTERVAL_SECONDS:-8}" PLUGIN_POLL_INTERVAL_SECONDS
  require_view

  require_workspace_file "${BYGGSTEG_LOG_ID_FILE}" "run the submit-job step first"

  local log_id
  log_id="$(read_file "${BYGGSTEG_LOG_ID_FILE}")"

  # The id goes into a URL path, so a file that holds something else -- a
  # newline, a quote, a whole JSON object -- is a mistake worth naming here
  # rather than a 404 that says nothing about it.
  if [[ ! ${log_id} =~ ^[A-Za-z0-9._~-]+$ ]]; then
    error_exit "${BYGGSTEG_LOG_ID_FILE} does not hold a log id: '${log_id}'"
  fi

  PLUGIN_POLL_VIEW="${PLUGIN_POLL_VIEW:-rendered}"

  # Nothing has been read from this log yet, so the first poll asks for the
  # whole of it.
  : >"${BYGGSTEG_LOG_OUTPUT_FILE}"

  log_info "Waiting for Byggsteg job: GET $(byggsteg_url "${BYGGSTEG_LOGS_PATH}/${log_id}")"

  poll_log "${log_id}"
}

# ===========================================================================
# all
#
# The three steps in one: for a pipeline that would rather have one step than
# three, or a machine that wants to run the bridge by hand.
# ===========================================================================

all_steps() {
  get_token
  submit_job
  poll_job
}

# ===========================================================================
# Entrypoint
# ===========================================================================

usage() {
  cat <<'EOF'
byggsteg-woodpecker - bridge a Woodpecker pipeline to a Byggsteg deployment

Usage: byggsteg-woodpecker <step>

Steps:
  get-token    sign in to Byggsteg and keep the session token in x-bewaking-byggsteg
  submit-job   submit BYGGSTEG_JOB_CODE, keep its log id in byggsteg-log-id
  poll-job     follow that log, print the job's output, pass or fail the build
  all          the three, in that order, in one step
  help         this message

The step may also be given as the BYGGSTEG_STEP setting.  Settings are the
Woodpecker `settings' keys, seen here as PLUGIN_-prefixed environment variables:

  BYGGSTEG_URL                     base URL of the Byggsteg deployment (required)
  BYGGSTEG_EMAIL                   account email                                  (get-token)
  BYGGSTEG_PASSWORD                account password                               (get-token)
  BYGGSTEG_JOB_CODE                the Lisp job definition            (submit-job)
  POLL_LIMIT                       status polls before giving up (4096)   (poll-job)
  POLL_INTERVAL_SECONDS            seconds between polls (8)              (poll-job)
  POLL_VIEW                        rendered (default) or raw              (poll-job)

Tuning: BYGGSTEG_RETRY_ATTEMPTS (8), BYGGSTEG_RETRY_INTERVAL (4s),
BYGGSTEG_CONNECT_TIMEOUT (10s), BYGGSTEG_REQUEST_TIMEOUT (120s),
BYGGSTEG_DEBUG (1 for every request and answer).
EOF
}

main() {
  local -r step="${1:-${PLUGIN_BYGGSTEG_STEP:-}}"

  case "${step}" in
    get-token) get_token ;;
    submit-job) submit_job ;;
    poll-job) poll_job ;;
    all) all_steps ;;
    help | -h | --help | usage)
      usage
      exit 0
      ;;
    '')
      usage 1>&2
      error_exit "no step given: name one of get-token, submit-job, poll-job or all"
      ;;
    *)
      error_exit "unknown step '${step}': name one of get-token, submit-job, poll-job or all"
      ;;
  esac
}

# The tuning variables are checked before anything is attempted, so a typo in
# one of them is a message rather than a curl that will not start.
validate_tuning
main "$@"
