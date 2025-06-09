
define container-build
	podman build  -f $(2) \
		-t "$(shell printf "%s:%s" $(1) $(CONTAINER_TAG))"
endef

define container-push
	podman push "$(1):$(CONTAINER_TAG)"
endef

build-poll-job:
	$(call container-build,"jjba23/byggsteg-woodpecker-poll-job", "./src/container-files/poll-job.containerfile")

push-poll-job:
	$(call container-push,"jjba23/byggsteg-woodpecker-poll-job")

build-submit-job:
	$(call container-build,"jjba23/byggsteg-woodpecker-submit-job", "./src/container-files/submit-job.containerfile")

push-submit-job:
	$(call container-push,"jjba23/byggsteg-woodpecker-submit-job")
