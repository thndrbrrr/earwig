;;; earwig-listen.el --- Recording through earwig-listener, and its wake word  -*- lexical-binding: t; -*-

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

;; Experimental.  earwig-listener, a helper program in earwig-listener/
;; (see its README.md), records the microphone all the time, keeps the
;; last few seconds, and listens for a wake word with openWakeWord,
;; using a few percent of one core.  `earwig-listener-command' starts
;; it; Earwig talks to it in JSON lines.  It serves two purposes, each
;; on its own or both:
;;
;; - A recorder, `listener' in `earwig-recorder', alongside sox and
;;   ffmpeg.  Its audio is always flowing, so a recording loses nothing
;;   at its start, and begins `earwig-listener-key-pre-roll' seconds
;;   before the key was pressed.  It streams as sox does.  Runs while
;;   `earwig-mode' is on.
;;
;; - Voice commands after a wake word, with `earwig-listen-mode': the
;;   command is recorded through it from `earwig-listener-pre-roll'
;;   seconds before the wake word was heard, so the wake word and what
;;   follows are all there, however quickly they're said.  From then on
;;   it's a voice command as one started with a command key: shown as
;;   you say it, stopped at the pause after it (see
;;   `earwig-listener-command-pause'), and run.  What was transcribed up
;;   to the wake word is dropped (`earwig-listener-wake-words').  The
;;   wake word does nothing while Earwig records or transcribes; while
;;   dictating, the wake words work as `earwig-wake-words' do, after a
;;   pause.  That's with any recorder.
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

(defgroup earwig-listen nil
  "Recording through earwig-listener, and voice commands after its wake word."
  :group 'earwig
  :prefix "earwig-listen")

(defcustom earwig-listener-command nil
  "The command that starts earwig-listener, as a list of strings.
For the one in Earwig's repository, set up with uv (see
earwig-listener/README.md):

  (setopt earwig-listener-command
          \\='(\"uv\" \"run\" \"--project\" \"/path/to/earwig/earwig-listener\"
            \"earwig-listener\" \"--model\" \"hey_jarvis\"))

Earwig adds --device with `earwig-input-device'; it takes effect when
the listener next starts.  Options such as --model and --threshold go
here."
  :type '(choice (const :tag "Not set" nil) (repeat string)))

(defcustom earwig-listener-key-pre-roll 0.25
  "Seconds before a recording starts that the `listener' recorder records from.
For a recording started with a key, so a word begun as the key went
down isn't cut; with push-to-talk, recording only starts once the key
is known to be held.  See `earwig-recorder'."
  :type 'number)

(defcustom earwig-listener-wake-words '("hey jarvis")
  "The wake words the listener's models hear, as transcribed.
What's transcribed up to the first of them is dropped from the command,
whatever the punctuation between their words.  With
`earwig-listen-mode', they also give a command while dictating, as
`earwig-wake-words' do."
  :type '(repeat string))

(defcustom earwig-listener-pre-roll 1.5
  "Seconds before the wake word was heard that its command is recorded from.
It's heard as it ends, or, said straight before a command, up to half a
second into the command; this must cover that and the wake word.  More
of what was said before only costs transcribing it.  At most the
listener's --buffer, 3 s by default."
  :type 'number)

(defcustom earwig-listener-command-pause 1.0
  "Seconds of silence that end a command given after the wake word.
Once it's a complete command; as `earwig-command-auto-stop', which is
used instead when set."
  :type 'number)

(defvar earwig-listen--process nil "The listener process.")
(defvar earwig-listen--ready nil "Non-nil once the listener has said it's ready.")
(defvar earwig-listen--pending "" "Output of the listener not yet a whole line.")
(defvar earwig-listen--recording nil
  "The process standing for the listener's recording, while it records.")
(defvar earwig-listen--started nil
  "Non-nil once the listener has said it started the recording.")
(defvar earwig-listen--stopped-count 0
  "How many times the listener has said a recording stopped.")
(defvar earwig-listen--timeout nil "Timer stopping a recording at `earwig-recording-timeout'.")

;;;; The listener process

(defun earwig-listen--wanted-p ()
  "Non-nil if the listener should run: it records, or listens for its wake word."
  (or (bound-and-true-p earwig-listen-mode)
      (and (bound-and-true-p earwig-mode) (eq (earwig--recorder) 'listener))))

(defun earwig-listen-update ()
  "Start the listener if it's wanted and not running; stop it if it's not wanted.
It's wanted with `earwig-listen-mode', or `earwig-mode' with the
`listener' recorder."
  (cond
   ((not (earwig-listen--wanted-p))
    (earwig-listen--quit))
   ((not (process-live-p earwig-listen--process))
    (earwig-listen--start))))

(defun earwig-listen--start ()
  "Start the listener."
  (unless earwig-listener-command
    (user-error "Set `earwig-listener-command' to start earwig-listener"))
  (setq earwig-listen--pending ""
        earwig-listen--ready nil
        earwig-listen--process
        (make-process :name "earwig-listener"
                      :command (append earwig-listener-command
                                       (list "--device" (or earwig-input-device "default")))
                      :connection-type 'pipe
                      :noquery t
                      :stderr (get-buffer-create " *earwig-listener*")
                      :filter #'earwig-listen--filter
                      :sentinel #'earwig-listen--sentinel)))

(defun earwig-listen-ensure ()
  "Have the listener running and ready, starting it and waiting if need be.
Signal an error if it isn't ready in 30 seconds."
  (unless (process-live-p earwig-listen--process)
    (earwig-listen--start))
  (unless earwig-listen--ready
    (message "Starting earwig-listener...")
    (with-timeout (30 (error "earwig-listener isn't ready after 30 s; M-x earwig-listener-log shows its output"))
      (while (and (not earwig-listen--ready) (process-live-p earwig-listen--process))
        (accept-process-output earwig-listen--process 0.1)))
    (unless earwig-listen--ready
      (error "earwig-listener stopped: %s" (earwig-listen--stderr))))
  earwig-listen--process)

(defun earwig-listen--quit ()
  "Stop the listener."
  (when (process-live-p earwig-listen--process)
    (process-send-eof earwig-listen--process)))

(defun earwig-listen--send (command)
  "Send the listener COMMAND, an alist."
  (when (process-live-p earwig-listen--process)
    (process-send-string earwig-listen--process (concat (json-serialize command) "\n"))))

;;;###autoload
(defun earwig-listener-log ()
  "Show what earwig-listener has written to stderr: its log and errors."
  (interactive)
  (display-buffer (get-buffer-create " *earwig-listener*")))

(defun earwig-listen--stderr ()
  "Return the end of what the listener wrote to stderr."
  (with-current-buffer (get-buffer-create " *earwig-listener*")
    (string-trim (buffer-substring (max (point-min) (- (point-max) 500)) (point-max)))))

(defun earwig-listen--filter (_proc output)
  "Act on each event in the listener's OUTPUT, a JSON object a line."
  (setq earwig-listen--pending (concat earwig-listen--pending output))
  (let ((lines (split-string earwig-listen--pending "\n")))
    (setq earwig-listen--pending (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-blank-p line)
        ;; An error here would only say the filter failed
        (condition-case err
            (earwig-listen--event (json-parse-string line :object-type 'alist))
          (error (message "Earwig listener: %s: %s" (error-message-string err) line)))))))

(defun earwig-listen--event (event)
  "Act on the listener's EVENT, an alist."
  (let-alist event
    (pcase .event
      ("ready"
       (setq earwig-listen--ready t)
       (when (bound-and-true-p earwig-listen-mode)
         (message "Listening for %s" (string-join earwig-listener-wake-words " or "))))
      ("wake"
       (when (bound-and-true-p earwig-listen-mode)
         (earwig-listen--wake .position)))
      ("started" (setq earwig-listen--started t))
      ("stopped"
       (cl-incf earwig-listen--stopped-count)
       (earwig-listen--stopped))
      ("error"
       (message "Earwig listener: %s" .message)
       ;; A recording it couldn't start won't stop either
       (unless earwig-listen--started
         (earwig-listen--stopped))))))

(defun earwig-listen--sentinel (proc _event)
  "Clean up once the listener PROC has exited."
  (unless (process-live-p proc)
    (setq earwig-listen--ready nil)
    (earwig-listen--stopped)
    (when (earwig-listen--wanted-p)
      (let ((output (earwig-listen--stderr)))
        (when (bound-and-true-p earwig-listen-mode)
          (setq earwig-listen-mode nil))
        (message "Earwig listener stopped%s"
                 (if (string-empty-p output) "" (concat ": " output)))))))

;;;; Recording: the `listener' recorder, and commands after the wake word

(defun earwig-listen-record (file format sentinel &optional from)
  "Have the listener record to FILE; return the process standing for it.
FORMAT is `raw' or `wav'.  From the listener's position FROM, or from
`earwig-listener-key-pre-roll' seconds ago.  SENTINEL is the process's,
run once the recording has stopped.  See the commentary."
  (earwig-listen-ensure)
  (let ((proc (make-pipe-process :name "earwig-listener-recording"
                                 :buffer (generate-new-buffer " *earwig-record*")
                                 :noquery t
                                 :sentinel sentinel)))
    (process-put proc 'earwig-stop #'earwig-listen--stop-recording)
    (setq earwig-listen--recording proc
          earwig-listen--started nil)
    (earwig-listen--send
     `((command . "start") (path . ,file) (format . ,(symbol-name format))
       ,(if from
            `(from . ,from)
          `(back . ,(* 2 (round (* earwig-listener-key-pre-roll 16000)))))))
    (when earwig-recording-timeout
      (setq earwig-listen--timeout
            (run-at-time earwig-recording-timeout nil #'earwig-listen--stop-recording proc)))
    ;; The listener's audio is flowing already
    (setq earwig--audio-flowing t)
    proc))

(defun earwig-listen--stop-recording (proc)
  "Have the listener stop the recording PROC stands for.
PROC goes once it has, so its sentinel finds the recording complete."
  (if (process-live-p earwig-listen--process)
      (earwig-listen--send '((command . "stop")))
    (when (process-live-p proc)
      (delete-process proc))))

(defun earwig-listen--stopped ()
  "The listener's recording has stopped: so does the process standing for it."
  (when (timerp earwig-listen--timeout)
    (cancel-timer earwig-listen--timeout))
  (let ((proc earwig-listen--recording))
    (setq earwig-listen--timeout nil
          earwig-listen--recording nil)
    (when (process-live-p proc)
      (delete-process proc))))

(defun earwig-listen-record-test (file seconds)
  "Record SECONDS of raw audio to FILE through the listener, for the setup check.
Return nil, or what went wrong."
  (condition-case err
      (let ((stopped earwig-listen--stopped-count))
        (earwig-listen-ensure)
        (earwig-listen--send `((command . "start") (path . ,file) (format . "raw")))
        (sit-for seconds)
        (earwig-listen--send '((command . "stop")))
        (with-timeout (5 "the listener didn't stop recording")
          (while (= stopped earwig-listen--stopped-count)
            (accept-process-output earwig-listen--process 0.1))
          nil))
    (error (error-message-string err))))

;;;; Commands after the wake word

;;;###autoload
(define-minor-mode earwig-listen-mode
  "Listen for a wake word, and give the voice command said after it.
Starts `earwig-listener-command', which keeps the microphone open.
See `earwig-listener-wake-words'."
  :global t
  :group 'earwig-listen
  (condition-case err
      (progn
        (earwig-listen-update)
        (when (and earwig-listen-mode earwig-listen--ready)
          (message "Listening for %s" (string-join earwig-listener-wake-words " or "))))
    (error
     (setq earwig-listen-mode nil)
     (signal (car err) (cdr err)))))

(defun earwig-listen--wake (position)
  "Record the command after the wake word, heard at the listener's POSITION."
  (cond
   ((or (earwig--recording-p) (earwig--record-transcribing-p) (earwig-stream-transcribing-p))
    nil)
   ((not (earwig-server-ready-p))
    (message "Wake word heard, but the speech server isn't running"))
   (t
    (let ((from (max 0 (- position (* 2 (round (* earwig-listener-pre-roll 16000)))))))
      (with-current-buffer (window-buffer (selected-window))
        (setq earwig--mode 'command)
        (earwig--record from))))))

(defun earwig-listen-after-wake-word (raw)
  "Return the transcription RAW from after the first of the wake words on.
RAW as it is if it has none of `earwig-listener-wake-words'."
  (let ((case-fold-search t)
        (regexp (concat "\\<\\(?:"
                        (mapconcat (lambda (words)
                                     (replace-regexp-in-string
                                      " +" "[[:punct:][:space:]]+" (regexp-quote words)))
                                   earwig-listener-wake-words "\\|")
                        "\\)\\>[[:punct:]]*[[:space:]]*")))
    (if (and earwig-listener-wake-words (string-match regexp raw))
        (substring raw (match-end 0))
      raw)))

(provide 'earwig-listen)
;;; earwig-listen.el ends here
