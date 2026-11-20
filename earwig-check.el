;;; earwig-check.el --- Check that voice control is set up  -*- lexical-binding: t; -*-

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

;; `earwig-check-setup' checks everything voice control needs on this
;; host and lists it, with how to fix whatever is missing: the recorder
;; and its audio driver, the speech server, the microphone (by recording
;; half a second from it and having the server transcribe it), the
;; keyboard settings push-to-talk relies on, and whether dictation can
;; stream.  It changes nothing.  What differs between macOS and Linux comes from
;; earwig-platform.el.  Setting up: README.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'earwig-platform)
(require 'earwig-server)
(require 'earwig-stream)

(defvar earwig-input-device)
(defvar earwig-recorder)
(defvar earwig-hold-initial-window)
(defvar earwig-hold-repeat-max)
(defvar earwig-hold-release-delay)
(declare-function earwig--recorder "earwig" ())

(defcustom earwig-check-app-id "org.gnu.Emacs"
  "The macOS bundle identifier of Emacs, for its own keyboard settings."
  :type 'string
  :group 'earwig)

;;;; The checks
;; Each returns a list of (STATUS LABEL DETAIL FIX): STATUS is `ok', `warn'
;; or `fail', FIX says what to do about anything but `ok'.

(defun earwig--check-sox-hint ()
  "Return how to have sox record: install it, or choose it if it's there."
  (if (executable-find "sox")
      "set earwig-recorder to auto or sox"
    (format "%s, with earwig-recorder auto or sox" (earwig--install-hint "sox"))))

