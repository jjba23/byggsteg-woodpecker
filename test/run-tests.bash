#!/usr/bin/env bash

# byggsteg-woodpecker

# SPDX-License-Identifier: MIT
# Copyright © 2026 Josep Bigorra <jjbigorra@gmail.com>

# The licence's own text -- the permission notice and the disclaimer -- is in
# LICENSE, which travels with every copy of this software.

# End-to-end tests for the step script.  They run the script itself -- not the
# built image -- against a mock Byggsteg server (mock-byggsteg.scm), so the
# suite needs only bash, curl and guile (which Maak already needs).  Run it with
# `maak test`.

set -uo pipefail

# A CDPATH in the caller's environment makes `cd` echo where it landed and
# would end up inside the paths below.
unset CDPATH

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
root="$(cd -- "$test_dir/.." >/dev/null 2>&1 && pwd)"
script="$root/src/bash/byggsteg-woodpecker.bash"

port="${BYGGSTEG_TEST_PORT:-8799}"
base="http://127.0.0.1:$port"
state="$(mktemp -d)"
work="$(mktemp -d)"
server_pid=""
pass=0
fail=0

cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  rm -rf "$state" "$work"
}
trap cleanup EXIT

# scenario <name> -- what the mock server should play from now on.  A change of
# scenario also resets what the mock wrote down about the run before it, so
# each group of tests starts from nothing.
scenario() {
  printf '%s' "$1" >"$state/scenario"
  : >"$state/requests.txt"
  : >"$state/have-values.txt"
}

# fresh -- an empty workspace, and a fresh record of what the mock was asked.
# What the steps exchange goes through the workspace, so each group of tests
# starts with none of it.
fresh() {
  rm -rf "$work" && mkdir -p "$work"
  : >"$state/requests.txt"
  : >"$state/have-values.txt"
}

# run <step> [environment...] -- run one step of the script against the mock.
# TEST_URL overrides the address, for the tests that check a bad one.
run() {
  local step="$1"
  shift
  (cd "$work" && env "PLUGIN_BYGGSTEG_URL=${TEST_URL:-$base}" "$@" bash "$script" "$step")
}

# sign-in -- put a token in the workspace, the way get-token would have.
sign_in() {
  scenario success
  run get-token PLUGIN_BYGGSTEG_EMAIL=user@example.org \
    PLUGIN_BYGGSTEG_PASSWORD=s3cret >/dev/null 2>&1
}

check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n         expected: %q\n         actual:   %q\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

# contains <text> <needle> -- 1 when TEXT holds NEEDLE, 0 otherwise.
contains() {
  if [[ "$1" == *"$2"* ]]; then printf 1; else printf 0; fi
}

# counted <text> <literal> -- how many lines of TEXT hold LITERAL.
counted() {
  grep -cF -- "$2" <<<"$1" || true
}

# counted_re <text> <extended regex> -- how many lines of TEXT match it.
counted_re() {
  grep -cE -- "$2" <<<"$1" || true
}

# poll_count -- how many times the last scenario polled the job.
poll_count() { cat "$state/poll-count.txt" 2>/dev/null || printf 0; }

# requests -- what the mock was asked, one "METHOD path?query" per line.
requests() { cat "$state/requests.txt" 2>/dev/null || printf ''; }

# have_values -- the `have' of every status request, one per line.
have_values() { cat "$state/have-values.txt" 2>/dev/null || printf ''; }

# ---- start the mock server -------------------------------------------------
scenario success
guile --no-auto-compile "$test_dir/mock-byggsteg.scm" "$port" "$state" >"$state/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "$base/" && break
  sleep 0.2
done

echo "get-token"
fresh
scenario success
out="$(run get-token PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret 2>&1)"
check "valid credentials exit 0" 0 "$?"
check "token stored" "test-token-123" "$(cat "$work/x-bewaking-byggsteg" 2>/dev/null)"
check "sign-in answer kept" 1 "$([[ -s "$work/byggsteg-login-response.json" ]] && printf 1 || printf 0)"
check "one call, to /api/v2/login" "POST /api/v2/login" "$(requests | awk '{print $1, $2}')"

scenario login-unauthorized
out="$(run get-token PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=wrong 2>&1)"
check "wrong password exit non-zero" 1 "$?"
check "wrong password not retried" 1 "$(requests | wc -l)"
check "wrong password explained" 1 "$(contains "$out" "do not match an account")"

