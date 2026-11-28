;;; earwig.el --- Push-to-talk dictation and voice commands via Orukeet  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 thndrbrrr

;; Author: thndrbrrr <thndrbrrr@gmail.com>
;; Maintainer: thndrbrrr <thndrbrrr@gmail.com>
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (phony "4.0.0"))
;; URL: https://github.com/thndrbrrr/earwig
;; Keywords: convenience, multimedia, text, speech, dictation, voice
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

;; `earwig-mode' turns it on.  Cmd-d (F7 on Linux) or keypad 0 starts
;; recording; pressing it again stops it and inserts the transcription
;; at point.  Cmd-f (F8) or keypad Enter does the same for a spoken
;; command (earwig-commands.el).  With `earwig-push-to-talk', holding the space
;; bar dictates until it's let go, while a tap still types a space
;; (earwig-hold.el).  Which keys toggle, which push to talk, and what
;; each records for are options, `earwig-toggle-keys' and
;; `earwig-push-to-talk-keys'.
;; A recording is sent to the local speech server (earwig-server.el)
;; once it stops; with `earwig-streaming', dictation is transcribed
;; while you speak instead (earwig-stream.el).  What differs between
;; macOS and Linux is in earwig-platform.el.
;;
;; Setting up: README.md, then `earwig-check-setup' (earwig-check.el).

;;; Code:

