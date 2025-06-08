container-build:
	podman build -t jjba23/byggsteg-woodpecker .
container-push: container-build
	podman push jjba23/byggsteg-woodpecker
