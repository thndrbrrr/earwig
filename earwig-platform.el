;;; earwig-platform.el --- What differs between macOS, Linux and Windows  -*- lexical-binding: t; -*-

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

;; Everything Earwig does differently on each operating system is here,
;; decided by `system-type', so the rest of it needn't know which one it
;; runs on:
;;
;; - the audio driver and device sox and ffmpeg record from
;;   (`earwig-audio-driver'), and how a recorder is stopped;
;; - how a server started from Emacs is stopped;
;; - the default voice keys, as Cmd on a Mac is Super, a key the desktop
;;   keeps for itself elsewhere;
;; - for `earwig-check-setup': the microphones there are, how the
;;   keyboard repeats, how to install a missing tool, and where
;;   microphone access is allowed.
;;
;; macOS and Linux are supported.  The Windows branches are either
;; untested guesses, marked as such, or return nil where nothing is
;; known yet; see docs/roadmap/windows.md.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defvar earwig-input-device)

;;;; Running things

(defun earwig--run (program &rest args)
  "Run PROGRAM with ARGS; return (EXIT-STATUS . OUTPUT), output trimmed.
EXIT-STATUS is -1, and OUTPUT says why, if PROGRAM can't be run."
  (with-temp-buffer
    (let ((status (condition-case err
                      (apply #'call-process program nil t nil args)
                    (file-error (insert (error-message-string err)) -1))))
      (cons status (string-trim (buffer-string))))))

(defun earwig--run-output (program &rest args)
  "Run PROGRAM with ARGS; return its output if it succeeded, else nil."
  (pcase-let ((`(,status . ,output) (apply #'earwig--run program args)))
    (and (eql status 0) output)))

;;;; Recording

(defcustom earwig-audio-driver 'auto
  "Audio driver sox records the microphone through.
`auto' picks the one for this system: coreaudio on macOS; on Linux
pulseaudio, which PipeWire serves too, if sox has it and a sound server
is running, alsa otherwise.  ffmpeg, when it records, follows the same
choice.  `earwig-check-setup' says whether sox has the driver."
  :type '(choice (const :tag "The one for this system" auto)
                 (const coreaudio) (const pulseaudio) (const alsa)
                 (const waveaudio) (symbol :tag "Another sox driver"))
  :group 'earwig)

