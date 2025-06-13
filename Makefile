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

define container-build
	podman build -f $(2) \
		-t "$(shell printf "%s:%s" $(1) $(shell git describe --exact-match --tags))" .
endef

define container-push
	podman push "$(shell printf "%s:%s" $(1) $(shell git describe --exact-match --tags))"
endef

build-poll-job:
	$(call container-build,"jjba23/byggsteg-woodpecker-poll-job", "poll-job.containerfile")

push-poll-job:
	$(call container-push,"jjba23/byggsteg-woodpecker-poll-job")

build-submit-job:
	$(call container-build,"jjba23/byggsteg-woodpecker-submit-job", "submit-job.containerfile")

push-submit-job:
	$(call container-push,"jjba23/byggsteg-woodpecker-submit-job")

build-get-token:
	$(call container-build,"jjba23/byggsteg-woodpecker-get-token", "get-token.containerfile")

push-get-token:
	$(call container-push,"jjba23/byggsteg-woodpecker-get-token")

container-push:
	make build-poll-job
	make push-poll-job
	make build-submit-job
	make push-submit-job
	make build-get-token
	make push-get-token