(defun earwig--check-tools ()
  "Check the recorder, sox's audio driver, and curl."
  (let ((sox (executable-find "sox"))
        (ffmpeg (executable-find "ffmpeg"))
        (recorder (earwig--recorder)))
    (append
     (list
      (cond
       ((and (eq recorder 'sox) sox) (list 'ok "Recorder" (format "sox (%s)" sox)))
       ((and (eq recorder 'ffmpeg) ffmpeg)
        (list 'warn "Recorder" "ffmpeg: no streaming, and on macOS it loses about a second at the start"
              (earwig--check-sox-hint)))
       (t (list 'fail "Recorder" (format "%s not found" recorder)
                (earwig--install-hint (symbol-name recorder))))))
     (when (and (eq recorder 'sox) sox)
       (let ((driver (earwig--audio-driver)))
         (list (if (memq driver (earwig--sox-drivers))
                   (list 'ok "Audio driver" (symbol-name driver))
                 (list 'fail "Audio driver" (format "sox has no %s driver" driver)
                       (earwig--sox-driver-hint driver))))))
     (list
      (if (executable-find "curl")
          (list 'ok "curl" (executable-find "curl"))
        (list 'fail "curl" "not found" (earwig--install-hint "curl")))))))

(defun earwig--check-server-command ()
  "Check `earwig-speech-server-command', if it's set."
  (when earwig-speech-server-command
    (let ((directory (earwig-server--directory))
          (program (earwig-server--program)))
      (list
       (cond
        ((not (file-directory-p directory))
         (list 'fail "Server command" (format "no directory %s" directory)
               "set earwig-speech-server-directory"))
        ((not (if (file-name-directory program)
                  (file-executable-p program)
                (executable-find program)))
         (list 'fail "Server command" (format "%s not found" program)
               "set earwig-speech-server-command"))
        (t
         (list 'ok "Server command" (abbreviate-file-name program))))))))

(defun earwig--check-server ()
  "Check that the speech server answers; return a check result."
  (let ((url (earwig-server-url)))
    (cond
     ((earwig-server-ready-p)
      (list 'ok "Server" (format "listening at %s" url)))
     ((earwig-server-running-p)
      (list 'fail "Server" (format "started, but not listening at %s yet" url)
            "wait for it to load, then press g; M-x earwig-speech-server-log shows its output"))
     (earwig-speech-server-command
      (list 'fail "Server" (format "not running at %s" url) "M-x earwig-speech-server-start"))
     (t
      (list 'fail "Server" (format "nothing listens at %s" url)
            "start your speech server, or set earwig-speech-server-command for M-x earwig-speech-server-start; it must answer POST /v1/audio/transcriptions as OpenAI's API does, see docs/manual.md")))))

(defun earwig--check-record (file)
  "Record half a second from the microphone to FILE as raw 16 kHz samples.
Return nil, or the error output if recording failed."
  (pcase-let ((`(,status . ,output)
               (if (eq (earwig--recorder) 'sox)
                   (let ((sox (earwig--sox-program)))
                     (apply #'earwig--run (car sox)
                            `(,@(cdr sox) "-q" "-V1" ,@(earwig--sox-input-args)
                              "-t" "raw" "-r" "16000" "-c" "1" "-b" "16"
                              "-e" "signed-integer" ,file "trim" "0" "0.5")))
                 (earwig--run "ffmpeg" "-loglevel" "error" "-y"
                              "-f" (earwig--ffmpeg-input-format)
                              "-i" (earwig--ffmpeg-input-device) "-t" "0.5"
                              "-ac" "1" "-ar" "16000" "-f" "s16le" file))))
    (unless (and (eql status 0) (file-exists-p file)
                 (> (file-attribute-size (file-attributes file)) earwig--stream-frame-bytes))
      (earwig--check-error-line output status))))

(defun earwig--check-error-line (output status)
  "Return the line of a recorder's error OUTPUT that says what's wrong.
STATUS is its exit status, for when it said nothing."
  (let ((lines (split-string output "\n" t "[ \t]+")))
    (replace-regexp-in-string
     "\\`\\(?:\\[[^]]*\\] \\|[^ ]*sox \\(?:FAIL \\)?\\)" ""
     (or (cl-find-if (lambda (line) (string-match-p "not found\\|can't open\\|can not open" line)) lines)
         (car (last lines))
         (format "exit status %s" status)))))

(defconst earwig--check-quiet-level 0.001
  "Loudest level below which the microphone check warns, about -60 dBFS.")

(defun earwig--check-level (file)
  "Return the level of the loudest 30 ms frame in the raw recording FILE, 0 to 1."
  (let ((bytes (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally file)
                 (buffer-string))))
    (/ (cl-loop for offset from 0 to (- (length bytes) earwig--stream-frame-bytes)
                by earwig--stream-frame-bytes
                maximize (earwig--frame-level bytes offset))
       32768.0)))

(defun earwig--check-transcribe (raw)
  "Send the raw recording RAW to the server; return a check result."
  (let ((wav (make-temp-file "earwig-check-" nil ".wav")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally raw)
            (goto-char (point-min))
            (insert (earwig--wav-header (buffer-size)))
            (let ((coding-system-for-write 'no-conversion))
              (write-region nil nil wav nil 'silent)))
          (pcase-let ((`(,status . ,output)
                       (earwig--run "curl" "-s" "-o" null-device "-w" "%{http_code} %{time_total}"
                                    "-F" (concat "model=" earwig-speech-server-model)
                                    "-F" "response_format=text"
                                    "-F" (concat "file=@" wav)
                                    (earwig-server-url "/v1/audio/transcriptions"))))
            (if (and (eql status 0) (string-prefix-p "200 " output))
                (list 'ok "Transcription" (format "half a second transcribed in %.2f s"
                                                  (string-to-number (substring output 4))))
              (list 'fail "Transcription" (format "request failed: %s" output)
                    (if (earwig-server-running-p)
                        "M-x earwig-speech-server-log"
                      "see the speech server's log")))))
      (delete-file wav))))

(defun earwig--check-microphone ()
  "Check the input device and the server, by recording from the microphone."
  (let* ((devices (earwig--input-devices))
         (fix-device (cond
                      ((and (eq (earwig--recorder) 'sox)
                            (not (memq (earwig--audio-driver) (earwig--sox-drivers))))
                       "see Audio driver above")
                      (devices
                       (format "set earwig-input-device to \"default\" or one of: %s"
                               (string-join (mapcar (lambda (name) (format "\"%s\"" name))
                                                    devices)
                                            ", ")))
                      (t "set earwig-input-device to \"default\" or a microphone's name")))
         (server (earwig--check-server)))
    (if (not earwig-input-device)
        (list (list 'fail "Microphone" "earwig-input-device not set" fix-device) server)
      (let ((raw (make-temp-file "earwig-check-" nil ".raw")))
        (unwind-protect
            (let* ((failure (earwig--check-record raw))
                   (level (and (not failure) (earwig--check-level raw))))
              (append
               (list
                (cond
                 (failure
                  (list 'fail "Microphone" (format "can't record from \"%s\": %s"
                                                   earwig-input-device failure)
                        fix-device))
                 ;; Shown as 0.0000, it's no audio at all
                 ((< level 0.00005)
                  (list 'fail "Microphone" (format "\"%s\" records only silence" earwig-input-device)
                        (earwig--microphone-access-hint)))
                 ;; Quieter than the background noise of a real microphone
                 ((< level earwig--check-quiet-level)
                  (list 'warn "Microphone" (format "\"%s\" records almost silence, loudest level %.4f"
                                                   earwig-input-device level)
                        "check it's the right input and isn't turned down; speak during the check"))
                 (t
                  (list 'ok "Microphone" (format "\"%s\", loudest level %.3f"
                                                 earwig-input-device level))))
                server)
               ;; A recording to transcribe, and a server to do it
               (and (not failure) (eq (car server) 'ok)
                    (list (earwig--check-transcribe raw)))))
          (delete-file raw))))))

(defun earwig--check-press-and-hold ()
  "Check that holding a key in Emacs repeats it, on macOS; nil elsewhere."
  (when (eq system-type 'darwin)
    (let ((press-hold (earwig--macos-default earwig-check-app-id "ApplePressAndHoldEnabled")))
      (list
       (if (member (downcase (or press-hold "")) '("0" "no" "false"))
           (list 'ok "Press and hold" "off for Emacs, so held keys repeat")
         (list 'fail "Press and hold" "on: holding a key shows accents instead of repeating it"
               (format "defaults write %s ApplePressAndHoldEnabled -bool false, then restart Emacs"
                       earwig-check-app-id)))))))

(defun earwig--check-key-repeat ()
  "Check that the key repeat suits the `earwig-hold-*' options."
  (list
   (pcase (earwig--key-repeat)
     ('nil
      (list 'warn "Key repeat" "can't read how the keyboard repeats"
            "measure with (setq earwig-hold-debug t), then set earwig-hold-*"))
     ('off
      (list 'fail "Key repeat" "off: a held key can't be told from a tap"
            "turn key repeat on in the keyboard settings, for push-to-talk"))
     (`(,delay . ,interval)
      (let ((window (max 0.4 (/ (* 1.3 delay) 1000.0)))
            (repeat-max (/ (* 2 interval) 1000.0))
            (release (max 0.15 (/ (* 3 interval) 1000.0))))
        (if (and (<= (* 1.2 delay) (* 1000 earwig-hold-initial-window))
                 (<= (* 1.5 interval) (* 1000 earwig-hold-repeat-max))
                 (<= (* 2 interval) (* 1000 earwig-hold-release-delay)))
            (list 'ok "Key repeat"
                  (format "starts after %d ms, then every %d ms%s" delay interval
                          (if (< (* 1.5 window) earwig-hold-initial-window)
                              (format "; earwig-hold-initial-window %.2f, earwig-hold-repeat-max %.2f and earwig-hold-release-delay %.2f would notice holds sooner"
                                      window repeat-max release)
                            "")))
          (list 'warn "Key repeat"
                (format "starts after %d ms, then every %d ms: slower than earwig-hold-* expect"
                        delay interval)
                (format "set earwig-hold-initial-window %.2f, earwig-hold-repeat-max %.2f, earwig-hold-release-delay %.2f"
                        window repeat-max release))))))))

(defun earwig--check-keyboard ()
  "Check the keyboard settings holding a voice key relies on."
  (append (earwig--check-press-and-hold)
          (earwig--check-key-repeat)))

(defun earwig--check-emacs ()
  "Check that the settings fit together."
  (list
   (cond
    ((not earwig-streaming) (list 'ok "Streaming" "off"))
    ((eq (earwig--recorder) 'sox) (list 'ok "Streaming" "on"))
    (t (list 'warn "Streaming" "on, but it needs sox: dictation is transcribed when it stops"
             (earwig--check-sox-hint))))))

;;;; The report

;;;###autoload
(defun earwig-check-setup ()
  "Check that Earwig is set up on this computer, and show what to fix.
Records half a second from the microphone; changes nothing.  Press
\\`g' in the report to check again."
  (interactive)
  (require 'earwig)
  (message "Checking Earwig setup...")
  (setq earwig--sox-drivers-cache nil)
  (let ((results (append (earwig--check-tools)
                         (earwig--check-server-command)
                         (earwig--check-microphone)
                         (earwig--check-keyboard)
                         (earwig--check-emacs))))
    (with-current-buffer (get-buffer-create "*Earwig setup*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Earwig on %s\n\n" (system-name)) 'face 'bold))
        (pcase-dolist (`(,status ,label ,detail ,fix) results)
          (insert (pcase status
                    ('ok (propertize "✓" 'face 'success))
                    ('warn (propertize "!" 'face 'warning))
                    (_ (propertize "✗" 'face 'error)))
                  (format " %-16s %s\n" label detail))
          (when fix
            (insert (format "  %-16s → %s\n" "" fix))))
        (let ((failed (cl-count 'fail results :key #'car))
              (warned (cl-count 'warn results :key #'car)))
          (insert "\n" (cond ((> failed 0) (format "%d to fix" failed))
                             ((> warned 0) (format "Ready, %d to consider" warned))
                             (t "Ready"))
                  ".  Setting up: Earwig's README.md\n")))
      (special-mode)
      (setq-local revert-buffer-function (lambda (&rest _) (earwig-check-setup)))
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))
    (message nil)))

(provide 'earwig-check)
;;; earwig-check.el ends here
