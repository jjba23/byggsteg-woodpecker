
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

all:
	make build-poll-job
	make push-poll-job
	make build-submit-job
	make push-submit-job
