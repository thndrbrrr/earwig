;;; earwig-hold.el --- Tap or hold the voice keys  -*- lexical-binding: t; -*-

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

;; Emacs never sees a key being released, but holding a key makes the
;; system repeat it, on macOS and Linux alike.  That tells a tap of a voice key (start recording, tap
;; again to stop) from a hold, push-to-talk (record while held, stop on
;; release), the way Claude CLI's hold-space voice mode works in a
;; terminal.  A push-to-talk key can be one that types, such as the
;; space bar, which still types when tapped.

;;; Code:

(require 'cl-lib)

;; Bound dynamically to find what a key does without `earwig-mode'
(defvar earwig-mode)
;; Kept from flushing provisional text on a key, which is for taps only
(defvar earwig--stream-pushed-to-talk)
(declare-function earwig--recording-p "earwig" ())
(declare-function earwig--toggle-recording "earwig" (mode))
(declare-function earwig--stream-flush-on-key "earwig-stream" ())

(defgroup earwig-hold nil
  "Telling a held voice key from a tap."
  :group 'earwig
  :prefix "earwig-hold-")

;; The defaults are on the safe side: they suit a delay until repeat of
;; up to about 1.1 s and a repeat every 100 ms or faster (on macOS
;; InitialKeyRepeat 68 and KeyRepeat 6, in ticks of 1/60 s, or less),
;; which takes in what macOS starts with, and GNOME, KDE and X11 too
;; (500 to 660 ms, then every 25 to 40 ms).  With faster key repeat,
;; smaller values notice a hold, and its release, sooner:
;; `earwig-check-setup' suggests them, and `earwig-hold-debug' shows the
;; actual intervals.

(defcustom earwig-hold-initial-window 1.5
  "Seconds after a press within which its first auto-repeat may arrive.
Somewhat longer than the system's delay until repeat.  A second tap of a
toggle key within this time is told from a repeat by no repeat
following it, within `earwig-hold-repeat-max'."
  :type 'number)

(defcustom earwig-hold-repeat-max 0.2
  "Most seconds between two auto-repeats of a held key.
About twice the system's repeat interval, and shorter than a person can tap
the same key twice."
  :type 'number)

(defcustom earwig-hold-release-delay 0.3
  "Seconds without a repeat after which a held key counts as released.
About three times the system's repeat interval, with room for Emacs being busy."
  :type 'number)

(defcustom earwig-hold-typing-repeats 4
  "Repeats that confirm a push-to-talk key that types is held, not tapped.
More than one, so a key tapped quickly, e.g. spaces for indenting,
doesn't count."
  :type 'natnum)

(defcustom earwig-hold-debug nil
  "Non-nil to log the time between voice key presses to *Messages*."
  :type 'boolean)

(cl-defstruct (earwig--press (:constructor earwig--make-press))
  "A key press being followed to tell a tap from a hold."
  key            ; the event pressed
  last           ; time of its latest repeat
  (repeats 0)    ; auto-repeats so far
  held           ; non-nil once confirmed held
  on-release     ; what to call when a hold ends, if anything
  timer
  typed)         ; a key that types: characters typed by this press so far

(defvar earwig--press nil "The press being followed, if any.")

(defvar earwig--typed-run nil
  "(START END TIME) of what a push-to-talk key just typed in a row.
START is a marker, END the position after the last one, TIME when it
was typed.  Taken back when a hold turns out to be dictation, even if
Emacs was too busy to see every repeat as one.")

(defun earwig--hold-now ()
  "Return the current time in seconds; a function so tests can replace it."
  (float-time))

(defun earwig--hold-log (now)
  "Log the time from the previous press to NOW when `earwig-hold-debug' is on."
  (when (and earwig-hold-debug earwig--press)
    (let ((inhibit-message t))
      (message "earwig hold: %s after %d ms" (key-description (vector last-command-event))
               (round (* 1000 (- now (earwig--press-last earwig--press))))))))

(defun earwig--hold-repeat-p (now)
  "Non-nil if pressing the current key at NOW repeats the press followed.
The first repeat comes after the system's delay until repeat, later ones
quickly after each other.  Once the key is known to be held, any press
of it is a repeat: a repeat Emacs was too busy to see in time mustn't
end the hold, only the release timer does."
  (let ((press earwig--press))
    (and press
         (equal (earwig--press-key press) last-command-event)
         (or (earwig--press-held press)
             (< (- now (earwig--press-last press))
                (if (zerop (earwig--press-repeats press))
                    earwig-hold-initial-window
                  earwig-hold-repeat-max))))))

(defun earwig--hold-end ()
  "Stop following the press."
  (when earwig--press
    (when (earwig--press-timer earwig--press)
      (cancel-timer (earwig--press-timer earwig--press)))
    (setq earwig--press nil)))

(defun earwig--hold-arm (seconds function)
  "Call FUNCTION in SECONDS unless the press is followed up before."
  (let ((press earwig--press))
    (when (earwig--press-timer press)
      (cancel-timer (earwig--press-timer press)))
    (setf (earwig--press-timer press) (run-at-time seconds nil function))))

(defun earwig--hold-released ()
  "The key was let go: stop the recording a hold started.
Unless input is waiting: repeats Emacs was too busy to read yet."
  (if (and earwig--press (input-pending-p))
      (earwig--hold-arm earwig-hold-release-delay #'earwig--hold-released)
    (earwig--hold-release)))

(defun earwig--hold-release ()
  "Stop following the press, and the recording its hold started."
  (let ((on-release (and earwig--press
                         (earwig--press-held earwig--press)
                         (earwig--press-on-release earwig--press))))
    (earwig--hold-end)
    (when (and on-release (earwig--recording-p))
      (funcall on-release))))

(defun earwig--repeated (now)
  "Count a repeat of the press at NOW and wait for the next one."
  (cl-incf (earwig--press-repeats earwig--press))
  (setf (earwig--press-last earwig--press) now)
  (earwig--hold-arm earwig-hold-release-delay #'earwig--hold-released))

;;;; Voice keys

(defun earwig--tap-or-hold (toggle push-to-talk)
  "Call TOGGLE for a fresh press of the current key, then tell a tap from a hold.
TOGGLE starts or stops recording.  With PUSH-TO-TALK, if this press
started recording and the key turns out to be held, recording stops
when it's let go; tapped, it goes on until the next press.  Repeats are
never a fresh press, so holding the key to stop doesn't start a new
recording.  Without PUSH-TO-TALK, a press that may be the first repeat
or a second tap is a tap if no repeat follows it."
  (let ((now (earwig--hold-now))
        (press earwig--press))
    (earwig--hold-log now)
    (if (earwig--hold-repeat-p now)
        (if (or push-to-talk (earwig--press-held press) (> (earwig--press-repeats press) 0))
            (progn
              (setf (earwig--press-held press) t)
              (when (earwig--press-on-release press)
                (setq earwig--stream-pushed-to-talk t))
              (earwig--repeated now))
          (cl-incf (earwig--press-repeats press))
          (setf (earwig--press-last press) now)
          (earwig--hold-arm earwig-hold-repeat-max
                            (lambda () (earwig--toggle-tapped toggle))))
      (earwig--hold-end)
      (let ((recording (earwig--recording-p)))
        (funcall toggle)
        (setq earwig--press
              (earwig--make-press
               :key last-command-event :last now
               :on-release (and push-to-talk (not recording) (earwig--recording-p) toggle)))
        (earwig--hold-arm earwig-hold-initial-window #'earwig--hold-end)))))

;;;; Toggle only

(defun earwig--toggle-tapped (toggle)
  "No repeat followed the press: it was a second tap, so call TOGGLE.
Unless input is waiting: repeats Emacs was too busy to read yet."
  (if (and earwig--press (input-pending-p))
      (earwig--hold-arm earwig-hold-repeat-max (lambda () (earwig--toggle-tapped toggle)))
    (let ((key (and earwig--press (earwig--press-key earwig--press)))
          (last (and earwig--press (earwig--press-last earwig--press))))
      (earwig--hold-end)
      ;; Run from a timer, where an error would only say the timer failed
      (condition-case err
          (funcall toggle)
        (error (message "%s" (error-message-string err))))
      (when key
        (setq earwig--press (earwig--make-press :key key :last last))
        (earwig--hold-arm earwig-hold-initial-window #'earwig--hold-end)))))

;;;; Push to talk only

(defun earwig--push-to-talk-held (mode)
  "The key pressed is held: record for MODE until it's let go.
Unless something is recording already."
  (let ((press earwig--press))
    (setf (earwig--press-held press) t)
    (unless (earwig--recording-p)
      (earwig--toggle-recording mode)
      (when (earwig--recording-p)
        (setq earwig--stream-pushed-to-talk t)
        (setf (earwig--press-on-release press)
              (lambda () (earwig--toggle-recording mode)))))))

(defun earwig--push-to-talk (mode keys)
  "Record for MODE while the push-to-talk key KEYS is held; a tap does nothing.
For a key that types, see `earwig--push-to-talk-typing'."
  (if (earwig--typing-command-p (lookup-key global-map keys))
      (earwig--push-to-talk-typing mode keys)
    (let ((now (earwig--hold-now)))
      (earwig--hold-log now)
      (if (earwig--hold-repeat-p now)
          (progn
            (unless (earwig--press-held earwig--press)
              (earwig--push-to-talk-held mode))
            (earwig--repeated now))
        (earwig--hold-end)
        (setq earwig--press (earwig--make-press :key last-command-event :last now))
        (earwig--hold-arm earwig-hold-initial-window #'earwig--hold-end)))))

;;;; Push to talk with a key that types

(defun earwig--typing-command-p (command)
  "Non-nil if COMMAND types the key pressed, as `self-insert-command' does.
Modes have commands of their own for that, such as Org's
`org-self-insert-command' for the space bar."
  (and (symbolp command)
       (string-suffix-p "self-insert-command" (symbol-name command))))

(defun earwig--typing-fallback (keys)
  "Return what KEYS run without `earwig-mode'."
  (let ((earwig-mode nil))
    (key-binding keys t)))

(defun earwig--typing-run (command)
  "Run COMMAND for the key pressed as if it had been bound there directly.
Provisional dictation goes in first, as for any other key, so a space
typed while dictating goes after it.  Return point before COMMAND ran."
  (when command
    ;; Completion UIs and undo amalgamation look at `this-command'
    (setq this-command command)
    (earwig--stream-flush-on-key)
    (prog1 (point)
      (call-interactively command))))

(defun earwig--typing-typed (before now)
  "Note the character just typed at BEFORE at time NOW in `earwig--typed-run'.
It extends the run if it follows the last one straight away."
  (let ((run earwig--typed-run))
    (unless (and run
                 (eq (marker-buffer (nth 0 run)) (current-buffer))
                 (eql (nth 1 run) before)
                 (< (- now (nth 2 run)) earwig-hold-initial-window))
      (setq run (list (copy-marker before) nil nil)))
    (setf (nth 1 run) (point)
          (nth 2 run) now)
    (setq earwig--typed-run run)))

(defun earwig--typing-held (mode)
  "The key pressed is held: take back what it typed and record for MODE."
  (let ((run earwig--typed-run))
    (when (and run
               (eq (marker-buffer (nth 0 run)) (current-buffer))
               (eql (nth 1 run) (point))
               (characterp last-command-event)
               (string-match-p (concat "\\`" (regexp-quote (string last-command-event)) "+\\'")
                               (buffer-substring-no-properties (nth 0 run) (point))))
      (delete-region (nth 0 run) (point)))
    (setq earwig--typed-run nil)
    (earwig--push-to-talk-held mode)))

(defun earwig--push-to-talk-typing (mode keys)
  "Type with the push-to-talk key KEYS; held down, record for MODE until let go.
Only where the key types in a writable buffer and nothing is recording;
anywhere else it does what it would do without `earwig-mode'."
  (let ((now (earwig--hold-now))
        (fallback (earwig--typing-fallback keys))
        (press earwig--press))
    (earwig--hold-log now)
    (cond
     ;; Repeats of a held key: nothing to type
     ((and press (earwig--press-typed press) (earwig--press-held press)
           (earwig--hold-repeat-p now))
      (earwig--repeated now))
     ((or (not (earwig--typing-command-p fallback))
          buffer-read-only
          (minibufferp)
          (earwig--recording-p))
      (earwig--typing-run fallback))
     ;; Typed as usual until enough repeats show it's held
     ((and press (earwig--press-typed press) (earwig--hold-repeat-p now))
      (earwig--typing-typed (earwig--typing-run fallback) now)
      (cl-incf (earwig--press-typed press))
      (earwig--repeated now)
      (when (>= (earwig--press-repeats press) earwig-hold-typing-repeats)
        (earwig--typing-held mode)))
     (t
      (earwig--hold-end)
      (earwig--typing-typed (earwig--typing-run fallback) now)
      (setq earwig--press (earwig--make-press :key last-command-event :last now
                                              :typed 1))
      (earwig--hold-arm earwig-hold-initial-window #'earwig--hold-end)))))

(provide 'earwig-hold)
;;; earwig-hold.el ends here
