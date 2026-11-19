;;; earwig-cleanup.el --- Clean up dictated text before insertion  -*- lexical-binding: t; -*-

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

;; Runs on every transcription, in order: drop filler words, apply the
;; corrections in `earwig-corrections'; for dictation, then turn
;; spoken punctuation and breaks into symbols (`earwig-spoken-format')
;; and fit the text to where it's inserted (capitalization, trailing
;; punctuation, spacing, curly quotes).
;; `earwig-correct' fixes a misrecognition and remembers it in
;; `earwig-corrections-learned'.

;;; Code:

(require 'seq)
(require 'electric)

(defcustom earwig-filler-words
  '("um" "umm" "uh" "uhh" "uhm" "ah" "ahh" "er" "erm" "hm" "hmm" "mm")
  "Words dropped from transcriptions."
  :type '(repeat string)
  :group 'earwig)

(defcustom earwig-corrections nil
  "Corrections applied to every transcription, as (WRONG . RIGHT).
WRONG matches whole words, ignoring case, and is replaced by RIGHT.
Multi-word WRONGs apply before single words.  Corrections made with
`earwig-correct' go in `earwig-corrections-learned' instead, and win
over these for the same WRONG.  Misrecognized punctuation, as \"coma\",
goes in `earwig-spoken-format' instead, so it applies to dictation only."
  :type '(alist :key-type (string :tag "Wrong") :value-type (string :tag "Right"))
  :group 'earwig)

(defcustom earwig-corrections-commands nil
  "Corrections applied to voice commands only, as (WRONG . RIGHT).
For misrecognitions that are words in dictation, as \"kut\" for
\"cut\".  Matched like `earwig-corrections', after those, and only
when the command as said matches none: \"find note Kat\" keeps its
\"Kat\".  With `earwig-wake-word-commands', they apply to what follows
the wake word, not to the dictation around it.
Misrecognized words in your own commands are better as alternatives in
their patterns, which leave the rest of the command alone."
  :type '(alist :key-type (string :tag "Wrong") :value-type (string :tag "Right"))
  :group 'earwig)

(defcustom earwig-corrections-learned nil
  "Corrections made with `earwig-correct', as (WRONG . RIGHT).
Applied like `earwig-corrections', winning over those for the same
WRONG.  Saved with Customize, in `custom-file' if there is one."
  :type '(alist :key-type (string :tag "Wrong") :value-type (string :tag "Right"))
  :group 'earwig)

(defcustom earwig-keep-capitalized '("I" "I'm" "I've" "I'll" "I'd")
  "Words that keep their capital when dictated mid-sentence.
The right-hand sides of `earwig-corrections' and
`earwig-corrections-learned' keep theirs too."
  :type '(repeat string)
  :group 'earwig)

;;;; Filler words

(defun earwig--tidy ()
  "Fix the spacing and punctuation left behind in the current buffer."
  (dolist (fix '(("[ \t]\\{2,\\}" . " ")           ; doubled spaces
                 ("[ \t]+\\([,.?!;:]\\)" . "\\1")  ; space before punctuation
                 ("\\`[ \t\n,.;:]+" . "")          ; leading leftovers
                 ("[ \t\n]+\\'" . "")))
    (goto-char (point-min))
    (while (re-search-forward (car fix) nil t)
      (replace-match (cdr fix) t))))

(defun earwig-remove-fillers (text)
  "Return TEXT without `earwig-filler-words' and the commas around them."
  (with-temp-buffer
    (insert text)
    (let ((case-fold-search t)
          (filler (concat "\\b" (regexp-opt earwig-filler-words) "\\b")))
      ;; At a sentence start the next word takes over the capital:
      ;; "Um, so I" -> "So I"
      (goto-char (point-min))
      (while (re-search-forward
              (concat "\\(?:^\\|[.?!][ \t]+\\)\\(" filler "[,.]?[ \t]*\\)") nil t)
        (replace-match "" t t nil 1)
        (upcase-region (point) (min (1+ (point)) (point-max))))
      ;; Elsewhere drop the commas around it too: "and, uh, archive" -> "and archive"
      (goto-char (point-min))
      (while (re-search-forward (concat ",?[ \t]*" filler ",?") nil t)
        (replace-match "" t t))
      (earwig--tidy))
    (buffer-string)))

;;;; Corrections

(defun earwig--corrections (&optional commands)
  "Return the corrections to apply, as (WRONG . RIGHT), longest WRONG first.
Those of `earwig-corrections', with `earwig-corrections-learned' winning
for the same WRONG; with COMMANDS, those of `earwig-corrections-commands'
instead."
  (let (pairs)
    (dolist (pair (if commands
                      earwig-corrections-commands
                    (append earwig-corrections earwig-corrections-learned)))
      (setf (alist-get (string-join (split-string (car pair)) " ") pairs
                       nil nil #'string-equal-ignore-case)
            (cdr pair)))
    (sort pairs (lambda (a b) (> (length (car a)) (length (car b)))))))

(defun earwig--match-case (match replacement)
  "Return REPLACEMENT, capitalized if MATCH was and REPLACEMENT isn't."
  (let ((case-fold-search nil))
    (if (and (string-match-p "\\`[[:upper:]]" match)
             (string-match-p "\\`[[:lower:]]" replacement))
        (concat (upcase (substring replacement 0 1)) (substring replacement 1))
      replacement)))

(defun earwig--correction-regexp (wrong &optional separator)
  "Regexp matching WRONG as whole words, however much whitespace separates them.
SEPARATOR is the regexp between the words instead, if given.  Use with
`case-fold-search' bound to t."
  (concat "\\b" (mapconcat #'regexp-quote (split-string wrong) (or separator "[ \t\n]+"))
          "\\b"))

(defun earwig-apply-corrections (text &optional commands)
  "Return TEXT with `earwig-corrections' applied.
WRONG matches whole words, ignoring case.  With COMMANDS, apply
`earwig-corrections-commands' instead."
  (let ((case-fold-search t))
    (dolist (pair (earwig--corrections commands) text)
      (setq text (replace-regexp-in-string
                  (earwig--correction-regexp (car pair))
                  (lambda (match) (earwig--match-case match (cdr pair)))
                  text t t)))))

(defun earwig--replace-in-buffer (wrong right skip-beg skip-end)
  "Replace WRONG with RIGHT throughout the buffer, as whole words.
Matches like `earwig-apply-corrections'.  Leaves SKIP-BEG to SKIP-END
alone: the spot already corrected, which may contain WRONG itself.
Returns the number replaced."
  (let ((case-fold-search t)
        (regexp (earwig--correction-regexp wrong))
        (skip-beg (copy-marker skip-beg))
        (skip-end (copy-marker skip-end))
        (count 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (if (and (< (match-beginning 0) skip-end) (> (match-end 0) skip-beg))
            (goto-char (max (point) skip-end))
          (replace-match (earwig--match-case (match-string 0) right) t t)
          (setq count (1+ count)))))
    count))

(defun earwig--remember-correction (wrong right)
  "Add WRONG => RIGHT to `earwig-corrections-learned' and save it.
Returns nil without saving if that's already the correction for WRONG."
  (let ((wrong (string-join (split-string wrong) " ")))
    (unless (equal (alist-get wrong (earwig--corrections) nil nil #'string-equal-ignore-case)
                   right)
      (customize-save-variable
       'earwig-corrections-learned
       (append (seq-remove (lambda (pair) (string-equal-ignore-case (car pair) wrong))
                           earwig-corrections-learned)
               (list (cons wrong right))))
      t)))

;;;###autoload
(defun earwig-correct (beg end correction &optional everywhere)
  "Replace the text from BEG to END with CORRECTION and remember the fix.
Interactively, corrects the region, or else the word before point.  The
pair goes into `earwig-corrections-learned', so future transcriptions
get it right.  With EVERYWHERE (interactively, a prefix argument), also
replace the same misrecognition throughout the buffer."
  (interactive
   (let ((bounds (if (use-region-p)
                     (cons (region-beginning) (region-end))
                   (save-excursion
                     (skip-syntax-backward "^w")
                     (bounds-of-thing-at-point 'word)))))
     (unless bounds
       (user-error "No word before point to correct"))
     (let ((wrong (buffer-substring-no-properties (car bounds) (cdr bounds))))
       (list (car bounds) (cdr bounds)
             (read-string (format "Correct \"%s\"%s to: " wrong
                                  (if current-prefix-arg " everywhere" ""))
                          wrong)
             current-prefix-arg))))
  (let ((wrong (buffer-substring-no-properties beg end))
        (after (max 0 (- (point) end))))
    (when (string-empty-p (string-trim correction))
      (user-error "Empty correction"))
    (delete-region beg end)
    (goto-char beg)
    (insert correction)
    (forward-char (min after (- (point-max) (point))))
    (unless (string-equal wrong correction)
      (let ((others (if everywhere
                        (earwig--replace-in-buffer wrong correction
                                                     beg (+ beg (length correction)))
                      0)))
        (message "%s: %s => %s%s"
                 (if (earwig--remember-correction wrong correction)
                     "Remembered"
                   "Already known")
                 wrong correction
                 (if everywhere (format " (%d more replaced in buffer)" others) ""))))))

;;;; Spoken punctuation and breaks

(defcustom earwig-format-dictation t
  "Non-nil to turn spoken punctuation and breaks in dictation into symbols.
What's said and what it becomes are in `earwig-spoken-format'."
  :type 'boolean
  :group 'earwig)

(defcustom earwig-spoken-format
  '((punct ","  "comma")
    (punct "."  "period" "full stop")
    (punct ":"  "colon")
    (punct ";"  "semicolon" "semi colon")
    (punct "?"  "question mark")
    (punct "!"  "exclamation mark" "exclamation point")
    (punct "…"  "ellipsis" "dot dot dot")
    (open  "("  "open paren" "open parenthesis" "open parent")
    (close ")"  "close paren" "close parenthesis" "close parent")
    (open  "["  "open bracket" "open square bracket")
    (close "]"  "close bracket" "close square bracket")
    (open  "{"  "open brace" "open curly brace")
    (close "}"  "close brace" "close curly brace")
    (open  "\"" "open quote" "begin quote" "open double quote")
    (close "\"" "close quote" "end quote" "unquote" "close double quote")
    (toggle "\"" "quote")
    (continue "\"" "continue quote")
    (open  "'"  "open single quote" "begin single quote")
    (close "'"  "close single quote" "end single quote")
    (toggle "'" "single quote")
    (continue "'" "continue single quote")
    (join  "—"  "em dash" "m dash")
    (break "\n" "new line")
    (break "\n\n" "new paragraph")
    (capital "" "new sentence"))
  "What dictation turns into symbols: entries of (KIND SYMBOL PHRASE...).
A PHRASE, matched as whole words ignoring case, becomes SYMBOL.  KIND
says how SYMBOL sits between the words around it:
  punct  right after the word before, then a space
  open   a space before, none after
  close  right after the word before, then a space
  join   no space either side
  break  a line break, with a capital after it
  toggle  a quote that closes if one is open in the paragraph, else opens
  continue  a quote that opens again after a comma, with no capital
          after it: \"I may,\" he said, \"go\"
  capital  nothing, but a capital for the word after it, as for a
          new sentence after a closing quote: \"Fiddlesticks!\" He went
Each replaces the punctuation Orukeet puts around the phrase itself, as
in \"tomorrow, period.\".  Only phrases that are rarely meant as words
are here; `earwig-spoken-format-code' has more.  Entries of your own can
repeat a SYMBOL, as for misrecognitions: (punct \",\" \"coma\").
The first entry with a PHRASE wins, so for single quotes on \"open
quote\" put (open \"'\" \"open quote\") and (close \"'\" \"close quote\")
first.  Straight quotes become curly ones as `earwig-curly-quotes' says."
  :type '(repeat (cons (choice (const punct) (const open) (const close)
                               (const join) (const break) (const toggle)
                               (const continue) (const capital))
                       (cons (string :tag "Symbol") (repeat (string :tag "Phrase")))))
  :group 'earwig)

(defconst earwig-spoken-format-code
  '((join "-"  "hyphen" "dash")
    (join "_"  "underscore")
    (join "/"  "slash")
    (join "\\" "backslash")
    (join "."  "dot")
    (join "~"  "tilde"))
  "Entries for `earwig-spoken-format' that are ordinary words too.
To dictate \"foo dot el\" as \"foo.el\" everywhere:
  (setq earwig-spoken-format
        (append earwig-spoken-format earwig-spoken-format-code))")

(defcustom earwig-literal-word "literal"
  "Said before a phrase in `earwig-spoken-format' to keep it as words.
\"literal period\" dictates \"period\"."
  :type 'string
  :group 'earwig)

(defconst earwig--phrase-gap "[,.;:?!]*[ \t\n]+"
  "Regexp for what separates the words of a spoken phrase as transcribed.")

(defun earwig--format-regexp (entries)
  "Regexp matching the phrases of ENTRIES, a `earwig-spoken-format'.
Group 1 is `earwig-literal-word' before one, group 2 the phrase.  The
words of a phrase may have Orukeet's punctuation between them, as in
\"continue, quote\"."
  (let ((phrases (sort (mapcan (lambda (entry) (copy-sequence (cddr entry))) entries)
                       (lambda (a b) (> (length a) (length b))))))
    (concat "\\b\\(?:\\(" (regexp-quote earwig-literal-word) "\\)[ \t]+\\)?\\("
            (mapconcat (lambda (phrase) (earwig--correction-regexp phrase earwig--phrase-gap))
                       phrases "\\|")
            "\\)")))

(defun earwig--format-absorbs (kind before &optional quote)
  "The punctuation of Orukeet's own that a symbol of KIND replaces.
On the side BEFORE it if non-nil, else after.  A list of characters.
Pause commas always go; sentence ends only where they can't be meant:
a bracket opened after a sentence is a new one, one closed may end it.
A closing bracket keeps a question or exclamation mark before it.  A
closing QUOTE takes all of it, on both sides, to put the strongest
inside (`earwig--strongest-mark')."
  (string-to-list (cond ((and quote (eq kind 'close)) ",.;:?!")
                        ((and before (eq kind 'close)) ",.;:")
                        ((if before
                             (memq kind '(punct continue capital))
                           (not (eq kind 'close)))
                         ",.;:?!")
                        (t ",;:"))))

(defun earwig--strongest-mark (punctuation)
  "The mark among Orukeet's PUNCTUATION, a string, that goes in a closing quote.
A question or exclamation mark, else a period, else a comma; nil if
there's none of them."
  (cond ((string-match "[?!]" punctuation) (match-string 0 punctuation))
        ((string-search "." punctuation) ".")
        ((string-search "," punctuation) ",")))

(defun earwig--continue-comma-p ()
  "Non-nil if a quote continued at point needs a comma before it.
After a word, or a bracket or quote that closes: he said, \"to go\"."
  (let ((char (char-before)))
    (and char
         (or (memq (char-syntax char) '(?w ?_ ?\)))
             (and (memq char (append '(?\" ?') (earwig--quote-chars 'close)))
                  (not (earwig--opening-quote-p
                        char (char-before (1- (point)))
                        (get-text-property (1- (point)) 'earwig-spoken))))))))

(defun earwig--format-skip-back (chars)
  "Move back over spaces and Orukeet's punctuation among CHARS.
Stops at symbols already put in by `earwig-apply-format'."
  (skip-chars-backward " \t")
  (while (and (not (bobp))
              (memq (char-before) chars)
              (not (get-text-property (1- (point)) 'earwig-spoken)))
    (backward-char))
  (skip-chars-backward " \t"))

(defun earwig--format-symbol (entry beg end)
  "Replace the phrase from BEG to END with ENTRY's symbol, spaced for its kind.
Takes the punctuation around the phrase with it, and fixes the capital
of the word after.  Leaves point after the symbol.  A `toggle' quote
must have been made `open' or `close'; a `continue' quote is an `open'
one with a `earwig-continue' property, and a `capital' leaves a
`earwig-capital' property on the word after it, for
`earwig-fit-to-context'."
  (pcase-let* ((`(,kind ,symbol . ,_) entry)
               (quote (earwig--quote-char-p symbol))
               (case-fold-search nil)
               (sentence-end nil)
               (absorbed nil)
               (start nil)
               (inside nil))
    (goto-char end)
    (let ((from (point)))
      (while (memq (char-after) (earwig--format-absorbs kind nil quote))
        (forward-char))
      (setq sentence-end (string-match-p "[.?!]" (buffer-substring from (point)))))
    (skip-chars-forward " \t")
    (let ((after (point)))
      (goto-char beg)
      (earwig--format-skip-back (earwig--format-absorbs kind t quote))
      (setq absorbed (replace-regexp-in-string
                      "[^,.;:?!]" "" (buffer-substring-no-properties (point) after)))
      (delete-region (point) after))
    ;; Orukeet's punctuation goes inside a closing quote, unless spoken
    ;; punctuation is there: "for her." not "for her".  At the start,
    ;; what's inside is in the buffer: the mark stays after the quote,
    ;; for `earwig-fit-to-context'
    (setq start (and (eq kind 'close) quote (bobp)
                     (earwig--strongest-mark absorbed)))
    (when (and (eq kind 'close) quote
               (not (bobp))
               (not (memq (char-before) '(?\s ?\t ?\n)))
               (not (eq (get-text-property (1- (point)) 'earwig-spoken) 'punct)))
      (let ((mark (earwig--strongest-mark absorbed)))
        (when mark
          (insert (propertize mark 'earwig-spoken 'punct)))))
    (when (and (eq kind 'continue) (earwig--continue-comma-p))
      (insert ","))
    (when (and (memq kind '(open continue capital))
               (not (bobp))
               (not (memq (char-before) '(?\s ?\t ?\n)))
               (not (memq (get-text-property (1- (point)) 'earwig-spoken)
                          '(open join break))))
      (insert " "))
    (insert (if (eq kind 'continue)
                (propertize symbol 'earwig-spoken 'open 'earwig-continue t)
              (propertize symbol 'earwig-spoken kind)))
    (setq inside (and (eq kind 'close) quote
                      (char-before (- (point) (length symbol)))))
    (when start
      (insert start))
    (when (and (memq kind '(punct close))
               (not (or (eobp) (memq (char-after) '(?. ?? ?! ?, ?\; ?:)))))
      (insert " "))
    (cond
     ((or (eq kind 'break) (and (eq kind 'punct) (string-match-p "[.?!]\\'" symbol)))
      (when (looking-at "[[:lower:]]")
        (upcase-region (point) (1+ (point)))))
     ((eq kind 'capital)
      (when (looking-at "[[:alpha:]]")
        (upcase-region (point) (1+ (point)))
        (put-text-property (point) (1+ (point)) 'earwig-capital t)))
     ;; After a quote closed: "Go!" he said, but "Go." He went
     (inside
      (cond ((and (eq inside ?.) (looking-at "[[:lower:]]"))
             (upcase-region (point) (1+ (point))))
            ((and (not (eq inside ?.))
                  (looking-at "[[:upper:]][[:alnum:]']*")
                  (not (earwig--keep-capital-p (match-string 0))))
             (downcase-region (point) (1+ (point))))))
     ;; A quote continued after "he said,": no capital
     ((eq kind 'continue)
      (when (and (looking-at "[[:upper:]][[:alnum:]']*")
                 (not (earwig--keep-capital-p (match-string 0))))
        (downcase-region (point) (1+ (point)))))
     ;; A quote opened where a sentence can start: He said, "Go"
     ((and (eq kind 'open) (earwig--quote-char-p symbol))
      (cond ((earwig--quote-opens-sentence-p (- (point) (length symbol)))
             (when (looking-at "[[:lower:]]")
               (upcase-region (point) (1+ (point)))))
            ((and sentence-end
                  (looking-at "[[:upper:]][[:alnum:]']*")
                  (not (earwig--keep-capital-p (match-string 0))))
             (downcase-region (point) (1+ (point))))))
     ;; Orukeet ended a sentence where "comma" was said: "note, comma. Thanks"
     ((and sentence-end
           (memq kind '(punct join))
           (looking-at "[[:upper:]][[:alnum:]']*")
           (not (earwig--keep-capital-p (match-string 0))))
      (downcase-region (point) (1+ (point)))))))

(defun earwig--spoken-entry (phrase entries)
  "The entry of ENTRIES that PHRASE, as transcribed, was said for."
  (let ((phrase (string-join (split-string phrase earwig--phrase-gap) " ")))
    (seq-find (lambda (entry) (member-ignore-case phrase (cddr entry))) entries)))

(defun earwig--quote-family (char)
  "The straight quote, ?\" or ?', of the quote CHAR, straight or curly."
  (cond ((memq char (list ?\" (nth 2 electric-quote-chars) (nth 3 electric-quote-chars))) ?\")
        ((memq char (list ?' (nth 0 electric-quote-chars) (nth 1 electric-quote-chars))) ?')))

(defun earwig--open-quotes (buffer pos)
  "The quotes open at POS in BUFFER: a list of ?\" and ?', innermost first.
Counted from the start of the paragraph.  A single quote closing right
before a letter is an apostrophe: don't."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (let ((regexp (concat "[\"'" (apply #'string electric-quote-chars) "]"))
            open)
        (when (re-search-backward "^[ \t]*$" nil 'move)
          ;; On a blank line itself, nothing is open
          (goto-char (min pos (line-beginning-position 2))))
        (while (re-search-forward regexp pos t)
          (let ((char (char-before))
                (family (earwig--quote-family (char-before))))
            (cond
             ((earwig--opening-quote-p char (char-before (1- (point))))
              (push family open))
             ((and (eq family ?') (looking-at "[[:alpha:]]")))
             ((memq family open)
              (let ((i (seq-position open family)))
                (setq open (append (seq-take open i) (nthcdr (1+ i) open))))))))
        open))))

(defun earwig-apply-format (text &optional no-breaks buffer pos)
  "Return TEXT with spoken punctuation and breaks as symbols.
See `earwig-spoken-format'.  With NO-BREAKS, \"new line\" and the like
stay words.  Each symbol has a `earwig-spoken' property, its kind,
for `earwig-absorb-before' and `earwig-fit-to-context'.  A `toggle'
quote closes if one is open, in TEXT or, given BUFFER, at POS in it."
  (let ((entries (if no-breaks
                     (seq-remove (lambda (entry) (eq (car entry) 'break))
                                 earwig-spoken-format)
                   earwig-spoken-format)))
    (if (not (and earwig-format-dictation entries))
        text
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (let ((case-fold-search t)
              (regexp (earwig--format-regexp entries))
              (open (and buffer (earwig--open-quotes buffer pos))))
          (while (re-search-forward regexp nil t)
            (if (match-beginning 1)
                (replace-match (match-string 2) t t)
              (pcase-let* ((beg (match-beginning 0))
                           (end (match-end 0))
                           (`(,kind ,symbol . ,phrases)
                            (earwig--spoken-entry (match-string 2) entries))
                           (family (and (earwig--quote-char-p symbol)
                                        (earwig--quote-family (aref symbol 0)))))
                (when (eq kind 'toggle)
                  (setq kind (if (memq family open) 'close 'open)))
                (when family
                  (setq open (if (eq kind 'close)
                                 (remq family open)
                               (cons family open))))
                (earwig--format-symbol (cons kind (cons symbol phrases)) beg end)))))
        (string-trim (buffer-string) "[ \t]+" "[ \t]+")))))

(defun earwig-absorb-before (text buffer pos)
  "Delete what TEXT's first symbol replaces before POS in BUFFER.
TEXT is from `earwig-apply-format'.  The same as it does within a
transcription, across where TEXT goes: a pause before \"comma\" while
streaming leaves \"tomorrow.\" in the buffer and \"Comma.\" to come.
Punctuation and closing brackets take the spaces before them too.  An
opening quote leaves the comma or colon before it: He said, \"Go.\"
A continued quote replaces a period with a comma, or adds one, and a
closing quote takes only the spaces.
Returns where TEXT goes now."
  (let ((kind (and (> (length text) 0) (get-text-property 0 'earwig-spoken text))))
    (cond
     ((and kind (get-text-property 0 'earwig-continue text))
      (with-current-buffer buffer
        (save-excursion
          (goto-char pos)
          (skip-chars-backward " \t")
          (let ((spaces (- pos (point))))
            (when (memq (char-before) '(?. ?\;))
              (delete-char -1))
            (when (earwig--continue-comma-p)
              (insert ","))
            (+ (point) spaces)))))
     ((or (not kind)
          (and (eq kind 'open) (earwig--quote-char-p (substring text 0 1))))
      pos)
     ;; Punctuation before a closing quote is inside it: "for her."
     ((and (eq kind 'close) (earwig--quote-char-p (substring text 0 1)))
      (with-current-buffer buffer
        (save-excursion
          (goto-char pos)
          (skip-chars-backward " \t")
          (delete-region (point) pos)
          (point))))
     (t
      (with-current-buffer buffer
        (save-excursion
          (goto-char pos)
          (skip-chars-backward " \t")
          (let ((spaces (point)))
            (while (memq (char-before) (earwig--format-absorbs kind t))
              (backward-char))
            (skip-chars-backward " \t")
            (if (or (< (point) spaces) (not (eq kind 'open)))
                (progn (delete-region (point) pos)
                       (point))
              pos))))))))

;;;; Fitting text to where it's inserted

(defcustom earwig-curly-quotes 'electric
  "Whether dictated quotes and apostrophes are curly, as “this” and don’t.
`electric' for where `electric-quote-mode' would curl what you type,
t for everywhere, nil for nowhere (\"this\" and don't).  Which curly
quotes they are is up to `electric-quote-chars'."
  :type '(choice (const :tag "Where electric-quote-mode is on" electric)
                 (const :tag "Everywhere" t)
                 (const :tag "Nowhere" nil))
  :group 'earwig)

(defun earwig--quote-chars (side)
  "The curly quotes of `electric-quote-chars' that open, if SIDE is `open'.
Else those that close."
  (if (eq side 'open)
      (list (nth 0 electric-quote-chars) (nth 2 electric-quote-chars))
    (list (nth 1 electric-quote-chars) (nth 3 electric-quote-chars))))

(defun earwig--quote-char-p (symbol)
  "Non-nil if SYMBOL, a string, is a quote, straight or curly."
  (and (= (length symbol) 1)
       (memq (aref symbol 0) (append '(?\" ?') electric-quote-chars))))

(defun earwig--opening-quote-p (char before &optional kind)
  "Non-nil if CHAR is a quote that opens, after the character BEFORE.
BEFORE is nil at the start of the text.  KIND is CHAR's `earwig-spoken'
kind if it has one.  Otherwise a straight quote opens, as with
`electric-quote-mode', after whitespace, an opening bracket or quote."
  (cond ((memq char (earwig--quote-chars 'open)))
        ((memq char '(?\" ?'))
         (if kind
             (eq kind 'open)
           (or (null before)
               (memq before '(?\s ?\t ?\n))
               (eq (char-syntax before) ?\()
               (memq before (earwig--quote-chars 'open)))))))

(defun earwig--curly-quotes-p (pos)
  "Non-nil if quotes dictated at POS in the current buffer are curly.
See `earwig-curly-quotes'."
  (if (not (eq earwig-curly-quotes 'electric))
      earwig-curly-quotes
    (and (bound-and-true-p electric-quote-mode)
         (save-excursion
           (goto-char pos)
           (and (not (run-hook-with-args-until-success 'electric-quote-inhibit-functions))
                (if (derived-mode-p 'text-mode)
                    electric-quote-paragraph
                  (let ((ppss (syntax-ppss)))
                    (or (and electric-quote-comment (nth 4 ppss))
                        (and electric-quote-string (nth 3 ppss))))))))))

(defun earwig--curl-quotes (text before)
  "Return TEXT with its straight quotes and apostrophes curled.
BEFORE is the character before where TEXT goes.  Each opens or closes
as `earwig--opening-quote-p' says, so \"don't\" becomes \"don’t\"."
  (let ((text (copy-sequence text)))
    (dotimes (i (length text))
      (let ((char (aref text i)))
        (when (memq char '(?\" ?'))
          (aset text i (nth (+ (if (eq char ?\") 2 0)
                               (if (earwig--opening-quote-p
                                    char (if (> i 0) (aref text (1- i)) before)
                                    (get-text-property i 'earwig-spoken text))
                                   0 1))
                            electric-quote-chars)))))
    text))

(defvar org-todo-regexp)

(defun earwig--title-at (pos)
  "Return (KIND . START) if POS is in the title of a heading or list item.
KIND is `heading' for an Org or Markdown heading, `checkbox' for a
list item with a checkbox and `item' for another; START is where the
title's text starts, after the stars or hashes, an Org heading's TODO
keyword and priority, the bullet or number, and the checkbox; or POS,
if it's in the spaces after them.  POS is in the title from there to
the end of the line."
  (save-excursion
    (goto-char pos)
    (let ((case-fold-search nil)
          (end (line-end-position))
          kind)
      (forward-line 0)
      (cond
       ((and (derived-mode-p 'org-mode) (looking-at "\\*+[ \t]+"))
        (goto-char (match-end 0))
        (when (and (bound-and-true-p org-todo-regexp)
                   (looking-at (concat org-todo-regexp "\\(?:[ \t]+\\|$\\)")))
          (goto-char (match-end 0)))
        (when (looking-at "\\[#[[:alnum:]]+\\]\\(?:[ \t]+\\|$\\)")
          (goto-char (match-end 0)))
        (setq kind 'heading))
       ((and (derived-mode-p 'markdown-mode) (looking-at "#+[ \t]+"))
        (goto-char (match-end 0))
        (setq kind 'heading))
       ((looking-at "[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+\\(\\[[ xX-]\\][ \t]+\\)?")
        (goto-char (match-end 0))
        (setq kind (if (match-beginning 1) 'checkbox 'item))))
      ;; Within the spaces after the prefix, as before an Org heading's
      ;; tags, POS is where the title starts
      (let ((start (point)))
        (skip-chars-backward " \t")
        (and kind (<= (point) pos end) (cons kind (min start pos)))))))

(defun earwig--sentence-start-p (pos)
  "Non-nil if text inserted at POS starts a new sentence.
That's at the start of a line, list item (after a checkbox too) or
heading, or after .?! , also when markup closes after them, as in
*Done.*  After a quote that opens, where the quote starts one
\(`earwig--quote-opens-sentence-p'); after one that closes, only if it
closes after a period, as \"Go!\" she said."
  (save-excursion
    (goto-char pos)
    (while (and (not (bobp))
                (earwig--opening-quote-p (char-before) (char-before (1- (point)))))
      (backward-char))
    (if (< (point) pos)
        (earwig--quote-opens-sentence-p (point))
      (or (looking-back "^[ \t]*\\(?:[-+*#]+[ \t]+\\(?:\\[[ xX-]\\][ \t]+\\)?\\|[0-9]+[.)][ \t]+\\(?:\\[[ xX-]\\][ \t]+\\)?\\)?"
                        (line-beginning-position))
          ;; After an Org heading's TODO keyword and priority
          (eql (cdr (earwig--title-at (point))) (point))
          (progn (skip-chars-backward " \t\n")
                 ;; Closing emphasis, Org's or Markdown's
                 (skip-chars-backward "*_/=~+`")
                 (let ((closed nil))
                   (while (and (not (bobp))
                               (or (memq (char-before) (earwig--quote-chars 'close))
                                   (and (memq (char-before) '(?\" ?'))
                                        (not (earwig--opening-quote-p
                                              (char-before) (char-before (1- (point))))))))
                     (backward-char)
                     (setq closed t))
                   (or (bobp) (memq (char-before) (if closed '(?.) '(?. ?? ?!))))))))))

(defun earwig--quote-opens-sentence-p (pos)
  "Non-nil if a quote opened at POS starts a sentence.
At a sentence start, or after a comma or colon: He said, \"Go.\""
  (or (earwig--sentence-start-p pos)
      (save-excursion
        (goto-char pos)
        (skip-chars-backward " \t")
        (memq (char-before) '(?, ?:)))))

(defun earwig--keep-capital-p (word)
  "Non-nil if WORD keeps its capital mid-sentence (\"I\", names, acronyms)."
  (let ((case-fold-search nil))
    (or (member word earwig-keep-capitalized)
        (member word (mapcar (lambda (pair) (car (split-string (cdr pair))))
                             (earwig--corrections)))
        (string-match-p "\\`[[:upper:]][[:upper:][:digit:]]+\\'" word))))

(defun earwig-fit-to-context (text buffer pos)
  "Adjust TEXT for insertion into BUFFER at POS.
Mid-sentence, the first word loses its capital; after a quote TEXT
opens with, it gets one where the quote starts a sentence, and loses
it elsewhere or where the quote continues one.  A word with a
`earwig-capital' property always has one.  After a quote TEXT closes
with, it has one if a period ends the quote.  When more text follows on
the line, sentence-ending punctuation is dropped, unless TEXT is a
whole sentence inserted before another.  At the start of a heading or
list item, a first word all in lower case gets a capital; in a heading
or checkbox item, the period TEXT ends with goes, unless it was said or
the title is more than one sentence (`earwig--title-at').  Spaces are
added where TEXT would otherwise run into the neighbouring words, except next to
symbols from `earwig-apply-format' that attach to them and after an
opening quote; spoken punctuation at the end stays.  Quotes are
curled as `earwig-curly-quotes' says.
Returns TEXT without text properties."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (let* ((case-fold-search nil)
             (prev (char-before))
             (text (if (earwig--curly-quotes-p pos) (earwig--curl-quotes text prev) text))
             (closing (and (> (length text) 0)
                           (memq (aref text 0) (append '(?\" ?') (earwig--quote-chars 'close)))
                           (not (earwig--opening-quote-p
                                 (aref text 0) prev (get-text-property 0 'earwig-spoken text)))))
             ;; Orukeet's punctuation after a quote TEXT closes goes inside,
             ;; unless some is there: "for her." and "Go!" not "Go!".
             (text (if (and closing
                            (string-match "\\`.\\([,.;:?!]+\\)" text)
                            (not (get-text-property 1 'earwig-spoken text)))
                       (let ((mark (and (not (memq prev '(?. ?? ?! ?… ?, ?\; ?:)))
                                        (earwig--strongest-mark (match-string 1 text)))))
                         (concat (if mark (propertize mark 'earwig-spoken 'punct) "")
                                 (substring text 0 1)
                                 (substring text (match-end 1))))
                     text))
             (inside (and closing
                          (if (eq (get-text-property 0 'earwig-spoken text) 'punct)
                              (aref text 0)
                            prev)))
             (first (and (> (length text) 0) (get-text-property 0 'earwig-spoken text)))
             (last (and (> (length text) 0)
                        (get-text-property (1- (length text)) 'earwig-spoken text)))
             (start-p (earwig--sentence-start-p pos))
             (title (earwig--title-at pos))
             (next (save-excursion
                     (skip-chars-forward " \t")
                     (unless (eolp) (char-after))))
             (word (if (and closing (string-match "\\`[^ \t]+[ \t]+" text)) (match-end 0) 0)))
        ;; The first word is after the quotes TEXT opens with, or the one it closes
        (while (and (< word (length text))
                    (earwig--opening-quote-p (aref text word)
                                             (if (> word 0) (aref text (1- word)) prev)
                                             (get-text-property word 'earwig-spoken text)))
          (setq word (1+ word)))
        (when (and (string-match "[[:alpha:]][[:alnum:]']*" text word)
                   (= (match-beginning 0) word))
          (let* ((first-word (match-string 0 text))
                 (capital (string-match-p "\\`[[:upper:]]" first-word))
                 (said (get-text-property word 'earwig-capital text))
                 ;; Where a sentence starts, after any quotes TEXT opens with
                 (start (cond (said)
                              ;; "Go!" he said, but "Go." He went
                              (closing (eq inside ?.))
                              ((> word 0)
                               (and (not (text-property-not-all 0 word 'earwig-continue nil text))
                                    (earwig--quote-opens-sentence-p pos)))
                              (t start-p))))
            (cond ((and start (not capital)
                        (or said (> word 0)
                            ;; A heading or item starts with one, even if
                            ;; Orukeet heard the middle of a sentence; a
                            ;; word like "iPhone" stays as it is
                            (and (eql (cdr title) pos)
                                 (string-match-p "\\`[[:lower:]][[:lower:]']*\\'"
                                                 first-word))))
                   (setq text (concat (substring text 0 word)
                                      (upcase (substring text word (1+ word)))
                                      (substring text (1+ word)))))
                  ((and capital (not start) (not (earwig--keep-capital-p first-word)))
                   (setq text (concat (substring text 0 word)
                                      (downcase (substring text word (1+ word)))
                                      (substring text (1+ word))))))))
        (when (and next
                   (not (eq last 'punct))
                   (not (and start-p (string-match-p "[[:upper:]]" (string next)))))
          (setq text (replace-regexp-in-string "[.?!]+\\'" "" text)))
        ;; A heading or checkbox item has no period of Orukeet's, unless
        ;; it's sentences: more than one, in TEXT or with what's before it
        (when (and (memq (car title) '(heading checkbox))
                   (not (eq last 'punct))
                   (string-match-p "\\(?:\\`\\|[^.]\\)\\.\\'" text)
                   (not (string-match-p "[.?!][ \t]\\|\n" text))
                   (not (string-match-p "[.?!]\\(?:[ \t]\\|\\'\\)"
                                        (buffer-substring-no-properties (cdr title) pos))))
          (setq text (substring text 0 -1)))
        (when (and prev
                   (not (memq prev '(?\s ?\t ?\n)))
                   (not (string-prefix-p "\n" text))
                   (not (memq first '(punct close join)))
                   (not (eq (char-syntax prev) ?\())
                   (not (earwig--opening-quote-p prev (char-before (1- pos)))))
          (setq text (concat " " text)))
        (when (and next (eq next (char-after)) (memq (char-syntax next) '(?w ?_))
                   (not (string-suffix-p "\n" text))
                   (not (memq last '(open join))))
          (setq text (concat text " ")))
        (substring-no-properties text)))))

(defun earwig-clean (text)
  "Return TEXT without filler words and with the corrections applied.
The part of the cleanup that doesn't depend on where TEXT goes, so it
applies to commands too."
  (earwig-apply-corrections (earwig-remove-fillers text)))

(provide 'earwig-cleanup)
;;; earwig-cleanup.el ends here
