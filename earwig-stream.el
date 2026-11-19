;;; earwig-stream.el --- Dictation transcribed while you speak  -*- lexical-binding: t; -*-

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

;; With `earwig-streaming', dictation is transcribed in segments
;; instead of when it stops.  sox records continuously; every so often
;; the new audio is measured in 30 ms frames against the background
;; noise, and at each pause of `earwig-stream-pause' seconds after
;; speech, the audio up to the middle of the pause is sent to the speech
;; server as a segment and inserted while you keep talking.  When
;; recording stops, whatever is left is sent too, so nothing is lost even
;; if no pause was found.  Each segment is cleaned up like a whole
;; dictation, and corrections spanning two segments are applied across
;; the join.  Commands, and dictation without streaming, are recorded
;; in one piece instead (earwig.el).
;;
;; Segments go where point is, in the selected window, so clicking
;; elsewhere or a command that moves point takes the dictation along.
;; The segment being spoken ends where point moved: what was said before
;; still goes where it was said, where its provisional text shows, and
;; what's said after goes to point.
;; A command given while dictating (`earwig-wake-word-commands'), or
;; dictation moving on, ends the dictation so far: it's one undo step
;; and what \"scratch that\" takes back.
;;
;; While you talk, the part since the last pause is transcribed about
;; every second too and shown as provisional text, in
;; `earwig-provisional', where the segment will go, and with
;; `earwig-provisional-command' too when it starts with a wake word.
;; An icon leads it, where it goes, as in the mode line: a red dot,
;; `earwig-recording-icon', or for a command a blue triangle,
;; `earwig-command-icon', in place of the wake word and of each of
;; `earwig-chain-words' that follows a command (that one is
;; `earwig-provisional-chain-mark').
;; It's not in the buffer; the segment's final transcription replaces
;; it.  In dictation started with a tap, a key pressed while it shows
;; flushes it: it goes in as the segment's final text, before what the
;; key does (`earwig-stream-flush-on-key'), and what's said after it is
;; a new segment.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'earwig-platform)
(require 'earwig-server)
(require 'earwig-cleanup)

(defgroup earwig-stream nil
  "Dictation transcribed while you speak."
  :group 'earwig
  :prefix "earwig-stream-")

(defcustom earwig-streaming t
  "Non-nil to transcribe dictation segment by segment while recording.
Needs sox (see `earwig-recorder'); when ffmpeg records, dictation is
transcribed when it stops, as when this is nil, and *Messages* says so."
  :type 'boolean)

(defcustom earwig-stream-pause 1.5
  "Seconds of silence after speech that end a segment.
Shorter means text appears sooner, but more pauses inside a sentence
end up as a full stop."
  :type 'number)

(defcustom earwig-stream-speech-ratio 3.0
  "How many times louder than the background noise counts as speech.
Relative rather than absolute, as microphones differ a lot in level;
lower it if pauses are found in the middle of quiet speech, raise it if
background noise keeps segments from ending."
  :type 'number)

;; Shared with earwig.el
(defvar earwig-input-device)
(defvar earwig--audio-flowing)
(defvar earwig--record-start)
(defvar earwig--last-dictation)
(defvar earwig-wake-word-commands)
(defvar earwig-recording-icon)
(defvar earwig--command-heard)
(defvar earwig-command-icon)
(declare-function earwig--process-text "earwig" (text target pos))
(declare-function earwig--terminal-p "earwig" (buffer))
(declare-function earwig--follow-point "earwig" (marker))
(declare-function earwig--evil-stepped-back-p "earwig" (pos target))
(declare-function earwig--drop-end-punctuation "earwig" (pos))
(declare-function earwig--strip-wake-word "earwig-commands" (text))
(declare-function earwig--chain-cuts "earwig-commands" (text))
(declare-function earwig--command-text "earwig-commands" (text))
(declare-function earwig-find-command "earwig-commands" (text))
(declare-function earwig--strip-cancel-word "earwig-commands" (text))
(declare-function earwig--recorder-filter "earwig" (proc output))
(declare-function earwig--show-phase "earwig" (phase))
(declare-function earwig--send-to-terminal "earwig" (text))
(declare-function earwig-insert-parts "earwig-structure" (parts pos))

(defcustom earwig-stream-provisional t
  "Non-nil to show provisional text for the segment being spoken."
  :type 'boolean)

(defcustom earwig-stream-provisional-interval 1.0
  "Least seconds between the starts of two provisional transcriptions."
  :type 'number)

(defcustom earwig-stream-flush-on-key t
  "Non-nil for a key pressed while provisional text shows to put it in.
The provisional text goes in as the segment's final text, then the key
does what it does, as typing after it.  Only in dictation started with
a tap, not pushed to talk, and not for the voice keys, mouse events, or
a command said after a wake word.  A key in
`earwig-stream-flush-punctuation' replaces the period or comma the text
ends with."
  :type 'boolean)

(defcustom earwig-stream-flush-punctuation ".,:;!?…—–-"
  "Keys that replace the period or comma dictation ends with.
Typing \",\" after \"Hello there.\" gives \"Hello there,\": right after
the last dictation, as long as it's as it went in, streamed or not,
and after the provisional text a key flushes (see
`earwig-stream-flush-on-key').  With `earwig-mode'; \"\" for none."
  :type 'string)

(defcustom earwig-stream-max-segment 15
  "Seconds after which a segment without a pause is cut anyway.
At the quietest moment of its last 1.5 s, so provisional transcriptions,
which grow with the segment, stay quick."
  :type '(choice (const :tag "No limit" nil) number))

(defface earwig-provisional '((t :inherit shadow :slant italic))
  "Face for provisional text, until the segment's final transcription."
  :group 'earwig-stream)

(defface earwig-provisional-command '((t))
  "Face for provisional text of a command given while dictating.
That's text starting with one of `earwig-wake-words', with
`earwig-wake-word-commands'; on top of `earwig-provisional'.  While
this sets no color, the text has that of CMD in the mode line,
`earwig-mode-line-command' (blue by default)."
  :group 'earwig-stream)

(defcustom earwig-provisional-command-display 'buffer
  "Where provisional text of a command given while dictating shows.
`buffer' where the dictation goes, as provisional text of dictation
does; `echo-area' in the echo area, below the minibuffer prompt's
place, as a command given with a command key does, leaving the
dictation in the buffer as it is.  See `earwig-wake-word-commands'."
  :type '(choice (const :tag "In the buffer" buffer)
                 (const :tag "In the echo area" echo-area))
  :group 'earwig-stream)

(defcustom earwig-provisional-icons t
  "Non-nil for an icon before provisional text, where it goes.
The one before REC in the mode line, `earwig-recording-icon', or for
a command given while dictating, the one before CMD,
`earwig-command-icon', in place of the wake word.  See
`earwig-wake-word-commands'."
  :type 'boolean
  :group 'earwig-stream)

(defcustom earwig-provisional-chain-mark nil
  "Mark in place of chain words in provisional text of a command.
It replaces each of `earwig-chain-words' once what's before it is a
command, as in \"▶ select last sentence ▶ cut that\".  nil for
`earwig-command-icon'.  In the color of `earwig-mode-line-command'."
  :type '(choice (const :tag "The command icon" nil) string)
  :group 'earwig-stream)

(defconst earwig--stream-frame-bytes 960
  "Bytes in a 30 ms frame of the 16 kHz, 16-bit mono recording.")

(defvar earwig--stream-input nil
  "Input arguments for sox instead of the microphone, e.g. (\"in.wav\"), for testing.")

(defvar earwig--stream-process nil "The sox process recording.")
(defvar earwig--stream-dir nil "Directory with the recording and its segments.")
(defvar earwig--stream-read 0 "Bytes of the recording measured so far.")
(defvar earwig--stream-segment-start 0 "Byte offset where the current segment starts.")
(defvar earwig--stream-speech nil "Non-nil once the current segment has speech.")
(defvar earwig--stream-quiet 0 "Frames without speech since the last speech.")
(defvar earwig--stream-levels nil "Recent frame levels, newest first, for the noise.")
(defvar earwig--stream-count 0 "Number of segments cut so far.")
(defvar earwig--stream-queue nil
  "Segments waiting to be transcribed, as (FILE . START).
START is the byte offset where the segment starts in the recording.")
(defvar earwig--stream-curl nil
  "The transcription request in flight, until its text has been acted on.
Not just until its process exits: Emacs may read the output of several
finished requests at once, and run their callbacks in any order.")
(defvar earwig--stream-timer nil "Timer measuring the new audio.")
(defvar earwig--stream-target nil "Marker where the next segment goes; advances.")
(defvar earwig--stream-start nil "Marker at the start of the dictation.")
(defvar earwig--stream-join nil "Marker where the last segment was inserted.")
(defvar earwig--stream-moves nil
  "Where point moved to, for segments spoken after it did.
Each is (START . MARKER): the segments from byte START on go to MARKER,
once the ones spoken before point moved are in.")
(defvar earwig--stream-change-group nil
  "Change group making the dictation so far one undo step, once it has text.")
(defvar earwig--stream-overlay nil "Overlay showing the provisional text.")
(defvar earwig--stream-echo nil
  "The provisional text shown in the echo area, if any.")
(defvar earwig--stream-provisional-for nil
  "Byte offset of the segment the provisional text shown is for, if any.")
(defvar earwig--stream-provisional-time 0 "When the last provisional pass started.")
(defvar earwig--stream-provisional-end 0 "Byte offset the last provisional pass reached.")
(defvar earwig--stream-provisional-raw nil
  "The transcription of the provisional text shown, and the byte offset it reaches.
As (RAW . END), for `earwig--stream-flush'.")
(defvar earwig--stream-pushed-to-talk nil
  "Non-nil if the streaming dictation is pushed to talk, its key held.
Set by earwig-hold.el once it tells the hold from a tap.")
(defvar earwig--stream-flushed nil
  "Byte offsets of the segments flushed, whose final text is dropped.")

(defun earwig-stream-recording-p ()
  "Non-nil while a streaming dictation is recording."
  (process-live-p earwig--stream-process))

(defun earwig-stream-transcribing-p ()
  "Non-nil while segments of a stopped streaming dictation are transcribed."
  (and (not (earwig-stream-recording-p)) earwig--stream-dir t))

;;;; Recording

(defun earwig--stream-raw ()
  "The raw recording: 16 kHz, signed 16-bit, mono samples."
  (expand-file-name "audio.raw" earwig--stream-dir))

(defun earwig--stream-command ()
  "Return the sox command recording to `earwig--stream-raw'."
  `(,@(earwig--sox-program) "-S" "-V1" "--buffer" "1920"
    ,@(or earwig--stream-input (earwig--sox-input-args))
    "-t" "raw" "-r" "16000" "-c" "1" "-b" "16" "-e" "signed-integer"
    ,(earwig--stream-raw)))

(defun earwig-stream-start ()
  "Start a streaming dictation into the current buffer at point."
  (setq earwig--stream-dir (make-temp-file "earwig-stream-" t)
        earwig--stream-read 0
        earwig--stream-segment-start 0
        earwig--stream-speech nil
        earwig--stream-quiet 0
        earwig--stream-levels nil
        earwig--stream-count 0
        earwig--stream-queue nil
        earwig--stream-curl nil
        earwig--stream-target (copy-marker (point) t)
        earwig--stream-start (copy-marker (point))
        earwig--stream-join nil
        earwig--stream-moves nil
        earwig--stream-change-group nil
        earwig--stream-overlay nil
        earwig--stream-provisional-for nil
        earwig--stream-provisional-time 0
        earwig--stream-provisional-end 0
        earwig--stream-provisional-raw nil
        earwig--stream-echo nil
        earwig--command-heard nil
        earwig--stream-flushed nil
        earwig--stream-pushed-to-talk nil
        earwig--audio-flowing nil
        earwig--record-start (current-time))
  (setq earwig--stream-process
        (let ((process-adaptive-read-buffering nil))
          (make-process :name "earwig-stream"
                        :command (earwig--stream-command)
                        :buffer (generate-new-buffer " *earwig-stream-sox*")
                        :connection-type 'pipe
                        :noquery t
                        :filter #'earwig--recorder-filter
                        :sentinel #'earwig--stream-recorder-sentinel)))
  (setq earwig--stream-timer (run-at-time 0.2 0.2 #'earwig--stream-measure))
  (add-hook 'pre-command-hook #'earwig--stream-flush-on-key)
  (add-hook 'post-command-hook #'earwig--stream-point-moved)
  (earwig--show-phase 'recording))

(defun earwig-stream-stop ()
  "Stop recording; the audio not transcribed yet is, and inserted."
  (when (earwig-stream-recording-p)
    (earwig--stop-recorder earwig--stream-process)))

(defun earwig--stream-recorder-sentinel (proc event)
  "Send the rest of the recording once sox (PROC) has exited with EVENT."
  (unless (process-live-p proc)
    (cancel-timer earwig--stream-timer)
    (unless (earwig--recorder-stopped-p event)
      (message "Recording failed (%s): %s" (string-trim event)
               (with-current-buffer (process-buffer proc) (string-trim (buffer-string)))))
    (kill-buffer (process-buffer proc))
    (if earwig--stream-dir
        (progn
          (earwig--show-phase 'transcribing)
          (earwig--stream-measure t))
      (earwig--show-phase nil))))

;;;; Finding the pauses

(defun earwig--frame-level (bytes start)
  "Return the RMS level of the 30 ms frame in BYTES at START."
  (let ((sum 0))
    (cl-loop for i from start below (+ start earwig--stream-frame-bytes) by 2
             do (let ((sample (logior (aref bytes i) (ash (aref bytes (1+ i)) 8))))
                  (when (>= sample 32768)
                    (setq sample (- sample 65536)))
                  (setq sum (+ sum (* sample sample)))))
    (sqrt (/ sum (/ earwig--stream-frame-bytes 2.0)))))

(defun earwig--stream-noise (&optional levels)
  "Return the background noise level: the quietest tenth of recent frames.
Those of the streaming dictation, or LEVELS.  Nil until there are
enough frames to tell."
  (when (>= (length (or levels earwig--stream-levels)) 10)
    (let ((levels (sort (copy-sequence (or levels earwig--stream-levels)) #'<)))
      (nth (/ (length levels) 10) levels))))

(defun earwig--stream-measure (&optional final)
  "Measure the audio recorded since last time, cutting segments at pauses.
With FINAL, also send the rest of the recording as the last segment."
  (when earwig--stream-dir
    (let* ((raw (earwig--stream-raw))
           (size (or (file-attribute-size (file-attributes raw)) 0))
           (end (- size (mod size earwig--stream-frame-bytes)))
           (pause-frames (round (/ earwig-stream-pause 0.03))))
      (when (> end earwig--stream-read)
        (let ((bytes (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally raw nil earwig--stream-read end)
                       (buffer-string))))
          (cl-loop for offset from 0 below (length bytes) by earwig--stream-frame-bytes
                   do (let ((level (earwig--frame-level bytes offset))
                            (noise (earwig--stream-noise)))
                        (push level earwig--stream-levels)
                        ;; About ten seconds of history
                        (when (> (length earwig--stream-levels) 330)
                          (setq earwig--stream-levels (butlast earwig--stream-levels)))
                        (if (and noise (> level (* earwig-stream-speech-ratio noise)))
                            (setq earwig--stream-speech t
                                  earwig--stream-quiet 0)
                          (cl-incf earwig--stream-quiet))
                        (let ((frame-end (+ earwig--stream-read offset earwig--stream-frame-bytes)))
                          (cond
                           ((and earwig--stream-speech
                                 (>= earwig--stream-quiet pause-frames))
                            ;; Cut in the middle of the pause
                            (earwig--stream-cut (- frame-end (* (/ earwig--stream-quiet 2)
                                                                  earwig--stream-frame-bytes))))
                           ((and earwig-stream-max-segment
                                 (> (- frame-end earwig--stream-segment-start)
                                    (* earwig-stream-max-segment 32000)))
                            (earwig--stream-cut (earwig--stream-quietest frame-end))
                            ;; Cut in the middle of speech
                            (setq earwig--stream-speech t))))))
          (setq earwig--stream-read end)))
      ;; The rest is sent if it has speech; noise alone makes Orukeet
      ;; invent text.  If no pause was found at all, it's sent anyway, so
      ;; nothing is lost even when the speech wasn't told from the noise.
      (when (and final
                 (> (- end earwig--stream-segment-start) 6400)
                 (or earwig--stream-speech (zerop earwig--stream-count)))
        (earwig--stream-cut end))
      ;; Before sending, so a segment cut where point moved goes now
      (unless final
        (earwig--stream-follow-point))
      (earwig--stream-next)
      (unless final
        (earwig--stream-maybe-provisional end)))))

(defun earwig--stream-quietest (frame-end &optional frames)
  "Return the middle of the quietest frame in the 1.5 s up to FRAME-END.
With FRAMES, in that many frames up to it instead."
  (let* ((recent (seq-take earwig--stream-levels (or frames 50)))
         (index (cl-position (apply #'min recent) recent)))
    (- frame-end (* index earwig--stream-frame-bytes) (/ earwig--stream-frame-bytes 2))))

(defun earwig--le-bytes (number count)
  "Return NUMBER as COUNT little-endian bytes."
  (apply #'unibyte-string
         (cl-loop for i below count collect (logand (ash number (* -8 i)) 255))))

(defun earwig--wav-header (length)
  "Return the WAV header for LENGTH bytes of 16 kHz, 16-bit mono samples."
  (concat "RIFF" (earwig--le-bytes (+ 36 length) 4) "WAVEfmt "
          (earwig--le-bytes 16 4) (earwig--le-bytes 1 2) (earwig--le-bytes 1 2)
          (earwig--le-bytes 16000 4) (earwig--le-bytes 32000 4)
          (earwig--le-bytes 2 2) (earwig--le-bytes 16 2)
          "data" (earwig--le-bytes length 4)))

(defun earwig--stream-write-wav (file beg end)
  "Write the recording from byte BEG to END to FILE as a WAV file."
  (let ((length (- end beg)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (earwig--wav-header length))
      (goto-char (point-max))
      (insert-file-contents-literally (earwig--stream-raw) nil beg end)
      (let ((coding-system-for-write 'no-conversion))
        (write-region nil nil file nil 'silent)))))

(defun earwig--stream-cut (end)
  "Queue the recording from the current segment start to END as a segment."
  (let ((file (expand-file-name (format "segment%03d.wav" (cl-incf earwig--stream-count))
                                earwig--stream-dir)))
    (earwig--stream-write-wav file earwig--stream-segment-start end)
    (setq earwig--stream-queue (append earwig--stream-queue
                                         (list (cons file earwig--stream-segment-start)))
          earwig--stream-segment-start end
          earwig--stream-speech nil
          earwig--stream-quiet 0)))

;;;; Transcribing

(defun earwig--stream-request (file callback)
  "Send FILE to the server; call CALLBACK with success and the output when done.
FILE is deleted then.  Only one request runs at a time, as the server
takes one at a time, and the segments go in in order: the next one is
only sent once CALLBACK has run for this one."
  (let (request)
    (setq request
          (earwig-server-transcribe file (lambda (ok output)
                                           (when (eq earwig--stream-curl request)
                                             (setq earwig--stream-curl nil))
                                           (when (file-exists-p file)
                                             (delete-file file))
                                           (funcall callback ok output)))
          earwig--stream-curl request)))

(defun earwig--stream-next ()
  "Send the next queued segment, or finish once everything is inserted."
  (unless earwig--stream-curl
    (pcase-let ((`(,file . ,start) (pop earwig--stream-queue)))
      (cond
       ;; Too short to hold a word
       ((and file (< (file-attribute-size (file-attributes file)) (+ 44 3200)))
        (delete-file file)
        (earwig--stream-provisional-done start)
        (earwig--stream-next))
       (file
        (earwig--stream-request
         file (lambda (ok output) (earwig--stream-transcribed ok output start))))
       ((and (not (earwig-stream-recording-p)) earwig--stream-dir)
        (earwig--stream-finish))))))

(defun earwig--stream-transcribed (ok output start)
  "Insert OUTPUT for the segment at byte START if OK, then send the next one."
  (condition-case err
      (cond
       ((memql start earwig--stream-flushed)
        (setq earwig--stream-flushed (delq start earwig--stream-flushed)))
       ((not ok)
        (message "Transcription failed: %s" output))
       ((not (string-empty-p output))
        (earwig--stream-insert output start)))
    (error (message "Inserting dictation failed: %s" (error-message-string err))))
  (earwig--stream-provisional-done start)
  (earwig--stream-next))

;;;; Provisional text

(defun earwig--stream-maybe-provisional (end)
  "Transcribe the segment being spoken, up to byte END, if it's time to."
  (let ((buffer (and earwig--stream-target (marker-buffer earwig--stream-target))))
    (when (and earwig-stream-provisional
               (earwig-stream-recording-p)
               (not earwig--stream-curl)
               (null earwig--stream-queue)
               earwig--stream-speech
               buffer
               (not (buffer-local-value 'buffer-read-only buffer))
               ;; Half a second of it, grown by a tenth since the last pass
               (>= (- end earwig--stream-segment-start) 16000)
               (>= (- end (max earwig--stream-provisional-end earwig--stream-segment-start))
                   3200)
               (>= (- (float-time) earwig--stream-provisional-time)
                   earwig-stream-provisional-interval))
      (let ((file (expand-file-name "provisional.wav" earwig--stream-dir))
            (start earwig--stream-segment-start))
        (earwig--stream-write-wav file start end)
        (setq earwig--stream-provisional-time (float-time)
              earwig--stream-provisional-end end)
        (earwig--stream-request
         file (lambda (ok output)
                (when ok
                  (earwig--stream-show-provisional output start end))
                (earwig--stream-next)))))))

(defun earwig--stream-show-provisional (raw start &optional end)
  "Show the transcription RAW of the segment at byte START as provisional text.
In the buffer as an overlay where the segment will go; for a terminal,
or a command with `earwig-provisional-command-display' set to
`echo-area', in the echo area.  RAW is of the audio up to byte END."
  ;; Only for the segment being spoken or one waiting for its final text
  (when (and earwig--stream-dir earwig--stream-target
             (or (= start earwig--stream-segment-start)
                 (rassoc start earwig--stream-queue)))
    ;; Where the segment will go, which is where point was when it was spoken
    (earwig--stream-move-on start)
    (let* ((target earwig--stream-target)
           (buffer (marker-buffer target))
           (clean (earwig-clean raw))
           (face (earwig--provisional-face clean))
           (command (and (not (eq face 'earwig-provisional))
                         (earwig--provisional-command-text clean)))
           (terminal (and buffer (earwig--terminal-p buffer)))
           (echo (or terminal
                     (and command (eq earwig-provisional-command-display 'echo-area))))
           (text (and buffer
                      (or command
                          (earwig-apply-format clean terminal (unless terminal buffer)
                                               (marker-position target))))))
      ;; A command shows its mark before anything follows the wake word
      (unless (or (null buffer) (and (not command) (string-empty-p text)))
        (setq earwig--stream-provisional-for start
              earwig--stream-provisional-raw (cons raw end))
        (earwig--stream-command-heard (and command t))
        (if echo
            (progn
              (when (overlayp earwig--stream-overlay)
                (overlay-put earwig--stream-overlay 'before-string nil))
              (earwig--stream-echo (earwig--provisional-propertize
                                    (earwig--provisional-mark text command) face)))
          (earwig--stream-echo nil)
          (setq text (earwig--provisional-mark
                      (if command
                          (with-current-buffer buffer
                            (if (memq (char-before target) '(nil ?\s ?\t ?\n))
                                text
                              (concat " " text)))
                        (earwig-fit-to-context text buffer (marker-position target)))
                      command))
          (unless (overlayp earwig--stream-overlay)
            ;; Advancing, so it stays after final text inserted at it
            (setq earwig--stream-overlay (make-overlay target target buffer t t)))
          (move-overlay earwig--stream-overlay target target buffer)
          (overlay-put earwig--stream-overlay 'before-string
                       (earwig--provisional-propertize text face)))))))

(defun earwig--provisional-propertize (text face)
  "Return TEXT with FACE, below the face of its mark."
  (add-face-text-property 0 (length text) face t text)
  text)

(defun earwig--provisional-face (text)
  "Return the face for the provisional TEXT, cleaned up.
With `earwig-provisional-command' if it's a command given while
dictating, and the color of `earwig-mode-line-command' unless that
face sets one."
  ;; The space lets a wake word with nothing after it yet match
  (if (and earwig-wake-word-commands (earwig--strip-wake-word (concat text " ")))
      (earwig--provisional-command-face)
    'earwig-provisional))

(defun earwig--provisional-command-face ()
  "Return the face for provisional text of a command.
`earwig-provisional-command' on top of `earwig-provisional', in the
color of `earwig-mode-line-command' unless the first sets one."
  (let ((color (face-foreground 'earwig-mode-line-command nil t)))
    `(earwig-provisional-command
      ,@(and color `((:foreground ,color)))
      earwig-provisional)))

(defun earwig--provisional-command-text (text &optional bare)
  "Return the provisional TEXT of a command, cleaned up, as it shows.
That's without the wake word; with BARE, TEXT is a command said with a
command key, which needs none, but loses one said by habit too.
`earwig-provisional-chain-mark' takes the place of each of
`earwig-chain-words' that follows a command, and what isn't (yet) a
command is in `earwig-provisional', grey.  When TEXT ends with one of
`earwig-cancel-words', the commands are struck through before it."
  (let* ((rest (string-trim (or (earwig--strip-wake-word (concat text " "))
                                (if bare text ""))))
         (cancel (earwig--strip-cancel-word rest))
         (rest (if cancel (string-trim (car cancel)) rest))
         (mark (propertize (or earwig-provisional-chain-mark earwig-command-icon)
                           'face 'earwig-mode-line-command))
         (from 0)
         parts)
    (pcase-dolist (`(,cut-end . ,cut-start) (earwig--chain-cuts rest))
      (let ((part (substring rest from cut-end)))
        (when (earwig-find-command part)
          (push (earwig--command-text part) parts)
          (setq from cut-start))))
    (let ((tail (earwig--command-text (substring rest from))))
      (push (if (or (string-empty-p tail) (earwig-find-command tail))
                tail
              (propertize tail 'face 'earwig-provisional))
            parts))
    (let ((shown (mapconcat #'identity (seq-remove #'string-empty-p (nreverse parts))
                            (concat " " mark " "))))
      (if (not cancel)
          shown
        (add-face-text-property 0 (length shown) '(:strike-through t) nil shown)
        (concat shown (if (string-empty-p shown) "" " ")
                (propertize (downcase (cdr cancel)) 'face 'earwig-mode-line-command))))))

(defun earwig--provisional-mark (text command)
  "Return the provisional TEXT with its icon, after any leading space.
The icon is `earwig-command-icon' if COMMAND is non-nil, otherwise
`earwig-recording-icon'; none without `earwig-provisional-icons'."
  (let ((mark (and earwig-provisional-icons
                   (if command earwig-command-icon earwig-recording-icon))))
    (if (or (null mark) (string-empty-p mark))
        text
      (string-match "\\`[ \t\n]*" text)
      (concat (match-string 0 text)
              (propertize mark 'face (if command 'earwig-mode-line-command
                                       'earwig-mode-line-recording))
              (if (= (match-end 0) (length text)) "" " ")
              (substring text (match-end 0))))))

(defun earwig--stream-echo (text)
  "Show TEXT in the echo area as provisional text; with nil, clear it.
Clearing leaves a message shown since alone."
  (if text
      (let ((message-log-max nil))
        (message "%s" text)
        (setq earwig--stream-echo text))
    (when (and earwig--stream-echo (equal (current-message) earwig--stream-echo))
      (message nil))
    (setq earwig--stream-echo nil)))

(defun earwig--stream-command-heard (heard)
  "Show CMD in the mode line if HEARD, otherwise REC.
For a command given while dictating, see `earwig--command-heard'."
  (unless (eq heard earwig--command-heard)
    (setq earwig--command-heard heard)
    (force-mode-line-update t)))

(defun earwig--stream-provisional-done (start)
  "The segment at byte START has its final text: drop its provisional text."
  (when (and start (eql start earwig--stream-provisional-for))
    (setq earwig--stream-provisional-for nil
          earwig--stream-provisional-raw nil)
    ;; Unless it's a command, which shows CMD until it has run
    (unless (eq earwig--command-heard 'running)
      (earwig--stream-command-heard nil))
    (when (overlayp earwig--stream-overlay)
      (overlay-put earwig--stream-overlay 'before-string nil))
    (earwig--stream-echo nil)))

;;;; Flushing provisional text

(defun earwig--stream-flush-on-key ()
  "Flush the provisional text before the command of a key pressed.
For `pre-command-hook', while streaming.  See `earwig-stream-flush-on-key'."
  (when (and (not earwig--stream-pushed-to-talk)
             (not (consp last-input-event))
             (not (memq this-command '(earwig-voice-key earwig-dictate earwig-command))))
    ;; An error here would take the function off the hook
    (condition-case err
        (earwig--stream-flush (and (characterp last-command-event) last-command-event))
      (error (message "Flushing dictation failed: %s" (error-message-string err))))))

(defun earwig--stream-restart-segment (end)
  "Start the segment being spoken anew at byte END.
Whether the audio from END on, measured already, has speech, and how
long it's been quiet since, is told from the levels measured."
  (let* ((frames (/ (max 0 (- earwig--stream-read end)) earwig--stream-frame-bytes))
         (recent (seq-take earwig--stream-levels frames))
         (noise (earwig--stream-noise))
         (speech-p (lambda (level) (and noise (> level (* earwig-stream-speech-ratio noise))))))
    (setq earwig--stream-segment-start end
          earwig--stream-speech (and (seq-some speech-p recent) t)
          earwig--stream-quiet (or (cl-position-if speech-p recent) frames))))

(defun earwig--stream-flush (&optional key)
  "Insert the provisional text shown as its segment's final text.
KEY is the character of the key that flushed it, if any; one in
`earwig-stream-flush-punctuation' replaces the period or comma it ends with.
Only in the buffer it shows in, when that's current, and not for a
command said after a wake word.  The audio the provisional text was
transcribed from is done with: a segment queued is dropped, one in
flight has its final text dropped when it comes, and the one being
spoken starts anew where the provisional text ends.  It ends the
dictation so far, as what's typed next is no part of it."
  (pcase-let ((start earwig--stream-provisional-for)
              (`(,raw . ,end) earwig--stream-provisional-raw)
              (overlay earwig--stream-overlay))
    (when (and earwig-stream-flush-on-key
               earwig--stream-dir start raw
               (overlayp overlay)
               (overlay-get overlay 'before-string)
               (eq (overlay-buffer overlay) (current-buffer))
               (not (and earwig-wake-word-commands
                         (earwig--strip-wake-word (concat (earwig-clean raw) " ")))))
      (let ((queued (rassoc start earwig--stream-queue)))
        (cond
         ((and (= start earwig--stream-segment-start) (earwig-stream-recording-p))
          (earwig--stream-restart-segment (or end earwig--stream-read)))
         (queued
          (setq earwig--stream-queue (delq queued earwig--stream-queue))
          (when (file-exists-p (car queued))
            (delete-file (car queued))))
         (t
          (push start earwig--stream-flushed))))
      (earwig--stream-insert raw start)
      ;; Where the key types, which may be elsewhere if point moved
      (when (and key (seq-contains-p earwig-stream-flush-punctuation key))
        (earwig--drop-end-punctuation (point)))
      (earwig--stream-provisional-done start)
      (earwig--stream-break)
      (earwig--stream-next))))

;;;; Inserting

(defun earwig--stream-fix-join (beg join end)
  "Apply corrections that span JOIN, between BEG and END.
Each segment had the corrections applied on its own; this catches the
WRONG split by a pause, allowing for the punctuation Orukeet puts at the
end of a segment, as in \"Aura. Keat\"."
  (let ((case-fold-search t)
        (join (copy-marker join))
        (end (copy-marker end)))
    (dolist (pair (earwig--corrections))
      (save-excursion
        (goto-char beg)
        (while (re-search-forward
                (earwig--correction-regexp (car pair) "[.,;:!?]*[ \t\n]+") end t)
          (when (< (match-beginning 0) join (match-end 0))
            (replace-match (earwig--match-case (match-string 0) (cdr pair)) t t)))))))

(defun earwig--stream-follow-point ()
  "Have the segments spoken from now on go where point is.
See `earwig--follow-point'.  The segment being spoken ends where point
moved (`earwig--stream-cut-at-move').  The ones spoken already still go
where the dictation was, where their provisional text shows;
`earwig--stream-move-on' moves on after them.  Once recording has
stopped, everything has been spoken."
  (when (earwig-stream-recording-p)
    (let* ((last (car (last earwig--stream-moves)))
           (place (copy-marker (if last (cdr last) earwig--stream-target) t)))
      (if (not (earwig--follow-point place))
          (set-marker place nil)
        (let ((start (earwig--stream-cut-at-move)))
          (if (and last (= (car last) start))
              ;; Moving again before anything was said there
              (progn
                (set-marker (cdr last) nil)
                (setcdr last place))
            (setq earwig--stream-moves
                  (append earwig--stream-moves (list (cons start place))))))))))

(defun earwig--stream-cut-at-move ()
  "End the segment being spoken as point moves; return where the next starts.
If it has speech, it's cut at the quietest moment of the last 0.3 s
measured, and queued; what's after that starts the next one.  Without
any audio measured to cut, the segment being spoken is left whole, to
go where point was."
  (let ((frames (min 10 (/ (max 0 (- earwig--stream-read earwig--stream-segment-start))
                           earwig--stream-frame-bytes))))
    (cond
     ((not earwig--stream-speech)
      earwig--stream-segment-start)
     ((< frames 1)
      (1+ earwig--stream-segment-start))
     (t
      (let ((cut (earwig--stream-quietest earwig--stream-read frames)))
        (earwig--stream-cut cut)
        (earwig--stream-restart-segment cut)
        cut)))))

(defun earwig--stream-point-moved ()
  "Have the dictation follow point as soon as a command has moved it.
For `post-command-hook' while streaming: the segment being spoken ends
where point moved, rather than when the audio is next measured, up to
0.2 s later.  See `earwig--stream-follow-point'."
  (when (and (earwig-stream-recording-p) earwig--stream-target)
    ;; An error here would take the function off the hook
    (condition-case err
        (let ((place (copy-marker (or (cdar (last earwig--stream-moves))
                                      earwig--stream-target))))
          (when (earwig--follow-point place)
            (earwig--stream-measure))
          (set-marker place nil))
      (error (message "Following point failed: %s" (error-message-string err))))))

(defun earwig--stream-after-command ()
  "Have the rest of the dictation go where a command left point.
That's a command given while dictating; what's said after it goes there
even if it was being said while the command ran.  The dictation starts
anew there, after anything the command inserted, such as the closing
markup of \"format bold\", so \"scratch that\" leaves that alone."
  (when earwig--stream-dir
    (earwig--stream-drop-moves)
    (earwig--follow-point earwig--stream-target)
    (earwig--stream-break)))

(defun earwig--stream-drop-moves ()
  "Forget where point moved to, see `earwig--stream-moves'."
  (pcase-dolist (`(,_ . ,place) earwig--stream-moves)
    (set-marker place nil))
  (setq earwig--stream-moves nil))

(defun earwig--stream-move-on (start)
  "Have the segment at byte START go where point was when it was spoken.
Dictation moving on ends the dictation so far."
  (let (place)
    (while (and earwig--stream-moves (<= (caar earwig--stream-moves) start))
      (when place
        (set-marker place nil))
      (setq place (cdr (pop earwig--stream-moves))))
    (when place
      (set-marker earwig--stream-target place (marker-buffer place))
      (set-marker place nil)
      (earwig--stream-break))))

(defun earwig--stream-break ()
  "End the streaming dictation so far, if one is going on.
It becomes one undo step, and the next segment starts the dictation
\"scratch that\" takes back, at `earwig--stream-target'."
  (when earwig--stream-dir
    (earwig--stream-accept-group)
    (setq earwig--stream-start (copy-marker earwig--stream-target)
          earwig--stream-join nil)))

(defun earwig--stream-accept-group ()
  "Make the dictation so far one undo step."
  (when earwig--stream-change-group
    ;; The buffer may have been killed while the segments came in
    (ignore-errors
      (accept-change-group earwig--stream-change-group)
      (undo-amalgamate-change-group earwig--stream-change-group)
      ;; Kept from what's dictated next, which may come before a command does that
      (pcase-dolist (`(,buffer . ,_) earwig--stream-change-group)
        (with-current-buffer buffer
          (undo-boundary))))
    (setq earwig--stream-change-group nil)))

(defun earwig--stream-insert (raw start)
  "Clean up the transcribed segment RAW, at byte START, and insert it.
It goes where point was when it was spoken: after the previous segment,
unless point had moved.  Point follows the text."
  (earwig--stream-follow-point)
  (earwig--stream-move-on start)
  (let* ((target earwig--stream-target)
         (buffer (marker-buffer target))
         (text (and buffer (earwig--process-text raw buffer (marker-position target)))))
    (when text
      (unless earwig--stream-change-group
        (setq earwig--stream-change-group (prepare-change-group buffer))
        (activate-change-group earwig--stream-change-group))
      (with-current-buffer buffer
        (let* ((pos (marker-position target))
               (back (earwig--evil-stepped-back-p (point) pos))
               (follow (or back (= (point) pos)))
               (windows (cl-remove-if-not (lambda (window) (= (window-point window) pos))
                                          (get-buffer-window-list buffer nil t))))
          (cond
           ((earwig--terminal-p buffer)
            (earwig--send-to-terminal text))
           ;; Headings and items, which may move on to another place
           ((consp text)
            (pcase-let ((`(,start . ,end) (save-excursion (earwig-insert-parts text pos))))
              (unless (= start pos)
                (setq earwig--stream-start (copy-marker start)))
              (set-marker target end)
              (setq earwig--stream-join nil
                    earwig--last-dictation
                    (list (copy-marker earwig--stream-start t) (copy-marker target)
                          (buffer-substring-no-properties earwig--stream-start target)))))
           (t
            (save-excursion
              (goto-char pos)
              (insert text))
            (when earwig--stream-join
              (earwig--stream-fix-join earwig--stream-join pos target))
            (setq earwig--stream-join (copy-marker pos)
                  earwig--last-dictation
                  (list (copy-marker earwig--stream-start t) (copy-marker target)
                        (buffer-substring-no-properties earwig--stream-start target)))))
          (when follow
            (goto-char (if back (1- target) target)))
          (dolist (window windows)
            (set-window-point window target))))
      ;; Provisional text of a later segment, shown before this text went
      ;; in before it, was fitted to what was there then
      (pcase-let ((`(,later-raw . ,later-end) earwig--stream-provisional-raw)
                  (later earwig--stream-provisional-for))
        (when (and later later-raw (/= later start)
                   (not (earwig--terminal-p buffer)))
          (earwig--stream-show-provisional later-raw later later-end))))))

(defun earwig--stream-finish ()
  "Wrap up the streaming dictation: one undo step, indicator off."
  (earwig--show-phase nil)
  (setq earwig--command-heard nil)
  (earwig--stream-accept-group)
  (when (overlayp earwig--stream-overlay)
    (delete-overlay earwig--stream-overlay))
  (when earwig--stream-provisional-for
    (earwig--stream-provisional-done earwig--stream-provisional-for))
  (when earwig--stream-dir
    (delete-directory earwig--stream-dir t))
  (earwig--stream-drop-moves)
  (remove-hook 'pre-command-hook #'earwig--stream-flush-on-key)
  (remove-hook 'post-command-hook #'earwig--stream-point-moved)
  (setq earwig--stream-dir nil
        earwig--stream-flushed nil
        earwig--stream-overlay nil
        earwig--stream-join nil))

(provide 'earwig-stream)
;;; earwig-stream.el ends here
