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

FROM alpine:3.22.1

# Only what the step actually needs: bash for the scripts, curl for the HTTP
# calls and ca-certificates for TLS.  Everything else the scripts use (date,
# sed, tr, head, base64, sleep, grep, cut) is already in busybox.
RUN apk add --no-cache bash curl ca-certificates

COPY --chmod=755 src/bash/byggsteg/prelude.bash /bin/
COPY --chmod=755 src/bash/byggsteg/poll-job.bash /bin/

ENTRYPOINT ["/bin/poll-job.bash"]
