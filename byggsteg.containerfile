# byggsteg-woodpecker -*- mode: Dockerfile -*-

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

# One image for the whole bridge: the same script runs every step, and which
# one it runs is its argument (get-token, submit-job, poll-job, or all), or the
# BYGGSTEG_STEP setting when a pipeline would rather name it there.
#
# It is Alpine with three packages and one file.  bash is the script, curl is
# the API, ca-certificates is TLS; everything else the script reaches for
# (date, sleep, head) is already in busybox.  There is deliberately no jq: the
# answers are small JSON objects and the handful of fields read from them are
# pulled out with bash pattern matching, so neither jq nor the oniguruma it
# drags along has to be pulled at the start of every pipeline step.

FROM alpine:3.22.1

RUN apk add --no-cache bash curl ca-certificates

COPY --chmod=755 src/bash/byggsteg-woodpecker.bash /bin/byggsteg-woodpecker

# The step is the argument (`/bin/byggsteg-woodpecker get-token`), or the
# BYGGSTEG_STEP setting, which is what a step that names no commands uses.
ENTRYPOINT ["/bin/byggsteg-woodpecker"]