scenario login-error
out="$(run get-token PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret BYGGSTEG_RETRY_ATTEMPTS=2 \
  BYGGSTEG_RETRY_INTERVAL=1 2>&1)"
check "server error exit non-zero" 1 "$?"
check "server error retried once" 2 "$(requests | wc -l)"
check "server error says it gave up" 1 "$(contains "$out" "failed after 2 attempts")"

scenario login-no-token
out="$(run get-token PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret 2>&1)"
check "200 without a token exit non-zero" 1 "$?"
check "200 without a token explained" 1 "$(contains "$out" "carried no token")"

out="$(run get-token 2>&1)"
check "missing settings exit non-zero" 1 "$?"
check "missing settings explained" 1 "$(contains "$out" "PLUGIN_BYGGSTEG_EMAIL is required")"

out="$(TEST_URL=byggsteg.example.org run get-token 2>&1)"
check "address without a scheme explained" 1 \
  "$(contains "$out" "must be an http:// or https:// address")"

echo "submit-job"
fresh
sign_in
scenario success
out="$(run submit-job PLUGIN_BYGGSTEG_JOB_CODE='(lambda() `((project . "%%CI_REPO_NAME%%")))' \
  CI_REPO_NAME=myrepo 2>&1)"
check "submit exit 0" 0 "$?"
check "log-id stored" "log-abc-123" "$(cat "$work/byggsteg-log-id" 2>/dev/null)"
check "placeholders expanded" 1 \
  "$(contains "$(cat "$state/last-job-code.txt" 2>/dev/null)" 'project . "myrepo"')"
check "submit names the log and the run" 1 \
  "$(contains "$out" "log-id log-abc-123, run-id run-abc-123")"
check "submit does not dump the answer" 0 "$(contains "$out" '"run":')"

scenario submit-error
out="$(run submit-job PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' \
  BYGGSTEG_RETRY_ATTEMPTS=2 BYGGSTEG_RETRY_INTERVAL=1 2>&1)"
check "submit server error exit non-zero" 1 "$?"

scenario submit-forbidden
out="$(run submit-job PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit without the permission exit non-zero" 1 "$?"
check "submit without the permission not retried" 1 "$(requests | wc -l)"
check "submit without the permission explained" 1 \
  "$(contains "$out" "does not hold byggsteg:job-create")"

scenario submit-not-json
out="$(run submit-job PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit non-JSON exit non-zero" 1 "$?"
check "submit non-JSON shows the answer" 1 "$(contains "$out" "upstream proxy said no")"

scenario submit-no-log-id
out="$(run submit-job PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit without a log exit non-zero" 1 "$?"
check "submit without a log explained" 1 "$(contains "$out" "no run with a log to follow")"

rm -f "$work/x-bewaking-byggsteg"
out="$(run submit-job PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit without token exit non-zero" 1 "$?"
check "submit without token explained" 1 "$(contains "$out" "run the get-token step first")"

: >"$work/x-bewaking-byggsteg"
out="$(run submit-job PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit with an empty token exit non-zero" 1 "$?"
check "submit with an empty token explained" 1 "$(contains "$out" "empty x-bewaking-byggsteg")"

echo "poll-job"
fresh
sign_in
printf 'log-abc-123' >"$work/byggsteg-log-id"

scenario success
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "success exit 0" 0 "$?"
check "job output printed once" 1 "$(counted "$out" 'hello from the byggsteg job')"
check "job output unescaped" 1 "$(counted "$out" 'it printed "quotes", a \ backslash and a')"
check "no raw JSON dumped" 0 "$(counted_re "$out" 'log-data|"status"')"
check "success line printed" 1 "$(contains "$out" "Byggsteg job succeeded")"
check "polled past the running answer" 1 "$(($(poll_count) >= 2))"
check "the second poll said what it had" 1 \
  "$([[ $(have_values | tail -1) =~ ^[1-9][0-9]*$ ]] && printf 1 || printf 0)"

scenario success-quiet
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "quiet success exit 0" 0 "$?"
check "quiet success still prints the output" 1 \
  "$(counted "$out" 'hello from the byggsteg job')"
check "quiet success read the output once" 1 \
  "$(counted "$out" 'it printed "quotes", a \ backslash and a')"

