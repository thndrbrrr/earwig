;;; earwig-listen.el --- Voice commands after a wake word, any time  -*- lexical-binding: t; -*-

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

;; Experimental.  With `earwig-listen-mode', the microphone stays open,
;; and saying a wake word gives a voice command, without a key.
;;
;; The listening is done by earwig-listener, a helper program in
;; earwig-listener/ (see its README.md), which `earwig-listener-command'
;; starts.  It records the microphone all the time, keeps the last few
;; seconds, and listens for the wake word with openWakeWord, using a few
;; percent of one core; the speech server only transcribes once the wake
;; word is heard.  When it is, Earwig has the helper record a voice
;; command from `earwig-listener-pre-roll' seconds before, so the wake
;; word and what follows it are all there, however quickly they're
;; said.  From then on it's a voice command as one started with a
;; command key: shown as you say it, stopped at the pause after it (see
;; `earwig-listener-command-pause'), and run.  What was transcribed up to
;; the wake word is dropped (`earwig-listener-wake-words').
;;
;; Only commands for now: the wake word is ignored while Earwig records
;; or transcribes, and dictation started with a key is still recorded by
;; sox.  During dictation, the wake words work as `earwig-wake-words'
;; do: after a pause.  The design, and what's planned, is in
;; docs/roadmap/wake-word.md.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'earwig)

(defgroup earwig-listen nil
  "Voice commands after a wake word, with the microphone always open."
  :group 'earwig
  :prefix "earwig-listen")

(defcustom earwig-listener-command nil
  "The command that starts earwig-listener, as a list of strings.
For the one in Earwig's repository, set up with uv (see
earwig-listener/README.md):

  (setopt earwig-listener-command
          \\='(\"uv\" \"run\" \"--project\" \"/path/to/earwig/earwig-listener\"
            \"earwig-listener\" \"--model\" \"hey_jarvis\"))

Earwig adds --device with `earwig-input-device'.  Options such as
--model and --threshold go here."
  :type '(choice (const :tag "Not set" nil) (repeat string)))

(defcustom earwig-listener-wake-words '("hey jarvis")
  "The wake words the listener's models hear, as transcribed.
What's transcribed up to the first of them is dropped from the command,
whatever the punctuation between their words.  While listening, they
also give a command while dictating, as `earwig-wake-words' do."
  :type '(repeat string))

(defcustom earwig-listener-pre-roll 1.5
  "Seconds before the wake word was heard that its command is recorded from.
The listener hears it as it ends, so this must be longer than it takes
to say; more of what was said before only costs transcribing it.  At
most the listener's --buffer, 3 s by default."
  :type 'number)

(defcustom earwig-listener-command-pause 1.0
  "Seconds of silence that end a command given after the wake word.
Once it's a complete command; as `earwig-command-auto-stop', which is
used instead when set."
  :type 'number)

(defvar earwig-listen--process nil "The listener process.")
(defvar earwig-listen--pending "" "Output of the listener not yet a whole line.")
(defvar earwig-listen--recording nil
  "The process standing for the listener's recording, while it records.
A pipe process with no other use, so the recording is a process as sox
is: live while recording, and its sentinel runs once it has stopped.")
(defvar earwig-listen--timeout nil "Timer stopping a recording at `earwig-recording-timeout'.")

;;;; The listener

;;;###autoload
(define-minor-mode earwig-listen-mode
  "Listen for a wake word, and give the voice command said after it.
Starts `earwig-listener-command', which keeps the microphone open.
See `earwig-listener-wake-words'."
  :global t
  :group 'earwig-listen
  (if earwig-listen-mode
      (condition-case err
          (earwig-listen--start)
        (error
         (setq earwig-listen-mode nil)
         (signal (car err) (cdr err))))
    (earwig-listen--quit)))

(defun earwig-listen--start ()
  "Start the listener."
  (unless earwig-listener-command
    (user-error "Set `earwig-listener-command' to start earwig-listener"))
  (unless (process-live-p earwig-listen--process)
    (setq earwig-listen--pending ""
          earwig-listen--process
          (make-process :name "earwig-listener"
                        :command (append earwig-listener-command
                                         (list "--device" (or earwig-input-device "default")))
                        :connection-type 'pipe
                        :noquery t
                        :stderr (get-buffer-create " *earwig-listener*")
                        :filter #'earwig-listen--filter
                        :sentinel #'earwig-listen--sentinel))))

(defun earwig-listen--quit ()
  "Stop the listener."
  (when (process-live-p earwig-listen--process)
    (process-send-eof earwig-listen--process)))

(defun earwig-listen--send (command)
  "Send the listener COMMAND, an alist."
  (when (process-live-p earwig-listen--process)
    (process-send-string earwig-listen--process (concat (json-serialize command) "\n"))))

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
       (message "Listening for %s" (string-join earwig-listener-wake-words " or ")))
      ("wake" (earwig-listen--wake .position))
      ("stopped" (earwig-listen--stopped))
      ("error" (message "Earwig listener: %s" .message)))))

(defun earwig-listen--sentinel (proc _event)
  "Clean up once the listener PROC has exited."
  (unless (process-live-p proc)
    (earwig-listen--stopped)
    (when earwig-listen-mode
      (setq earwig-listen-mode nil)
      (let ((output (with-current-buffer (get-buffer-create " *earwig-listener*")
                      (string-trim (buffer-substring (max (point-min) (- (point-max) 500))
                                                     (point-max))))))
        (message "Earwig listener stopped%s"
                 (if (string-empty-p output) "" (concat ": " output)))))))

;;;; Recording a command

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

(defun earwig-listen--record (file from sentinel)
  "Have the listener record to the WAV FILE from its position FROM.
Return the process standing for the recording, with SENTINEL; see
`earwig-listen--recording'."
  (let ((proc (make-pipe-process :name "earwig-listener-recording"
                                 :buffer (generate-new-buffer " *earwig-record*")
                                 :noquery t
                                 :sentinel sentinel)))
    (process-put proc 'earwig-stop #'earwig-listen--stop-recording)
    (setq earwig-listen--recording proc)
    (earwig-listen--send `((command . "start") (path . ,file) (from . ,from) (format . "wav")))
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

(defun earwig-listen--after-wake-word (raw)
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
