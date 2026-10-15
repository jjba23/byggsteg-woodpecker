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

# End-to-end tests for the step scripts.  They run the scripts themselves --
# not the built images -- against a mock Byggsteg server (mock-byggsteg.scm),
# so the suite needs only bash, curl and guile (which Maak already needs).
# Run it with `maak test`.

set -uo pipefail

# A CDPATH in the caller's environment makes `cd` echo where it landed and
# would end up inside the paths below.
unset CDPATH

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
root="$(cd -- "$test_dir/.." >/dev/null 2>&1 && pwd)"
scripts_dir="$root/src/bash/byggsteg"

# The steps source prelude.bash through $PATH, the way they do in the image.
export PATH="$scripts_dir:$PATH"

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

# scenario <name> -- what the mock server should play from now on.
scenario() { printf '%s' "$1" >"$state/scenario"; }

# run <script> [env assignment...] -- run one step against the mock server.
run() {
  local script="$1"
  shift
  (cd "$work" && env "PLUGIN_BYGGSTEG_URL=$base" "$@" bash "$scripts_dir/$script")
}

# fresh -- an empty workspace for the next group of steps.
fresh() { rm -rf "$work" && mkdir -p "$work"; }

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

# poll_count -- how many times the last scenario polled the job.
poll_count() { cat "$state/poll-count.txt" 2>/dev/null || printf 0; }

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
out="$(run get-token.bash PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret 2>&1)"
check "valid credentials exit 0" 0 "$?"
check "token stored" "test-token-123" "$(cat "$work/x-bewaking-byggsteg" 2>/dev/null)"

out="$(run get-token.bash PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=wrong BYGGSTEG_RETRY_ATTEMPTS=2 BYGGSTEG_RETRY_INTERVAL=1 2>&1)"
check "wrong credentials exit non-zero" 1 "$?"

scenario login-error
out="$(run get-token.bash PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret BYGGSTEG_RETRY_ATTEMPTS=2 BYGGSTEG_RETRY_INTERVAL=1 2>&1)"
check "server error exit non-zero" 1 "$?"

scenario login-no-token
out="$(run get-token.bash PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret BYGGSTEG_RETRY_ATTEMPTS=2 BYGGSTEG_RETRY_INTERVAL=1 2>&1)"
check "200 without a token exit non-zero" 1 "$?"
check "200 without a token explained" 1 "$(contains "$out" "without an x-bewaking-byggsteg token")"

out="$(run get-token.bash 2>&1)"
check "missing settings exit non-zero" 1 "$?"
check "missing settings explained" 1 "$(contains "$out" "PLUGIN_BYGGSTEG_EMAIL is required")"

echo "submit-job"
fresh
scenario success
run get-token.bash PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret >/dev/null 2>&1
out="$(run submit-job.bash PLUGIN_BYGGSTEG_JOB_CODE='(lambda() `((project . "%%CI_REPO_NAME%%")))' \
  CI_REPO_NAME=myrepo 2>&1)"
check "submit exit 0" 0 "$?"
check "log-id stored" "abc-123" "$(cat "$work/byggsteg-log-id" 2>/dev/null)"
check "placeholders expanded" 1 "$(contains "$(cat "$state/last-job-code.txt" 2>/dev/null)" 'project . "myrepo"')"
check "submit JSON shown" 1 "$(contains "$out" '"log-id"')"

scenario submit-error
out="$(run submit-job.bash PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' \
  BYGGSTEG_RETRY_ATTEMPTS=2 BYGGSTEG_RETRY_INTERVAL=1 2>&1)"
check "submit server error exit non-zero" 1 "$?"

scenario submit-not-json
out="$(run submit-job.bash PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit non-JSON exit non-zero" 1 "$?"
check "submit non-JSON shows the answer" 1 "$(contains "$out" "upstream proxy said no")"

scenario submit-no-log-id
out="$(run submit-job.bash PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit without a log-id exit non-zero" 1 "$?"
check "submit without a log-id explained" 1 "$(contains "$out" "carried no log-id")"

rm -f "$work/x-bewaking-byggsteg"
out="$(run submit-job.bash PLUGIN_BYGGSTEG_JOB_CODE='(lambda())' 2>&1)"
check "submit without token exit non-zero" 1 "$?"
check "submit without token explained" 1 "$(contains "$out" "run the get-token step first")"

echo "poll-job"
fresh
scenario success
run get-token.bash PLUGIN_BYGGSTEG_EMAIL=user@example.org \
  PLUGIN_BYGGSTEG_PASSWORD=s3cret >/dev/null 2>&1
printf 'abc-123' >"$work/byggsteg-log-id"

out="$(run poll-job.bash PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "success exit 0" 0 "$?"
check "job output printed once" 1 "$(grep -c 'hello from the byggsteg job' <<<"$out")"
check "no raw JSON dumped" 0 "$(grep -c 'log-data' <<<"$out")"
check "success line printed" 1 "$(contains "$out" "Byggsteg job succeeded")"
check "polled past the in-progress answer" 1 "$(($(poll_count) >= 2))"

scenario failure
out="$(run poll-job.bash PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "failure exit non-zero" 1 "$?"
check "failure output printed once" 1 "$(grep -c 'hello from the byggsteg job' <<<"$out")"
check "failure line printed" 1 "$(contains "$out" "Byggsteg job failed")"

scenario timeout
out="$(run poll-job.bash PLUGIN_POLL_INTERVAL_SECONDS=1 PLUGIN_POLL_LIMIT=3 2>&1)"
check "timeout exit non-zero" 1 "$?"
check "timeout line printed" 1 "$(contains "$out" "Timed out")"
check "quiet while in progress" 0 "$(grep -c 'log-data\|in-progress' <<<"$out")"
check "polled exactly up to the limit" 3 "$(poll_count)"

scenario status-not-json
out="$(run poll-job.bash PLUGIN_POLL_INTERVAL_SECONDS=1 2>&1)"
check "unusable status exit non-zero" 1 "$?"
check "unusable status shows the answer" 1 "$(contains "$out" "not a byggsteg status")"
check "unusable status fails at once" 0 "$(grep -c 'Timed out' <<<"$out")"
check "unusable status is not a pass" 0 "$(grep -c 'succeeded' <<<"$out")"
check "unusable status polled once" 1 "$(poll_count)"

rm -f "$work/byggsteg-log-id"
scenario success
out="$(run poll-job.bash 2>&1)"
check "poll without log-id exit non-zero" 1 "$?"
check "poll without log-id explained" 1 "$(contains "$out" "run the submit-job step first")"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
