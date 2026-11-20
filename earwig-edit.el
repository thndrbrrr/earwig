;;; earwig-edit.el --- Spoken text editing: a verb, then a target  -*- lexical-binding: t; -*-

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

;; Editing commands are a verb followed by what it acts on, so every
;; verb works on every target: "select last two words", "delete that",
;; "capitalize deadline", "cut because through Friday".  "replace A with
;; B [in TARGET | everywhere]" takes the same targets as its scope.
;; `earwig-edit-commands' goes into `earwig-commands', so like any
;; voice command the whole phrase has to match, ignoring case and
;; punctuation.  docs/manual.md has the same as a user's guide.
;;
;; Verbs, in `earwig--edit-verbs':
;;   select                      a visual selection in evil's normal and
;;                               visual states, else the region
;;   delete, cut                 cut into the kill ring; whole lines go
;;                               with their newline, and the spaces left
;;                               behind are tidied
;;   copy, yank                  into the kill ring
;;   capitalize, cap             the first letter of each word
;;   uppercase, upper case, upcase, all caps
;;   lowercase, lower case, downcase
;;   title case                  capitals, but not for small words like
;;                               "of" and "the" (`earwig--title-case-region')
;; Each change is its own undo step.  After any verb but select, the
;; region or evil's visual state is done with.
;;
;; Targets:
;;   (none), region, selection   the region (evil's visual selection);
;;                               "select" alone needs one
;;   that, this, it              the region, or else the last dictation
;;                               in this buffer
;;   [this | the | current] UNIT the UNIT around point
;;   last | previous | next [N] UNIT[s]
;;                               before or after point; N as digits or
;;                               words ("last three words")
;;   the [whole | entire] buffer | file, everything, all
;;   A through | thru | until B, from A to | until | through B
;;                               from the nearest A that has a B after
;;                               it to the end of the first such B
;;   anything else               the nearest occurrence of those words
;;   WORDS in TARGET             words, or A through B, looked for only
;;                               in TARGET, one of the parts of the
;;                               buffer above: "meow in the last two
;;                               sentences"; otherwise "in" is a word, as
;;                               in "log in screen"
;; UNIT is word, sentence, paragraph or line.  "last word" leaves the
;; punctuation after it alone, and in evil's normal state the character
;; under the cursor counts as before point.  Words and phrases match
;; ignoring case and the punctuation between them ("end of file" finds
;; "end-of-file"), as whole words.  Markup around words doesn't get in
;; the way, nor do word units include it: "heading" is found in Org's
;; _underlined heading_ even with `_' in the syntax table as part of
;; words.  An underscore between letters joins them: foo_bar is one word.  The nearest is looked for in the window, then in the
;; whole buffer: a match around point wins, then the closest before
;; point, then the closest after.
;;
;; Formatting: "format STYLE TARGET", e.g. "format bold meow in the
;; last two sentences", puts markup around the target, or takes it off
;; if the target has that style already, so saying it twice undoes it.
;;   bold, italic | italics, underline | underlined, code, verbatim,
;;   strike through | strikethrough | strike | crossed out
;;   plain | normal | none       takes all markup off, also inside
;; The markup depends on the major mode, `earwig-format-markup': Org's
;; *bold* /italic/ _underline_ ~code~ =verbatim= +strike+, Markdown's
;; **bold** _italic_ <u>underline</u> `code` ~~strike~~; other modes
;; have none.  Markup goes around each line's text, not its indentation,
;; bullet, checkbox or heading stars, nor an Org heading's TODO keyword,
;; priority and tags.  So a target over several list items or
;; paragraphs is marked up part by part, as is one longer than the
;; lines Org's emphasis can span (`org-emphasis-regexp-components').
;;
;; Replacing:
;;   replace A with B            the nearest A
;;   replace A with B in TARGET  every A in TARGET, one of the parts of
;;                               the buffer above, not words
;;   replace A with B everywhere every A in the buffer
;;   replace that with B         the region itself, if there is one
;; B takes A's capital, but that of "I", an acronym or a name only at
;; a sentence start.  A and B may contain "with": each way of
;; splitting at it is tried until one finds something to replace.
;;
;; Moving, and the rest:
;;   go before | after WORDS [in TARGET]
;;                               to the nearest WORDS, as for targets
;;   next | previous one | match the next or previous WORDS after
;;                               "select WORDS" or "go before/after"
;;   go to [the] start | beginning | end of [the | this] line |
;;   sentence | paragraph
;;   go back                     to where point was before the last
;;                               "go" or "next | previous one" that
;;                               moved it; again, to where it was
;;   paste [that | it]           the buffer's own paste: after the cursor
;;                               in evil's normal state (unless "go
;;                               before | after" put it there), replacing a
;;                               visual selection, typed into terminals;
;;                               spaced from the words around it as
;;                               dictation is.  Lines cut or copied
;;                               whole go in as lines, before the line
;;                               point is on, or after it from its end
;;   new line | paragraph        also inside dictation, by
;;                               `earwig-spoken-format' (earwig-cleanup.el)

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar earwig--last-dictation)
(defvar evil-state)
(defvar evil-visual-beginning)
(defvar evil-visual-end)
(defvar org-todo-keywords-1)
(defvar org-emphasis-regexp-components)
(declare-function earwig-parse-number "earwig-commands" (text &optional whole noerror))
(declare-function earwig--match-case "earwig-cleanup" (match replacement))
(declare-function earwig--keep-capital-p "earwig-cleanup" (word))
(declare-function earwig--sentence-start-p "earwig-cleanup" (pos))
(declare-function earwig--opening-quote-p "earwig-cleanup" (char before &optional kind))
(declare-function evil-yank-line-handler "evil-common" (text))
(declare-function evil-visual-select "evil-states" (beg end &optional type dir message))
(declare-function evil-visual-state-p "evil-states" (&optional state))
(declare-function evil-exit-visual-state "evil-states" (&optional later buffer))
(declare-function evil-paste-after "evil-commands" (count &optional register yank-handler))
(declare-function evil-paste-before "evil-commands" (count &optional register yank-handler))
(declare-function evil-visual-paste "evil-commands" (count &optional register))

(defconst earwig--edit-verbs
  '((select "select")
    (delete "delete")
    (cut "cut")
    (copy "copy" "yank")
    (capitalize "capitalize" "cap")
    (upcase "uppercase" "upper case" "upcase" "all caps")
    (downcase "lowercase" "lower case" "downcase")
    (title-case "title case"))
  "Editing verbs as (VERB SPOKEN...).")

(defconst earwig--unit-regexp "\\(word\\|sentence\\|paragraph\\|line\\)s?"
  "Regexp for a text unit, the singular in group 1.")

(defvar earwig--edit-last nil
  "(BUFFER REGEXP KIND BEG END) of the last word target selected or gone to.
KIND is `select', `before' or `after'; for \"next one\".")

;;;; Ranges

(defun earwig--evil-state-p (&rest states)
  "Non-nil if evil is on in this buffer and in one of STATES."
  (and (bound-and-true-p evil-local-mode) (memq evil-state states)))

(defun earwig--region ()
  "Return (BEG . END) of evil's visual selection or the active region, or nil."
  (cond ((earwig--evil-state-p 'visual)
         (cons (marker-position evil-visual-beginning) (marker-position evil-visual-end)))
        ((use-region-p)
         (cons (region-beginning) (region-end)))))

(defun earwig--trim (beg end)
  "Return (BEG . END) without the whitespace at either end."
  (save-excursion
    (goto-char end)
    (skip-chars-backward " \t\n" beg)
    (setq end (point))
    (goto-char beg)
    (skip-chars-forward " \t\n" end)
    (cons (point) end)))

(defun earwig--count (count)
  "Return the number spoken as COUNT, one if nil."
  (if count (earwig-parse-number count t) 1))

(defun earwig--this-unit (unit)
  "Return (BEG . END) of the UNIT (a string) around point."
  (if (equal unit "line")
      (cons (line-beginning-position) (line-end-position))
    (let ((bounds (or (bounds-of-thing-at-point (intern unit))
                      ;; At the end of the buffer, the one point is after
                      (save-excursion
                        (skip-chars-backward " \t\n")
                        (and (not (bobp))
                             (progn (backward-char) (bounds-of-thing-at-point (intern unit))))))))
      (unless bounds
        (user-error "No %s at point" unit))
      (let ((range (earwig--trim (car bounds) (cdr bounds))))
        (if (equal unit "word") (earwig--unmarked (car range) (cdr range)) range)))))

(defun earwig--last-units (n unit)
  "Return (BEG . END) of the N UNITs (a string) before point.
A word comes without the punctuation after it.  A sentence point is
inside, as when it's just before the period, counts whole.  In evil's
normal state the character under the cursor counts as before it."
  (if (equal unit "line")
      (cons (line-beginning-position (- 1 n)) (line-end-position 0))
    (save-excursion
      (when (and (earwig--evil-state-p 'normal 'visual) (not (eolp)))
        (forward-char))
      (if (equal unit "word")
          (while (and (not (bobp)) (not (earwig--letter-p (char-before))))
            (backward-char))
        (skip-chars-backward " \t\n"))
      (when (equal unit "sentence")
        (goto-char (max (point) (save-excursion (backward-sentence) (forward-sentence) (point)))))
      (let ((end (point)))
        (pcase unit
          ("word" (backward-word n))
          ("sentence" (backward-sentence n))
          ("paragraph" (backward-paragraph n) (skip-chars-forward " \t\n")))
        (if (equal unit "word") (earwig--unmarked (point) end) (cons (point) end))))))

(defun earwig--next-units (n unit)
  "Return (BEG . END) of the N UNITs (a string) after point."
  (if (equal unit "line")
      (cons (line-beginning-position 2) (line-end-position (1+ n)))
    (save-excursion
      (if (equal unit "word")
          (while (and (not (eobp)) (not (earwig--letter-p (char-after))))
            (forward-char))
        (skip-chars-forward " \t\n"))
      (let ((beg (point)))
        (pcase unit
          ("word" (forward-word n))
          ("sentence" (forward-sentence n))
          ("paragraph" (forward-paragraph n) (skip-chars-backward " \t\n")))
        (if (equal unit "word") (earwig--unmarked beg (point)) (cons beg (point)))))))

(defun earwig--that ()
  "Return (BEG . END) of the region, or else of the last dictation here."
  (or (earwig--region)
      (pcase-let ((`(,start ,end) earwig--last-dictation))
        (and start (eq (marker-buffer start) (current-buffer))
             (earwig--trim start end)))
      (user-error "No region or dictation here")))

