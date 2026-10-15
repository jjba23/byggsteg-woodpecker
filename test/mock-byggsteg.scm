#!/usr/bin/env -S guile --no-auto-compile -s
!#
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

;; A tiny mock of the Byggsteg HTTP API, used by test/run-tests.bash.
;;
;; It answers the three endpoints the pipeline steps call, and reads the
;; scenario it should play from <state-dir>/scenario on every request, so a
;; test can ask for a login failure, a job that fails, a job that never
;; finishes, and so on:
;;
;;   success           one in-progress poll, then success (with base64 log-data)
;;   failure           one in-progress poll, then failure (with base64 log-data)
;;   timeout           always in-progress
;;   login-error       the login endpoint answers 500
;;   login-no-token    the login endpoint answers 200 without a token header
;;   submit-error      the submit endpoint answers 500
;;   submit-not-json   the submit endpoint answers 200 with a non-JSON body
;;   submit-no-log-id  the submit endpoint answers 200 without a log-id
;;   status-not-json   the status endpoint answers 200 with a non-JSON body
;;
;; Only the test suite uses this; the images never do.  It is written in Guile
;; -- the language Maak, which runs the suite, already needs -- so the tests
;; need no runtime the project does not already use.
;;
;; Usage: guile --no-auto-compile test/mock-byggsteg.scm <port> <state-dir>

