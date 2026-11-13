# Vision

Byggsteg-woodpecker is one small image that lets a Woodpecker pipeline hand its work
to a Byggsteg deployment and follow it honestly to a green or a red build. Its whole
design is subtraction: Alpine, `bash`, `curl` and `ca-certificates`, no JSON library,
no runtime, three steps that each do one thing. This document is about what that
subtraction buys, and how far it should be pushed before it becomes an accident
rather than a decision.

## Where byggsteg-woodpecker is today

The bridge is `src/bash/byggsteg-woodpecker.bash`, 863 lines of Bash, in an image of
about 16.6 MB built by `byggsteg.containerfile` from Alpine 3.22.1. It speaks `/api/v2`
and never calls `/api/v1`.

What exists, concretely:

- **Three steps and `all`.** `get-token` signs in and stores the token, `submit-job`
  expands the job code and stores the log id, `poll-job` follows that log and is what
  passes or fails the build. `all` runs the three in order inside one step, and `help`
  prints the usage.
- **The step is named in a setting, not in `commands`.** Woodpecker refuses a step
  that configures both `commands` and `settings`, so the image is driven as a plugin:
  `BYGGSTEG_STEP` says which of the three this step is. The README documents the
  `environment:` spelling with the `PLUGIN_` prefix for the case where `commands` is
  unavoidable, because that prefix is the only difference between the two forms.
- **The steps talk through files in Woodpecker's workspace**: the token, the log id,
  the three answers, and the job's output as `byggsteg-job-output.txt`. Nothing is
  held in a process, because each step is its own container.
- **The log is printed once.** A green build shows the job's output and little else;
  a red build shows the same output plus the reason; nothing is dumped while the job
  runs. Polling is incremental — after the first answer each poll sends the length it
  already has as `have`, and the deployment answers that nothing changed instead of
  sending the text again.
- **Refusals are read as sentences.** Byggsteg answers with `{"error": "..."}`, and
  that sentence is printed instead of a status code alone, so a 403 reads as "the token
  does not hold `byggsteg:job-create`".
- **What is retried, and what is not, is decided by the answer.** 5xx, 408, 425, 429,
  a network failure or a timeout is retried up to `BYGGSTEG_RETRY_ATTEMPTS` (8); any
  other 4xx fails immediately, because asking again cannot change it; and a 2xx whose
  body is not the JSON the step needs fails at once rather than passing a pipeline on
  nothing.
- **No `jq`.** The answers are small and the handful of fields read from them are
  pulled out with Bash pattern matching, so neither `jq` nor oniguruma is pulled at the
  start of every pipeline step.
- **The suite needs nothing but bash, curl and guile.** `test/mock-byggsteg.scm` serves
  a fake API and `test/run-tests.bash` drives thirteen scenarios through the real
  script: success, a quiet success, a failure, a timeout, a login refused, a login
  answering 500, a login answering 200 with no token, a submit forbidden, a submit
  answering 500, a submit that is not JSON, a submit with no log id, an unrecognisable
  status and a log that is not there.
- **`maak` owns the image lifecycle**: `build`, `push`, `lint` (shellcheck), `fmt`
  (shfmt), `test`, `sizes`, `clean`, with the tag taken from the git tag you are
  standing on and `IMAGE_REGISTRY`/`IMAGE_ORG` overridable.

Two decisions constrain what comes next. The first is **size**, which is not a
coincidence but a product: the image is pulled at the start of every step, so every
dependency is paid for on every build. The second is that **the image is a plugin in
somebody else's pipeline** — it does not own the pipeline, the queue or the job, and
every feature it grows has to fit that role.

One consequence is worth naming: this image is not only for Woodpecker. The sibling
`byggsteg-github` project runs this same image as its step image, which is why its
default names `jjba23/byggsteg-woodpecker` — a fact that the name hides.

## The vision

1. **Size is a budget, enforced.** The image stays under a stated ceiling, measured by
   `maak sizes` and asserted in CI, so a change that adds a dependency has to argue for
   the megabytes rather than discover them later.

2. **The bridge is a CLI with a contract.** The three steps, the files they exchange,
   the settings they read and the exit codes they return are documented as an interface
   another CI can drive, so a third forge is a driver rather than a rewrite.

3. **A pipeline can check its permissions before it deploys.** A step that signs in and
   reports which account it is and what it may do — without submitting anything — turns
   the most common first-run failure into one line of output.

4. **The run's artifacts come back with its output.** A job that collected tarballs has
   them offered by the deployment; today the bridge prints the log and leaves them, so a
   Woodpecker build cannot use what Byggsteg built.

5. **Nobody ships a password to a pipeline.** A token minted by an earlier step, or a
   trust relationship with the forge, replaces the email and password this bridge asks
   for today.

## Features that are in scope and not built yet

- **Artifact download.** `submit-job` already parses the answer for a log id, and the run
  answer names the tarballs it will collect. The hard part is timing: artifacts exist
  only once the run is over, so the download has to happen inside `poll-job` after the
  status turns, and it has to fail loudly when the deployment offers nothing.
- **A token as an input.** `get-token` mints one from an email and a password; a step
  that is handed a token already (from a vault, or from an earlier job) should skip the
  sign-in entirely. The hard part is that the deployment mints tokens with the account's
  permissions baked in at sign-in, so a shorter-lived token is an API question before it
  is a bridge question.
- **A wall-clock deadline.** `POLL_LIMIT` (4096) times `POLL_INTERVAL_SECONDS` (8) is the
  only ceiling, which is about nine hours of not knowing. The hard part is telling "slow"
  from "hung": neither the status nor the log says when the job last made progress, so a
  deadline today can only be blunter than a reader would like.