scenario failure
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "failure exit non-zero" 1 "$?"
check "failure output printed once" 1 "$(counted "$out" 'hello from the byggsteg job')"
check "failure line printed" 1 "$(contains "$out" "Byggsteg job failed")"

scenario timeout
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 PLUGIN_POLL_LIMIT=3 2>&1)"
check "timeout exit non-zero" 1 "$?"
check "timeout line printed" 1 "$(contains "$out" "Timed out")"
check "quiet while in progress" 0 "$(counted_re "$out" 'log-data|in-progress')"
check "polled exactly up to the limit" 3 "$(poll_count)"

scenario status-not-json
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "unusable status exit non-zero" 1 "$?"
check "unusable status shows the answer" 1 "$(contains "$out" "not a byggsteg status")"
check "unusable status fails at once" 0 "$(counted "$out" 'Timed out')"
check "unusable status is not a pass" 0 "$(counted "$out" 'succeeded')"
check "unusable status polled once" 1 "$(poll_count)"

scenario log-not-found
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "missing log exit non-zero" 1 "$?"
check "missing log explained" 1 "$(contains "$out" "no log with that id")"
check "missing log fails at once" 1 "$(poll_count)"

scenario success
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 PLUGIN_POLL_VIEW=raw 2>&1)"
check "raw view exit 0" 0 "$?"
check "raw view asked for" 1 "$(contains "$(requests | head -1)" "view=raw")"

out="$(run poll-job PLUGIN_POLL_VIEW=sideways 2>&1)"
check "unknown view exit non-zero" 1 "$?"
check "unknown view explained" 1 "$(contains "$out" "PLUGIN_POLL_VIEW must be")"

rm -f "$work/byggsteg-log-id"
out="$(run poll-job 2>&1)"
check "poll without log-id exit non-zero" 1 "$?"
check "poll without log-id explained" 1 "$(contains "$out" "run the submit-job step first")"

printf '{"log-id": "log-abc-123"}' >"$work/byggsteg-log-id"
out="$(run poll-job 2>&1)"
check "poll with a corrupted log-id exit non-zero" 1 "$?"
check "poll with a corrupted log-id explained" 1 \
  "$(contains "$out" "does not hold a log id")"

echo "all"
fresh
scenario success
out="$(run all PLUGIN_BYGGSTEG_EMAIL=user@example.org PLUGIN_BYGGSTEG_PASSWORD=s3cret \
  PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "one step, three calls: exit 0" 0 "$?"
check "one step: token, log-id and output" 1 \
  "$([[ -s "$work/x-bewaking-byggsteg" && -s "$work/byggsteg-log-id" ]] && printf 1 || printf 0)"
check "one step prints the job output" 1 \
  "$(counted "$out" 'hello from the byggsteg job')"

echo "logging"
fresh
sign_in
printf 'log-abc-123' >"$work/byggsteg-log-id"
scenario success
out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 PLUGIN_POLL_LIMIT=1 2>&1)"
check "no debug lines unless asked" 0 "$(counted "$out" 'DEBUG')"
check "info lines carry a level and a time" 1 \
  "$(($(counted_re "$out" '\[INFO\]\[20[0-9][0-9]-') > 0))"

out="$(run poll-job PLUGIN_POLL_INTERVAL_SECONDS=1 PLUGIN_POLL_LIMIT=1 BYGGSTEG_DEBUG=1 2>&1)"
check "debug lines when asked" 1 "$(($(counted "$out" 'DEBUG') > 0))"

echo "interface"
out="$(bash "$script" help 2>&1)"
check "help exit 0" 0 "$?"
check "help names the steps" 1 "$(contains "$out" 'get-token')"
check "help names the settings" 1 "$(contains "$out" 'BYGGSTEG_JOB_CODE')"

out="$(bash "$script" 2>&1)"
check "no step exit non-zero" 1 "$?"
check "no step says what to do" 1 "$(contains "$out" "no step given")"

out="$(bash "$script" nonsense 2>&1)"
check "unknown step exit non-zero" 1 "$?"
check "unknown step explained" 1 "$(contains "$out" "unknown step 'nonsense'")"

echo "the API"
check "no call to /api/v1 at all" 0 "$(counted "$(requests)" '/api/v1')"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
