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
ADD src/bash/byggsteg/prelude.bash /bin/
ADD src/bash/byggsteg/get-token.bash /bin/
RUN chmod +x /bin/prelude.bash
RUN chmod +x /bin/get-token.bash
RUN apk -Uuv add bash curl ca-certificates jq coreutils make grep ncurses
ENTRYPOINT /bin/get-token.bash