(defcustom earwig-pulse-latency 30
  "Milliseconds of audio PulseAudio hands sox at a time, or nil for its default.
Only with the pulseaudio driver, PipeWire's included.  Its default can
be much more, so streamed text comes in bursts and REC shows late."
  :type '(choice (const :tag "PulseAudio's default" nil) natnum)
  :group 'earwig)

(defvar earwig--sox-drivers-cache nil
  "(SOX . DRIVERS): the audio drivers of the sox at SOX, as found last.")

(defun earwig--parse-sox-drivers (help)
  "Return the audio device drivers sox's HELP output lists, as symbols."
  (when (string-match "^AUDIO DEVICE DRIVERS:\\(.*\\)$" help)
    (mapcar #'intern (split-string (match-string 1 help)))))

(defun earwig--sox-drivers ()
  "Return the audio device drivers of the sox installed, as symbols.
Nil if sox isn't installed.  Remembered until sox moves, or
`earwig-check-setup' looks again."
  (when-let* ((sox (executable-find "sox")))
    (unless (equal (car earwig--sox-drivers-cache) sox)
      (setq earwig--sox-drivers-cache
            (cons sox (earwig--parse-sox-drivers (cdr (earwig--run sox "-h"))))))
    (cdr earwig--sox-drivers-cache)))

(defun earwig--pulse-server-p ()
  "Non-nil if a PulseAudio server, or PipeWire's, seems to be running."
  (or (getenv "PULSE_SERVER")
      (when-let* ((runtime (getenv "XDG_RUNTIME_DIR")))
        (file-exists-p (expand-file-name "pulse/native" runtime)))))

(defun earwig--default-audio-driver (&optional for-ffmpeg)
  "Return the audio driver for this system, see `earwig-audio-driver'.
With FOR-FFMPEG, PulseAudio doesn't depend on what sox has."
  (pcase system-type
    ('darwin 'coreaudio)
    ;; Windows: untested
    ('windows-nt 'waveaudio)
    (_ (if (and (earwig--pulse-server-p)
                (or for-ffmpeg (memq 'pulseaudio (earwig--sox-drivers))))
           'pulseaudio
         'alsa))))

(defun earwig--audio-driver ()
  "Return the sox driver to record with, see `earwig-audio-driver'."
  (if (eq earwig-audio-driver 'auto)
      (earwig--default-audio-driver)
    earwig-audio-driver))

(defun earwig--sox-program ()
  "Return the program and arguments that start sox, as a list.
With PulseAudio and `earwig-pulse-latency', sox is started through env,
so that PULSE_LATENCY_MSEC is set for it alone; env runs sox in its own
place, so stopping the process stops sox."
  (if (and earwig-pulse-latency (eq (earwig--audio-driver) 'pulseaudio))
      (list "env" (format "PULSE_LATENCY_MSEC=%d" earwig-pulse-latency) "sox")
    (list "sox")))

(defun earwig--sox-input-args ()
  "Return the sox arguments that record from `earwig-input-device'."
  (list "-t" (symbol-name (earwig--audio-driver)) earwig-input-device))

(defun earwig--ffmpeg-input-format ()
  "Return the ffmpeg input format for the audio driver, see `earwig-audio-driver'."
  (pcase (if (eq earwig-audio-driver 'auto)
             (earwig--default-audio-driver t)
           earwig-audio-driver)
    ('coreaudio "avfoundation")
    ('pulseaudio "pulse")
    ;; Windows: untested
    ('waveaudio "dshow")
    (driver (symbol-name driver))))

(defun earwig--ffmpeg-input-device ()
  "Return `earwig-input-device' as ffmpeg's input format names it."
  (pcase (earwig--ffmpeg-input-format)
    ("avfoundation" (concat ":" earwig-input-device))
    ;; Windows: untested, and DirectShow has no "default" device
    ("dshow" (concat "audio=" earwig-input-device))
    (_ earwig-input-device)))

(defun earwig--stop-recorder (proc)
  "Stop the recorder PROC, so it finishes what it's writing."
  (if (eq system-type 'windows-nt)
      ;; Windows: untested.  It has no SIGINT, so the recorder is killed,
      ;; which loses what it hasn't written yet; recording a little
      ;; longer first keeps the last word.
      (run-at-time 0.3 nil (lambda ()
                             (when (process-live-p proc)
                               (delete-process proc))))
    (interrupt-process proc)))

(defun earwig--recorder-stopped-p (event)
  "Non-nil if the process EVENT of a recorder is its being stopped, not failing."
  (or (string-prefix-p "finished" event)
      (string-prefix-p "interrupt" event)
      ;; ffmpeg's exit status once interrupted
      (string-prefix-p "exited abnormally with code 255" event)
      ;; Windows: untested, see `earwig--stop-recorder'
      (and (eq system-type 'windows-nt)
           (or (string-prefix-p "killed" event)
               (string-prefix-p "deleted" event)))))

;;;; Servers

(defun earwig--interrupt-server (proc)
  "Ask the server PROC to shut down cleanly."
  (if (eq system-type 'windows-nt)
      ;; Windows: untested; no SIGINT, so it's killed
      (delete-process proc)
    (signal-process proc 'SIGINT)))

;;;; Keys

(defun earwig--default-keys (which)
  "Return this system's default keys: WHICH is `toggle' or `correct'.
Toggle keys as for `earwig-toggle-keys', correct keys as for
`earwig-correct-keys'.  On macOS they're on Cmd, which Emacs calls
Super, s-.  Elsewhere Super is the logo key the desktop keeps for
itself, so they're function keys.  The keypad keys are the same
everywhere."
  (let ((mac (eq system-type 'darwin)))
    (pcase which
      ('toggle `((,(if mac "s-d" "<f7>") . dictate) ("<kp-0>" . dictate)
                 (,(if mac "s-f" "<f8>") . command) ("<kp-enter>" . command)))
      ('correct (list (if mac "s-e" "<f9>") "<kp-decimal>")))))

;;;; Microphones

(defun earwig--parse-macos-devices (json)
  "Return the input device names in system_profiler's SPAudioDataType JSON."
  (ignore-errors
    (cl-loop for group across (alist-get 'SPAudioDataType (json-read-from-string json))
             append (cl-loop for device across (alist-get '_items group)
                             when (assq 'coreaudio_device_input device)
                             collect (alist-get '_name device)))))

(defun earwig--parse-pactl-sources (output)
  "Return the source names in OUTPUT of pactl list short sources.
Without the monitors of outputs, which record what's played."
  (cl-loop for line in (split-string (or output "") "\n" t)
           for name = (nth 1 (split-string line "\t"))
           when (and name (not (string-suffix-p ".monitor" name)))
           collect name))

(defun earwig--parse-arecord-devices (output)
  "Return the device names in OUTPUT of arecord -L, but null."
  (cl-loop for line in (split-string (or output "") "\n" t)
           unless (or (string-match-p "\\`[ \t]" line) (equal line "null"))
           collect line))

(defun earwig--input-devices ()
  "Return the names of the microphones `earwig-input-device' can name.
Nil if they can't be listed."
  (pcase system-type
    ('darwin (earwig--parse-macos-devices
              (or (earwig--run-output "system_profiler" "-json" "SPAudioDataType") "")))
    ;; Windows: not yet
    ('windows-nt nil)
    (_ (if (eq (earwig--audio-driver) 'pulseaudio)
           (earwig--parse-pactl-sources (earwig--run-output "pactl" "list" "short" "sources"))
         (earwig--parse-arecord-devices (earwig--run-output "arecord" "-L"))))))

(defun earwig--microphone-access-hint ()
  "Return what to do when the microphone records only silence."
  (pcase system-type
    ('darwin "allow Emacs in System Settings > Privacy & Security > Microphone, then restart it")
    ;; Windows: untested
    ('windows-nt "turn on Settings > Privacy & security > Microphone > Let desktop apps access your microphone")
    (_ "check that the input isn't muted or turned down, e.g. with pavucontrol; an Emacs from Flatpak or Snap also needs to be allowed the microphone")))

;;;; Key repeat

(defun earwig--macos-default (domain key)
  "Return the macOS default KEY in DOMAIN as a string, or nil if unset."
  (earwig--run-output "defaults" "read" domain key))

(defun earwig--macos-key-repeat ()
  "Return (DELAY . INTERVAL) of the macOS key repeat in ms, or nil.
As the HID system has it, which knows it even when System Settings
were never changed; otherwise from the user defaults, in ticks of 1/60 s."
  (let ((hid (or (earwig--run-output "ioreg" "-r" "-c" "IOHIDSystem" "-w0") "")))
    (if (string-match "\"HIDInitialKeyRepeat\"=\\([0-9]+\\)" hid)
        (let ((delay (/ (string-to-number (match-string 1 hid)) 1000000)))
          (and (string-match "\"HIDKeyRepeat\"=\\([0-9]+\\)" hid)
               (cons delay (/ (string-to-number (match-string 1 hid)) 1000000))))
      (let ((initial (earwig--macos-default "-g" "InitialKeyRepeat"))
            (repeat (earwig--macos-default "-g" "KeyRepeat")))
        (and initial repeat
             (cons (round (/ (* 1000 (string-to-number initial)) 60.0))
                   (round (/ (* 1000 (string-to-number repeat)) 60.0))))))))

(defun earwig--parse-xset-repeat (output)
  "Return (DELAY . INTERVAL) in ms from OUTPUT of xset q, `off', or nil."
  (cond
   ((null output) nil)
   ((string-match-p "auto repeat: +off" output) 'off)
   ((string-match "auto repeat delay: +\\([0-9]+\\) +repeat rate: +\\([0-9]+\\)" output)
    (let ((rate (string-to-number (match-string 2 output))))
      (and (> rate 0)
           (cons (string-to-number (match-string 1 output)) (round (/ 1000.0 rate))))))))

(defun earwig--parse-gsettings-number (output)
  "Return the number in OUTPUT of gsettings get, as \"uint32 500\", or nil."
  (and output (string-match "\\([0-9]+\\)\\'" output)
       (string-to-number (match-string 1 output))))

(defun earwig--gnome-key-repeat ()
  "Return (DELAY . INTERVAL) in ms from GNOME's settings, `off', or nil."
  (let ((schema "org.gnome.desktop.peripherals.keyboard"))
    (if (equal (earwig--run-output "gsettings" "get" schema "repeat") "false")
        'off
      (let ((delay (earwig--parse-gsettings-number
                    (earwig--run-output "gsettings" "get" schema "delay")))
            (interval (earwig--parse-gsettings-number
                       (earwig--run-output "gsettings" "get" schema "repeat-interval"))))
        (and delay interval (cons delay interval))))))

(defun earwig--kde-key-repeat ()
  "Return (DELAY . INTERVAL) in ms from KDE Plasma's settings, or nil.
Its rate is in repeats a second, and either may be a fraction."
  (when-let* ((kreadconfig (seq-find #'executable-find '("kreadconfig6" "kreadconfig5"))))
    (cl-flet ((setting (key default)
                (let ((value (earwig--run-output kreadconfig "--file" "kcminputrc" "--group"
                                                 "Keyboard" "--key" key "--default" default)))
                  (and value (string-match-p "\\`[0-9.]+\\'" value) (string-to-number value)))))
      (let ((delay (setting "RepeatDelay" "600"))
            (rate (setting "RepeatRate" "25")))
        (and delay rate (> rate 0)
             (cons (round delay) (round (/ 1000.0 rate))))))))

(defun earwig--linux-key-repeat ()
  "Return (DELAY . INTERVAL) of the Linux key repeat in ms, `off', or nil.
Under Wayland the desktop repeats keys, so it's read from GNOME's or
KDE's settings, or not known; under X11 from the X server, which
GNOME and KDE set up too."
  (cond
   ((getenv "WAYLAND_DISPLAY")
    (let ((desktop (or (getenv "XDG_CURRENT_DESKTOP") "")))
      (cond ((string-match-p "GNOME" desktop) (earwig--gnome-key-repeat))
            ((string-match-p "KDE" desktop) (earwig--kde-key-repeat)))))
   ((getenv "DISPLAY")
    (earwig--parse-xset-repeat (earwig--run-output "xset" "q")))))

(defun earwig--key-repeat ()
  "Return how this system repeats a held key, or nil if that isn't known.
As (DELAY . INTERVAL): milliseconds until the first repeat, and between
repeats after that.  The symbol `off' if keys don't repeat."
  (pcase system-type
    ('darwin (earwig--macos-key-repeat))
    ;; Windows: not yet; HKCU\Control Panel\Keyboard has it
    ('windows-nt nil)
    (_ (earwig--linux-key-repeat))))

;;;; Installing things

(defun earwig--package-manager ()
  "Return the package manager to suggest: brew, apt, dnf, pacman, zypper or winget.
Nil if none is known here."
  (pcase system-type
    ('darwin 'brew)
    ('windows-nt 'winget)
    (_ (seq-find (lambda (manager) (executable-find (symbol-name manager)))
                 '(apt dnf pacman zypper)))))

(defun earwig--install-command (packages)
  "Return the command that installs the string PACKAGES, or nil."
  (pcase (earwig--package-manager)
    ('brew (concat "brew install " packages))
    ('apt (concat "sudo apt install " packages))
    ('dnf (concat "sudo dnf install " packages))
    ('pacman (concat "sudo pacman -S " packages))
    ('zypper (concat "sudo zypper install " packages))))

(defun earwig--install-hint (tool)
  "Return how to install TOOL, a program such as \"sox\" or \"curl\"."
  (or (earwig--install-command
       ;; Debian and Ubuntu put sox's audio drivers in packages of their own
       (if (and (equal tool "sox") (eq (earwig--package-manager) 'apt))
           "sox libsox-fmt-pulse libsox-fmt-alsa"
         tool))
      (format "install %s" tool)))

(defun earwig--sox-driver-hint (driver)
  "Return what to do about sox lacking the audio DRIVER, a symbol."
  (let ((package (and (eq (earwig--package-manager) 'apt)
                      (pcase driver
                        ('pulseaudio "libsox-fmt-pulse")
                        ('alsa "libsox-fmt-alsa")))))
    (if package
        (earwig--install-command package)
      (format "use a sox with %s, or set earwig-audio-driver to one this one has: %s"
              driver (mapconcat #'symbol-name (earwig--sox-drivers) ", ")))))

;;;; Support

(defvar earwig--platform-warned nil
  "Non-nil once Earwig has warned that it's untested here.")

(defun earwig--platform-warn ()
  "Warn, once, if this system is one Earwig hasn't been tested on."
  (unless (or earwig--platform-warned (memq system-type '(darwin gnu/linux)))
    (setq earwig--platform-warned t)
    (display-warning
     'earwig
     (format "Earwig hasn't been tested on %s; recording may not work (see docs/roadmap/windows.md)"
             system-type))))

(provide 'earwig-platform)
;;; earwig-platform.el ends here
