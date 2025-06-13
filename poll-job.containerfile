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

FROM alpine:3.22.0
ADD src/sh/byggsteg/prelude.sh /bin/
ADD src/sh/byggsteg/poll-job.sh /bin/
RUN chmod +x /bin/prelude.sh
RUN chmod +x /bin/poll-job.sh
RUN apk -Uuv add curl ca-certificates jq coreutils make ncurses
ENTRYPOINT /bin/poll-job.sh