(defun earwig--structural-range (spec)
  "Return (BEG END . LINE-P) for SPEC if it names a part of the buffer, else nil.
SPEC is lowercase; nil means the region.  LINE-P is non-nil for whole
lines, so deleting them takes the newline too."
  (let ((range
         (cond
          ((member spec '(nil "region" "the region" "selection" "the selection"))
           (cons (or (earwig--region) (user-error "No region")) nil))
          ((member spec '("that" "this" "it"))
           (cons (earwig--that) nil))
          ((string-match (concat "\\`\\(?:\\(?:this\\|the\\|current\\|the current\\) \\)?"
                                 earwig--unit-regexp "\\'")
                         spec)
           (let ((unit (match-string 1 spec)))
             (cons (earwig--this-unit unit) (equal unit "line"))))
          ((string-match (concat "\\`\\(?:the \\)?\\(last\\|previous\\|next\\)"
                                 "\\(?: \\(.+?\\)\\)? " earwig--unit-regexp "\\'")
                         spec)
           (let ((n (earwig--count (match-string 2 spec)))
                 (unit (match-string 3 spec)))
             (cons (if (equal (match-string 1 spec) "next")
                       (earwig--next-units n unit)
                     (earwig--last-units n unit))
                   (equal unit "line"))))
          ((string-match-p (concat "\\`\\(?:\\(?:the \\)?\\(?:whole \\|entire \\)?"
                                   "\\(?:buffer\\|file\\)\\|everything\\|all\\)\\'")
                           spec)
           (cons (cons (point-min) (point-max)) nil)))))
    (when range
      (when (>= (caar range) (cdar range))
        (user-error "Nothing there: %s" spec))
      (list (caar range) (cdar range) (cdr range)))))

;;;; Finding words

(defun earwig--phrase-regexp (phrase)
  "Regexp matching the words of PHRASE, whatever punctuation or space is between.
Search with `earwig--search', which makes them whole words."
  (mapconcat #'regexp-quote (split-string phrase) "[[:space:][:punct:]]+"))

(defun earwig--letter-p (char)
  "Non-nil if CHAR is a letter or digit: word syntax, but not an underscore."
  (and char (/= char ?_) (eq (char-syntax char) ?w)))

(defun earwig--word-edge-p (pos before)
  "Non-nil if no word goes on past POS, on the side BEFORE it or else after.
An underscore between letters joins them, as in foo_bar; next to a
space or punctuation it's markup, as in Org's _underlined_, so it's an
edge whether or not the syntax table makes it part of words."
  (let ((char (if before (char-before pos) (char-after pos))))
    (cond ((null char) t)
          ((eq char ?_) (not (earwig--letter-p (if before
                                                       (char-before (1- pos))
                                                     (char-after (1+ pos))))))
          (t (not (eq (char-syntax char) ?w))))))

(defun earwig--whole-words-p (beg end)
  "Non-nil if the text from BEG to END neither starts nor ends inside a word."
  (and (< beg end)
       (or (not (earwig--letter-p (char-after beg))) (earwig--word-edge-p beg t))
       (or (not (earwig--letter-p (char-before end))) (earwig--word-edge-p end nil))))

(defun earwig--search (regexp bound &optional backward)
  "Search for REGEXP as whole words, forward or BACKWARD, up to BOUND.
Like `re-search-forward' with NOERROR: returns point and sets the match
data, or returns nil."
  (let (found)
    (while (and (not found)
                (if backward
                    (re-search-backward regexp bound t)
                  (re-search-forward regexp bound t)))
      (if (earwig--whole-words-p (match-beginning 0) (match-end 0))
          (setq found (point))
        (goto-char (if backward (match-beginning 0) (1+ (match-beginning 0))))))
    found))

(defun earwig--matches (regexp beg end)
  "Return the (BEG . END) of each match of REGEXP between BEG and END."
  (let ((case-fold-search t) matches)
    (save-excursion
      (goto-char beg)
      (while (earwig--search regexp end)
        (push (cons (match-beginning 0) (match-end 0)) matches)))
    (nreverse matches)))

(defun earwig--first-nearest (pred matches)
  "Return the first non-nil PRED of MATCHES, (BEG . END) each, nearest point first.
A match around point comes first, then those before point, closest
first, then those after it."
  (let ((pt (point)))
    (or (cl-some pred (cl-remove-if-not (lambda (m) (<= (car m) pt (cdr m))) matches))
        (cl-some pred (reverse (cl-remove-if-not (lambda (m) (< (cdr m) pt)) matches)))
        (cl-some pred (cl-remove-if-not (lambda (m) (> (car m) pt)) matches)))))

(defun earwig--nearest (regexp &optional beg end pred)
  "Return (BEG . END) of the match of REGEXP nearest point, or nil.
Looks between BEG and END if given, else in the window first, then in
the whole buffer.  A match around point wins, then the closest one
before point, then the one after.  With PRED, the nearest match it
returns non-nil for counts, and that value is returned instead."
  (let ((window (get-buffer-window (current-buffer)))
        (pred (or pred #'identity)))
    (if beg
        (earwig--first-nearest pred (earwig--matches regexp beg end))
      (or (and window (earwig--first-nearest
                       pred (earwig--matches regexp (window-start window)
                                               (window-end window t))))
          (earwig--first-nearest pred (earwig--matches regexp (point-min) (point-max)))))))

(defun earwig--find (phrase)
  "Return (BEG . END) of PHRASE nearest point, or signal that it isn't there."
  (or (earwig--nearest (earwig--phrase-regexp phrase))
      (user-error "No \"%s\" here" phrase)))

(defun earwig--splits (spec separator)
  "Return the ways of splitting SPEC in two at SEPARATOR, a regexp, as (A . B).
SEPARATOR matches ignoring case."
  (let ((case-fold-search t)
        (start 0) splits)
    (while (string-match separator spec start)
      (push (cons (substring spec 0 (match-beginning 0)) (substring spec (match-end 0)))
            splits)
      (setq start (1+ (match-beginning 0))))
    (nreverse splits)))

(defun earwig--through-range (spec &optional beg end)
  "Return (BEG . END) for SPEC as \"A through B\" or \"from A to B\", or nil.
Between BEG and END if given.  From the nearest A that has a B after
it, so a common A like \"I\" skips the ones after the B meant."
  (cl-some (pcase-lambda (`(,a . ,b))
             (let ((to (earwig--phrase-regexp b)))
               (earwig--nearest
                (earwig--phrase-regexp a) beg end
                (lambda (from)
                  (save-excursion
                    (goto-char (cdr from))
                    (let ((case-fold-search t))
                      (and (earwig--search to (or end (point-max)))
                           (cons (car from) (match-end 0)))))))))
           (append (earwig--splits spec " \\(?:through\\|thru\\|until\\) ")
                   (and (string-prefix-p "from " spec)
                        (earwig--splits (substring spec 5)
                                          " \\(?:to\\|through\\|thru\\|until\\) ")))))

(defun earwig--scoped (spec)
  "Split SPEC as \"WORDS in TARGET\" into (WORDS BEG END), or return nil.
Only when TARGET names a part of the buffer, so \"log in screen\" stays
words.  SPEC is lowercase."
  (cl-loop for (words . tail) in (earwig--splits spec " in ")
           for range = (and (not (string-empty-p words)) (earwig--structural-range tail))
           when range return (list words (car range) (cadr range))))

(defun earwig-part-range (spec)
  "Return (BEG . END) of the part of the buffer SPEC names, or nil if none.
SPEC is spoken, as an editing verb's target is: \"last two sentences\",
\"this paragraph\", \"that\" (the region, or else the last dictation),
\"the whole buffer\"; nil, \"region\" or \"selection\" is the region.
Words to look for, which other targets can be, aren't parts of the
buffer, so they give nil.  Signals a `user-error' if the part isn't
there, as for \"selection\" with nothing selected.

For commands of your own in `earwig-extra-commands' that act on a part
of the buffer, as \"clean up last paragraph\" might."
  (let ((range (earwig--structural-range (and spec (downcase (string-trim spec))))))
    (and range (cons (car range) (cadr range)))))

(defun earwig--target (spec)
  "Return (BEG END LINE-P WORD-REGEXP) for the target SPEC.
WORD-REGEXP is set when SPEC was found as words, for \"next one\"."
  (let ((spec (and spec (downcase spec))))
    (or (earwig--structural-range spec)
        (pcase-let ((`(,words ,beg ,end) (or (earwig--scoped spec) (list spec))))
          (or (let ((range (earwig--through-range words beg end)))
                (and range (list (car range) (cdr range) nil)))
              (let* ((regexp (earwig--phrase-regexp words))
                     (range (or (earwig--nearest regexp beg end)
                                (user-error "No \"%s\" %s" words (if beg "there" "here")))))
                (list (car range) (cdr range) nil regexp)))))))

;;;; Acting on a range

(defun earwig--select (beg end)
  "Select BEG to END, with point at END; a visual selection in evil."
  (if (earwig--evil-state-p 'normal 'visual)
      (evil-visual-select beg end 'inclusive)
    (goto-char end)
    (push-mark beg t t)))

(defun earwig--tidy-gap (pos)
  "Fix the spacing at POS, where text was just deleted."
  (save-excursion
    (goto-char pos)
    (let ((space '(?\s ?\t)))
      (cond
       ((and (memq (char-before) space) (memq (char-after) space))
        (delete-char 1))
       ((and (memq (char-before) space)
             (or (eolp) (memq (char-after) '(?. ?, ?\; ?: ?! ?? ?\)))))
        (delete-char -1))
       ((and (or (bolp) (eq (char-before) ?\()) (memq (char-after) space))
        (delete-char 1))))))

(defun earwig--done-with-region ()
  "Leave evil's visual state, or deactivate the region."
  (if (earwig--evil-state-p 'visual)
      (evil-exit-visual-state)
    (deactivate-mark)))

(defun earwig--apply-verb (verb beg end &optional line-p)
  "Do VERB to the text from BEG to END.
LINE-P means whole lines, whose newline goes too when deleted or cut."
  (unless (memq verb '(select copy))
    (barf-if-buffer-read-only)
    (undo-boundary))
  (when (and line-p (memq verb '(delete cut copy)) (< end (point-max)))
    (setq end (1+ end)))
  (pcase verb
    ('select (earwig--select beg end))
    ('copy (kill-ring-save beg end)
           (when line-p (earwig--kill-lines))
           (message "Copied \"%s\"" (truncate-string-to-width
                                      (string-trim-right (current-kill 0 t)) 50 nil nil t)))
    ('delete (delete-region beg end) (earwig--tidy-gap beg))
    ('cut (kill-region beg end)
          (when line-p (earwig--kill-lines))
          (earwig--tidy-gap beg))
    ('capitalize (upcase-initials-region beg end))
    ('upcase (upcase-region beg end))
    ('downcase (downcase-region beg end))
    ('title-case (earwig--title-case-region beg end)))
  (unless (eq verb 'select)
    (earwig--done-with-region)))

(defun earwig--kill-lines ()
  "Mark the last kill as whole lines, for \"paste\" to put in as lines.
It gets the newline it may lack, at the end of the buffer.  In evil,
it's line-wise for evil's own paste too, as \"dd\" or \"yy\" would
leave it."
  (let ((text (current-kill 0 t)))
    (unless (string-suffix-p "\n" text)
      (setq text (concat text "\n")))
    (put-text-property 0 (length text) 'earwig-lines t text)
    (when (and (bound-and-true-p evil-local-mode) (fboundp 'evil-yank-line-handler))
      (put-text-property 0 (length text) 'yank-handler
                         (list #'evil-yank-line-handler nil t) text))
    (kill-new text t)))

(defun earwig--title-case-region (start end)
  "Convert the region between START and END to title case.
Capitalizes the first letter of each word, except for a set of
small words (articles, conjunctions, short prepositions) unless
they are the first or last word of the region."
  (let ((small-words '("a" "an" "and" "as" "at" "but" "by" "for" "if"
                       "in" "nor" "of" "on" "or" "so" "the" "to" "up"
                       "yet" "vs"))
        (case-fold-search t))
    (save-excursion
      (save-restriction
        (narrow-to-region start end)
        (goto-char (point-min))
        ;; Downcase everything first so we start from a clean state
        (downcase-region (point-min) (point-max))
        (goto-char (point-min))
        (let ((first t))
          (while (re-search-forward "\\w+" nil t)
            (let* ((word-start (match-beginning 0))
                   (word-end (match-end 0))
                   (word (match-string 0))
                   (last-word (save-excursion
                                (goto-char word-end)
                                (not (re-search-forward "\\w+" nil t)))))
              (if (or first
                      last-word
                      (not (member word small-words)))
                  (progn
                    (goto-char word-start)
                    (capitalize-word 1))
                (goto-char word-end))
              (setq first nil))))))))

;;;; Formatting

(defcustom earwig-format-markup
  '((org-mode (bold "*") (italic "/") (underline "_") (code "~") (verbatim "=")
              (strike "+"))
    (markdown-mode (bold "**") (italic "_") (underline "<u>" "</u>") (code "`")
                   (verbatim "`") (strike "~~")))
  "Markup for \"format STYLE\", by major mode: (MODE (STYLE OPEN [CLOSE])...).
CLOSE is OPEN if left out.  The first MODE the buffer's mode is or
derives from applies; other modes have no formatting."
  :type '(alist :key-type (symbol :tag "Major mode")
                 :value-type (alist :key-type (symbol :tag "Style")
                                    :value-type (choice (list string) (list string string))))
  :group 'earwig)

(defconst earwig--format-styles
  '((bold "bold")
    (italic "italic" "italics")
    (underline "underline" "underlined")
    (code "code")
    (verbatim "verbatim")
    (strike "strike through" "strikethrough" "strike" "crossed out")
    (plain "plain" "normal" "none"))
  "Styles for \"format STYLE\" as (STYLE SPOKEN...); `plain' takes markup off.")

(defun earwig--format-entry ()
  "Return the entry of `earwig-format-markup' for this buffer, or nil."
  (cl-find-if (lambda (entry) (derived-mode-p (car entry))) earwig-format-markup))

(defun earwig--format-pairs ()
  "Return this buffer's markup as an alist of (STYLE OPEN CLOSE)."
  (let ((entry (earwig--format-entry)))
    (unless entry
      (user-error "No formatting in %s" major-mode))
    (mapcar (pcase-lambda (`(,style ,open ,close)) (list style open (or close open)))
            (cdr entry))))

(defun earwig--unmarked (beg end)
  "Return (BEG . END) without the markup at its edges that's word syntax.
So a word in Org's _underlined_ comes without the underscores, when
the syntax table makes them part of words."
  (let ((chars (cl-loop for (_ open) in (cdr (earwig--format-entry))
                        when (and (= (length open) 1) (eq (char-syntax (aref open 0)) ?w))
                        collect (aref open 0))))
    (while (and (< beg end) (memq (char-after beg) chars))
      (setq beg (1+ beg)))
    (while (and (< beg end) (memq (char-before end) chars))
      (setq end (1- end)))
    (cons beg end)))

(defun earwig--line-prefix-end ()
  "Return where the text of the current line starts, after its structure.
That's indentation, a bullet or number, a checkbox, a quote, or heading
stars or hashes; for an Org heading also its TODO keyword and priority."
  (save-excursion
    (beginning-of-line)
    (let ((heading (and (derived-mode-p 'org-mode) (looking-at-p "\\*+[ \t]"))))
      (looking-at "[ \t]*\\(?:\\*+[ \t]+\\|#+[ \t]+\\|>[ \t]*\\|[-+*][ \t]+\\|[0-9]+[.)][ \t]+\\)?\
\\(?:\\[[ xX-]\\][ \t]+\\)?")
      (goto-char (match-end 0))
      (when heading
        ;; Keywords are case-sensitive: "* Done with it" has none
        (when (and (bound-and-true-p org-todo-keywords-1)
                   (let ((case-fold-search nil))
                     (looking-at (concat (regexp-opt org-todo-keywords-1 'words) "[ \t]+"))))
          (goto-char (match-end 0)))
        (when (looking-at "\\[#.\\][ \t]+")
          (goto-char (match-end 0))))
      (point))))

(defun earwig--line-text-end ()
  "Return where the text of the current line ends: before an Org heading's tags."
  (save-excursion
    (beginning-of-line)
    (if (and (derived-mode-p 'org-mode) (looking-at-p "\\*+[ \t]")
             (re-search-forward "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*$" (line-end-position) t))
        (match-beginning 0)
      (line-end-position))))

(defun earwig--format-pieces (beg end)
  "Split BEG to END into the parts markup goes around, as a list of (BEG . END).
Each line's structure (see `earwig--line-prefix-end') stays outside,
so a paragraph splits at blank lines and at lines that start a list item
or heading.  In Org, also wherever a part would have more lines than its
emphasis allows."
  (let ((limit (if (derived-mode-p 'org-mode)
                   (or (nth 4 (bound-and-true-p org-emphasis-regexp-components)) 1)
                 most-positive-fixnum))
        pieces piece)                   ; PIECE is (BEG END NEWLINES)
    (save-excursion
      (goto-char beg)
      (while (progn
               (let* ((prefix (earwig--line-prefix-end))
                      (lbeg (max beg prefix))
                      (lend (min end (earwig--line-text-end)))
                      (structural (> prefix (save-excursion (back-to-indentation) (point)))))
                 (cond
                  ((not (string-match-p "[^ \t]" (buffer-substring lbeg (max lbeg lend))))
                   (when piece (push piece pieces) (setq piece nil)))
                  ((and piece (not structural) (< (nth 2 piece) limit))
                   (setq piece (list (car piece) lend (1+ (nth 2 piece)))))
                  (t
                   (when piece (push piece pieces))
                   (setq piece (list lbeg lend 0)))))
               (and (zerop (forward-line 1)) (< (point) end) (not (eobp)))))
      (when piece (push piece pieces)))
    (delq nil (mapcar (pcase-lambda (`(,beg ,end))
                        (let ((range (earwig--trim beg end)))
                          (and (< (car range) (cdr range)) range)))
                      (nreverse pieces)))))

(defun earwig--word-char-p (char)
  "Non-nil if CHAR is part of a word, so markup next to it isn't markup."
  (and char (eq (char-syntax char) ?w)))

(defun earwig--format-layers (pairs beg end)
  "Return (LAYERS IBEG IEND) for the text from BEG to END.
LAYERS is the markup of PAIRS, (OPEN CLOSE) each, around the text and at
its edges, outermost first, as (OPEN CLOSE OBEG OEND); IBEG to IEND is
the text inside them all.  Positions are markers."
  (let ((at (lambda (pos string)
              (and (<= (point-min) pos) (<= (+ pos (length string)) (point-max))
                   (string= (buffer-substring-no-properties pos (+ pos (length string)))
                            string))))
        found layers)
    ;; Out to the outermost markup around it
    (while (setq found (cl-find-if
                        (pcase-lambda (`(,open ,close))
                          (and (funcall at (- beg (length open)) open)
                               (funcall at end close)
                               (not (earwig--word-char-p (char-before (- beg (length open)))))
                               (not (earwig--word-char-p (char-after (+ end (length close)))))))
                        pairs))
      (setq beg (- beg (length (car found)))
            end (+ end (length (cadr found)))))
    ;; Then in, through each layer that holds nothing but the text
    (while (setq found (cl-find-if
                        (pcase-lambda (`(,open ,close))
                          (and (> (- end beg) (+ (length open) (length close)))
                               (funcall at beg open)
                               (funcall at (- end (length close)) close)
                               (not (string-search
                                     close (buffer-substring-no-properties
                                            (+ beg (length open)) (- end (length close)))))))
                        pairs))
      (push (list (car found) (cadr found) (copy-marker beg) (copy-marker end)) layers)
      (setq beg (+ beg (length (car found)))
            end (- end (length (cadr found)))))
    (list (nreverse layers) (copy-marker beg) (copy-marker end))))

(defun earwig--format-remove (layer)
  "Delete the markup of LAYER, from `earwig--format-layers'."
  (pcase-let ((`(,open ,close ,obeg ,oend) layer))
    (delete-region (- oend (length close)) oend)
    (delete-region obeg (+ obeg (length open)))))

(defun earwig--format-strip (pairs beg end)
  "Delete the markup of PAIRS on text wholly between BEG and END."
  (let ((end (copy-marker end))
        (case-fold-search nil))
    (pcase-dolist (`(,open ,close) pairs)
      (save-excursion
        (goto-char beg)
        (while (re-search-forward (concat (regexp-quote open)
                                          "\\([^ \t\n]\\|[^ \t\n][^\n]*?[^ \t\n]\\)"
                                          (regexp-quote close))
                                  end t)
          (if (or (earwig--word-char-p (char-before (match-beginning 0)))
                  (earwig--word-char-p (char-after (match-end 0))))
              (goto-char (1+ (match-beginning 0)))
            (replace-match (match-string 1) t t)))))))

(defun earwig--format (style beg end)
  "Format BEG to END in STYLE, or take STYLE off if it's all in it already.
STYLE `plain' takes all markup off.  Returns a message saying what was done."
  (let* ((markup (earwig--format-pairs))
         (pair (unless (eq style 'plain)
                 (or (cdr (assq style markup))
                     (user-error "No %s in %s" style major-mode))))
         ;; Longest first, so ** is seen before *
         (pairs (sort (delete-dups (mapcar #'cdr markup))
                      (lambda (a b) (> (length (car a)) (length (car b))))))
         (pieces (or (earwig--format-pieces beg end) (user-error "Nothing to format")))
         (found (mapcar (pcase-lambda (`(,beg . ,end)) (earwig--format-layers pairs beg end))
                        pieces))
         (has (lambda (layers)
                (cl-find-if (lambda (layer) (equal (list (nth 0 layer) (nth 1 layer)) pair))
                            layers)))
         (off (and pair (cl-every (lambda (f) (funcall has (car f))) found))))
    (barf-if-buffer-read-only)
    (undo-boundary)
    (pcase-dolist (`(,layers ,ibeg ,iend) found)
      (cond
       ((null pair)
        (earwig--format-strip pairs ibeg iend)
        (mapc #'earwig--format-remove layers))
       (off
        (earwig--format-remove (funcall has layers)))
       ((not (funcall has layers))
        ;; Point at the end of the text stays after the closing markup
        (let ((pt (if (= (point) iend) (copy-marker iend t) (point-marker))))
          (goto-char iend)
          (insert (cadr pair))
          (goto-char ibeg)
          (insert (car pair))
          (goto-char pt)))))
    (format "%s%s" (capitalize (symbol-name style)) (if off " off" ""))))

;;;; Commands

(defun earwig-cmd-edit (spoken target)
  "Do the verb SPOKEN to TARGET, see the commentary of earwig-edit.el."
  (let ((verb (car (cl-find-if (lambda (v) (member (downcase spoken) (cdr v)))
                               earwig--edit-verbs))))
    (when (and (eq verb 'select) (null target) (not (earwig--region)))
      (user-error "Select what?"))
    (pcase-let ((`(,beg ,end ,line-p ,regexp) (earwig--target target)))
      (setq earwig--edit-last (and regexp (eq verb 'select)
                                     (list (current-buffer) regexp 'select beg end)))
      (earwig--apply-verb verb beg end line-p))))

(defun earwig-cmd-format (spoken target)
  "Format TARGET in the style SPOKEN, or take that style off again.
\"plain\" takes all markup off.  See the commentary of earwig-edit.el."
  (let ((style (car (cl-find-if (lambda (s) (member (downcase spoken) (cdr s)))
                                earwig--format-styles))))
    (pcase-let ((`(,beg ,end) (earwig--target target)))
      (let ((done (earwig--format style beg end)))
        (earwig--done-with-region)
        (message "%s" done)))))

(defun earwig--go (kind beg end)
  "Put point before (KIND `before') or after BEG to END."
  (goto-char (if (eq kind 'before) beg end)))

(defun earwig-cmd-go (where phrase)
  "Move point before or after (WHERE) the nearest PHRASE.
PHRASE may end in \"in TARGET\", to look only there."
  (pcase-let* ((kind (intern (downcase where)))
               (`(,words ,beg ,end) (or (earwig--scoped (downcase phrase)) (list phrase)))
               (regexp (earwig--phrase-regexp words))
               (range (or (earwig--nearest regexp beg end)
                          (user-error "No \"%s\" %s" words (if beg "there" "here")))))
    (push-mark nil t)
    (earwig--go kind (car range) (cdr range))
    (setq earwig--edit-last (list (current-buffer) regexp kind (car range) (cdr range)))))

(defun earwig-cmd-go-edge (edge unit)
  "Move point to the start or end (EDGE) of the UNIT around it."
  (push-mark nil t)
  (let ((start (member (downcase edge) '("start" "beginning"))))
    (pcase (downcase unit)
      ("line" (if start (beginning-of-line) (end-of-line)))
      ("sentence" (if start (backward-sentence) (forward-sentence)))
      ("paragraph" (if start
                       (progn (backward-paragraph) (skip-chars-forward " \t\n"))
                     (forward-paragraph) (skip-chars-backward " \t\n"))))))

(defvar earwig--go-from nil
  "Marker where point was before the last \"go\" command, for \"go back\".")

(defun earwig-cmd-go-back ()
  "Go back to where point was before the last \"go\" command.
Saying it again goes back there in turn.  Pasting or selecting doesn't
change where it goes, as it would with the mark."
  (unless (and (markerp earwig--go-from)
               (eq (marker-buffer earwig--go-from) (current-buffer)))
    (user-error "Nowhere to go back to"))
  (let ((here (point)))
    (push-mark nil t)
    (goto-char earwig--go-from)
    (set-marker earwig--go-from here)))

(defun earwig-cmd-next-match (direction)
  "Move the last word target selected or gone to on to the next match.
DIRECTION is \"next\" or \"previous\"."
  (pcase-let ((`(,buffer ,regexp ,kind ,beg ,end) earwig--edit-last))
    (unless (eq buffer (current-buffer))
      (user-error "Nothing selected by voice here"))
    (let* ((case-fold-search t)
           (match (save-excursion
                    (if (equal (downcase direction) "next")
                        (progn (goto-char end) (earwig--search regexp nil))
                      (goto-char beg) (earwig--search regexp nil t)))))
      (unless match
        (user-error "No %s match" (downcase direction)))
      (setq beg (match-beginning 0) end (match-end 0))
      (setq earwig--edit-last (list buffer regexp kind beg end))
      (if (eq kind 'select)
          (earwig--select beg end)
        (earwig--go kind beg end)))))

(defun earwig--replacement-case (pos old replacement)
  "Return REPLACEMENT for the text OLD at POS, with OLD's capital if it's needed.
A word that keeps its capital anywhere, like \"I\" or an acronym, only
passes it on at the start of a sentence."
  (save-match-data
    (if (and (string-match "\\`[[:alnum:]']+" old)
             (earwig--keep-capital-p (match-string 0 old))
             (not (earwig--sentence-start-p pos)))
        replacement
      (earwig--match-case old replacement))))

(defun earwig--replace-in (regexp replacement beg end)
  "Replace each match of REGEXP from BEG to END with REPLACEMENT.
Returns the number replaced."
  (let ((case-fold-search t)
        (end (copy-marker end))
        (count 0))
    (save-excursion
      (goto-char beg)
      (while (earwig--search regexp end)
        (replace-match (earwig--replacement-case (match-beginning 0) (match-string 0)
                                                   replacement)
                       t t)
        (cl-incf count)))
    count))

(defun earwig-cmd-replace (spec)
  "Replace as SPEC says: \"A with B\", optionally \"in TARGET\" or \"everywhere\".
Without a scope, the nearest A is replaced; with one, every A in it.
\"replace that with B\" replaces the region when there is one."
  (barf-if-buffer-read-only)
  (let* ((case-fold-search t)
         (spec (string-trim spec))
         (scope nil))
    ;; The scope is a tail naming a part of the buffer; anything else is B
    (if (string-match " everywhere\\'" spec)
        (setq scope (list (point-min) (point-max))
              spec (substring spec 0 (match-beginning 0)))
      (cl-loop for (rest . tail) in (earwig--splits spec " in ")
               for range = (earwig--structural-range (downcase tail))
               when range do (setq scope range spec rest) and return nil))
    (undo-boundary)
    (let ((done
           (cl-some
            (pcase-lambda (`(,a . ,b))
              (let ((regexp (earwig--phrase-regexp a))
                    ;; The whitespace around a selection stays
                    (region (let ((r (earwig--region))) (and r (earwig--trim (car r) (cdr r))))))
                (cond
                 ((and region (null scope)
                       (member (downcase a) '("that" "this" "it" "the region" "region"
                                              "the selection" "selection")))
                  (let ((old (buffer-substring (car region) (cdr region))))
                    (earwig--done-with-region)
                    (goto-char (car region))
                    (delete-region (car region) (cdr region))
                    (insert (earwig--replacement-case (point) old b)))
                  1)
                 (scope
                  (let ((count (earwig--replace-in regexp b (car scope) (cadr scope))))
                    (and (> count 0) count)))
                 (t
                  (let ((range (earwig--nearest regexp)))
                    (when range
                      (earwig--replace-in regexp b (car range) (cdr range))))))))
            (earwig--splits spec " with "))))
      (unless done
        (user-error "Nothing to replace in \"%s\"" spec))
      (message "Replaced %d" done))))

(defun earwig-cmd-paste ()
  "Paste the last kill, the way the buffer's own paste command would.
Terminals get it as typed input, evil's normal state pastes after the
cursor, or where \"go before\" or \"go after\" put point, and its
visual state replaces the selection.  Elsewhere it's
spaced from the words around it, as dictation is
\(`earwig--space-pasted'), and lines cut or copied whole go in as
lines (`earwig--paste-lines')."
  (let* ((terminal (derived-mode-p 'ghostel-mode 'vterm-mode 'eat-mode 'term-mode))
         (text (and (not terminal)
                    (not (earwig--evil-state-p 'visual))
                    (ignore-errors (current-kill 0 t))))
         (command (cond
                   (terminal #'yank)
                   ;; Where "go before" or "go after" said, not after the cursor
                   ((earwig--evil-state-p 'normal)
                    (if (earwig--went-here-p) #'evil-paste-before #'evil-paste-after))
                   ((earwig--evil-state-p 'visual) #'evil-visual-paste)
                   (t #'yank)))
         (inserted nil))
    (if (and text (get-text-property 0 'earwig-lines text))
        (earwig--paste-lines text)
      ;; Where the paste went in, whichever command put it there
      (let ((after-change-functions
             (cons (lambda (beg end _length)
                     (when (< beg end)
                       (setq inserted (if inserted
                                          (cons (min beg (car inserted)) (max end (cdr inserted)))
                                        (cons beg end)))))
                   after-change-functions)))
        ;; Terminals remap `yank' to their own paste
        (call-interactively (or (command-remapping command) command)))
      (when (and inserted (not terminal))
        (earwig--space-pasted (car inserted) (cdr inserted))))))

(defun earwig--went-here-p ()
  "Non-nil if point is where \"go before\" or \"go after\" put it."
  (pcase earwig--edit-last
    (`(,buffer ,_ ,kind ,beg ,end)
     (and (eq buffer (current-buffer))
          (memq kind '(before after))
          (= (point) (if (eq kind 'before) beg end))))))

(defun earwig--space-pasted (beg end)
  "Space the text pasted from BEG to END from the words around it.
As `earwig-fit-to-context' spaces dictation: a space before it after a
word or punctuation, unless it starts with punctuation or follows an
opening bracket or quote, and one after it before a word."
  (save-excursion
    (goto-char end)
    (when (and (memq (char-syntax (or (char-after) ?\s)) '(?w ?_))
               (not (memq (char-before) '(?\s ?\t ?\n)))
               (not (eq (char-syntax (char-before)) ?\())
               (not (earwig--opening-quote-p (char-before) (char-before (1- (point))))))
      (insert " "))
    (goto-char beg)
    (when (and (not (bobp))
               (< beg end)
               (not (memq (char-before) '(?\s ?\t ?\n)))
               (not (memq (char-after) '(?\s ?\t ?\n ?. ?, ?\; ?: ?! ??)))
               (not (eq (char-syntax (char-after)) ?\)))
               (not (eq (char-syntax (char-before)) ?\())
               (not (earwig--opening-quote-p (char-before) (char-before (1- (point))))))
      (insert " "))))

(defun earwig--paste-lines (text)
  "Put in TEXT, whole lines, before the line point is on.
After it when point is at the end of its text, or in evil's normal
state on its last character.  Point goes to the start of the first
line put in, after its indentation, as with evil's paste."
  (let ((below (and (not (bolp))
                    (save-excursion
                      (when (and (earwig--evil-state-p 'normal) (not (eolp)))
                        (forward-char))
                      (skip-chars-forward " \t")
                      (eolp)))))
    (push-mark nil t)
    (if (not below)
        (beginning-of-line)
      (end-of-line)
      (if (eobp) (insert "\n") (forward-char)))
    (let ((start (point)))
      (insert (substring-no-properties text))
      (goto-char start)
      (skip-chars-forward " \t"))))

(defun earwig-cmd-new-line (what)
  "Start a new line, or with WHAT \"paragraph\", a new paragraph."
  (delete-horizontal-space t)
  (newline (if (equal (downcase what) "paragraph") 2 1)))

(defconst earwig-edit-targets-help
  '(("[the] selection"                 "the selection; also when TARGET is left out")
    ("that | this"                     "the selection, or else the last dictation")
    ("[this] word | sentence | paragraph | line"
                                       "the one around the cursor")
    ("last | next [N] words | sentences | paragraphs | lines"
                                       "before or after the cursor")
    ("the whole buffer"                "")
    ("WORDS"                           "the nearest place they're said")
    ("[from] A until | through B"      "from words A to words B")
    ("WORDS in TARGET"                 "WORDS, looked for only in TARGET")
    (""                                "(\"meow in the last two sentences\")"))
  "What \"what can I say\" shows for TARGET, as (SPOKEN EXPLANATION).")

(defconst earwig-edit-commands
  `((,(concat "\\(" (regexp-opt (cl-mapcan (lambda (v) (copy-sequence (cdr v)))
                                           earwig--edit-verbs))
              "\\)\\(?: \\(.+\\)\\)?")
     earwig-cmd-edit
     "select | delete | cut | copy | capitalize | uppercase | lowercase | title case TARGET")
    (,(concat "format \\("
              (regexp-opt (cl-mapcan (lambda (s) (copy-sequence (cdr s))) earwig--format-styles))
              "\\)\\(?: \\(.+\\)\\)?")
     earwig-cmd-format
     "format bold | italic | underline | code | verbatim | strike through | plain TARGET")
    ("replace \\(.+\\)" earwig-cmd-replace
     "replace A with B [in TARGET | everywhere]")
    ("\\(next\\|previous\\) \\(?:one\\|match\\)" earwig-cmd-next-match
     "next | previous one    (after select WORDS or go before/after)")
    ("go \\(before\\|after\\) \\(.+\\)" earwig-cmd-go
     "go before | after WORDS [in TARGET]")
    ("go to \\(?:the \\)?\\(start\\|beginning\\|end\\) of \\(?:the \\|this \\)?\\(line\\|sentence\\|paragraph\\)"
     earwig-cmd-go-edge
     "go to [the] start | end of line | sentence | paragraph")
    ("go back" earwig-cmd-go-back
     "go back")
    ("paste\\(?: that\\| it\\)?" earwig-cmd-paste
     "paste")
    ("new \\(line\\|paragraph\\)" earwig-cmd-new-line
     "new line | paragraph"))
  "Editing entries for `earwig-commands'.")

(provide 'earwig-edit)
;;; earwig-edit.el ends here
