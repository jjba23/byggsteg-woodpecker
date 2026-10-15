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
;;   maak build                  build the three step images
;;   maak test                   run the end-to-end tests
;;
;; Only the names in `#:export' below are tasks, so the helpers beside them
;; stay helpers.

(define-module (maak)
  #:use-module (maak maak)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:declarative? #t
  #:export (default build push lint fmt test sizes clean))

;; ====== Constants ======

;; The registry and organisation the images are published under; override for
;; your own builds with IMAGE_REGISTRY and IMAGE_ORG.
(define image-registry
  (or (getenv "IMAGE_REGISTRY") "docker.io"))

(define image-org
  (or (getenv "IMAGE_ORG") "jjba23"))

(define image-prefix
  "byggsteg-woodpecker")

;; The three pipeline steps, in the order a pipeline runs them.
(define steps
  '("get-token" "submit-job" "poll-job"))

;; The image tag: VERSION when it is set, otherwise the exact git tag we are
;; standing on, or the short commit hash away from a tag.
(define version
  (let ((named (getenv "VERSION")))
    (if (and named (positive? (string-length named)))
        named
        (let* ((port (open-input-pipe
                      "git describe --exact-match --tags 2>/dev/null || git rev-parse --short HEAD"))
               (tag (get-string-all port)))
          (close-pipe port)
          (string-trim-both tag)))))

;; ====== Helpers ======

;; The full name an image is built and pushed under.
(define (image step)
  (~ "~a/~a/~a-~a:~a" image-registry image-org image-prefix step version))

;; ====== Tasks ======

(define (default)
  "Default task: list the available tasks."
  ($ '("maak --list")))

(define (build . wanted)
  "Build the step images (all three when none are named)."
  (for-each (lambda (step)
              ($ (list (~ "podman build -f ~a.containerfile -t ~a ."
                          step (image step)))))
            (if (null? wanted) steps wanted)))

(define (push . wanted)
  "Build and then push the step images (all three when none are named)."
  (apply build wanted)
  (for-each (lambda (step)
              ($ (list (~ "podman push ~a" (image step)))))
            (if (null? wanted) steps wanted)))

(define (lint)
  "Static analysis of the step scripts and the test runner, with shellcheck."
  ($ '("shellcheck -x -P src/bash/byggsteg src/bash/byggsteg/*.bash test/run-tests.bash")))

(define (fmt)
  "Format the step scripts and the test runner, with shfmt."
  ($ '("shfmt -i 2 -ci -w src/bash/byggsteg/*.bash test/run-tests.bash")))

(define (test)
  "Run the end-to-end tests against a mock Byggsteg server."
  ($ '("bash test/run-tests.bash")))

(define (sizes)
  "Report the size of each built step image."
  ($ (list (~ "podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep byggsteg-woodpecker || true"))))

(define (clean)
  "Remove the locally built step images."
  ($ (list (~ "podman rmi ~a 2>/dev/null || true"
              (string-join (map image steps) " ")))))
