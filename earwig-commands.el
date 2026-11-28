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

;; Voice commands: earwig.el hands the cleaned-up text of a command
;; recording (Cmd-f, F8), or with `earwig-wake-word-commands', what's
;; said after a wake word while dictating, to `earwig-run-command'
;; (earwig-grammar.el).  Commands are rules of a phony.el grammar,
;; Earwig's defined with `earwig-defcommand' and yours with
;; `phony-defun'; several can be said in a row ("cut that go to top
;; paste"), with `earwig-chain-words' ("and then") between them or
;; not.  Ending with one of `earwig-cancel-words' ("cut that, never
;; mind") runs nothing.
;;
;; For commands of your own, the rules `earwig-number',
;; `earwig-words', `earwig-text', `earwig-part', `earwig-target',
;; `earwig-destination' (earwig-grammar.el) and `earwig-when'
;; (earwig-org.el), and the functions `earwig-part-range',
;; `earwig-target-range', `earwig-target-ranges' (earwig-edit.el) and
;; `earwig-spoken-time' (earwig-org.el), and `earwig-raw-command', help
;; in writing them.
;;
;; A few commands use consult when it's installed, and built-in
;; commands otherwise: "search", "switch to buffer" and "go to heading".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'earwig-cleanup)
(require 'earwig-grammar)
(require 'earwig-edit)
(require 'earwig-structure)
(require 'earwig-move)
(require 'earwig-org)

;; Packages the commands use are only loaded when a command needs them
(declare-function consult-buffer "consult" (&optional sources))
(declare-function consult-line "consult" (&optional initial start))
(declare-function consult-org-heading "consult-org" (&optional match scope))
(declare-function earwig--mode-keys "earwig" (mode))

(defcustom earwig-wake-words '("okay" "ok")
  "Wake words: words that give a command while dictating.
See `earwig-wake-word-commands'.  A wake word may be several words, as
\"hey jarvis\", and there may be several.  With `earwig-listen-mode',
they're also the words Pincer listens for, as they're transcribed:
set them to the words of Pincer's model (`earwig-pincer-command'),
e.g. \='(\"hey jarvis\") for the pre-trained hey_jarvis model.  Earwig
doesn't check that they match."
  :type '(repeat string)
  :group 'earwig)

(defcustom earwig-wake-word-commands t
  "Non-nil to give voice commands while dictating, starting with a wake word.
Dictation carries on around them: pause, say \"okay, scratch that\" or a
chain such as \"okay, select last sentence and then cut that\", pause,
and keep dictating, where point is then.  With `earwig-streaming' this
works at every pause (see `earwig-dictation-pause'), otherwise only at
the start of a recording; with Pincer listening (`earwig-listen-mode')
and recording (`earwig-recorder'), at any moment, without a pause
first.  The wake words are `earwig-wake-words'.  If no command matches,
what was said is inserted as dictation, unless Pincer heard the wake
word.  Recordings made with a command key are commands either way; nil
makes a dictation key only ever dictate."
  :type 'boolean
  :group 'earwig)

(defcustom earwig-cancel-words '("cancel" "never mind" "nevermind")
  "Words that, said last, cancel a voice command, so nothing runs.
As in \"select last sentence and then cut that, cancel\", with a
command key or after a wake word; the words aren't dictated then
either.  Only as the last words, so \"cancel\" can still be part of a
command of your own."
  :type '(repeat string)
  :group 'earwig)

(defvar earwig-extra-commands nil
  "No longer used: voice commands of your own are `phony-defun' rules.")
(make-obsolete-variable 'earwig-extra-commands
                        "define voice commands with `phony-defun', see the manual."
                        "0.3.0")

(defvar earwig--last-dictation nil
  "(START END TEXT) of the last dictation inserted, for \"scratch that\".
START and END are markers; set by earwig.el.")

;;;; Wake and cancel words

(defun earwig--wake-word-regexp (between)
  "Return a regexp matching one of `earwig-wake-words', as a whole word.
BETWEEN matches what may come between the words of a wake word of
several, as the punctuation Orukeet may put there."
  (concat "\\<\\(?:"
          (mapconcat (lambda (words)
                       (replace-regexp-in-string " +" between (regexp-quote words) t t))
                     earwig-wake-words "\\|")
          "\\)\\>"))

(defun earwig--strip-wake-word (text)
  "Return TEXT after a leading wake word, or nil if it doesn't start with one.
A wake word of several words may have punctuation between them."
  (let ((case-fold-search t))
    (when (and earwig-wake-words
               (string-match (concat "\\`[ \t]*" (earwig--wake-word-regexp "[,.!]?[ \t]+")
                                     "[,.!]?[ \t]+")
                             text))
      (substring text (match-end 0)))))

(defun earwig--split-at-wake-word (text)
  "Return (BEFORE . AFTER), TEXT around the first wake word in it, or nil.
AFTER is from after the wake word and the punctuation and space after
it; BEFORE is up to it, trimmed.  A wake word of several words may have
any punctuation between them.  See `earwig-wake-words'."
  (let ((case-fold-search t))
    (when (and earwig-wake-words
               (string-match (concat (earwig--wake-word-regexp "[[:punct:][:space:]]+")
                                     "[[:punct:]]*[[:space:]]*")
                             text))
      (cons (string-trim (substring text 0 (match-beginning 0)))
            (substring text (match-end 0))))))

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

;;;; Helpers

(defun earwig-downcase-first-word (text)
  "Return TEXT with its first word lowercased, as Orukeet may capitalize it.
For spoken text that goes into a search, say.  TEXT may be nil."
  (and text (replace-regexp-in-string "\\`[^ ]+" #'downcase text t t)))

(defun earwig-with-input (input command)
  "Call COMMAND interactively with INPUT, if any, typed into its first prompt."
  (minibuffer-with-setup-hook (lambda () (when input (insert input)))
    (call-interactively command)))

(defconst earwig--number-words
  '(("zero" . 0) ("oh" . 0) ("one" . 1) ("two" . 2) ("three" . 3) ("four" . 4)
    ("five" . 5) ("six" . 6) ("seven" . 7) ("eight" . 8) ("nine" . 9)
    ("ten" . 10) ("eleven" . 11) ("twelve" . 12) ("thirteen" . 13)
    ("fourteen" . 14) ("fifteen" . 15) ("sixteen" . 16) ("seventeen" . 17)
    ("eighteen" . 18) ("nineteen" . 19) ("twenty" . 20) ("thirty" . 30)
    ("forty" . 40) ("fifty" . 50) ("sixty" . 60) ("seventy" . 70)
    ("eighty" . 80) ("ninety" . 90))
  "The number words below a hundred, and their values.")

(defconst earwig--number-scales
  '(("thousand" . 1000) ("million" . 1000000) ("billion" . 1000000000))
  "The words above \"hundred\" that multiply the number before them.")

(defconst earwig--number-points '("point" "decimal")
  "The words between a number and its decimals.")

(defun earwig--number-error (text format &rest args)
  "Signal a `user-error' that TEXT says no number, for the reason FORMAT and ARGS."
  (user-error "Can't parse number \"%s\": %s" text (apply #'format format args)))

(defun earwig--number-quote (word)
  "Return WORD in double quotes, or \"nothing\" if it's nil."
  (if word (format "\"%s\"" word) "nothing"))

(defun earwig--number-tokens (text)
  "Return the words and digit runs of TEXT, lowercased.
Spaces, commas and hyphens between words separate them, as in
\"forty-two\" and \"1,000\"; a dot before a digit is \"point\"."
  (let ((text (downcase (string-trim text))))
    (setq text (replace-regexp-in-string "[.?!]+\\'" "" text)
          text (replace-regexp-in-string "-\\([a-z]\\)" " \\1" text)
          text (replace-regexp-in-string "\\.\\([0-9]\\)" " point \\1" text))
    (split-string text "[ \t\n,;:]+" t)))

(defun earwig--number-chunk (tokens text start decimals)
  "Read the number that begins TOKENS, the words of TEXT, as far as it goes.
Return (DIGITS . REST): its digits as a string, and the tokens after it.
It ends at a word that can't continue it, as the second \"one\" in \"one
one\" can't, and signals a `user-error' at one that can't come there at
all.  START non-nil lets it begin with \"a\", \"hundred\" or a scale, as at
the start of TEXT; DECIMALS non-nil, after a decimal point, allows
neither \"hundred\" nor a scale."
  (let ((total 0)        ; what the scales so far make
        (limit nil)      ; the last scale: the next must be smaller
        (hundreds nil)   ; the hundreds of the group since then
        (small nil)      ; the rest of the group
        (kind nil)       ; what SMALL is: unit, teen, tens, tens-unit, digits or zero
        (literal nil)    ; the digit run the number began with, leading zeros and all
        (empty t)
        (after-and nil)
        (last nil))
    (when (and start (equal (car tokens) "a"))
      (unless (or (equal (cadr tokens) "hundred")
                  (assoc (cadr tokens) earwig--number-scales))
        (earwig--number-error text "\"a\" before %s" (earwig--number-quote (cadr tokens))))
      (setq last "a" tokens (cdr tokens)))
    (while
        (and tokens
             (let* ((token (car tokens))
                    (value (cdr (assoc token earwig--number-words)))
                    (scale (cdr (assoc token earwig--number-scales)))
                    (digits (and (string-match-p "\\`[0-9]+\\'" token)
                                 (string-to-number token)))
                    (taken
                     (cond
                      ((member token earwig--number-points) nil)
                      ((and value (zerop value))
                       (when empty (setq small 0 kind 'zero literal "0") t))
                      ((and value (< value 10))
                       (cond ((null kind) (setq small value kind 'unit) t)
                             ((eq kind 'tens) (setq small (+ small value) kind 'tens-unit) t)))
                      ((and value (< value 20))
                       (when (null kind) (setq small value kind 'teen) t))
                      (value
                       (when (null kind) (setq small value kind 'tens) t))
                      (digits
                       (cond (empty (setq small digits kind 'digits literal token) t)
                             ((and (eq kind 'tens) (= (length token) 1) (> digits 0))
                              (setq small (+ small digits) kind 'tens-unit) t)
                             ((and (null kind) (< digits (if hundreds 100 1000)))
                              (setq small digits kind 'digits) t)))
                      ((or scale (equal token "hundred"))
                       (when decimals
                         (earwig--number-error text "\"%s\" after a decimal point" token))
                       (let ((group (+ (or hundreds 0) (or small 0))))
                         (cond ((and empty start)
                                (if scale
                                    (setq total scale limit scale)
                                  (setq hundreds 100)))
                               ((and (not scale) (null hundreds) small (<= 1 small 99))
                                (setq hundreds (* small 100) small nil kind nil))
                               ((and scale (> group 0) (or (null limit) (< scale limit)))
                                (setq total (+ total (* group scale)) limit scale
                                      hundreds nil small nil kind nil))
                               (t (earwig--number-error text "\"%s\" after %s"
                                                        token (earwig--number-quote last))))
                         t))
                      ((equal token "and")
                       (unless (or (equal last "hundred") (assoc last earwig--number-scales))
                         (earwig--number-error text "\"and\" after %s" (earwig--number-quote last)))
                       (unless (cdr tokens)
                         (earwig--number-error text "nothing after \"and\""))
                       t)
                      ((equal token "a")
                       (earwig--number-error text "\"a\" goes only first, as in \"a hundred\""))
                      (t (earwig--number-error text "\"%s\" is no number" token)))))
               (cond
                (taken
                 (setq after-and (equal token "and") last token empty nil
                       tokens (cdr tokens))
                 t)
                (after-and
                 (earwig--number-error text "\"%s\" after \"and\"" token))
                (empty
                 (earwig--number-error text "\"%s\" out of place" token))))))
    (cons (if (and literal (zerop total) (null hundreds))
              literal
            (number-to-string (+ total (or hundreds 0) (or small 0))))
          tokens)))

(defun earwig--read-number (text)
  "Return the number TEXT says, or signal a `user-error' that says why not.
See `earwig-parse-number'."
  (let ((tokens (earwig--number-tokens text))
        (start t) whole decimals in-decimals)
    (unless tokens
      (earwig--number-error text "there's no number"))
    (while tokens
      (if (member (car tokens) earwig--number-points)
          (progn
            (when in-decimals
              (earwig--number-error text "a second decimal point"))
            (unless (cdr tokens)
              (earwig--number-error text "nothing after \"%s\"" (car tokens)))
            (setq in-decimals t tokens (cdr tokens)))
        (pcase-let ((`(,digits . ,rest)
                     (earwig--number-chunk tokens text start in-decimals)))
          (if in-decimals (push digits decimals) (push digits whole))
          (setq tokens rest)))
      (setq start nil))
    (string-to-number
     (concat (if whole (apply #'concat (nreverse whole)) "0")
             (and decimals (concat "." (apply #'concat (nreverse decimals))))))))

(defun earwig-parse-number (text &optional whole noerror)
  "Return the number TEXT says, in digits or words.
Understands e.g. \"42\", \"forty-two\", \"one hundred and five\", \"a
thousand\", \"2 million\" and \"1,000\", and decimals after \"point\" or
\"decimal\", as in \"two point five\" or \"2.5\", which give a float.
Numbers said one after another give one number of all their digits, as
when a number is said digit by digit or in parts: \"one one\" is 11,
\"nineteen eighty-four\" 1984, \"five twenty\" 520.  \"oh\" is zero, as
in \"nineteen oh five\".

When TEXT says no number, as \"lots\", \"minus three\" or \"five hundred
hundred\" don't, signal a `user-error' that says why: \"Can't parse
number ...\".  With WHOLE, do so for a decimal too: \"Not a whole
number ...\".  With NOERROR, return nil instead of signalling.

Leaves the match data alone, so a caller can parse a group and then
read the next."
  (save-match-data
    (condition-case err
        (let ((number (earwig--read-number (or text ""))))
          (when (and whole (floatp number))
            (user-error "Not a whole number: \"%s\"" text))
          number)
      (user-error (unless noerror (signal (car err) (cdr err)))))))

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

(defun earwig-cmd-goto-line (line)
  "Go to line LINE, a number."
  (push-mark)
  (goto-char (point-min))
  (forward-line (1- line)))

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

;;;; The commands' grammar

(earwig-defcommand earwig-say-save ("save" (? (? "the") (| "file" "buffer")))
  "Save the buffer."
  :help "save [file | buffer]"
  (call-interactively #'save-buffer))

(earwig-defcommand earwig-say-undo ("undo" (? "that"))
  "Undo, further back each time: never a redo, as `undo' said again is.
Each voice command is a command of its own to Emacs, so `undo' would
start over each time, and undo the undo before."
  :help "undo [that]"
  (call-interactively #'undo-only))

(earwig-defcommand earwig-say-redo "redo"
  "Redo."
  :help "redo"
  (call-interactively #'undo-redo))

(earwig-defcommand earwig-say-scratch-that "scratch that"
  "Delete the last dictation."
  :help "scratch that           (delete the last dictation)"
  (earwig-cmd-scratch-that))

(earwig-defcommand earwig-say-comment ("comment" (| "that" "this" "line"))
  "Comment the region or line."
  :help "comment that           (region or line)"
  (call-interactively #'comment-line))

(earwig-defcommand earwig-say-close ("close" (? (? (| "the" "this")) "buffer"))
  "Close the buffer."
  :help "close [buffer]"
  (call-interactively #'kill-current-buffer))

(earwig-defcommand earwig-say-goto-line ("go to line" (line earwig-number))
  "Go to line LINE."
  :help "go to line N           (\"forty two\" or 42)"
  :go t
  (earwig-cmd-goto-line line))

(earwig-defcommand earwig-say-top ("go to" (? "the") "top")
  "Go to the top of the buffer."
  :help "go to [the] top"
  :go t
  (call-interactively #'beginning-of-buffer))

(earwig-defcommand earwig-say-bottom ("go to" (? "the") "bottom")
  "Go to the bottom of the buffer."
  :help "go to [the] bottom"
  :go t
  (call-interactively #'end-of-buffer))

(earwig-defcommand earwig-say-goto-heading ("go to heading" (? (name earwig-text)))
  "Pick a heading, starting from NAME."
  :help "go to heading [NAME]"
  :go t
  (earwig-cmd-goto-heading name))

(earwig-defcommand earwig-say-scroll ("scroll" (direction (| "down" "up")))
  "Scroll down or up (DIRECTION)."
  :help "scroll down | up"
  (call-interactively (if (equal direction "down") #'scroll-up-command #'scroll-down-command)))

(earwig-defcommand earwig-say-other-window "other window"
  "Select the other window."
  :help "other window"
  (call-interactively #'other-window))

(earwig-defcommand earwig-say-search ("search" (? "for") (? (text earwig-text)))
  "Search the buffer, starting from TEXT."
  :help "search [for] [TEXT]"
  (earwig-cmd-search text))

(earwig-defcommand earwig-say-run-command ("run command" (name earwig-text))
  "Run the command NAME."
  :help "run command NAME       (\"org agenda\")"
  (earwig-cmd-run-command name))

(earwig-defcommand earwig-say-switch-buffer ("switch" (? "to") (? "buffer") (? (name earwig-text)))
  "Switch buffers, starting from NAME."
  :help "switch to [buffer] [NAME] (\"init dot el\")"
  (earwig-cmd-switch-buffer name))

(earwig-defcommand earwig-say-help "what can i say"
  "List the voice commands."
  :help "what can I say"
  (earwig-cmd-help))

;;;; Help

(defconst earwig--help-order
  '(earwig-say-save earwig-say-undo earwig-say-redo earwig-say-scratch-that earwig-say-comment
    earwig-say-edit earwig-say-format earwig-say-replace earwig-say-next-match earwig-say-go
    earwig-say-go-to earwig-say-go-back earwig-say-paste earwig-say-new-line
    earwig-say-move earwig-say-copy-to earwig-say-swap earwig-say-duplicate earwig-say-rewrite
    earwig-say-put-around earwig-say-unwrap earwig-say-replace-pair earwig-say-new-at
    earwig-say-go-into earwig-say-open-link earwig-say-focus earwig-say-where
    earwig-say-join earwig-say-structure earwig-say-close earwig-say-goto-line
    earwig-say-top earwig-say-bottom earwig-say-goto-heading earwig-say-scroll
    earwig-say-other-window earwig-say-search earwig-say-run-command
    earwig-say-schedule earwig-say-mark-done earwig-say-toggle-todo earwig-say-agenda
    earwig-say-switch-buffer earwig-say-help)
  "Earwig's commands in the order \"what can I say\" lists them; others follow.")

(defun earwig--help-rows (rows)
  "Print ROWS of (LEFT RIGHT) as two indented columns."
  (dolist (row rows)
    (let ((left (car row)) (right (cadr row)))
      (princ (cond ((string-empty-p right) (format "  %s\n" left))
                   ((> (length left) 30) (format "  %s\n  %-30s %s\n" left "" right))
                   (t (format "  %-30s %s\n" left right)))))))

(defun earwig--pattern-closed-p (pattern)
  "Non-nil if the Phony PATTERN only matches its own words, without rules."
  (pcase pattern
    ((pred stringp) t)
    ((pred symbolp) nil)
    (`(,(or 'seq '| '\? '+ '*) . ,parts) (seq-every-p #'earwig--pattern-closed-p parts))
    (`(,_argument ,sub) (earwig--pattern-closed-p sub))))

(defun earwig--pattern-help (pattern &optional inner)
  "Return PATTERN as \"what can I say\" shows it.
PATTERN is a Phony pattern, from `earwig--phony-rule-pattern'.  INNER
non-nil means it's part of a sequence, so alternatives need
parentheses."
  (pcase pattern
    ((pred stringp) pattern)
    ((pred symbolp)
     (upcase (string-remove-prefix "earwig-" (symbol-name pattern))))
    (`(seq . ,parts)
     (mapconcat (lambda (part) (earwig--pattern-help part (cdr parts))) parts " "))
    (`(\? ,sub) (format "[%s]" (earwig--pattern-help sub)))
    (`(| . ,alternatives)
     (format (if inner "(%s)" "%s")
             (mapconcat #'earwig--pattern-help alternatives " | ")))
    (`(,(or '+ '*) ,sub) (format "%s..." (earwig--pattern-help sub t)))
    (`(,argument ,sub)
     (if (earwig--pattern-closed-p sub)
         (earwig--pattern-help sub inner)
       (upcase (symbol-name argument))))))

(defun earwig--user-commands ()
  "Return the names of the voice commands that aren't Earwig's.
Those are the interactive Phony rules of the current buffer."
  (seq-remove (lambda (name) (memq name earwig--commands))
              (earwig--phony-interactive-rules (earwig--grammar))))

(defun earwig-cmd-help ()
  "List the voice commands.
How to chain and cancel them and what TARGET can be come first, then
Earwig's commands, then the rest, your own."
  (with-help-window "*Voice commands*"
    (princ (format "Voice commands (%s%s)\n\n"
                   (mapconcat #'identity (earwig--mode-keys 'command) " or ")
                   (if (and earwig-wake-word-commands earwig-wake-words)
                       (format ", or say \"%s\" while dictating" (car earwig-wake-words))
                     "")))
    (earwig--help-rows
     (append
      (list (list (if earwig-chain-words
                      (format "COMMAND [%s] COMMAND ..." (car earwig-chain-words))
                    "COMMAND COMMAND ...")
                  "one after another"))
      (when earwig-cancel-words
        (list (list (format "COMMAND ..., %s" (car earwig-cancel-words))
                    "runs nothing")))))
    (princ "\nTARGET, what an editing command acts on:\n\n")
    (earwig--help-rows earwig-edit-targets-help)
    (princ "\nCommands:\n\n")
    (dolist (name (append (seq-filter (lambda (name) (memq name earwig--commands))
                                      earwig--help-order)
                          (seq-remove (lambda (name) (memq name earwig--help-order))
                                      earwig--commands)))
      (let ((help (get name 'earwig-help)))
        (when help
          (princ (format "  %s\n" help)))))
    (let ((user (earwig--user-commands)))
      (when user
        (princ "\nYour commands:\n\n")
        (earwig--help-rows
         (mapcar (lambda (name)
                   (list (earwig--pattern-help (earwig--phony-rule-pattern name (earwig--grammar)))
                         (car (split-string (or (earwig--phony-rule-documentation name (earwig--grammar))
                                                "")
                                            "\n"))))
                 user))))))

(provide 'earwig-commands)
;;; earwig-commands.el ends here