(defgroup earwig nil
  "Push-to-talk dictation and voice commands, transcribed locally."
  :group 'convenience
  :prefix "earwig-"
  :link '(url-link :tag "Website" "https://github.com/thndrbrrr/earwig"))

(require 'cl-lib)
(require 'earwig-platform)
(require 'earwig-log)
(require 'earwig-server)
(require 'earwig-cleanup)
(require 'earwig-commands)
(require 'earwig-structure)
(require 'earwig-stream)
(require 'earwig-hold)
(require 'earwig-check)

(declare-function ghostel-send-string "ghostel" (string))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function term-send-raw-string "term" (chars))
;; Here as well as by its cookie, for Earwig loaded from a checkout,
;; whose autoloads nothing generates
(autoload 'earwig-listen-mode "earwig-pincer"
  "Listen for a wake word, and give the voice command said after it." t)
;; What the `pincer' recorder and wake-word commands need
(autoload 'earwig-pincer-record "earwig-pincer")
(autoload 'earwig-pincer-ensure "earwig-pincer")
(autoload 'earwig-pincer-update "earwig-pincer")
(autoload 'earwig-pincer-after-wake-word "earwig-pincer")
(autoload 'earwig-pincer-log "earwig-pincer"
  "Show what Pincer has written to stderr: its log and errors." t)
(defvar eat-terminal)

(defcustom earwig-input-device "default"
  "Name of the microphone to record from, or \"default\".
\"default\" is the input chosen in the system's sound settings.  Other
names are those of the audio driver (see `earwig-audio-driver'): on
macOS a CoreAudio device name, as \"Display Audio\", on Linux a
PulseAudio source or an ALSA device.  `earwig-check-setup' lists the
devices there are."
  :type '(choice (const :tag "System default" "default") (string :tag "Device name")))

(defcustom earwig-recorder 'auto
  "Recorder for dictation and commands: `sox', `ffmpeg', `pincer' or `auto'.
`auto' uses sox if it's installed (it starts capturing much sooner,
and only it can stream, see `earwig-streaming'), ffmpeg otherwise.
`pincer' is Pincer, the helper that listens for a wake word
(experimental, earwig-pincer.el): it runs while `earwig-mode' is on,
keeping the microphone open, so recording starts at once, and from a
moment before the key was pressed (`earwig-pincer-key-pre-roll').  It
streams too.  It needs `earwig-pincer-command'."
  :type '(choice (const auto) (const sox) (const ffmpeg)
                 (const :tag "Pincer (experimental)" pincer)))

(defcustom earwig-recording-timeout 300
  "Seconds after which a recording transcribed when it stops stops by itself.
That's a command, or dictation without streaming; nil for no limit."
  :type '(choice (const :tag "No limit" nil) number))

(defcustom earwig-command-preview t
  "Non-nil to show a voice command in the echo area while you say it.
For a recording made with a command key: what's been said so far is
transcribed about every `earwig-stream-provisional-interval' seconds and
shown as the commands it chains, after `earwig-command-icon', with what
isn't (yet) a command in grey.  It still only runs when recording stops,
unless it ends with one of `earwig-cancel-words'.  \\[keyboard-quit]
while recording cancels it too."
  :type 'boolean)

(defcustom earwig-command-pause 1.5
  "Seconds of silence after a complete voice command before it runs.
However you started it: with a command key, see
`earwig-command-key-stops-at-pause', or with the wake word.  Shorter
runs commands sooner, but commands said one after another must then
follow each other without a pause this long.  While what you said
isn't a complete command yet, `earwig-unfinished-command-pause'
applies instead.

What you say is transcribed while you say it, to tell when it's
complete; it then runs as that transcription has it, without being
transcribed again.  A command, or commands chained, is complete
unless it ends with one of `earwig-chain-words' or needs more, as
\"go to line\" before its number; ending with one of
`earwig-cancel-words' completes it too.  Speech is told from the
background noise as in streaming dictation, see
`earwig-stream-speech-ratio'; before you've said anything, it waits."
  :type 'number)

(defcustom earwig-unfinished-command-pause 3.0
  "Seconds of silence that end a voice command that isn't complete yet.
As \"go to line\" before its number: somewhat longer than
`earwig-command-pause', so there's time to finish it.  While
dictating without Pincer listening (`earwig-listen-mode'), Earwig
only knows you gave a command from what's transcribed, and the wake
word may just be part of a sentence; so there it doesn't wait this
long, and the command ends like dictation until it's complete.  nil
to wait for the command key, or without one, until
`earwig-recording-timeout', or while dictating, until it stops."
  :type '(choice (const :tag "Wait" nil) number))

(defcustom earwig-command-key-stops-at-pause t
  "Non-nil for a command started with a command key to stop by itself.
At the pause after it, see `earwig-command-pause'.  nil to stop it
only with the key.  Pushed to talk, it always stops when the key is
let go."
  :type 'boolean)

(defvar-keymap earwig-mode-map
  :doc "Keymap for `earwig-mode'.
The keys of `earwig-push-to-talk-keys', `earwig-toggle-keys' and
`earwig-correct-keys' are bound here.")

(defvar earwig--bound-keys nil
  "The (KEY . COMMAND) bindings `earwig--bind-keys' made.")

(defun earwig--bind-keys ()
  "Bind the voice keys and `earwig-correct-keys' in `earwig-mode-map'.
In place of those bound before, so a key taken out of an option is
unbound; bindings of your own stay."
  (pcase-dolist (`(,key . ,command) earwig--bound-keys)
    (when (eq (keymap-lookup earwig-mode-map key) command)
      (keymap-unset earwig-mode-map key t)))
  (setq earwig--bound-keys nil)
  (dolist (binding (append (and (bound-and-true-p earwig-push-to-talk)
                                (boundp 'earwig-push-to-talk-keys)
                                (mapcar (lambda (entry) (cons (car entry) 'earwig-voice-key))
                                        earwig-push-to-talk-keys))
                           (and (boundp 'earwig-toggle-keys)
                                (mapcar (lambda (entry) (cons (car entry) 'earwig-voice-key))
                                        earwig-toggle-keys))
                           (and (boundp 'earwig-correct-keys)
                                (mapcar (lambda (key) (cons key 'earwig-correct))
                                        earwig-correct-keys))))
    (keymap-set earwig-mode-map (car binding) (cdr binding))
    (push binding earwig--bound-keys)))

(defun earwig--set-keys (option keys)
  "Set OPTION to KEYS and bind them, for `defcustom'."
  (set-default-toplevel-value option keys)
  (earwig--bind-keys))

(define-widget 'earwig-voice-keys 'lazy
  "Keys, each with what it records for."
  :type '(alist :key-type (key :tag "Key")
                :value-type (choice :tag "Records"
                                    (const :tag "Dictation" dictate)
                                    (const :tag "A voice command" command))))

(defcustom earwig-toggle-keys (earwig--default-keys 'toggle)
  "Toggle keys: tapped, they start recording, and tapped again stop it.
Each is (KEY . MODE), KEY as for `keymap-set' and MODE `dictate' or
`command'.  By default Cmd-d and keypad 0 dictate, and Cmd-f and keypad
Enter give a command; on Linux, where the desktop keeps Super (Cmd) for
itself, F7 and F8 take Cmd's place.  Holding one down counts as a
single press, unless it's a push-to-talk key too, see
`earwig-push-to-talk'.  Set with `setopt' or Customize; after `setq',
the keys change the next time `earwig-mode' is turned on."
  :type 'earwig-voice-keys
  :set #'earwig--set-keys)

(defcustom earwig-push-to-talk nil
  "Non-nil for push-to-talk with the keys of `earwig-push-to-talk-keys'.
Set as `earwig-toggle-keys'."
  :type 'boolean
  :set #'earwig--set-keys)

(defcustom earwig-push-to-talk-keys '(("SPC" . dictate))
  "Push-to-talk keys: held down, they record until let go.
Only with `earwig-push-to-talk'.  Each is (KEY . MODE), as for
`earwig-toggle-keys'.  A key that's a toggle key too toggles recording
when tapped, with the MODE given here.  Otherwise a tap does nothing,
except for a key that types a character, such as \"SPC\": a tap still
types it, and a hold takes back what it typed and records, wherever the
key types; anywhere else the key does what it would without
`earwig-mode'.

A push-to-talk key that isn't a toggle key too starts recording once
the hold is noticed, see `earwig-hold-initial-window' and
`earwig-hold-typing-repeats'.  To give commands while holding a
dictation key, say a wake word, see `earwig-wake-word-commands'.
Set as `earwig-toggle-keys'."
  :type 'earwig-voice-keys
  :set #'earwig--set-keys)

(defcustom earwig-correct-keys (earwig--default-keys 'correct)
  "Keys for `earwig-correct' in `earwig-mode-map', as for `keymap-set'.
By default Cmd-e, or F9 on Linux, and keypad \".\".
Set as `earwig-toggle-keys'."
  :type '(repeat key)
  :set #'earwig--set-keys)

(defcustom earwig-recording-icon "\u25cf"
  "Icon before REC in the mode line, a red dot by default.
Also before provisional text of dictation, see `earwig-provisional-icons'.
Its color is that of `earwig-mode-line-recording'."
  :type 'string)

(defcustom earwig-command-icon "\u25b6"
  "Icon before CMD in the mode line, a blue triangle by default.
Also in place of the wake word in provisional text of a command, see
`earwig-provisional-icons'.  Its color is that of
`earwig-mode-line-command'."
  :type 'string)

(defface earwig-mode-line-recording '((t :inherit error))
  "Face for REC in the mode line, while dictation records.
Also for `earwig-recording-icon' before provisional text.")

(defface earwig-mode-line-command
  '((((class color) (min-colors 88) (background dark))
     :foreground "#5c9cff" :weight bold)
    (((class color) (min-colors 88)) :foreground "#1e5bd6" :weight bold)
    (((class color)) :foreground "blue" :weight bold)
    (t :inherit bold))
  "Face for CMD in the mode line, while a voice command records.
Also for `earwig-command-icon' in provisional text.  Its color is also
that of provisional text for a command given while dictating, unless
`earwig-provisional-command' sets one.")

(defface earwig-mode-line-transcribing '((t :inherit warning))
  "Face for STT in the mode line, while the last of a recording is transcribed.")

(defvar earwig--mode 'dictate
  "What the current recording is for: `dictate' or `command'.")

(defvar earwig--audio-flowing nil
  "Non-nil once the recorder reports captured audio for the current recording.")

(defvar earwig--record-start nil
  "Time the current recording's recorder process was started.")

(defun earwig--recorder ()
  "Return the recorder to use, `sox' or `ffmpeg', per `earwig-recorder'."
  (if (eq earwig-recorder 'auto)
      (if (executable-find "sox") 'sox 'ffmpeg)
    earwig-recorder))

(defvar earwig--record-process nil
  "The recorder of a recording transcribed when it stops.")

(defvar earwig--record-file nil
  "The WAV file it records to, until it's transcribed and acted on.")

(defvar earwig--record-target nil "Marker where its dictation goes.")

(defvar earwig--record-wake nil
  "Non-nil if the recording is of a command after Pincer's wake word.
Then Pincer records it, from that position on (earwig-pincer.el).")

(defvar earwig--record-auto-stop nil
  "Non-nil if the command being recorded stops at the pause after it.
See `earwig-command-pause' and `earwig-command-key-stops-at-pause'.")

(defvar earwig--preview-timer nil "Timer transcribing the command being said.")
(defvar earwig--preview-request nil "The preview's transcription request in flight.")
(defvar earwig--preview-size 0 "Bytes of audio the last preview was of.")

(defvar earwig--auto-stop-timer nil
  "Timer listening for the pause that ends a command.
See `earwig-command-pause'.")
(defvar earwig--auto-stop-read 0 "Bytes of the command's audio measured so far.")
(defvar earwig--auto-stop-levels nil "Levels of its frames, newest first, for the noise.")
(defvar earwig--auto-stop-speech nil "Non-nil once it has speech.")
(defvar earwig--auto-stop-quiet 0 "Frames without speech since the last speech.")
(defvar earwig--auto-stop-speech-end 0 "Byte offset where the last speech ends.")
(defvar earwig--preview-heard nil
  "The latest transcription of the command being said, as (RAW . BYTES).
BYTES is how much of its audio RAW is of.")
(defvar earwig--record-final nil
  "The command's transcription, if a preview of all of it stopped the recording.
Then it's acted on as it is, rather than transcribed again; see
`earwig-command-pause'.")

(defvar earwig--record-cancelled nil
  "Non-nil once the recording is cancelled, so it's dropped when it stops.")

(defun earwig--cancel-key-filter (command)
  "Return COMMAND while a recording transcribed when it stops records.
Otherwise nil, so \\[keyboard-quit] does what it always does."
  (and (process-live-p earwig--record-process) command))

(keymap-set earwig-mode-map "C-g"
            '(menu-item "" earwig-cancel-recording :filter earwig--cancel-key-filter))

(defun earwig--record-transcribing-p ()
  "Non-nil while a recording transcribed when it stops is being transcribed.
From when its recorder stops, before its sentinel has run too."
  (and earwig--record-file (not (process-live-p earwig--record-process))))

(defvar earwig--phase nil
  "What the mode line shows: `recording', `transcribing' or nil.")

(defvar earwig--command-heard nil
  "Non-nil while a command given while dictating is heard or runs.
t while it shows as provisional text, `running' from its final text
until it has run.  The mode line shows CMD then, and REC again after.")

(defconst earwig--mode-line-entry '(:eval (earwig--mode-line))
  "Earwig's entry in `global-mode-string'.")

(defun earwig--mode-line ()
  "Return what the mode line shows for `earwig--phase'.
REC only shows once audio is actually captured, not when the recorder
starts.  CMD shows instead for a command, also one given while
dictating, see `earwig--command-heard'."
  (pcase earwig--phase
    ('recording
     (when earwig--audio-flowing
       (if (or (eq earwig--mode 'command) earwig--command-heard)
           (propertize (format " %s CMD " earwig-command-icon)
                       'face 'earwig-mode-line-command)
         (propertize (format " %s REC " earwig-recording-icon)
                     'face 'earwig-mode-line-recording))))
    ('transcribing
     (propertize " … STT " 'face 'earwig-mode-line-transcribing))))

(defun earwig--show-phase (phase)
  "Show PHASE in the mode line: `recording', `transcribing', or nil for nothing."
  (setq earwig--phase phase)
  (if phase
      (unless (member earwig--mode-line-entry global-mode-string)
        (setq global-mode-string
              (cons earwig--mode-line-entry
                    (if (listp global-mode-string)
                        global-mode-string
                      (list global-mode-string)))))
    (when (listp global-mode-string)
      (setq global-mode-string (delete earwig--mode-line-entry global-mode-string))))
  (force-mode-line-update t))

(defun earwig--record-command (file)
  "Return the command recording to the WAV FILE.
sox loses ~0.1 s at the start, where ffmpeg's AVFoundation input on
macOS loses about a second even with probing cut to the minimum.
Either way the recorder prints progress that tells
`earwig--recorder-filter' when audio flows."
  (let ((timeout (and earwig-recording-timeout
                      (number-to-string earwig-recording-timeout))))
    (if (eq (earwig--recorder) 'sox)
        `(,@(earwig--sox-program) "-S" "-V1" ,@(earwig--sox-input-args)
          "-r" "16000" "-c" "1" "-b" "16" ,file
          ,@(and timeout (list "trim" "0" timeout)))
      `("ffmpeg" "-probesize" "32" "-analyzeduration" "0" "-fflags" "nobuffer"
        "-progress" "pipe:1" "-stats_period" "0.1" "-nostats"
        "-f" ,(earwig--ffmpeg-input-format) "-i" ,(earwig--ffmpeg-input-device)
        ,@(and timeout (list "-t" timeout))
        "-ar" "16000" "-ac" "1" "-y" ,file))))

(defun earwig--audio-reported-p (output)
  "Non-nil if recorder progress OUTPUT reports any audio written.
Matches sox's \"Out:979\" and ffmpeg's \"out_time_us=138313\"."
  (let ((start 0) found)
    (while (and (not found)
                (string-match "\\(?:Out:\\|out_time_us=\\)\\([0-9.]+\\)" output start))
      (setq found (> (string-to-number (match-string 1 output)) 0)
            start (match-end 0)))
    found))

(defun earwig--log-mic-live ()
  "Log how long the microphone took to go live, see `earwig-log'."
  (earwig--log "record" "microphone live after %d ms"
               (round (* 1000 (float-time (time-since earwig--record-start))))))

(defun earwig--recorder-filter (proc output)
  "Keep the recorder's OUTPUT in PROC's buffer; show REC once audio flows.
Only its last few thousand characters, for an error message.  The
recorder is started without `process-adaptive-read-buffering', which
would hold back its small, frequent progress reports by up to a second."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert output)
      (when (> (buffer-size) 4000)
        (delete-region (point-min) (- (point-max) 2000)))))
  (when (and (not earwig--audio-flowing)
             (earwig--audio-reported-p output))
    (setq earwig--audio-flowing t)
    (force-mode-line-update t)
    (earwig--log-mic-live)))

(defun earwig--record (&optional wake)
  "Record a dictation or command, transcribed when it stops.
It goes into the current buffer at point.  With WAKE, it's a command
after the wake word, which Pincer records from its position WAKE
on (earwig-pincer.el), and which stops at the pause after it."
  (earwig--log "record" "%s starts%s, recording through %s, into %s at %d"
               (if (eq earwig--mode 'command) "a command" "dictation")
               (if wake (format " after the wake word, from Pincer's position %s"
                                (earwig--log-seconds wake))
                 "")
               (if wake 'pincer (earwig--recorder)) (current-buffer) (point))
  (setq earwig--record-file (make-temp-file "earwig-" nil ".wav")
        earwig--record-target (point-marker)
        earwig--record-cancelled nil
        earwig--record-wake wake
        earwig--record-final nil
        earwig--record-auto-stop (or wake earwig-command-key-stops-at-pause)
        earwig--stream-pushed-to-talk nil
        earwig--audio-flowing nil
        earwig--record-start (current-time)
        earwig--record-process
        (if (or wake (eq (earwig--recorder) 'pincer))
            (earwig-pincer-record earwig--record-file 'wav #'earwig--record-sentinel wake)
          (let ((process-adaptive-read-buffering nil))
            (make-process :name "earwig-record"
                          :command (earwig--record-command earwig--record-file)
                          :buffer (generate-new-buffer " *earwig-record*")
                          ;; On a pty, with sox's progress output, a recording
                          ;; loses whole seconds
                          :connection-type 'pipe
                          :noquery t
                          :filter #'earwig--recorder-filter
                          :sentinel #'earwig--record-sentinel))))
  (when (and (or earwig-command-preview earwig--record-auto-stop)
             (eq earwig--mode 'command))
    (setq earwig--preview-size 0
          earwig--preview-heard nil
          earwig--preview-timer (run-at-time earwig-stream-provisional-interval
                                             earwig-stream-provisional-interval
                                             #'earwig--preview-tick)))
  (when (and earwig--record-auto-stop (eq earwig--mode 'command))
    (setq earwig--auto-stop-read 0
          earwig--auto-stop-levels nil
          earwig--auto-stop-speech nil
          earwig--auto-stop-quiet 0
          earwig--auto-stop-speech-end 0
          earwig--auto-stop-timer (run-at-time 0.2 0.2 #'earwig--auto-stop-tick)))
  (earwig--show-phase 'recording))

(defun earwig--record-sentinel (proc event)
  "Send the recording to the server once its recorder PROC has exited with EVENT."
  (unless (process-live-p proc)
    (let ((output (with-current-buffer (process-buffer proc)
                    (string-trim (buffer-string)))))
      (kill-buffer (process-buffer proc))
      (earwig--preview-stop)
      (earwig--auto-stop-cancel)
      (earwig--log "record" "stopped (%s), %s of audio%s" (string-trim event)
                   (earwig--log-seconds (max 0 (- (or (file-attribute-size
                                                       (file-attributes earwig--record-file))
                                                      44)
                                                  44)))
                   (cond (earwig--record-cancelled ", cancelled")
                         (earwig--record-final
                          (format ", runs as heard: %S" earwig--record-final))
                         (t "")))
      (cond
       (earwig--record-cancelled
        (earwig--record-done))
       ((and earwig--record-final (earwig--recorder-stopped-p event proc))
        (earwig--record-transcribed t earwig--record-final))
       ((earwig--recorder-stopped-p event proc)
        (earwig--show-phase 'transcribing)
        (condition-case err
            (earwig-server-transcribe earwig--record-file #'earwig--record-transcribed
                                      "recording")
          (error
           (earwig--record-done)
           (message "Transcription failed: %s" (error-message-string err)))))
       (t
        (earwig--record-done)
        (message "Recording failed (%s): %s" (string-trim event) output))))))

(defun earwig--record-transcribed (ok output)
  "Act on the transcription OUTPUT of the recording, if OK."
  (let ((target earwig--record-target))
    (unwind-protect
        (condition-case err
            (cond
             ((not ok)
              (message "Transcription failed: %s" output))
             ;; Or a dash or dot written for silence
             ((not (earwig-heard-words-p output))
              (earwig--log-message "Nothing heard"))
             (t
              (earwig--follow-point target)
              (let ((commands (and earwig--record-wake
                                   (earwig--split-at-wake-words
                                    (earwig-clean (earwig--record-heard output))))))
                (if (cdr commands)
                    ;; The wake word said again: the commands before the last
                    (progn
                      (when earwig-log
                        (earwig--log-clean (earwig--record-heard output))
                        (earwig--log "split" "at the wake word said again: commands %S"
                                     commands))
                      (dolist (command (butlast commands))
                        (earwig--stream-woken-command
                         command (if (eq earwig-repeated-wake-word 'start-over) 'drop 'if-complete)
                         (marker-buffer target)))
                      (earwig--insert-transcription (car (last commands)) target))
                  (earwig--insert-transcription (earwig--record-heard output) target)))))
          (error (message "Inserting dictation failed: %s" (error-message-string err))))
      (earwig--record-done))))

(defun earwig--record-done ()
  "Clean up after a recording transcribed when it stopped."
  (when (and earwig--record-file (file-exists-p earwig--record-file))
    (delete-file earwig--record-file))
  (when earwig--record-target
    (set-marker earwig--record-target nil))
  (setq earwig--record-file nil
        earwig--record-target nil
        earwig--record-cancelled nil
        earwig--record-wake nil
        earwig--record-final nil)
  (earwig--show-phase nil))

(defun earwig-cancel-recording ()
  "Stop the recording and drop it: no command runs, no dictation goes in.
Bound to \\[keyboard-quit] in `earwig-mode' while a command, or dictation
without streaming, records."
  (interactive)
  (when (process-live-p earwig--record-process)
    (setq earwig--record-cancelled t)
    (earwig--hold-end)
    (earwig--preview-stop)
    (earwig--stop-recorder earwig--record-process)
    (message "%s cancelled" (if (eq earwig--mode 'command) "Voice command" "Dictation"))))

;;;; Stopping a command at a pause

(defun earwig--auto-stop-tick ()
  "Stop the command being recorded at a pause after speech.
Measures the audio recorded since last time, in 30 ms frames.  See
`earwig-command-pause'."
  (let ((file earwig--record-file))
    (when (and file
               (process-live-p earwig--record-process)
               (not earwig--stream-pushed-to-talk))
      ;; An error in a timer would only say the timer failed
      (condition-case err
          (let* ((audio (or (earwig--recorded-so-far file) ""))
                 (end (- (length audio) (mod (length audio) earwig--stream-frame-bytes))))
            (while (< earwig--auto-stop-read end)
              (let ((level (earwig--frame-level audio earwig--auto-stop-read))
                    (noise (earwig--stream-noise earwig--auto-stop-levels)))
                (push level earwig--auto-stop-levels)
                ;; About ten seconds of history
                (when (> (length earwig--auto-stop-levels) 330)
                  (setq earwig--auto-stop-levels (butlast earwig--auto-stop-levels)))
                (if (and noise (> level (* earwig-stream-speech-ratio noise)))
                    (setq earwig--auto-stop-speech t
                          earwig--auto-stop-quiet 0
                          earwig--auto-stop-speech-end
                          (+ earwig--auto-stop-read earwig--stream-frame-bytes))
                  (cl-incf earwig--auto-stop-quiet)))
              (cl-incf earwig--auto-stop-read earwig--stream-frame-bytes))
            (let ((quiet (* earwig--auto-stop-quiet 0.03)))
              (when earwig--auto-stop-speech
                ;; A pause begins: have what's said up to it transcribed
                ;; now, rather than at the next preview
                (when (and (>= quiet 0.3)
                           (< earwig--preview-size earwig--auto-stop-speech-end))
                  (earwig--preview-tick))
                (let ((complete (and (>= quiet earwig-command-pause)
                                     (earwig--command-heard-complete-p))))
                  (when (or complete
                            (and earwig-unfinished-command-pause
                                 (>= quiet earwig-unfinished-command-pause)))
                    (earwig--log "record" "%s after %.2fs of quiet, heard as %S"
                                 (if complete "a complete command" "an unfinished command")
                                 quiet (car earwig--preview-heard))
                    ;; The preview has all of it: no need to transcribe it again
                    (when complete
                      (setq earwig--record-final (car earwig--preview-heard)))
                    (earwig--auto-stop-cancel)
                    ;; A tap of the key now starts a new recording
                    (earwig--hold-end)
                    (earwig--stop-recorder earwig--record-process))))))
        (error (message "Listening for the end of the command failed: %s"
                        (error-message-string err)))))))

(defun earwig--command-heard-complete-p ()
  "Non-nil if the command said so far, all of it, is transcribed and complete.
That's commands, as when it runs (`earwig--process-text'), and not
ending with one of `earwig-chain-words', which another follows; or
ending with one of `earwig-cancel-words'.  See `earwig--preview-heard'."
  (pcase earwig--preview-heard
    (`(,raw . ,bytes)
     (and (>= bytes earwig--auto-stop-speech-end)
          (let* ((text (earwig-clean (earwig--record-heard raw)))
                 ;; The last, if the wake word was said again
                 (text (if earwig--record-wake
                           (or (car (last (earwig--split-at-wake-words text))) "")
                         text)))
            (earwig--command-complete-p (or (earwig--strip-wake-word text) text)))))))

(defun earwig--command-complete-p (text)
  "Non-nil if TEXT, cleaned up, is a complete command, or ends with a cancel word.
See `earwig-commands-complete-p' and `earwig-cancel-words'."
  (let ((text (string-trim text)))
    (and (or (earwig--strip-cancel-word text)
             (earwig-commands-complete-p text))
         t)))

(defun earwig--auto-stop-cancel ()
  "Stop listening for the pause that ends a command."
  (when (timerp earwig--auto-stop-timer)
    (cancel-timer earwig--auto-stop-timer))
  (setq earwig--auto-stop-timer nil))

;;;; Command preview

(defun earwig--recorded-so-far (file)
  "Return the audio samples the recorder has written to the WAV FILE so far.
As a unibyte string, from its data chunk on; nil if there's none yet."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (goto-char (point-min))
    ;; After the header: sox's is 44 bytes, ffmpeg's has more chunks
    (when (search-forward "data" (min (point-max) 512) t)
      (let ((start (+ (point) 4)))
        (when (< start (point-max))
          (buffer-substring-no-properties
           start (- (point-max) (mod (- (point-max) start) 2))))))))

(defun earwig--preview-tick ()
  "Transcribe the command said so far, unless it's being already.
To show it, with `earwig-command-preview', and for
`earwig-command-pause' to tell when it's complete."
  (let ((file earwig--record-file))
    (when (and file
               (process-live-p earwig--record-process)
               (not (process-live-p earwig--preview-request)))
      (let* ((audio (earwig--recorded-so-far file))
             (bytes (length audio)))
        ;; Half a second at least, and more than last time
        (when (and audio (>= bytes 16000) (> bytes earwig--preview-size))
          (let ((preview (make-temp-file "earwig-preview-" nil ".wav")))
            (setq earwig--preview-size bytes)
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert (earwig--wav-header bytes) audio)
              (let ((coding-system-for-write 'no-conversion))
                (write-region nil nil preview nil 'silent)))
            (setq earwig--preview-request
                  (earwig-server-transcribe
                   preview
                   (lambda (ok output)
                     (when (file-exists-p preview)
                       (delete-file preview))
                     ;; Not once the recording has stopped
                     (when (and ok (eq file earwig--record-file)
                                (process-live-p earwig--record-process))
                       (setq earwig--preview-heard (cons output bytes))
                       (when earwig-command-preview
                         (earwig--show-command-preview (earwig--record-heard output)))))
                   (format "preview [0–%s]" (earwig--log-seconds bytes))))))))))

(defun earwig--record-heard (raw)
  "Return the transcription RAW of the recording, as it's acted on.
That's from after the wake word on, for a command after Pincer's
wake word, as the recording starts before it; see
`earwig-pincer-after-wake-word'."
  (if earwig--record-wake
      (earwig-pincer-after-wake-word raw)
    raw))

(defun earwig--show-command-preview (raw)
  "Show the command RAW, as transcribed so far, in the echo area."
  (let ((text (earwig--provisional-command-text
               (earwig-downcase-first-word (earwig-clean raw)) t)))
    (unless (string-empty-p text)
      (let ((message-log-max nil))
        (message "%s" (earwig--provisional-propertize
                       (earwig--provisional-mark text t)
                       (earwig--provisional-command-face)))))))

(defun earwig--preview-stop ()
  "Stop showing the command being said, and drop a transcription in flight."
  (when (timerp earwig--preview-timer)
    (cancel-timer earwig--preview-timer))
  (when (process-live-p earwig--preview-request)
    (delete-process earwig--preview-request))
  (setq earwig--preview-timer nil
        earwig--preview-request nil))

(defun earwig--insert-transcription (raw target)
  "Clean up the transcription RAW, then act on it at the marker TARGET.
A command is run; dictation is inserted, as one undo step."
  (let* ((buffer (marker-buffer target))
         (text (earwig--process-text raw buffer (marker-position target))))
    (cond
     ((stringp text)
      (earwig--insert-text text target))
     ;; Headings and items
     (text
      (earwig-insert-dictation text buffer (marker-position target))))))

(defun earwig--insert-text (text target)
  "Insert the dictation TEXT at the marker TARGET; point follows it.
In a terminal, it's typed instead.  Remembered for \"scratch that\"."
  (with-current-buffer (marker-buffer target)
    (if (earwig--terminal-p (current-buffer))
        (earwig--send-to-terminal text)
      (let* ((pos (marker-position target))
             (end (+ pos (length text)))
             (back (earwig--evil-stepped-back-p (point) pos))
             (follow (or back (= (point) pos)))
             (windows (cl-remove-if-not (lambda (window) (= (window-point window) pos))
                                        (get-buffer-window-list nil nil t))))
        (save-excursion
          (goto-char pos)
          (insert text))
        (when follow
          (goto-char (if back (1- end) end)))
        (dolist (window windows)
          (set-window-point window end))
        ;; The start advances past text typed right before it, so either way
        ;; an edit next to the dictation shows up as a mismatch
        (setq earwig--last-dictation
              (list (copy-marker pos t) (copy-marker end) text))))))

(defun earwig--drop-end-punctuation (pos)
  "Delete the periods and commas the last dictation ends with, if it ends at POS.
POS is in the current buffer, and the dictation must be as it was
inserted.  For punctuation typed after it, which replaces them."
  (pcase-let ((`(,beg ,end ,text) earwig--last-dictation))
    (when (and beg
               (eq (marker-buffer end) (current-buffer))
               (= end pos)
               (equal (buffer-substring-no-properties beg end) text))
      (save-excursion
        (goto-char end)
        (skip-chars-backward ".," beg)
        (when (< (point) end)
          (delete-region (point) end)
          (setf (nth 2 earwig--last-dictation)
                (buffer-substring-no-properties beg end)))))))

(defun earwig--punctuation-typed ()
  "Have punctuation typed right after a dictation replace its period or comma.
For `post-self-insert-hook', with `earwig-mode'.  The keys are those
in `earwig-stream-flush-punctuation': \"?\" typed right after \"Is it
ready.\" gives \"Is it ready?\", whether the text came in as you spoke,
when you stopped, or a key put in its provisional text."
  (when (and (characterp last-command-event)
             (eq (char-before) last-command-event)
             (seq-contains-p earwig-stream-flush-punctuation last-command-event))
    (earwig--drop-end-punctuation (1- (point)))))

(defvar earwig--terminal-last nil
  "(BUFFER . TEXT) of the dictation last typed into a terminal.")

(defun earwig--send-to-terminal (text)
  "Type TEXT into the terminal of the current buffer.
Right after the dictation typed into it last, as the terminal shows
it before point, TEXT starting with a word gets a space first, so two
dictations or streamed segments don't run together.  A terminal's
text is otherwise left as it is, as it's screen output."
  (pcase-let ((`(,buffer . ,last) earwig--terminal-last))
    (when (and (eq buffer (current-buffer))
               (string-match-p "[^ \t\n]\\'" last)
               (eq (char-before) (aref last (1- (length last))))
               (string-match-p "\\`[[:alnum:]\"'(]" text))
      (setq text (concat " " text))))
  (setq earwig--terminal-last (cons (current-buffer) text))
  (cond
   ((derived-mode-p 'ghostel-mode) (ghostel-send-string text))
   ((derived-mode-p 'vterm-mode) (vterm-send-string text))
   ((derived-mode-p 'eat-mode) (eat-term-send-string eat-terminal text))
   ((derived-mode-p 'term-mode) (term-send-raw-string text))))

(defun earwig--run-command-in (text buffer)
  "Run the voice command TEXT in BUFFER, where it was recorded.
In the selected window's buffer if BUFFER is gone.  Always made current:
this runs from a timer, which finds whatever buffer other timers and
process code left current."
  (unwind-protect
      (progn
        ;; Given while dictating, it ends the dictation so far
        (earwig--stream-break)
        (with-current-buffer (if (buffer-live-p buffer) buffer (window-buffer))
          (let ((before (and earwig-log (current-message))))
            (earwig--log "command" "runs in %s at %d" (current-buffer) (point))
            (earwig-run-command text)
            (let ((after (and earwig-log (current-message))))
              (earwig--log "command" "done, in %s at %d%s" (current-buffer) (point)
                           (if (and after (not (equal after before)))
                               (format ", saying %S" (substring-no-properties after))
                             "")))))
        (earwig--stream-after-command))
    ;; REC again in the mode line, unless the next command is heard already
    (when (eq earwig--command-heard 'running)
      (earwig--stream-command-heard nil))))

(defun earwig--process-text (text target pos)
  "Clean up TEXT recorded for buffer TARGET at POS, then act on it.
Runs a command, or says dictation can't go in, and returns nil.
Otherwise returns the dictation to insert, fitted to where it goes; or,
when it makes headings or list items, a list of parts for
`earwig-insert-parts'."
  (let ((result (earwig--process-text-1 text target pos)))
    (when earwig-log
      (earwig--log-transcription text result))
    (unless (eq result 'command)
      result)))

(defun earwig--log-transcription (raw result)
  "Log the transcription RAW and RESULT, what it gave; see `earwig-log'.
RESULT is what `earwig--process-text' returns, or the symbol `command'."
  (let ((print-escape-newlines t))
    (earwig--log "heard" "%S => %s" raw
             (pcase result
               ('command "command")
               ('nil "nothing inserted")
               ((pred stringp) (prin1-to-string (substring-no-properties result)))
               (_ (prin1-to-string
                   (mapcar (lambda (part)
                             (if (stringp part) (substring-no-properties part) part))
                           result)))))))

(defun earwig--log-command (command)
  "Log the voice COMMAND as its provisional text shows, faces and all.
See `earwig-log'."
  (when earwig-log
    (earwig--log-insert "command" (earwig--provisional-mark
                                   (earwig--provisional-command-text command t) t))))

(defun earwig--log-command-corrections (command)
  "Log the `earwig-corrections-commands' that change COMMAND, if any.
And whether they were needed: they're used only if COMMAND doesn't read
as said."
  (let ((corrected (earwig-apply-corrections command t)))
    (unless (string= corrected command)
      (earwig--log-clean command t)
      (earwig--log "cleanup" "the command corrections %s"
                   (if (equal (nth 3 (earwig--reading command)) corrected)
                       "are used, as it reads only with them"
                     "aren't needed, as it reads as said")))))

(defun earwig--process-text-1 (text target pos)
  "Do the work of `earwig--process-text' for TEXT, TARGET and POS.
Return the symbol `command' for a command."
  (let* ((text (if earwig-log (earwig--log-clean text) (earwig-clean text)))
         (command (cond
                   ;; A wake word said by habit is dropped
                   ((eq earwig--mode 'command)
                    (or (earwig--strip-wake-word text) text))
                   (earwig-wake-word-commands
                    (let ((rest (earwig--strip-wake-word text)))
                      (and rest
                           (or (earwig--strip-cancel-word rest) (earwig-find-commands rest))
                           rest))))))
    (cond
     (command
      (earwig--act-on-command command target))
     ((or (null target) (string-empty-p text))
      nil)
     ;; A terminal's text around point is screen output, not a sentence
     ((earwig--terminal-p target)
      (let ((formatted (substring-no-properties (earwig-apply-format text t))))
        (earwig--log-change "spoken punctuation" text formatted)
        formatted))
     ((buffer-local-value 'buffer-read-only target)
      (message "Buffer is read-only, dictation not inserted: %s" text)
      nil)
     ((earwig-structure-split text target pos))
     (t
      (let* ((formatted (earwig-apply-format text nil target pos))
             (before (and earwig-log (earwig--log-before target pos)))
             (pos (earwig-absorb-before formatted target pos))
             (fitted (earwig-fit-to-context formatted target pos)))
        (when earwig-log
          (earwig--log-change "spoken punctuation and formatting" text formatted)
          (earwig--log-change "what's before it in the buffer" before
                              (earwig--log-before target pos))
          (earwig--log-change "fitted to where it goes" formatted fitted))
        fitted)))))

(defun earwig--log-before (buffer pos)
  "Return the line in BUFFER up to POS, its last 40 characters, for the log."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (buffer-substring-no-properties (max (line-beginning-position) (- pos 40)) pos))))

(defun earwig--act-on-command (command target)
  "Run the voice COMMAND, cleaned up, in the buffer TARGET; return `command'.
Unless it ends with one of `earwig-cancel-words', which cancels it."
  (let ((cancelled (earwig--strip-cancel-word command)))
    (when (and earwig-log (not cancelled))
      (earwig--log-command-corrections command))
    (earwig--log-command command)
    (if cancelled
        (earwig--log-message "Voice command cancelled%s"
                 (if (string-empty-p (car cancelled))
                     ""
                   (format ": %s" (earwig--command-text (car cancelled)))))
      ;; CMD in the mode line until it has run
      (earwig--stream-command-heard 'running)
      ;; Outside the process sentinel, so commands can prompt and switch buffers
      (run-at-time 0 nil #'earwig--run-command-in command target))
    'command))

(defun earwig--terminal-p (buffer)
  "Non-nil if BUFFER is a terminal, where dictation is typed instead of inserted."
  (with-current-buffer buffer
    (derived-mode-p 'ghostel-mode 'vterm-mode 'eat-mode 'term-mode)))

(defun earwig--follow-point (marker)
  "Move MARKER to point in the selected window, for dictation to go there.
So a click, or a command that moves point or selects another buffer,
takes the dictation along.  In a terminal, where output moves point,
only selecting another buffer does.  Return non-nil if MARKER moved."
  (let* ((window (selected-window))
         (buffer (window-buffer window))
         (pos (window-point window)))
    (unless (and (eq buffer (marker-buffer marker))
                 (or (= pos marker)
                     (earwig--terminal-p buffer)
                     (with-current-buffer buffer
                       (earwig--evil-stepped-back-p pos marker))))
      (set-marker marker pos buffer)
      t)))

(defvar evil-state)
(defvar evil-move-cursor-back)

(defun earwig--evil-stepped-back-p (pos target)
  "Non-nil if point at POS is where evil left it, leaving insert state at TARGET.
In the current buffer.  That moves point back a character, with
`evil-move-cursor-back', to have the cursor on the last one typed; so
it's no move away from where the dictation goes, and dictation going in
moves point along to its last character."
  (and (bound-and-true-p evil-local-mode)
       (bound-and-true-p evil-move-cursor-back)
       (memq evil-state '(normal motion))
       (= pos (1- target))
       (not (eq (char-after pos) ?\n))))

(defun earwig--recording-p ()
  "Non-nil while recording, streaming or not."
  (or (earwig-stream-recording-p)
      (process-live-p earwig--record-process)))

(defvar earwig--stream-fallback-noted nil
  "Non-nil once *Messages* says why dictation doesn't stream.")

(defun earwig--stream-p (mode)
  "Non-nil if a recording for MODE should stream, see `earwig-streaming'.
Commands never do, as they're only run once complete.  Streaming needs
sox; with ffmpeg, dictation is transcribed when it stops instead, as
*Messages* says once."
  (and earwig-streaming
       (eq mode 'dictate)
       (or (memq (earwig--recorder) '(sox pincer))
           (progn
             (unless earwig--stream-fallback-noted
               (setq earwig--stream-fallback-noted t)
               (let ((inhibit-message t))
                 (message "Earwig: streaming is off, as ffmpeg records; dictation is transcribed when you stop.  %s"
                          (if (eq earwig-recorder 'ffmpeg)
                              "For streaming, set `earwig-recorder' to `sox'"
                            (format "For streaming, install sox (%s)"
                                    (earwig--install-hint "sox"))))))
             nil))))

(defun earwig--toggle-recording (mode)
  "Start recording for MODE (`dictate' or `command'), or stop recording."
  (cond
   ((earwig-stream-recording-p)
    (earwig-stream-stop))
   ((process-live-p earwig--record-process)
    (earwig--stop-recorder earwig--record-process))
   ((or (earwig--record-transcribing-p) (earwig-stream-transcribing-p))
    (message "Still transcribing the last recording"))
   ((not earwig-input-device)
    (user-error "Set `earwig-input-device' to a microphone"))
   ((earwig-server-ready-p)
    ;; Only dictation is refused, and with wake-word commands it isn't
    ;; known yet whether this is dictation
    (when (and (eq mode 'dictate)
               (not earwig-wake-word-commands)
               buffer-read-only
               (not (earwig--terminal-p (current-buffer))))
      (user-error "Buffer is read-only, can't dictate here"))
    ;; Before anything is set up for the recording, as it may fail
    (when (eq (earwig--recorder) 'pincer)
      (earwig-pincer-ensure))
    (setq earwig--mode mode)
    (if (earwig--stream-p mode)
        (earwig-stream-start)
      (earwig--record)))
   ((earwig-server-running-p)
    (message "The speech server is still starting"))
   ((not earwig-speech-server-command)
    (user-error "No speech server answers at %s: start it, or set `earwig-speech-server-command'"
                (earwig-server-url)))
   ((y-or-n-p "The speech server isn't running.  Start it? ")
    (earwig-speech-server-start))))

;;;###autoload
(defun earwig-dictate ()
  "Dictate: tap to start and tap again to stop, or push to talk.
Stopping transcribes into the current buffer at point.  Pushed to talk,
held down, it records until let go."
  (interactive)
  (earwig--tap-or-hold (lambda () (earwig--toggle-recording 'dictate)) t))

;;;###autoload
(defun earwig-command ()
  "Give a voice command: tap to start and tap again to stop, or push to talk.
Stopping runs the command spoken.  Pushed to talk, held down, it records
until let go.  Say \"what can I say\" for the commands."
  (interactive)
  (earwig--tap-or-hold (lambda () (earwig--toggle-recording 'command)) t))

(defun earwig--key-mode (keys alist)
  "Return the mode ALIST gives the key sequence KEYS, a vector, if any."
  (cdr (seq-find (lambda (entry) (equal (key-parse (car entry)) keys)) alist)))

(defun earwig--mode-keys (mode)
  "Return the voice keys that record for MODE, as for `keymap-set'."
  (seq-uniq (mapcar #'car (seq-filter (lambda (entry) (eq (cdr entry) mode))
                                      (append earwig-toggle-keys
                                              (and earwig-push-to-talk earwig-push-to-talk-keys))))))

(defun earwig-voice-key ()
  "Record with the key pressed, as the voice key options say.
A toggle key (`earwig-toggle-keys') records from a tap to the next, a
push-to-talk key (`earwig-push-to-talk-keys', with `earwig-push-to-talk')
while held, and a key that's both does either."
  (interactive)
  (earwig--voice-key-press (this-command-keys-vector)))

(defun earwig--voice-key-press (keys)
  "Record with the voice key KEYS, a vector, just pressed."
  (let* ((push-to-talk (and earwig-push-to-talk
                            (earwig--key-mode keys earwig-push-to-talk-keys)))
         (toggle (earwig--key-mode keys earwig-toggle-keys))
         (mode (or push-to-talk toggle)))
    (cond
     ((not mode)
      (user-error "%s isn't in `earwig-toggle-keys' or `earwig-push-to-talk-keys'"
                  (key-description keys)))
     (toggle
      (earwig--tap-or-hold (lambda () (earwig--toggle-recording mode)) push-to-talk))
     (t
      (earwig--push-to-talk mode keys)))))

;;;###autoload
(define-minor-mode earwig-mode
  "Push-to-talk dictation and voice commands.
Tap a toggle key to start recording and tap it again to stop, or, with
`earwig-push-to-talk', hold a push-to-talk key to record until you let
go.  The keys are in `earwig-toggle-keys', `earwig-push-to-talk-keys'
and `earwig-correct-keys'.

\\{earwig-mode-map}"
  :global t
  :group 'earwig
  (if earwig-mode
      (progn
        (earwig--platform-warn)
        (earwig--bind-keys)
        (add-hook 'post-self-insert-hook #'earwig--punctuation-typed)
        (condition-case err
            (earwig-speech-server-autostart)
          (error (message "Earwig: %s" (error-message-string err)))))
    (remove-hook 'post-self-insert-hook #'earwig--punctuation-typed)
    (earwig--hold-end)
    ;; Wake-word commands go with Earwig
    (when (bound-and-true-p earwig-listen-mode)
      (earwig-listen-mode -1)))
  ;; Pincer runs only while this mode is on
  (when (or (eq (earwig--recorder) 'pincer) (featurep 'earwig-pincer))
    (condition-case err
        (earwig-pincer-update)
      (error (message "Earwig: %s" (error-message-string err))))))

(provide 'earwig)
;;; earwig.el ends here
