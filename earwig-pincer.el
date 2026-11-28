;;; earwig-pincer.el --- Recording through Pincer, and its wake word  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 thndrbrrr

;; Author: thndrbrrr <thndrbrrr@gmail.com>
;; URL: https://github.com/thndrbrrr/earwig
;; Assisted-by: Claude:claude-opus-5-5

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Experimental.  Pincer, a helper program
;; (https://github.com/thndrbrrr/earwig-pincer), records the microphone all the time, keeps the
;; last few seconds, and listens for a wake word with openWakeWord,
;; using a few percent of one core.  `earwig-pincer-command' starts
;; it; Earwig talks to it in JSON lines.  It serves two purposes, each
;; on its own or both:
;;
;; - A recorder, `pincer' in `earwig-recorder', alongside sox and
;;   ffmpeg.  Its audio is always flowing, so a recording loses nothing
;;   at its start, and begins `earwig-pincer-key-pre-roll' seconds
;;   before the key was pressed.  It streams as sox does.  Runs while
;;   `earwig-mode' is on.
;;
;; - Voice commands after a wake word, with `earwig-listen-mode'.  The
;;   wake words are `earwig-wake-words', as they're transcribed; Pincer's
;;   model must hear the same.  Outside dictation, the command is
;;   recorded through Pincer from `earwig-pincer-pre-roll' seconds
;;   before the wake word was heard, so the wake word and what follows
;;   are all there, however quickly they're said.  From then on it's a
;;   voice command as one started with a command key: shown as you say
;;   it, stopped at the pause after it (`earwig-command-pause'), and
;;   run.  What was transcribed up to the wake word is dropped.
;;
;;   While dictating with the `pincer' recorder, the wake word cuts the
;;   dictation where it was said, without a pause first
;;   (`earwig-stream-wake', earwig-stream.el): Pincer's positions are
;;   bytes of the recording, less where it started (`from' in its
;;   `started' event).  With another recorder, the wake words work as
;;   when Pincer doesn't listen, after a pause.  The wake word does
;;   nothing while Earwig transcribes a recording that has stopped.
;;
;; Either way, Pincer runs only while `earwig-mode' is on: turning that
;; off stops it, and with it `earwig-listen-mode'.
;;
;; A recording through the helper is a process, as one by sox is, so the
;; rest of Earwig needn't tell them apart: a pipe process with no other
;; use stands for it, live while it records.  Stopping it
;; (`earwig--stop-recorder', by its `earwig-stop' property) asks the
;; helper to stop; once the helper says it has, the process is deleted,
;; and its sentinel finds the recording complete.
;;
;; The design, and what's planned, is in docs/roadmap/wake-word.md.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'earwig)

(defgroup earwig-pincer nil
  "Recording through Pincer, and voice commands after its wake word."
  :group 'earwig
  :prefix "earwig-pincer")

(defcustom earwig-pincer-command nil
  "The command that starts Pincer, as a list of strings.
Pincer is at https://github.com/thndrbrrr/earwig-pincer.  Installed as
its README says:

  (setopt earwig-pincer-command \\='(\"earwig-pincer\" \"--model\" \"hey_jarvis\"))

Earwig adds --device with `earwig-input-device'; it takes effect when
Pincer next starts.  Options such as --model and --threshold go
here."
  :type '(choice (const :tag "Not set" nil) (repeat string)))

(defcustom earwig-pincer-key-pre-roll 0.25
  "Seconds before a recording starts that the `pincer' recorder records from.
For a recording started with a key, so a word begun as the key went
down isn't cut; with push-to-talk, recording only starts once the key
is known to be held.  See `earwig-recorder'."
  :type 'number)

(defcustom earwig-pincer-pre-roll 1.5
  "Seconds before the wake word was heard that its command is recorded from.
It's heard as it ends, or, said straight before a command, up to half a
second into the command; this must cover that and the wake word.  More
of what was said before only costs transcribing it.  At most
Pincer's --buffer, 3 s by default."
  :type 'number)

(defvar earwig-listen-mode)
(defvar earwig-pincer--process nil "Pincer process.")
(defvar earwig-pincer--ready nil "Non-nil once Pincer has said it's ready.")
(defvar earwig-pincer--pending "" "Output of Pincer not yet a whole line.")
(defvar earwig-pincer--recording nil
  "The process standing for Pincer's recording, while it records.")
(defvar earwig-pincer--started nil
  "Non-nil once Pincer has said it started the recording.")
(defvar earwig-pincer--from 0
  "Pincer's position where the recording starts: its first byte.")
(defvar earwig-pincer--stopped-count 0
  "How many times Pincer has said a recording stopped.")
(defvar earwig-pincer--timeout nil "Timer stopping a recording at `earwig-recording-timeout'.")

;;;; Pincer process

(defun earwig-pincer--wanted-p ()
  "Non-nil if Pincer should run: it records, or listens for its wake word.
Only while `earwig-mode' is on, so turning that off closes the microphone."
  (and (bound-and-true-p earwig-mode)
       (or (bound-and-true-p earwig-listen-mode)
           (eq (earwig--recorder) 'pincer))))

(defun earwig-pincer-update ()
  "Start Pincer if it's wanted and not running; stop it if it's not wanted.
It's wanted while `earwig-mode' is on, with `earwig-listen-mode' or the
`pincer' recorder."
  (cond
   ((not (earwig-pincer--wanted-p))
    (earwig-pincer--quit))
   ((not (process-live-p earwig-pincer--process))
    (earwig-pincer--start))))

(defun earwig-pincer--start ()
  "Start Pincer, saying with what command."
  (unless earwig-pincer-command
    (user-error "Set `earwig-pincer-command' to start earwig-pincer"))
  (let ((command (append earwig-pincer-command
                         (list "--device" (or earwig-input-device "default")))))
    (message "Starting Pincer: %s" (combine-and-quote-strings command))
    (earwig-pincer--log "#" (concat "start: " (combine-and-quote-strings command)))
    (setq earwig-pincer--pending ""
          earwig-pincer--ready nil
          earwig-pincer--process
          (make-process :name "earwig-pincer"
                        :command command
                        :connection-type 'pipe
                        :noquery t
                        :stderr (get-buffer-create " *earwig-pincer*")
                        :filter #'earwig-pincer--filter
                        :sentinel #'earwig-pincer--sentinel))))

(defun earwig-pincer-ensure ()
  "Have Pincer running and ready, starting it and waiting if need be.
Signal an error if it isn't ready in 30 seconds."
  (if (process-live-p earwig-pincer--process)
      (unless earwig-pincer--ready
        (message "Starting Pincer..."))
    ;; Which says so, with its command
    (earwig-pincer--start))
  (unless earwig-pincer--ready
    (with-timeout (30 (error "Pincer isn't ready after 30 s; M-x earwig-pincer-log shows its output"))
      (while (and (not earwig-pincer--ready) (process-live-p earwig-pincer--process))
        (accept-process-output earwig-pincer--process 0.1)))
    (unless earwig-pincer--ready
      (error "Pincer stopped: %s" (earwig-pincer--stderr))))
  earwig-pincer--process)

(defun earwig-pincer--quit ()
  "Stop Pincer: close its input, and kill it if it hasn't exited in 3 s."
  (let ((proc earwig-pincer--process))
    (when (process-live-p proc)
      (process-send-eof proc)
      (run-at-time 3 nil (lambda ()
                           (when (process-live-p proc)
                             (delete-process proc)))))))

(defun earwig-pincer--send (command)
  "Send Pincer COMMAND, an alist."
  (when (process-live-p earwig-pincer--process)
    (let ((line (json-serialize command)))
      (earwig-pincer--log ">" line)
      (process-send-string earwig-pincer--process (concat line "\n")))))

(defun earwig-pincer--log (mark line)
  "Log LINE after MARK, see `earwig-log'.
MARK is \"<\" for what Pincer wrote, \">\" for what Earwig sent it, and
\"#\" for Pincer starting and exiting."
  (earwig--log (pcase mark ("<" "pincer<") (">" "pincer>") (_ "pincer")) "%s" line))

;;;###autoload
(defun earwig-pincer-log ()
  "Show what Pincer has written to stderr: its log and errors."
  (interactive)
  (display-buffer (get-buffer-create " *earwig-pincer*")))

(defun earwig-pincer--stderr ()
  "Return the end of what Pincer wrote to stderr."
  (with-current-buffer (get-buffer-create " *earwig-pincer*")
    (string-trim (buffer-substring (max (point-min) (- (point-max) 500)) (point-max)))))

(defun earwig-pincer--filter (_proc output)
  "Act on each event in Pincer's OUTPUT, a JSON object a line."
  (setq earwig-pincer--pending (concat earwig-pincer--pending output))
  (let ((lines (split-string earwig-pincer--pending "\n")))
    (setq earwig-pincer--pending (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-blank-p line)
        (earwig-pincer--log "<" line)
        ;; An error here would only say the filter failed
        (condition-case err
            (earwig-pincer--event (json-parse-string line :object-type 'alist))
          (error (message "Pincer: %s: %s" (error-message-string err) line)))))))

(defun earwig-pincer--event (event)
  "Act on Pincer's EVENT, an alist."
  (let-alist event
    (pcase .event
      ("ready"
       (setq earwig-pincer--ready t)
       (when (bound-and-true-p earwig-listen-mode)
         (earwig-pincer--listening-message)))
      ("wake"
       (if (bound-and-true-p earwig-listen-mode)
           (earwig-pincer--wake .position)
         (earwig--log "wake" "ignored: listen mode is off")))
      ("started"
       (setq earwig-pincer--started t
             earwig-pincer--from .from))
      ("stopped"
       (cl-incf earwig-pincer--stopped-count)
       (earwig-pincer--stopped))
      ("error"
       (message "Pincer: %s" .message)
       ;; A recording it couldn't start won't stop either
       (unless earwig-pincer--started
         (earwig-pincer--stopped))))))

(defun earwig-pincer--sentinel (proc event)
  "Clean up once Pincer PROC has exited, as EVENT says."
  (unless (process-live-p proc)
    (earwig-pincer--log "#" (string-trim event))
    (setq earwig-pincer--ready nil)
    (earwig-pincer--stopped)
    (when (earwig-pincer--wanted-p)
      (let ((output (earwig-pincer--stderr))
            (listening (bound-and-true-p earwig-listen-mode)))
        (when listening
          (setq earwig-listen-mode nil))
        (message "%sPincer stopped%s"
                 (if listening "Earwig listen mode off: " "")
                 (if (string-empty-p output) "" (concat ": " output)))))))

;;;; Recording: the `pincer' recorder, and commands after the wake word

(defun earwig-pincer-record (file format sentinel &optional from)
  "Have Pincer record to FILE; return the process standing for it.
FORMAT is `raw' or `wav'.  From Pincer's position FROM, or from
`earwig-pincer-key-pre-roll' seconds ago.  SENTINEL is the process's,
run once the recording has stopped.  See the commentary."
  (earwig-pincer-ensure)
  (let ((proc (make-pipe-process :name "earwig-pincer-recording"
                                 :buffer (generate-new-buffer " *earwig-record*")
                                 :noquery t
                                 :sentinel sentinel)))
    (process-put proc 'earwig-stop #'earwig-pincer--stop-recording)
    (setq earwig-pincer--recording proc
          earwig-pincer--started nil
          earwig-pincer--from 0)
    (earwig-pincer--send
     `((command . "start") (path . ,file) (format . ,(symbol-name format))
       ,(if from
            `(from . ,from)
          `(back . ,(* 2 (round (* earwig-pincer-key-pre-roll 16000)))))))
    (when earwig-recording-timeout
      (setq earwig-pincer--timeout
            (run-at-time earwig-recording-timeout nil #'earwig-pincer--stop-recording proc)))
    ;; Pincer's audio is flowing already
    (setq earwig--audio-flowing t)
    proc))

(defun earwig-pincer--stop-recording (proc)
  "Have Pincer stop the recording PROC stands for.
PROC goes once it has, so its sentinel finds the recording complete."
  (if (process-live-p earwig-pincer--process)
      (earwig-pincer--send '((command . "stop")))
    (when (process-live-p proc)
      (delete-process proc))))

(defun earwig-pincer--stopped ()
  "Pincer's recording has stopped: so does the process standing for it."
  (when (timerp earwig-pincer--timeout)
    (cancel-timer earwig-pincer--timeout))
  (let ((proc earwig-pincer--recording))
    (setq earwig-pincer--timeout nil
          earwig-pincer--recording nil)
    (when (process-live-p proc)
      (delete-process proc))))

(defun earwig-pincer-record-test (file seconds)
  "Record SECONDS of raw audio to FILE through Pincer, for the setup check.
Return nil, or what went wrong."
  (condition-case err
      (let ((stopped earwig-pincer--stopped-count))
        (earwig-pincer-ensure)
        (earwig-pincer--send `((command . "start") (path . ,file) (format . "raw")))
        (sit-for seconds)
        (earwig-pincer--send '((command . "stop")))
        (with-timeout (5 "Pincer didn't stop recording")
          (while (= stopped earwig-pincer--stopped-count)
            (accept-process-output earwig-pincer--process 0.1))
          nil))
    (error (error-message-string err))))

;;;; Commands after the wake word

;;;###autoload
(define-minor-mode earwig-listen-mode
  "Listen for a wake word, and give the voice command said after it.
Starts `earwig-pincer-command', which keeps the microphone open.
`earwig-log' logs what Pincer and Earwig say to each other.  The
wake words are `earwig-wake-words', which must be the words Pincer's
model hears.  While dictating with Pincer as the recorder
\(`earwig-recorder'), the wake word gives a command at any moment,
without a pause first.  Goes with `earwig-mode': turning this on turns
that on, and turning that off turns this off.  Turned off, Pincer
stops, unless it's the recorder."
  :global t
  :group 'earwig-pincer
  (condition-case err
      (progn
        (when (and earwig-listen-mode (not (bound-and-true-p earwig-mode)))
          ;; Its body updates Pincer
          (earwig-mode 1))
        (earwig-pincer-update)
        (cond
         ((and earwig-listen-mode earwig-pincer--ready)
          (earwig-pincer--listening-message))
         (earwig-listen-mode
          (message "Earwig listen mode on: starting Pincer…"))
         ((earwig-pincer--wanted-p)
          (message "Earwig listen mode off; Pincer still records (earwig-recorder)"))
         (t
          (message "Earwig listen mode off"))))
    (error
     (setq earwig-listen-mode nil)
     (signal (car err) (cdr err)))))

(defun earwig-pincer--listening-message ()
  "Say that listen mode is on, and for which wake words."
  (message "Earwig listen mode on: listening for %s"
           (if earwig-wake-words
               (mapconcat (lambda (words) (format "\"%s\"" words)) earwig-wake-words " or ")
             "nothing: set `earwig-wake-words'")))

(defun earwig-pincer--wake (position)
  "Act on the wake word, heard at Pincer's POSITION.
While dictating through Pincer, cut the dictation there for the
command (`earwig-stream-wake'); otherwise, unless Earwig records or
transcribes, record the command after it."
  (cond
   ((and (earwig-stream-recording-p)
         (eq earwig--stream-process earwig-pincer--recording)
         earwig-pincer--started)
    (earwig-stream-wake (- position earwig-pincer--from)))
   ((or (earwig--recording-p) (earwig--record-transcribing-p) (earwig-stream-transcribing-p))
    (earwig--log "wake" "ignored: %s"
                 (cond ((earwig-stream-recording-p)
                        "dictation records, but not through Pincer, so it isn't cut")
                       ((earwig--recording-p) "a command or dictation records already")
                       (t "the last recording is still being transcribed"))))
   ((not (earwig-server-ready-p))
    (earwig--log-message "Wake word heard, but the speech server isn't running"))
   (t
    (let ((from (max 0 (- position (* 2 (round (* earwig-pincer-pre-roll 16000)))))))
      (with-current-buffer (window-buffer (selected-window))
        (setq earwig--mode 'command)
        (earwig--record from))))))

(defun earwig-pincer-after-wake-word (raw)
  "Return the transcription RAW from after the first of the wake words on.
Whatever the punctuation between the words of a wake word.  If RAW has
none of `earwig-wake-words', as Orukeet heard it as something else
\(\"Zella\", \"sell the\"), the commands it ends with
\(`earwig--split-at-command'); RAW as it is if it ends with none."
  (or (cdr (earwig--split-at-wake-word raw))
      (cdr (earwig--split-at-command (earwig-clean raw)))
      raw))

(provide 'earwig-pincer)
;;; earwig-pincer.el ends here
