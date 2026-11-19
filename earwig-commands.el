;;; earwig-commands.el --- Spoken commands for voice control  -*- lexical-binding: t; -*-

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

;; `earwig-commands' maps spoken phrases to Emacs commands.  earwig.el
;; hands it the cleaned-up text of a command recording (Cmd-f, F8), or
;; with `earwig-wake-word-commands', what's said after a wake word
;; while dictating.  Commands of your own go in
;; `earwig-extra-commands', which are tried first; `earwig-with-input',
;; `earwig-downcase-first-word', `earwig-raw-command', for parts of the
;; buffer `earwig-part-range' (earwig-edit.el), and for dates
;; `earwig-when-regexp' and `earwig-spoken-time' (earwig-org.el), help
;; in writing them.  Commands joined by `earwig-chain-words' ("cut that
;; and then go to top and then paste") run one after another.  Ending
;; with one of `earwig-cancel-words' ("cut that, never mind") runs
;; nothing.
;;
;; A few commands use consult when it's installed, and built-in
;; commands otherwise: "search", "switch to buffer" and "go to heading".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'earwig-cleanup)
(require 'earwig-edit)
(require 'earwig-structure)
(require 'earwig-org)

;; Packages the commands use are only loaded when a command needs them
(declare-function consult-buffer "consult" (&optional sources))
(declare-function consult-line "consult" (&optional initial start))
(declare-function consult-org-heading "consult-org" (&optional match scope))
(declare-function earwig--mode-keys "earwig" (mode))

(defcustom earwig-wake-words '("okay" "ok")
  "Words that give a command while dictating, see `earwig-wake-word-commands'."
  :type '(repeat string)
  :group 'earwig)

(defcustom earwig-wake-word-commands t
  "Non-nil to give voice commands while dictating, starting with a wake word.
Dictation carries on around them: pause, say \"okay, scratch that\" or a
chain such as \"okay, select last sentence and then cut that\", pause,
and keep dictating, where point is then.  With `earwig-streaming' this
works at every pause (see `earwig-stream-pause'), otherwise only at the
start of a recording.  The wake words are `earwig-wake-words'.  If no
command matches, what was said is inserted as dictation.  Recordings
made with a command key are commands either way; nil makes a dictation
key only ever dictate."
  :type 'boolean
  :group 'earwig)

(defcustom earwig-chain-words '("and then")
  "Words between voice commands that run them one after another.
As in \"select last sentence and then cut that\".  A phrase is split
at them only when every part is a command; otherwise it's one command,
as in \"replace and then with so\"."
  :type '(repeat string)
  :group 'earwig)

(defcustom earwig-cancel-words '("cancel" "never mind" "nevermind")
  "Words that, said last, cancel a voice command, so nothing runs.
As in \"select last sentence and then cut that, cancel\", with a
command key or after a wake word; the words aren't dictated then
either.  Only as the last words, so \"cancel\" can still be part of a
command of your own."
  :type '(repeat string)
  :group 'earwig)

(defcustom earwig-extra-commands nil
  "Voice commands of your own, as (PATTERN FUNCTION HELP).
The same as for `earwig-commands', and tried before those, so they can
also take over one of its phrases.  For example:

  (add-to-list \\='earwig-extra-commands
               \\='(\"toggle \\\\(?:the \\\\)?margins?\" olivetti-mode
                 \"toggle margins\"))"
  :type '(repeat (list (regexp :tag "Pattern")
                       (function :tag "Function")
                       (string :tag "Help")))
  :group 'earwig)

(defvar earwig--last-dictation nil
  "(START END TEXT) of the last dictation inserted, for \"scratch that\".
START and END are markers; set by earwig.el.")

(defvar earwig-raw-command nil
  "While a voice command runs, its text before it was normalized.
That's with its punctuation, which matching ignores; for commands that
pass on what was said, like a prompt.")

(defvar earwig-commands
  `(;; Editing and moving around
    ("save\\(?: \\(?:the \\)?\\(?:file\\|buffer\\)\\)?" save-buffer
     "save [file | buffer]")
    ("undo\\(?: that\\)?" undo
     "undo [that]")
    ("redo" undo-redo
     "redo")
    ("scratch that" earwig-cmd-scratch-that
     "scratch that           (delete the last dictation)")
    ("comment \\(?:that\\|this\\|line\\)" comment-line
     "comment that           (region or line)")
    ,@earwig-edit-commands
    ,@earwig-structure-commands
    ("close\\(?: \\(?:the \\|this \\)?buffer\\)?" kill-current-buffer
     "close [buffer]")
    ("go to line \\(.+\\)" earwig-cmd-goto-line
     "go to line N           (\"forty two\" or 42)")
    ("go to \\(?:the \\)?top" beginning-of-buffer
     "go to [the] top")
    ("go to \\(?:the \\)?bottom" end-of-buffer
     "go to [the] bottom")
    ("go to heading\\(?: \\(.+\\)\\)?" earwig-cmd-goto-heading
     "go to heading [NAME]")
    ("scroll down" scroll-up-command
     "scroll down")
    ("scroll up" scroll-down-command
     "scroll up")
    ("other window" other-window
     "other window")
    ("search\\(?: for\\)?\\(?: \\(.+\\)\\)?" earwig-cmd-search
     "search [for] [TEXT]")
    ("run command \\(.+\\)" earwig-cmd-run-command
     "run command NAME       (\"org agenda\")")
    ,@earwig-org-commands
    ("switch\\(?: to\\)?\\(?: buffer\\)?\\(?: \\(.+\\)\\)?" earwig-cmd-switch-buffer
     "switch to [buffer] [NAME] (\"init dot el\")")
    ("what can i say" earwig-cmd-help
     "what can I say"))
  "Voice commands as (PATTERN FUNCTION HELP).
PATTERN is a regexp matched, ignoring case, against the whole command
text; the first match wins.  FUNCTION is called with PATTERN's groups as
arguments; a command without groups is called interactively.  HELP is
shown by \"what can I say\".  `earwig-extra-commands' come first.")

;;;; Matching

(defun earwig--strip-wake-word (text)
  "Return TEXT after a leading wake word, or nil if it doesn't start with one."
  (let ((case-fold-search t))
    (when (string-match (concat "\\`[ \t]*" (regexp-opt earwig-wake-words 'words)
                                "[,.!]?[ \t]+")
                        text)
      (substring text (match-end 0)))))

(defun earwig--strip-cancel-word (text)
  "Return (BEFORE . WORD) if TEXT ends with one of `earwig-cancel-words'.
BEFORE is TEXT before it, without the punctuation between them; WORD is
the cancel word as said.  Nil if TEXT doesn't end with one."
  (when earwig-cancel-words
    (let ((case-fold-search t))
      (when (string-match (concat "\\(?:\\`\\|[,;:.!? \t\n]+\\)\\("
                                  (mapconcat (lambda (word)
                                               (replace-regexp-in-string
                                                " +" "[ \t\n]+" (regexp-quote word)))
                                             earwig-cancel-words "\\|")
                                  "\\)\\b[,;:.!?]*[ \t\n]*\\'")
                          text)
        (cons (substring text 0 (match-beginning 0)) (match-string 1 text))))))

(defun earwig--command-text (text)
  "Return TEXT as a command, without punctuation and with single spaces.
Dots inside words, as in \"init.el\", stay."
  (string-trim
   (replace-regexp-in-string
    "[ \t\n]+" " "
    (replace-regexp-in-string "[,;:]\\|[.?!]+\\(?:[ \t\n]\\|\\'\\)" " " text))))

(defun earwig-find-command (text)
  "Return (FUNCTION . ARGS) for the voice command TEXT, or nil if none matches.
TEXT is matched as said, then with `earwig-corrections-commands' applied."
  (let* ((text (earwig--command-text text))
         (corrected (earwig-apply-corrections text t)))
    (or (earwig--match-command text)
        (and (not (equal corrected text))
             (earwig--match-command corrected)))))

(defun earwig--match-command (text)
  "Return (FUNCTION . ARGS) for TEXT, a `earwig--command-text', or nil."
  (let ((case-fold-search t))
    (cl-loop for (pattern function) in (append earwig-extra-commands earwig-commands)
             when (string-match (concat "\\`\\(?:" pattern "\\)\\'") text)
             ;; Groups an optional part left unmatched are passed as nil
             return (cons function
                          (cl-loop for group from 1 to (regexp-opt-depth pattern)
                                   collect (match-string group text))))))

(defun earwig--chain-cuts (text)
  "Return (END . START) of each of `earwig-chain-words' in TEXT.
END is where the command before it ends, START where the next one
starts; the punctuation around the words goes with them."
  (when earwig-chain-words
    (let ((case-fold-search t)
          (regexp (concat "[,;:.!?]*[ \t\n]+" (regexp-opt earwig-chain-words 'words)
                          "[,;:.!?]*[ \t\n]+"))
          (start 0)
          cuts)
      (while (string-match regexp text start)
        (push (cons (match-beginning 0) (match-end 0)) cuts)
        (setq start (match-end 0)))
      (nreverse cuts))))

(defun earwig-find-commands (text)
  "Return ((RAW FUNCTION . ARGS)...) for the voice commands TEXT chains, or nil.
TEXT is split at `earwig-chain-words' into as many commands as it can
be, each as for `earwig-find-command'; a part that's no command stays
joined to the next.  RAW is a command's part of TEXT."
  (cl-labels ((parse (start cuts)
                (or (cl-loop for (cut . rest) on cuts
                             for raw = (substring text start (car cut))
                             for command = (earwig-find-command raw)
                             for more = (and command (parse (cdr cut) rest))
                             when more return (cons (cons raw command) more))
                    (let* ((raw (substring text start))
                           (command (earwig-find-command raw)))
                      (and command (list (cons raw command)))))))
    (parse 0 (earwig--chain-cuts text))))

(defvar earwig--go-commands
  '(earwig-cmd-go earwig-cmd-go-edge earwig-cmd-goto-line earwig-cmd-goto-heading
    beginning-of-buffer end-of-buffer earwig-cmd-next-match)
  "Functions of voice commands that \"go back\" returns from.")

(defun earwig--run-step (command)
  "Run COMMAND, a (FUNCTION . ARGS) of `earwig-find-command'.
For one of `earwig--go-commands' that moves point, \"go back\" returns
to where point was; not for \"next one\" after \"select WORDS\"."
  (let ((from (point-marker)))
    (unwind-protect
        (progn
          (if (or (cdr command) (not (commandp (car command))))
              (apply (car command) (cdr command))
            (call-interactively (car command)))
          (when (and (memq (car command) earwig--go-commands)
                     (eq (marker-buffer from) (current-buffer))
                     (/= from (point))
                     (not (and (eq (car command) 'earwig-cmd-next-match)
                               (eq (nth 2 earwig--edit-last) 'select))))
            (when (markerp earwig--go-from)
              (set-marker earwig--go-from nil))
            (setq earwig--go-from from
                  from nil)))
      (when from
        (set-marker from nil)))))

(defun earwig-run-command (text)
  "Run the voice command TEXT, or the ones it chains, or say that none matches.
Chained commands run in turn, each its own undo step, and stop at one
that fails.  One that selects another buffer, as \"other window\" does,
leaves the rest to run there."
  (let ((steps (earwig-find-commands text)))
    (if (null steps)
        (message "No voice command for \"%s\"" (earwig--command-text text))
      (cl-loop
       for (raw . command) in steps
       for step from 1
       do (let ((buffer (window-buffer))
                (earwig-raw-command raw))
            (condition-case err
                (earwig--run-step command)
              (error
               (message "Voice command \"%s\" failed%s: %s"
                        (earwig--command-text raw)
                        (if (cdr steps) (format " (step %d of %d)" step (length steps)) "")
                        (error-message-string err))
               (cl-return)))
            (unless (eq (window-buffer) buffer)
              (set-buffer (window-buffer)))
            (undo-boundary))))))

;;;; Helpers

(defun earwig-downcase-first-word (text)
  "Return TEXT with its first word lowercased, as Orukeet may capitalize it.
For spoken text that goes into a search, say.  TEXT may be nil."
  (and text (replace-regexp-in-string "\\`[^ ]+" #'downcase text t t)))

(defun earwig-with-input (input command)
  "Call COMMAND interactively with INPUT, if any, typed into its first prompt."
  (minibuffer-with-setup-hook (lambda () (when input (insert input)))
    (call-interactively command)))

(defun earwig--parse-number (text)
  "Return the number TEXT says, as digits or words, or nil.
Understands e.g. \"42\", \"forty two\", \"one hundred and five\"."
  (if (string-match-p "\\`[0-9]+\\'" text)
      (string-to-number text)
    (let ((units '("zero" "one" "two" "three" "four" "five" "six" "seven" "eight"
                   "nine" "ten" "eleven" "twelve" "thirteen" "fourteen" "fifteen"
                   "sixteen" "seventeen" "eighteen" "nineteen"))
          (tens '("twenty" "thirty" "forty" "fifty" "sixty" "seventy" "eighty" "ninety"))
          (total 0) (current 0) (seen nil) (ok t))
      (dolist (word (split-string (downcase text) "[ -]+" t))
        (cond
         ((member word units)
          (setq current (+ current (cl-position word units :test #'equal)) seen t))
         ((member word tens)
          (setq current (+ current (* 10 (+ 2 (cl-position word tens :test #'equal)))) seen t))
         ((equal word "hundred")
          (setq current (* (max current 1) 100) seen t))
         ((equal word "thousand")
          (setq total (+ total (* (max current 1) 1000)) current 0 seen t))
         ((equal word "and"))
         (t (setq ok nil))))
      (when (and ok seen) (+ total current)))))

;;;; Editing and moving around

(defun earwig-cmd-scratch-that ()
  "Delete the last dictation, unless it has been edited since."
  (pcase-let ((`(,start ,end ,text) earwig--last-dictation))
    (unless (and start (marker-buffer start))
      (user-error "No dictation to scratch"))
    (with-current-buffer (marker-buffer start)
      (unless (equal (buffer-substring-no-properties start end) text)
        (user-error "The last dictation was edited since, not scratching it"))
      (delete-region start end))
    (setq earwig--last-dictation nil)
    (message "Scratched \"%s\"" (string-trim text))))

(defun earwig-cmd-goto-line (number)
  "Go to the line NUMBER says."
  (let ((line (or (earwig--parse-number number)
                  (user-error "Not a line number: %s" number))))
    (push-mark)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun earwig-cmd-goto-heading (name)
  "Pick a heading, starting from spoken NAME, if any.
With `consult-org-heading' in Org if consult is installed, else `imenu'."
  (earwig-with-input (earwig-downcase-first-word name)
                     (if (and (derived-mode-p 'org-mode) (fboundp 'consult-org-heading))
                         #'consult-org-heading
                       #'imenu)))

(defun earwig-cmd-switch-buffer (name)
  "Switch buffers with spoken NAME, if any, filled in.
With `consult-buffer' if it's installed, else `switch-to-buffer'.  NAME
is lowercased and the word \"dot\" dropped, so orderless matches
\"init dot el\" as the components \"init\" and \"el\"."
  (earwig-with-input
   (and name (string-join (remove "dot" (split-string (downcase name))) " "))
   (if (fboundp 'consult-buffer) #'consult-buffer #'switch-to-buffer)))

(defun earwig-cmd-search (text)
  "Search the buffer, starting from spoken TEXT, if any.
With `consult-line' if it's installed, else with isearch."
  (let ((text (earwig-downcase-first-word text)))
    (if (fboundp 'consult-line)
        (consult-line text)
      (isearch-forward nil t)
      (when text
        (isearch-yank-string text)))))

(defun earwig-cmd-run-command (name)
  "Run the command spoken as NAME, or else `execute-extended-command' with NAME."
  (let ((command (intern-soft (replace-regexp-in-string " +" "-" (downcase name)))))
    (if (commandp command)
        (call-interactively command)
      (earwig-with-input (downcase name) #'execute-extended-command))))

;;;; Help

(defun earwig-cmd-help ()
  "List the voice commands."
  (with-help-window "*Voice commands*"
    (princ (format "Voice commands (%s%s):\n\n"
                   (mapconcat #'identity (earwig--mode-keys 'command) " or ")
                   (if (and earwig-wake-word-commands earwig-wake-words)
                       (format ", or say \"%s\" while dictating" (car earwig-wake-words))
                     "")))
    (when earwig-chain-words
      (princ (format "  COMMAND %s COMMAND ...   (one after another)\n\n" (car earwig-chain-words))))
    (dolist (command (append earwig-extra-commands earwig-commands))
      (princ (format "  %s\n" (nth 2 command))))))

(provide 'earwig-commands)
;;; earwig-commands.el ends here
