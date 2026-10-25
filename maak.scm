;;; byggsteg-woodpecker

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; byggsteg-woodpecker is free software: you can redistribute it and/or modify
;; it under the terms of the Lesser GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; byggsteg-woodpecker is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; Lesser GNU General Public License for more details.

;; You should have received a copy of the Lesser GNU General Public License
;; along with byggsteg-woodpecker.  If not, see <https://www.gnu.org/licenses/>.

;; The project's tasks, run with Maak: https://codeberg.org/jjba23/maak
;;
;;   maak --list                 show every task
;;   maak build                  build the image
;;   maak test                   run the end-to-end tests
;;
;; Only the names in `#:export' below are tasks, so the helpers beside them
;; stay helpers.

(define-module (maak)
  #:use-module (maak maak)
  ;; The git and container helpers are imported under prefixes: the tasks below
  ;; are named the way maak exposes them on the command line, and a task may not
  ;; shadow the helper it calls.  `srfi srfi-13' is what trims what git prints.
  #:use-module ((maak git) #:prefix git:)
  #:use-module ((maak container) #:prefix ct:)
  #:use-module (srfi srfi-13)
  #:declarative? #t
  #:export (default build push lint fmt test sizes clean))

;; ====== Constants ======

;; The registry and organisation the image is published under; override for
;; your own builds with IMAGE_REGISTRY and IMAGE_ORG.
(define image-registry
  (or (getenv "IMAGE_REGISTRY") "docker.io"))

(define image-org
  (or (getenv "IMAGE_ORG") "jjba23"))

;; One image, one script: the three pipeline steps are three arguments to it.
(define image-name
  "byggsteg-woodpecker")

(define containerfile
  "byggsteg.containerfile")

;; The image tag: VERSION when it is set, otherwise the exact git tag we are
;; standing on, or the short commit hash away from a tag.
;;
;; The two questions are asked even in a dry run -- a version is a value a name
;; is built from, not a command a task performs -- so the dry run is turned off
;; around them, as it was when this read git through a pipe.  `git tag
;; --points-at HEAD' answers what `git describe --exact-match --tags' answers
;; without the `fatal:' line git writes when no tag matches.
(define (git-value . arguments)
  "What git printed for ARGUMENTS, read even in a dry run."
  (parameterize ((dry-run? #f))
    (string-trim-both
     (git:git-output arguments #:allow-failure? #t))))

(define version
  (let ((named (getenv "VERSION")))
    (if (and named (positive? (string-length named)))
        named
        (let ((tag (git-value "tag" "--points-at" "HEAD")))
          (if (string=? tag "")
              (git-value "rev-parse" "--short" "HEAD")
              (car (string-split tag #\newline)))))))

;; ====== Helpers ======

;; The full name the image is built and pushed under.
(define (image)
  (~ "~a/~a/~a:~a" image-registry image-org image-name version))

;; ====== Tasks ======

(define (default)
  "Default task: list the available tasks."
  (run (list "maak" "--list")))

(define (build)
  "Build the step image."
  (ct:container-build "." #:file containerfile #:tag (image)))

(define (push)
  "Build and then push the step image."
  (build)
  (ct:container-push (image)))

(define (lint)
  "Static analysis of the step script and the test runner, with shellcheck."
  (run (list "shellcheck" "-x" "src/bash/byggsteg-woodpecker.bash"
             "test/run-tests.bash")))

(define (fmt)
  "Format the step script and the test runner, with shfmt."
  (run (list "shfmt" "-i" "2" "-ci" "-w" "src/bash/byggsteg-woodpecker.bash"
             "test/run-tests.bash")))

(define (test)
  "Run the end-to-end tests against a mock Byggsteg server."
  (run (list "bash" "test/run-tests.bash")))

(define (sizes)
  "Report the size of the built step image."
  ;; What `podman images --format ... | grep byggsteg-woodpecker || true' did,
  ;; with the reading and the matching in Scheme: the listing is asked for once
  ;; and each line is kept when it names the image.  A machine with no such
  ;; image lists nothing, which is not a failure.
  (for-each (lambda (line)
              (when (string-contains line image-name)
                (log-info "~a" line)))
            (string-split (ct:container-output
                           (list "images" "--format"
                                 "{{.Repository}}:{{.Tag}} {{.Size}}")
                           #:allow-failure? #t)
                          #\newline)))

(define (clean)
  "Remove the locally built step image."
  ;; `podman rmi', not `container-rm': that helper runs `rm', which removes
  ;; containers and leaves the image this task is named for.  An image that was
  ;; never built is not a failure, which is what `|| true' said.
  (ct:container (list "rmi" (image)) #:allow-failure? #t))