(use-modules (web server)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (ice-9 format)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

;; ====== Constants ======

(define token
  "test-token-123")

(define email
  "user@example.org")

(define password
  "s3cret")

(define log-id
  "abc-123")

(define log-output
  "hello from the byggsteg job\n")

(define args
  (cdr (command-line)))

(define port
  (if (pair? args) (string->number (car args)) 8799))

(define state-dir
  (if (and (pair? args) (pair? (cdr args))) (cadr args) "."))

;; ====== Little helpers ======

;; base64, hand-rolled: this Guile ships no base64 module, and the client
;; base64-decodes the log-data the way Byggsteg encodes it.
(define base64-chars
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (base64-encode-string str)
  (let* ((bytes (string->utf8 str))
         (len (bytevector-length bytes)))
    (let loop ((i 0) (out '()))
      (if (>= i len)
          (apply string-append (reverse out))
          (let* ((b0 (bytevector-u8-ref bytes i))
                 (b1 (if (< (+ i 1) len) (bytevector-u8-ref bytes (+ i 1)) #f))
                 (b2 (if (< (+ i 2) len) (bytevector-u8-ref bytes (+ i 2)) #f))
                 (n (logior (ash b0 16)
                            (if b1 (ash b1 8) 0)
                            (if b2 b2 0)))
                 (c0 (string-ref base64-chars (logand (ash n -18) 63)))
                 (c1 (string-ref base64-chars (logand (ash n -12) 63)))
                 (c2 (if b1 (string-ref base64-chars (logand (ash n -6) 63)) #\=))
                 (c3 (if b2 (string-ref base64-chars (logand n 63)) #\=)))
            (loop (+ i 3) (cons (string c0 c1 c2 c3) out)))))))

;; The body arrives as a bytevector (or #f when there is none).
(define (body->string body)
  (cond ((not body) "")
        ((string? body) body)
        ((bytevector? body) (utf8->string body))
        ((port? body) (get-string-all body))
        (else "")))

;; A urlencoded body as an alist of field name to value.
(define (form-fields body)
  (if (string-null? body)
      '()
      (map (lambda (pair)
             (let ((eq (string-index pair #\=)))
               (if eq
                   (cons (uri-decode (substring pair 0 eq))
                         (uri-decode (substring pair (+ eq 1) (string-length pair))))
                   (cons (uri-decode pair) ""))))
           (filter (lambda (pair) (positive? (string-length pair)))
                   (string-split body #\&)))))

(define (respond code content-type body)
  (values (build-response #:code code
                          #:headers (list (cons 'content-type content-type)))
          body))

(define (respond-text code body)
  (respond code '(text/plain) body))

(define (respond-json code body)
  (respond code '(application/json) body))

;; ====== Scenario state ======

(define last-scenario #f)
(define polls (make-hash-table))

(define (scenario)
  (catch #t
         (lambda ()
           (string-trim (call-with-input-file (format #f "~a/scenario" state-dir)
                          get-string-all)))
         (lambda args "success")))

;; How many times the current scenario has polled the job, counted from one and
;; kept per log id, so a health probe against another id does not use up the
;; job's first poll.  A change of scenario resets the counts, so each group of
;; tests starts fresh.  The count the job reached is written out, so a test can
;; check that the step really polled through an in-progress answer.
(define (next-poll-number scenario id)
  (unless (equal? scenario last-scenario)
    (set! last-scenario scenario)
    (hash-clear! polls))
  (let ((number (+ 1 (hash-ref polls id 0))))
    (hash-set! polls id number)
    (when (equal? id log-id)
      (call-with-output-file (format #f "~a/poll-count.txt" state-dir)
        (lambda (port) (display number port))))
    number))

;; ====== Response bodies ======

(define (title-base64)
  (base64-encode-string "a title"))

(define (status-body success failure in-progress)
  (format #f
          "{\"success\": ~a, \"failure\": ~a, \"in-progress\": ~a, \"log-id\": \"~a\", \"title\": \"~a\", \"log-data\": \"~a\"}"
          success failure in-progress log-id (title-base64)
          (base64-encode-string log-output)))

(define (submit-body)
  (format #f "{\"log-id\": \"~a\", \"title\": \"~a\"}" log-id (title-base64)))

;; ====== Endpoints ======

(define (handle-login fields)
  (let ((scenario-now (scenario)))
    (cond
      ((string=? scenario-now "login-error")
       (respond-text 500 "login failed"))
      ;; A 200 the step cannot use: it is authenticated, but told nothing.
      ((string=? scenario-now "login-no-token")
       (respond-text 200 "ok"))
      ((and (equal? (assoc-ref fields "email") email)
            (equal? (assoc-ref fields "password") password))
       (values (build-response
                #:code 200
                #:headers (list (cons 'content-type '(text/plain))
                                (cons 'x-bewaking-byggsteg token)))
               "ok"))
      (else
       (respond-text 401 "bad credentials")))))

(define (handle-submit headers fields)
  (let ((scenario-now (scenario)))
    (cond
      ((string=? scenario-now "submit-error")
       (respond-text 500 "submit failed"))
      ((not (equal? (assq-ref headers 'x-bewaking-byggsteg) token))
       (respond-text 401 "no token"))
      ;; 200 answers the step cannot use: something that is not JSON at all
      ;; (an error page, a proxy's), and JSON that carries no log-id.
      ((string=? scenario-now "submit-not-json")
       (respond-text 200 "<html><body>upstream proxy said no</body></html>"))
      ((string=? scenario-now "submit-no-log-id")
       (respond-json 200 "{\"title\": \"a title\"}"))
      (else
       (call-with-output-file (format #f "~a/last-job-code.txt" state-dir)
         (lambda (port) (display (or (assoc-ref fields "job-code") "") port)))
       (respond-json 200 (submit-body))))))

(define (handle-log-status scenario path)
  (let* ((id (last (string-split path #\/)))
         (number (next-poll-number scenario id)))
    (cond
      ;; A 200 that is not a status at all: the step must fail on it, not poll
      ;; on it until the limit.
      ((string=? scenario "status-not-json")
       (respond-text 200 "<html><body>not a byggsteg status</body></html>"))
      ((or (string=? scenario "timeout") (= number 1))
       (respond-json 200 (status-body 0 0 1)))
      ((string=? scenario "failure")
       (respond-json 200 (status-body 0 1 0)))
      (else
       (respond-json 200 (status-body 1 0 0))))))

;; ====== The handler ======

(define (handler request body)
  (let* ((method (request-method request))
         (path (uri-path (request-uri request)))
         (headers (request-headers request))
         (scenario-now (scenario))
         (fields (form-fields (body->string body))))
    (cond
      ((and (eq? method 'POST) (string=? path "/api/v1/login"))
       (handle-login fields))
      ((and (eq? method 'POST) (string=? path "/api/v1/jobs/manage/submit"))
       (handle-submit headers fields))
      ((and (eq? method 'GET) (string-prefix? "/api/v1/logs/" path))
       (handle-log-status scenario-now path))
      (else
       (respond-text 404 "not found")))))

;; ====== Run ======

(run-server handler 'http (list #:host "127.0.0.1" #:port port))
