;;; earwig-log.el --- One log of what Earwig hears and does  -*- lexical-binding: t; -*-

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

;; With `earwig-log', what Earwig hears and does goes to one buffer,
;; *earwig-log*, a line each, with the time: Pincer's events and what
;; Earwig sends it, each transcription with how long Orukeet took and
;; for how much audio, where streaming dictation cut its segments and
;; why, what the wake word did to them, how a command after it was told
;; from the dictation, when and why a command ended, and the commands
;; run.  `earwig-show-log' shows it.
;;
;; Positions in a recording are in seconds from its start, as \"@3.21s\";
;; a segment is [START–END].  Each line starts with what it's about:
;;
;;   pincer<   an event from Pincer, as it wrote it
;;   pincer>   a command Earwig sent Pincer
;;   pincer    Pincer starting and exiting
;;   record    a recording starting and stopping, and the microphone
;;   orukeet   a request to the speech server and its answer, word for
;;             word as Orukeet wrote it
;;   cleanup   a step of the cleanup that changed what Orukeet wrote:
;;             filler words, a correction, spoken punctuation, fitting
;;             it to where it goes
;;   segment   streaming dictation cutting a segment, and why
;;   wake      the wake word, and what it did to the dictation
;;   split     a command after the wake word told from the dictation
;;   heard     a transcription, and what Earwig made of it in the end:
;;             the text it inserted, a command, or nothing
;;   command   a voice command run, and what it said
;;   message   what Earwig said in the echo area about a command

;;; Code:

(require 'seq)

(defcustom earwig-log nil
  "Non-nil to log what Earwig hears and does to *earwig-log*.
To find out why something was misheard, a command was missed, or a
wake word was handled wrongly; see the commentary of earwig-log.el.
\\[earwig-show-log] shows it."
  :type 'boolean
  :group 'earwig)

(defconst earwig--log-buffer "*earwig-log*" "The log's buffer.")

(defmacro earwig--log (what format &rest args)
  "Log a line about WHAT, a short string, with FORMAT and ARGS.
As for `format'.  Nothing is evaluated unless `earwig-log' is on."
  `(when earwig-log
     (earwig--log-insert ,what (format ,format ,@args))))

(defun earwig--log-insert (what text)
  "Insert TEXT about WHAT into the log, after the time.
TEXT keeps its faces.  Windows showing the log's end keep showing it.
The log keeps its last 2 MB or so."
  (let ((buffer (get-buffer-create earwig--log-buffer)))
    (with-current-buffer buffer
      (let ((at-end (seq-filter (lambda (window) (= (window-point window) (point-max)))
                                (get-buffer-window-list buffer nil t)))
            (follow (= (point) (point-max)))
            (inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert (format-time-string "%T.%3N ") (format "%-9s " what)
                  (replace-regexp-in-string "\n" "\\\\n" text) "\n")
          (when (> (buffer-size) 2000000)
            (goto-char (+ (point-min) 1000000))
            (delete-region (point-min) (line-beginning-position 2))))
        (when follow
          (goto-char (point-max)))
        (dolist (window at-end)
          (set-window-point window (point-max)))))))

(defun earwig--log-seconds (bytes)
  "Return BYTES of 16 kHz, 16-bit mono audio as seconds, as \"3.21s\"."
  (format "%.2fs" (/ bytes 32000.0)))

(defun earwig--log-range (beg end)
  "Return the stretch of audio from byte BEG to END, as \"[1.20s–3.51s]\"."
  (format "[%.2fs–%.2fs]" (/ beg 32000.0) (/ end 32000.0)))

(defun earwig--log-change (step before after)
  "Log a cleanup line saying STEP changed BEFORE into AFTER, if it did.
Strings, compared and shown without their text properties."
  (when (and earwig-log (not (string= before after)))
    (let ((print-escape-newlines t))
      (earwig--log "cleanup" "%s: %S → %S" step
                   (substring-no-properties before) (substring-no-properties after)))))

(defun earwig--log-message (format &rest args)
  "Show FORMAT with ARGS in the echo area, as `message', and log it."
  (let ((text (apply #'format-message format args)))
    (earwig--log "message" "%s" text)
    (message "%s" text)))

;;;###autoload
(defun earwig-show-log ()
  "Show the log of what Earwig hears and does, see `earwig-log'."
  (interactive)
  (unless earwig-log
    (message "The log is off: (setopt earwig-log t) turns it on"))
  (with-current-buffer (get-buffer-create earwig--log-buffer)
    (goto-char (point-max)))
  (display-buffer earwig--log-buffer))

(provide 'earwig-log)
;;; earwig-log.el ends here
