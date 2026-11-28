;;; earwig-server.el --- The speech server, and starting it from Emacs  -*- lexical-binding: t; -*-

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

;; The speech server is a separate program that transcribes recordings;
;; Earwig doesn't include or install one.  Earwig sends each recording
;; to it at `earwig-speech-server-base-url', as a 16 kHz mono WAV file
;; with the form fields `model' and response_format=text.  Any server
;; will do that answers OpenAI's POST /v1/audio/transcriptions with the
;; transcription as plain text, and listens only once it's ready to
;; transcribe; Orukeet's local_server.py is one.
;;
;; With `earwig-speech-server-command', `earwig-speech-server-start'
;; runs the server as an Emacs subprocess, so speech recognition only
;; uses CPU and memory while it's wanted.  `earwig-mode' starts it, in
;; the background, unless `earwig-speech-server-autostart' is nil.  Without it, start the server
;; yourself, e.g. at login.  `earwig-check-setup' checks either way.

;;; Code:

(require 'subr-x)
(require 'url-parse)
(require 'earwig-platform)
(require 'earwig-log)

(defgroup earwig-speech-server nil
  "The separate speech server Earwig sends recordings to."
  :group 'earwig
  :prefix "earwig-speech-server-")

(defcustom earwig-speech-server-base-url "http://127.0.0.1:18178"
  "Base URL of the speech server Earwig sends recordings to.
Recordings are sent to /v1/audio/transcriptions under it, as to
OpenAI's API."
  :type 'string)

(defcustom earwig-speech-server-model "orukeet"
  "Model name sent to the server with each recording."
  :type 'string)

(defcustom earwig-speech-server-command nil
  "Program and arguments to run the speech server from Emacs, or nil.
`earwig-speech-server-start' runs it as a subprocess.  With nil, Earwig
doesn't start or stop the server: start it yourself.
A program with a directory in it, as \".venv/bin/python\", is relative
to `earwig-speech-server-directory'; otherwise it's looked for on the
variable `exec-path'.
The server must listen at `earwig-speech-server-base-url'.  For Orukeet
installed in ~/.local/share/orukeet:

  (setopt earwig-speech-server-directory \"~/.local/share/orukeet\"
          earwig-speech-server-command
          \='(\".venv/bin/python\" \"local_server.py\"
            \"--installation\" \"installation.json\" \"--port\" \"18178\"))"
  :type '(choice (const :tag "None: started outside Emacs" nil)
                 (repeat :tag "Program and arguments" string)))

(defcustom earwig-speech-server-directory nil
  "Directory `earwig-speech-server-command' runs in, or nil for the home directory."
  :type '(choice (const :tag "Home directory" nil) directory))

(defcustom earwig-speech-server-autostart t
  "Non-nil to start the speech server as `earwig-mode' is turned on.
With `earwig-speech-server-command', unless a server already answers
at `earwig-speech-server-base-url'.  It loads in the background.  With
nil, recording while no server answers offers to start it."
  :type 'boolean)

(defcustom earwig-speech-server-stop-timeout 10
  "Seconds to wait for a clean shutdown before killing the server."
  :type 'number)

(defvar earwig-server-buffer-name "*earwig speech server*"
  "Buffer collecting the server's log output.")

(defvar earwig-server--process nil
  "The server process started by `earwig-speech-server-start', if any.")

(defvar earwig-server--ready-timer nil
  "Timer waiting for the server started to listen.")

(defun earwig-server-url (&optional path)
  "Return the server's base URL, with PATH appended if given."
  (concat (string-remove-suffix "/" earwig-speech-server-base-url) (or path "")))

(defun earwig-server--address ()
  "Return (HOST . PORT) of `earwig-speech-server-base-url'."
  (let ((url (url-generic-parse-url earwig-speech-server-base-url)))
    (cons (url-host url) (url-port url))))

(defun earwig-server--directory ()
  "Return the directory `earwig-speech-server-command' runs in."
  (file-name-as-directory (expand-file-name (or earwig-speech-server-directory "~"))))

(defun earwig-server--program ()
  "Return the program of `earwig-speech-server-command'.
Expanded in `earwig-speech-server-directory' if it has a directory in it."
  (let ((program (car earwig-speech-server-command)))
    (if (and program (file-name-directory program))
        (expand-file-name program (earwig-server--directory))
      program)))

(defun earwig-server-running-p ()
  "Non-nil if the server process started from Emacs is alive."
  (process-live-p earwig-server--process))

(defun earwig-server--port-in-use-p ()
  "Non-nil if something accepts connections at `earwig-speech-server-base-url'."
  (pcase-let ((`(,host . ,port) (earwig-server--address)))
    (condition-case nil
        (progn
          (delete-process
           (make-network-process :name "earwig-server-probe" :host host :service port))
          t)
      (file-error nil))))

(defun earwig-server-ready-p ()
  "Non-nil if a server is accepting requests at `earwig-speech-server-base-url'.
The server should only listen once it can transcribe, as Orukeet's
does once the model is loaded; that holds for one started outside
Emacs too."
  (earwig-server--port-in-use-p))

(defun earwig-server-transcribe (file callback &optional label)
  "Send the audio FILE to the server to transcribe; return the request process.
When it's done, CALLBACK is called with whether it succeeded, and the
transcription, or the error, as a string.  LABEL says what it is, for
the log (`earwig-log'), which has how long it took for how much audio."
  (if (not earwig-log)
      (earwig-server--transcribe file callback)
    (let ((start (float-time))
          (audio (/ (max 0 (- (or (file-attribute-size (file-attributes file)) 44) 44))
                    32000.0))
          (label (or label (file-name-nondirectory file))))
      (earwig--log "orukeet" "%s: %.2fs of audio sent" label audio)
      (earwig-server--transcribe
       file (lambda (ok output)
              (earwig--log "orukeet" "%s: %s after %.2fs: %S" label (if ok "heard" "failed")
                           (- (float-time) start) output)
              (funcall callback ok output))))))

(defun earwig-server--transcribe (file callback)
  "Send FILE to the server; call CALLBACK with success and output.
Return the request process.  See `earwig-server-transcribe'."
  (make-process
   :name "earwig-stt"
   :command (list "curl" "-s" "--fail-with-body"
                  "-F" (concat "model=" earwig-speech-server-model)
                  "-F" "response_format=text"
                  "-F" (concat "file=@" file)
                  (earwig-server-url "/v1/audio/transcriptions"))
   :buffer (generate-new-buffer " *earwig-stt*")
   :connection-type 'pipe
   :coding 'utf-8
   :noquery t
   :sentinel (lambda (proc _event)
               (unless (process-live-p proc)
                 (let ((output (with-current-buffer (process-buffer proc)
                                 (string-trim (buffer-string)))))
                   (kill-buffer (process-buffer proc))
                   (funcall callback (zerop (process-exit-status proc)) output))))))

(defun earwig-server--filter (proc output)
  "Log OUTPUT from PROC."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (save-excursion
        (goto-char (point-max))
        (insert output)))))

(defun earwig-server--wait-ready ()
  "Say when the server started listens; stop waiting once it has, or died."
  (cond
   ((not (earwig-server-running-p))
    (cancel-timer earwig-server--ready-timer))
   ((earwig-server-ready-p)
    (cancel-timer earwig-server--ready-timer)
    (message "Speech server ready at %s" (earwig-server-url)))))

(defun earwig-server--sentinel (proc event)
  "Report when PROC exits with EVENT."
  (unless (process-live-p proc)
    (when (eq proc earwig-server--process)
      (setq earwig-server--process nil))
    (message "Speech server stopped: %s" (string-trim event))))

;;;###autoload
(defun earwig-speech-server-start ()
  "Start the speech server with `earwig-speech-server-command'."
  (interactive)
  (cond
   ((earwig-server-running-p)
    (message "Speech server already running at %s" (earwig-server-url)))
   ((not earwig-speech-server-command)
    (user-error "Set `earwig-speech-server-command' to start the speech server from Emacs"))
   ((earwig-server--port-in-use-p)
    (user-error "Something already listens at %s (a server started outside Emacs?)"
                (earwig-server-url)))
   (t
    (let ((default-directory (earwig-server--directory)))
      (unless (file-directory-p default-directory)
        (user-error "No directory %s, see `earwig-speech-server-directory'" default-directory))
      (with-current-buffer (get-buffer-create earwig-server-buffer-name)
        (goto-char (point-max))
        (insert (format "\n--- started %s ---\n" (current-time-string))))
      (setq earwig-server--process
            (make-process
             :name "earwig-server"
             :buffer earwig-server-buffer-name
             :command (cons (earwig-server--program) (cdr earwig-speech-server-command))
             :connection-type 'pipe
             :noquery t
             :filter #'earwig-server--filter
             :sentinel #'earwig-server--sentinel))
      (when (timerp earwig-server--ready-timer)
        (cancel-timer earwig-server--ready-timer))
      (setq earwig-server--ready-timer (run-at-time 1 1 #'earwig-server--wait-ready))
      (message "Speech server starting...")))))

;;;###autoload
(defun earwig-speech-server-autostart ()
  "Start the speech server if it's set to start on its own and isn't running.
That's with `earwig-speech-server-autostart' and
`earwig-speech-server-command', when nothing answers at
`earwig-speech-server-base-url' yet."
  (when (and earwig-speech-server-autostart
             earwig-speech-server-command
             (not (earwig-server-running-p))
             (not (earwig-server--port-in-use-p)))
    (earwig-speech-server-start)))

;;;###autoload
(defun earwig-speech-server-stop ()
  "Stop the speech server started from Emacs.
Asks it to shut down cleanly, with SIGINT, and kills it if it hasn't
exited after `earwig-speech-server-stop-timeout' seconds."
  (interactive)
  (if (not (earwig-server-running-p))
      (message "No speech server was started from Emacs")
    (let ((proc earwig-server--process))
      (earwig--interrupt-server proc)
      (message "Speech server stopping...")
      (run-at-time earwig-speech-server-stop-timeout nil
                   (lambda ()
                     (when (process-live-p proc)
                       (delete-process proc)))))))

;;;###autoload
(defun earwig-speech-server-toggle ()
  "Start the speech server if it's stopped, stop it otherwise."
  (interactive)
  (if (earwig-server-running-p)
      (earwig-speech-server-stop)
    (earwig-speech-server-start)))

;;;###autoload
(defun earwig-speech-server-log ()
  "Show the log of the speech server started from Emacs."
  (interactive)
  (display-buffer (get-buffer-create earwig-server-buffer-name)))

(provide 'earwig-server)
;;; earwig-server.el ends here