- **Reading structured fields without a JSON parser.** Bash pattern matching is enough
  for a token and a log id and not enough for an array of artifacts. The hard part is
  the tension this project is built on: the fix is either a few hundred kilobytes of
  parser or a field the API should have answered flat.
- **A failed-step summary.** The console names which step failed and how long each took;
  the API's log answer is text. The hard part is on the deployment side — the bridge
  cannot summarise what it was never told.
- **Multi-architecture images.** An arm64 runner has to build the image itself today.
  The hard part is not the build but the verification: two architectures to run the same
  thirteen scenarios on.

## New features that would be worth having

- **`verify` — sign in and report.** `BYGGSTEG_STEP: verify` would print the account, the
  permissions its token holds and when the token stops being read, then exit 0 without
  touching a job. It is the step every new pipeline needs and none of them have.
- **`dry-run` — write the job and stop.** The job code `submit-job` would send is the one
  thing a pipeline author debugs; printing it, expanded, without queueing a deploy would
  make that possible on a real runner instead of by reading the script.
- **A neutral image name.** `byggsteg-bridge` with the current name kept as an alias
  would stop the GitHub bridge from advertising Woodpecker in its default settings. It is
  a rename, a tag and a README — and a small honesty about what this thing is.
- **A size assertion.** `maak sizes` reports; CI should fail above a threshold. The
  cheapest possible guard against a dependency creeping in.
- **The output as a Woodpecker-visible file.** The job's output is already written to
  `byggsteg-job-output.txt`; naming it in the README as the thing to attach to a build,
  or copying it into a path the pipeline can pick up, makes it usable rather than merely
  present.
- **A trust relationship with the forge** (speculative, and it needs a change in
  Byggsteg): both Woodpecker and GitHub can prove which repository and pipeline is
  asking. Verifying that instead of a password would remove the weakest secret in the
  whole arrangement.

## Contributions that would move the needle

1. **The `verify` step.** Two API calls, one paragraph of a README and one test scenario,
   and it answers the question every first pipeline asks.
2. **The size assertion in CI.** A dozen lines around the `sizes` task, and it protects
   the property the project is proudest of.
3. **`dry-run`.** Small, and it removes the reason people read the script.
4. **Artifact download in `poll-job`.** Bounded and useful, with the timing subtlety
   above as the whole of the difficulty.
5. **The neutral image name, with the old one aliased.** Cheap, and it unblocks the
   sibling project's defaults.
6. **A wall-clock deadline** alongside the poll count, once someone writes down what the
   bridge can actually observe about a job's progress.
7. **Multi-architecture builds**, which is mostly CI plumbing and a second run of the
   suite.

## Compared to related projects

| Project | What it is | Where byggsteg-woodpecker differs |
| --- | --- | --- |
| Woodpecker's own plugins (`woodpeckerci/plugin-*`) | Small images that each do one thing — clone a repository, build an image, deploy over SSH | This does not replace a step: it replaces the pipeline, handing the whole job to another CI and reporting its verdict |
| byggsteg-github (this project's sibling) | The same bridge for GitHub, driven by inputs and reusable workflows | Shares this image and the same three-step protocol; differs only in how the settings arrive |
| Drone plugins | The `settings` → `PLUGIN_*` convention Woodpecker inherited | Deliberately follows that convention, which is why the image drops into any pipeline without a custom wrapper |
| Self-hosted runners (`actions/runner`, `woodpecker-agent`) | An agent that claims work and executes steps on a machine that must stay online | The agent does the work; this delegates it and needs no persistent host — the deployment is the machine |
| `curlimages/curl`, `alpine/git` and friends | Tiny single-purpose images, the same size philosophy | The same philosophy, but this one speaks an API, polls incrementally and returns a verdict rather than a response body |
| A shell script in a `commands:` step | What a pipeline author writes when they want this and cannot find it | The retry policy, the incremental polling, the refusal sentences, the thirteen tested failure modes and the three-step protocol are the whole difference |

What the others do that byggsteg-woodpecker could still add is narrow, and it is why
this project should stay small. Plugins have individual interfaces narrow enough to
compose; runners have real isolation and a queue. The one thing worth borrowing is the
convention of a documented, verifiable interface: a plugin's settings are its contract,
and this bridge's settings deserve the same treatment rather than a README table that is
true until the next release.

Where it is ahead and should stay ahead: 16.6 MB in an ecosystem where CI helper images
routinely weigh a hundred times that; no JSON parser, no shell framework, no runtime; the
same script serving two forges; polling that sends only what changed; output printed once
rather than as per-poll noise; and a refusal that is printed as a sentence. Those are the
properties that make it cheap enough to run on every build, which is the only way a
bridge earns its place.

## In the long run

The first bet is that **this becomes the general bridge**, with a name that says so. The
three steps, the workspace files and the exit codes are already CI-agnostic; what is
Woodpecker-specific is how settings arrive, and that is a driver, not an architecture.

The second is that **size stays a defended property**. Every tempting dependency —
`jq`, a JSON library, a retry helper — costs the same megabytes on every build of every
pipeline that uses this image. A project that asserts its size in CI can say no with a
number.

The third is that **credentials leave the pipeline**. A shared email and password in a
CI secret is the arrangement everybody starts with and nobody should keep.

## What would make this document wrong

If Byggsteg grows a scheduler that can be triggered directly by a forge, the bridge
becomes an adapter with no logic and most of this list is moot. If Woodpecker's plugin
model changes so that a `settings`-driven image is no longer first-class, the
`environment:` spelling documented today becomes the only path and the README is the
thing to rewrite. Neither is visible from here, and both are cheap to absorb while the
bridge is 863 lines of Bash.

*A vision describes intent, not commitments: nothing here is promised for a release.*
