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
;; The commands are rules of the voice command grammar
;; (earwig-grammar.el), and the targets the rules `earwig-part' and
;; `earwig-target'; a target's words must be in the buffer for a
;; reading to be preferred.  docs/manual.md has the same as a user's
;; guide.
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
;;   that, this, it              the region, or else the text that went
;;                               in last: the last dictation, or what a
;;                               command put in after it (earwig-move.el)
;;   [this | the | current] UNIT the UNIT around point
;;   last | previous | next [N] UNIT[s]
;;                               before or after point; N as digits or
;;                               words ("last three words")
;;   the UNIT with | containing WORDS
;;                               the nearest UNIT with WORDS in it; for a
;;                               heading or section, in its title
;;   the heading above, the parent heading
;;   the body of | the text under HEADING
;;                               a heading's own text, without Org's
;;                               planning line and drawers, up to its
;;                               first subheading
;;   everything under HEADING    its body and subheadings
;;   the subheadings [of HEADING]
;;   the [whole | entire] buffer | file, everything, all
;;   A through | thru | until B, from A to | until | through B
;;                               from the nearest A that has a B after
;;                               it to the end of the first such B
;;   the next | following | previous | preceding WORDS
;;                               the nearest after or before point
;;   anything else               the nearest occurrence of those words
;;   WORDS in TARGET             words, A through B or the next WORDS,
;;                               looked for only in TARGET, one of the
;;                               parts of the buffer above: "meow in the
;;                               last two sentences"; otherwise "in" is a
;;                               word, as in "log in screen"
;;   every | each WORDS [in TARGET]
;;                               all of them
;;   the start | beginning | end of TARGET
;;                               the place before or after it
;;   A and B, both A and B, each of A B and C
;;                               several targets; "A and B" only where
;;                               "A and B" isn't in the buffer as words
;; HEADING is one of the parts that name a heading: "this heading",
;; "the section with budget", "the heading above", "the next heading".
;; UNIT is word, sentence, paragraph, line, heading (or headline: its
;; title, without stars, TODO keyword, priority or tags), section (or
;; subtree: a heading with all under it), item (or bullet: a list item
;; with its sub-items) or link.  Headings are counted by position at any
;; level, sections at the level of the one point is in.  Several places,
;; as "every" and "and" give, are acted on together, one undo step;
;; "select" takes one only.  "last word" leaves the
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
;;   go before | after TARGET    as "go before budget in this paragraph"
;;   next | previous one | match the next or previous WORDS after
;;                               "select WORDS" or "go before/after"
;;   go to the start | beginning | end of TARGET
;;                               as "go to the end of the line"
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
;; Moving text about, wrapping it and more are in earwig-move.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'earwig-grammar)
(require 'earwig-structure)

(defvar earwig--last-dictation)
(defvar evil-state)
(defvar evil-visual-beginning)
(defvar evil-visual-end)
(defvar org-todo-keywords-1)
(defvar org-emphasis-regexp-components)
(declare-function earwig--match-case "earwig-cleanup" (match replacement))
(declare-function earwig--keep-capital-p "earwig-cleanup" (word))
(declare-function earwig--sentence-start-p "earwig-cleanup" (pos))
(declare-function earwig--opening-quote-p "earwig-cleanup" (char before &optional kind))
(declare-function org-end-of-meta-data "org" (&optional full))
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

;; The text that went in last, for "that": dictation sets
;; `earwig--last-dictation' (earwig.el), commands that put text in call
;; `earwig--put'.

(defcustom earwig-flash t
  "Non-nil to flash the text a command put in, moved or wrapped.
So you see where it went.  \"where is TARGET\" flashes either way."
  :type 'boolean
  :group 'earwig)

(defvar earwig--last-put nil
  "(BEG END DICTATION) of the text a command put in last, for \"that\".
BEG and END are markers.  DICTATION is `earwig--last-dictation' as it
was then: once that's something else, a dictation came after.")

(defface earwig-flash '((t :inherit highlight))
  "Face for text that flashes: what a command put in, or \"where is\" found."
  :group 'earwig)

(defun earwig--flash (beg end)
  "Flash the text from BEG to END for a moment."
  (when (< beg end)
    (let ((overlay (make-overlay beg end)))
      (overlay-put overlay 'face 'earwig-flash)
      (overlay-put overlay 'priority 100)
      (run-at-time 0.6 nil #'delete-overlay overlay))))

(defun earwig--put (beg end)
  "Remember BEG to END as the text a command just put in, for \"that\"."
  (when earwig--last-put
    (set-marker (car earwig--last-put) nil)
    (set-marker (cadr earwig--last-put) nil))
  (setq earwig--last-put (list (copy-marker beg t) (copy-marker end) earwig--last-dictation))
  (when earwig-flash
    (earwig--flash beg end)))

(defun earwig--that ()
  "Return (BEG . END) of the region, or else of the text that went in last here.
That's the last dictation, or text a command put in after it."
  (or (earwig--region)
      (pcase-let ((`(,put-beg ,put-end ,dictation) earwig--last-put)
                  (`(,start ,end) earwig--last-dictation))
        (cond ((and put-beg (eq dictation earwig--last-dictation)
                    (eq (marker-buffer put-beg) (current-buffer)))
               (earwig--trim put-beg put-end))
              ((and start (eq (marker-buffer start) (current-buffer)))
               (earwig--trim start end))))
      (user-error "No region or dictation here")))

(defun earwig--spec-text (spec)
  "Return the target SPEC in words, for a message."
  (let ((text (lambda (target) (earwig--spec-text (earwig-target-spec target))))
        (units (lambda (n unit) (if (= n 1) unit (format "%s %ss" n unit)))))
    (pcase spec
      ('(region) "the region")
      ('(that) "that")
      (`(this ,unit) (concat "this " unit))
      (`(last ,n ,unit) (concat "last " (funcall units n unit)))
      (`(next ,n ,unit) (concat "next " (funcall units n unit)))
      ('(buffer) "the buffer")
      (`(with ,unit ,words) (format "the %s with %s" unit words))
      ('(parent) "the heading above")
      (`(body ,heading) (concat "the body of " (funcall text heading)))
      (`(under ,heading) (concat "everything under " (funcall text heading)))
      (`(subheadings ,heading)
       (if heading (concat "the subheadings of " (funcall text heading)) "the subheadings"))
      (`(words ,words) words)
      (`(through ,a ,b) (format "%s through %s" a b))
      (`(in ,what ,part) (format "%s in %s" (funcall text what) (funcall text part)))
      (`(every ,words ,part)
       (format "every %s%s" words (if part (concat " in " (funcall text part)) "")))
      (`(near ,direction ,words) (format "the %s %s" direction words))
      (`(edge ,edge ,target) (format "the %s of %s" edge (funcall text target)))
      (`(and ,_ . ,targets) (mapconcat text targets " and ")))))

;;;; Finding words

(defun earwig--phrase-regexp (phrase)
  "Regexp matching the words of PHRASE, whatever punctuation or space is between.
Search with `earwig--search', which makes them whole words."
  (mapconcat #'regexp-quote (split-string phrase) "[[:space:][:punct:]]+"))

(defun earwig--letter-p (char)
  "Non-nil if CHAR is a letter or digit: word syntax, not an underscore or quote."
  (and char (not (memq char '(?_ ?' ?’))) (eq (char-syntax char) ?w)))

(defun earwig--word-edge-p (pos before)
  "Non-nil if no word goes on past POS, on the side BEFORE it or else after.
An underscore between letters joins them, as in foo_bar; next to a
space or punctuation it's markup, as in Org's _underlined_, so it's an
edge whether or not the syntax table makes it part of words.  So is an
apostrophe: between letters, as in don't, but a quote in \='go\='."
  (let ((char (if before (char-before pos) (char-after pos))))
    (cond ((null char) t)
          ((memq char '(?_ ?' ?’)) (not (earwig--letter-p (if before
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

(defun earwig--through-range (a b &optional beg end)
  "Return (BEG . END) from the words A to the words B, or nil.
Between BEG and END if given.  From the nearest A that has a B after
it, so a common A like \"I\" skips the ones after the B meant."
  (let ((to (earwig--phrase-regexp b)))
    (earwig--nearest
     (earwig--phrase-regexp a) beg end
     (lambda (from)
       (save-excursion
         (goto-char (cdr from))
         (let ((case-fold-search t))
           (and (earwig--search to (or end (point-max)))
                (cons (car from) (match-end 0)))))))))

(defun earwig--nearest-in (regexp scopes &optional pred)
  "Return the match of REGEXP nearest point in SCOPES, as `earwig--nearest'.
SCOPES are ranges, or nil for the window, then the whole buffer.
PRED is as for `earwig--nearest'."
  (if (null scopes)
      (earwig--nearest regexp nil nil pred)
    (earwig--first-nearest (or pred #'identity)
                           (cl-loop for (beg end) in scopes
                                    append (earwig--matches regexp beg end)))))

;;;; Headings, items and links

(defun earwig--headings ()
  "Return (POS . LEVEL) of each heading in the buffer, in order.
Org's headings, or Markdown's # headings outside code blocks; signals a
`user-error' in other modes."
  (unless (earwig--structure-mode-p)
    (user-error "No headings in %s" major-mode))
  (let ((regexp (if (derived-mode-p 'org-mode) "^\\(\\*+\\)[ \t]" "^\\(#+\\)[ \t]"))
        (markdown (not (derived-mode-p 'org-mode)))
        (case-fold-search nil)
        headings)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (let ((pos (match-beginning 0))
              (level (length (match-string 1))))
          (unless (and markdown (earwig--md-code-p pos))
            (push (cons pos level) headings)))))
    (nreverse headings)))

(defun earwig--heading-at (pos headings)
  "Return the heading of HEADINGS that POS is under, or nil if none."
  (let (found)
    (while (and headings (<= (caar headings) pos))
      (setq found (pop headings)))
    found))

(defun earwig--section-end (heading headings)
  "Return where HEADING's section ends, before the blank lines after it.
HEADING is one of HEADINGS, from `earwig--headings'."
  (let ((next (cl-find-if (lambda (other)
                            (and (> (car other) (car heading)) (<= (cdr other) (cdr heading))))
                          headings)))
    (save-excursion
      (goto-char (if next (car next) (point-max)))
      (skip-chars-backward " \t\n" (car heading))
      (max (point) (progn (goto-char (car heading)) (line-end-position))))))

(defun earwig--heading-title (heading)
  "Return the range of HEADING's title.
Without its stars or hashes, TODO keyword, priority and tags."
  (save-excursion
    (goto-char (car heading))
    (let ((beg (earwig--line-prefix-end)))
      (list beg (max beg (earwig--line-text-end)) nil nil "heading"))))

(defun earwig--section (heading headings)
  "Return the range of HEADING's section: it, its text and its subheadings.
HEADING is one of HEADINGS, from `earwig--headings'."
  (list (car heading) (earwig--section-end heading headings) t nil "section"))

(defun earwig--body-start (heading headings)
  "Return where HEADING's own text starts, after Org's planning and drawers.
HEADING is one of HEADINGS, from `earwig--headings'."
  (let ((next (cl-find-if (lambda (other) (> (car other) (car heading))) headings)))
    (save-excursion
      (goto-char (car heading))
      (if (derived-mode-p 'org-mode)
          (org-end-of-meta-data t)
        (forward-line 1))
      (min (point) (if next (car next) (point-max))))))

(defun earwig--body (heading headings)
  "Return the range of HEADING's own text, up to its first subheading.
Without Org's planning line and drawers.  Empty if it has no text: at
the start of the line after them.  HEADING is one of HEADINGS."
  (let* ((next (cl-find-if (lambda (other) (> (car other) (car heading))) headings))
         (start (earwig--body-start heading headings))
         (end (save-excursion
                (goto-char (if next (car next) (point-max)))
                (skip-chars-backward " \t\n" start)
                (point))))
    (setq start (save-excursion (goto-char start) (skip-chars-forward " \t\n" end) (point)))
    ;; Whole lines, so its line break goes with it
    (list start end
          (and (< start end)
               (save-excursion (goto-char start) (bolp))
               (save-excursion (goto-char end) (eolp)))
          nil "body")))

(defun earwig--parent (heading headings)
  "Return the heading of HEADINGS that HEADING is under, or nil."
  (let (parent)
    (dolist (other headings)
      (when (and (< (car other) (car heading)) (< (cdr other) (cdr heading)))
        (setq parent other)))
    parent))

(defun earwig--heading-of (target)
  "Return (HEADING . HEADINGS) for TARGET, an `earwig-target' naming a heading.
Nil is the heading point is under.  HEADINGS are from `earwig--headings'."
  (let* ((headings (earwig--headings))
         (range (and target (car (earwig--ranges target)))))
    (when (and range (not (member (nth 4 range) '("heading" "section"))))
      (user-error "Not a heading: %s" (earwig--spec-text (earwig-target-spec target))))
    (cons (or (earwig--heading-at (if range (car range) (point)) headings)
              (user-error "No heading here"))
          headings)))

(defun earwig--headings-near (n unit after)
  "Return the ranges of N headings or sections before point, or AFTER it.
UNIT is \"heading\", for that many titles by position at any level, or
\"section\", for one range of that many sections at the level of the
one point is in, not past the section above it."
  (let* ((headings (earwig--headings))
         (current (earwig--heading-at (point) headings))
         (others (if after
                     (cl-remove-if-not (lambda (h) (> (car h) (if current (car current) (point))))
                                       headings)
                   (and current
                        (reverse (cl-remove-if-not (lambda (h) (< (car h) (car current)))
                                                   headings)))))
         (found
          (if (equal unit "heading")
              (seq-take others n)
            (let ((level (cond (current (cdr current))
                               (others (cdar others))))
                  found)
              (while (and others (< (length found) n) (>= (cdar others) level))
                (when (= (cdar others) level)
                  (push (car others) found))
                (pop others))
              (nreverse found)))))
    (when (< (length found) n)
      (user-error "%s %s %s"
                  (if found (format "Only %d" (length found)) "No")
                  (if (= (length found) 1) unit (concat unit "s"))
                  (if after "after this" "before this")))
    (if (equal unit "heading")
        (mapcar #'earwig--heading-title (if after found (reverse found)))
      (let ((first (if after (car found) (car (last found))))
            (last (if after (car (last found)) (car found))))
        (list (list (car first) (earwig--section-end last headings) t nil "section"))))))

(defun earwig--item-line-p ()
  "Non-nil if the line at point starts a list item: a bullet or a number."
  (save-excursion
    (beginning-of-line)
    (and (looking-at-p earwig--md-item-regexp)
         ;; In Org, stars at the start of a line are a heading
         (not (and (derived-mode-p 'org-mode) (looking-at-p "\\*+[ \t]"))))))

(defun earwig--items ()
  "Return (START . END) of each list item in the buffer, in order.
An item's range has its continuation lines and sub-items in it."
  (let (items)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (earwig--item-line-p)
          (push (cons (point) (earwig--md-item-end (point))) items))
        (forward-line 1)))
    (nreverse items)))

(defun earwig--item-at (pos items)
  "Return the innermost of ITEMS that POS is in, or nil."
  (let (found)
    (dolist (item items)
      (when (<= (car item) pos (cdr item))
        (setq found item)))
    found))

(defun earwig--item-range (item)
  "Return the range of ITEM, (START . END): whole lines."
  (list (car item) (cdr item) t nil "item"))

(defun earwig--items-near (n after)
  "Return the range of N list items before point, or AFTER it.
By position, at any level; not the items point is in."
  (let* ((items (earwig--items))
         (current (earwig--item-at (point) items))
         (from (if current (car current) (point)))
         (found (if after
                    (seq-take (cl-remove-if-not (lambda (item) (> (car item) from)) items) n)
                  (seq-take (reverse (cl-remove-if-not
                                      (lambda (item) (and (< (car item) from)
                                                          (not (<= (car item) (point) (cdr item)))))
                                      items))
                            n))))
    (when (< (length found) n)
      (user-error "%s %s" (if found (format "Only %d items" (length found)) "No items")
                  (if after "after this" "before this")))
    (list (list (apply #'min (mapcar #'car found)) (apply #'max (mapcar #'cdr found))
                t nil "item"))))

(defvar org-link-any-re)

(defconst earwig--url-regexp "\\<[a-z]+://[^][ \t\n<>()\"']+"
  "A bare URL.")

(defun earwig--links ()
  "Return (BEG . END) of each link in the buffer, in order.
Org's links, Markdown's [text](url) and <url>, and bare URLs."
  (let ((regexp (cond ((and (derived-mode-p 'org-mode) (boundp 'org-link-any-re))
                       (concat org-link-any-re "\\|" earwig--url-regexp))
                      ((derived-mode-p 'markdown-mode)
                       (concat "!?\\[[^]\n]*\\]([^)\n]*)\\|<[a-z]+:[^>\n]+>\\|"
                               earwig--url-regexp))
                      (t earwig--url-regexp)))
        (case-fold-search t)
        links)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (push (cons (match-beginning 0) (match-end 0)) links)))
    (nreverse links)))

(defun earwig--link-range (link)
  "Return the range of LINK, (BEG . END)."
  (list (car link) (cdr link) nil nil "link"))

(defun earwig--links-near (n after)
  "Return the ranges of N links before point, or AFTER it."
  (let* ((pt (point))
         (links (earwig--links))
         (found (if after
                    (seq-take (cl-remove-if-not (lambda (link) (> (car link) pt)) links) n)
                  (reverse (seq-take (reverse (cl-remove-if-not (lambda (link) (< (cdr link) pt))
                                                                links))
                                     n)))))
    (when (< (length found) n)
      (user-error "%s %s" (if found (format "Only %d links" (length found)) "No links")
                  (if after "after this" "before this")))
    (mapcar #'earwig--link-range found)))

;;;; Targets

;; A target is one or more ranges, (BEG END LINE-P REGEXP UNIT) each:
;; LINE-P for whole lines, whose newline goes with them when they're
;; deleted; REGEXP for words found, for "next one"; UNIT, a value of
;; `earwig-unit', "body", "words" or "edge", what kind of part it is,
;; for moving it.

(defun earwig--unit-at (unit pos)
  "Return the range of the UNIT (a string) around POS.
Signals a `user-error' if there's none."
  (pcase unit
    ((or "word" "sentence" "paragraph" "line")
     (save-excursion
       (goto-char pos)
       (let ((range (earwig--this-unit unit)))
         (list (car range) (cdr range) (equal unit "line") nil unit))))
    ((or "heading" "section")
     (let* ((headings (earwig--headings))
            (heading (or (earwig--heading-at pos headings) (user-error "No heading here"))))
       (if (equal unit "heading")
           (earwig--heading-title heading)
         (earwig--section heading headings))))
    ("item" (earwig--item-range (or (earwig--item-at pos (earwig--items))
                                    (user-error "No list item here"))))
    ("link" (earwig--link-range (or (cl-find-if (lambda (link) (<= (car link) pos (cdr link)))
                                                (earwig--links))
                                    (user-error "No link here"))))))

(defun earwig--units-near (n unit after)
  "Return the ranges of the N UNITs before point, or AFTER it."
  (pcase unit
    ((or "heading" "section") (earwig--headings-near n unit after))
    ("item" (earwig--items-near n after))
    ("link" (earwig--links-near n after))
    (_ (let ((range (if after (earwig--next-units n unit) (earwig--last-units n unit))))
         (list (list (car range) (cdr range) (equal unit "line") nil unit))))))

(defun earwig--unit-with (unit words)
  "Return the range of the UNIT with WORDS in it nearest point.
For a heading or section, the words must be in its title."
  (let* ((title (member unit '("heading" "section")))
         (headings (and title (earwig--headings)))
         (range (earwig--nearest
                 (earwig--phrase-regexp words) nil nil
                 (lambda (match)
                   (if title
                       (let ((heading (earwig--heading-at (car match) headings)))
                         (and heading
                              (= (car heading) (save-excursion (goto-char (car match))
                                                               (line-beginning-position)))
                              (if (equal unit "heading")
                                  (earwig--heading-title heading)
                                (earwig--section heading headings))))
                     (ignore-errors (earwig--unit-at unit (car match))))))))
    (or range (user-error "No %s with \"%s\"" unit words))))

(defconst earwig--part-kinds
  '(region that this last next buffer with parent body under subheadings)
  "The kinds of `earwig-target' spec that name a part of the buffer.")

(defun earwig--resolve (spec &optional empty-ok)
  "Return the ranges of the target SPEC, in buffer order.
See `earwig-target' for SPEC.  Signals a `user-error' if it isn't there,
or if it's a part of the buffer with nothing in it, unless EMPTY-OK."
  (let ((ranges
         (pcase spec
           ('(region) (let ((region (or (earwig--region) (user-error "No region"))))
                        (list (list (car region) (cdr region) nil nil nil))))
           ('(that) (let ((that (earwig--that)))
                      (list (list (car that) (cdr that) nil nil nil))))
           (`(this ,unit) (list (earwig--unit-at unit (point))))
           (`(last ,n ,unit) (earwig--units-near n unit nil))
           (`(next ,n ,unit) (earwig--units-near n unit t))
           ('(buffer) (list (list (point-min) (point-max) nil nil nil)))
           (`(with ,unit ,words) (list (earwig--unit-with unit words)))
           ('(parent)
            (pcase-let ((`(,heading . ,headings) (earwig--heading-of nil)))
              (list (earwig--heading-title (or (earwig--parent heading headings)
                                               (user-error "No heading above this one"))))))
           (`(body ,target)
            (pcase-let ((`(,heading . ,headings) (earwig--heading-of target)))
              (list (earwig--body heading headings))))
           (`(under ,target)
            (pcase-let ((`(,heading . ,headings) (earwig--heading-of target)))
              (list (list (earwig--body-start heading headings)
                          (earwig--section-end heading headings) t nil "body"))))
           (`(subheadings ,target)
            (pcase-let* ((`(,heading . ,headings) (earwig--heading-of target))
                         (end (earwig--section-end heading headings))
                         (child (cl-find-if (lambda (h) (< (car heading) (car h) end))
                                            headings)))
              (unless child
                (user-error "No subheadings"))
              (list (list (car child) end t nil "section"))))
           (`(words ,words)
            (let ((regexp (earwig--phrase-regexp words)))
              (pcase (or (earwig--nearest regexp) (user-error "No \"%s\" here" words))
                (`(,beg . ,end) (list (list beg end nil regexp "words"))))))
           (`(through ,a ,b)
            (pcase (or (earwig--through-range a b)
                       (user-error "No \"%s\" through \"%s\" here" a b))
              (`(,beg . ,end) (list (list beg end nil nil nil)))))
           (`(in ,what ,part)
            (earwig--resolve-in (earwig-target-spec what) (earwig--ranges part)))
           (`(every ,words ,part)
            (let ((regexp (earwig--phrase-regexp words))
                  (scopes (if part
                              (earwig--ranges part)
                            (list (list (point-min) (point-max))))))
              (or (cl-loop for (beg end) in scopes
                           append (mapcar (lambda (match)
                                            (list (car match) (cdr match) nil regexp "words"))
                                          (earwig--matches regexp beg end)))
                  (user-error "No \"%s\" %s" words (if part "there" "here")))))
           (`(near ,direction ,words) (earwig--resolve-near direction words nil))
           (`(edge ,edge ,target)
            (let* ((ranges (earwig--resolve (earwig-target-spec target) t))
                   (pos (if (eq edge 'start) (car (car ranges)) (cadr (car (last ranges))))))
              ;; An empty body stays one, so text put there gets a line
              (list (list pos pos nil nil (if (and (equal (nth 4 (car ranges)) "body")
                                                   (= (car (car ranges)) (cadr (car ranges))))
                                              "body"
                                            "edge")))))
           (`(and ,forced . ,targets) (earwig--resolve-and forced targets))
           (_ (error "Not a target: %S" spec)))))
    (when (and (not empty-ok) (memq (car spec) earwig--part-kinds) (not (eq (car spec) 'body)))
      (dolist (range ranges)
        (when (>= (car range) (cadr range))
          (user-error "Nothing there: %s" (earwig--spec-text spec)))))
    ranges))

(defun earwig--resolve-in (what scopes)
  "Return the ranges of the target spec WHAT, looked for only in SCOPES."
  (pcase what
    (`(words ,words)
     (let ((regexp (earwig--phrase-regexp words)))
       (pcase (or (earwig--nearest-in regexp scopes) (user-error "No \"%s\" there" words))
         (`(,beg . ,end) (list (list beg end nil regexp "words"))))))
    (`(through ,a ,b)
     (pcase (or (cl-some (pcase-lambda (`(,beg ,end)) (earwig--through-range a b beg end))
                         scopes)
                (user-error "No \"%s\" through \"%s\" there" a b))
       (`(,beg . ,end) (list (list beg end nil nil nil)))))
    (`(near ,direction ,words) (earwig--resolve-near direction words scopes))
    (_ (error "Can't look for %S in a part" what))))

(defun earwig--resolve-near (direction words scopes)
  "Return the range of the next or previous (DIRECTION) WORDS from point.
Not one that starts or ends right at point: after \"go before WORDS\",
the next is the one after.  In SCOPES, ranges, if given."
  (let* ((regexp (earwig--phrase-regexp words))
         (pt (point))
         (matches (cl-loop for (beg end) in (or scopes (list (list (point-min) (point-max))))
                           append (earwig--matches regexp beg end)))
         (match (if (eq direction 'next)
                    (cl-find-if (lambda (m) (> (car m) pt)) matches)
                  (cl-find-if (lambda (m) (< (cdr m) pt)) (reverse matches)))))
    (unless match
      (user-error "No %s \"%s\"" direction words))
    (list (list (car match) (cdr match) nil regexp "words"))))

(defun earwig--resolve-and (forced targets)
  "Return the ranges of TARGETS, `earwig-target's, all of them.
Unless FORCED, not when they're all words and \"A and B\" is there as
words, which is the one target then."
  (let ((specs (mapcar #'earwig-target-spec targets)))
    (when (and (not forced) (cl-every (lambda (spec) (eq (car spec) 'words)) specs))
      (let ((phrase (mapconcat #'cadr specs " and ")))
        (when (earwig--nearest (earwig--phrase-regexp phrase))
          (user-error "\"%s\" is there as words" phrase))))
    (let ((ranges (sort (mapcan (lambda (target) (copy-sequence (earwig--ranges target)))
                                targets)
                        (lambda (a b) (< (car a) (car b))))))
      (cl-loop for (a b) on ranges
               when (and b (> (cadr a) (car b)))
               do (user-error "Those overlap"))
      ranges)))

(defun earwig--ranges (target)
  "Return the ranges of TARGET, an `earwig-target', in buffer order.
Nil is the region.  Each is (BEG END LINE-P REGEXP UNIT), see
\"Targets\" above.  Signals a `user-error' if it isn't there."
  (earwig--resolve (if target (earwig-target-spec target) '(region))))

(defun earwig--target (target)
  "Return the one range of TARGET, an `earwig-target'; nil is the region.
Signals a `user-error' if it isn't there, or is several places."
  (let ((ranges (earwig--ranges target)))
    (when (cdr ranges)
      (user-error "That's %d places, not one: %s" (length ranges)
                  (earwig--spec-text (earwig-target-spec target))))
    (car ranges)))

(defun earwig-target-ranges (target)
  "Return a list of (BEG . END) for TARGET, the value of an `earwig-target' rule.
In buffer order; more than one for \"every WORDS\" or \"A and B\".  Nil
is the region.  Signals a `user-error' if it isn't there, as for words
that aren't in the buffer."
  (mapcar (lambda (range) (cons (car range) (cadr range))) (earwig--ranges target)))

(defun earwig-target-range (target)
  "Return (BEG . END) of TARGET, the value of an `earwig-target' rule.
Nil is the region.  Signals a `user-error' if it isn't there, as for
words that aren't in the buffer, or if it's several places, as \"every
WORDS\" is; see `earwig-target-ranges' for those.  For commands of your
own, see also `earwig-part-range'."
  (let ((range (earwig--target target)))
    (cons (car range) (cadr range))))

(defun earwig-part-range (part)
  "Return (BEG . END) of the part of the buffer PART names, or nil if none.
PART is the value of an `earwig-part' rule, or a part spoken as in
\"last two sentences\", \"this paragraph\", \"the section with budget\",
\"that\" (the region, or else the text that went in last), \"the whole
buffer\"; nil, \"region\" or \"selection\" is the region.  Words to look
for, which other targets can be, aren't parts of the buffer, so they
give nil.  A part of several places, as \"last two headings\", gives
from the start of the first to the end of the last.  Signals a
`user-error' if the part isn't there, as for \"selection\" with nothing
selected.

For commands of your own that act on a part of the buffer, as \"clean
up last paragraph\" might, see the manual."
  (let* ((spec (cond ((null part) '(region))
                     ((earwig-target-p part) (earwig-target-spec part))
                     (t (let ((parts (earwig--parse-rule 'earwig-part (string-trim part))))
                          (and parts (earwig-target-spec (car parts)))))))
         (ranges (and spec (memq (car spec) earwig--part-kinds) (earwig--resolve spec))))
    (and ranges (cons (car (car ranges)) (cadr (car (last ranges)))))))

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

(defmacro earwig--one-undo-step (&rest body)
  "Run BODY, making all its changes to the current buffer one undo step."
  (declare (indent 0))
  (let ((group (make-symbol "group")))
    `(let ((,group (prepare-change-group)))
       (activate-change-group ,group)
       (unwind-protect
           (progn ,@body)
         (accept-change-group ,group)
         (undo-amalgamate-change-group ,group)))))

(defun earwig--apply-verb-ranges (verb ranges)
  "Do VERB to each of RANGES, as `earwig--apply-verb', all one undo step.
Cut or copied, they go into the kill ring together, a line or a space
between them."
  (unless (eq verb 'copy)
    (barf-if-buffer-read-only)
    (undo-boundary))
  (when (memq verb '(cut copy))
    (kill-new (mapconcat (pcase-lambda (`(,beg ,end)) (buffer-substring beg end))
                         ranges (if (cl-some #'caddr ranges) "\n" " ")))
    (message "%s %d places" (if (eq verb 'cut) "Cut" "Copied") (length ranges)))
  (earwig--one-undo-step
    (pcase-dolist (`(,beg ,end ,line-p) (reverse ranges))
      (when (and line-p (memq verb '(delete cut)) (< end (point-max)))
        (setq end (1+ end)))
      (pcase verb
        ((or 'delete 'cut) (delete-region beg end) (earwig--tidy-gap beg))
        ('capitalize (upcase-initials-region beg end))
        ('upcase (upcase-region beg end))
        ('downcase (downcase-region beg end))
        ('title-case (earwig--title-case-region beg end)))))
  (earwig--done-with-region))

(defun earwig-cmd-edit (verb target)
  "Do VERB, a symbol of `earwig--edit-verbs', to TARGET, an `earwig-target'.
Nil is the region.  See the commentary of earwig-edit.el."
  (when (and (eq verb 'select) (null target) (not (earwig--region)))
    (user-error "Select what?"))
  (let ((ranges (earwig--ranges target)))
    (cond
     ((cdr ranges)
      (when (eq verb 'select)
        (user-error "Can't select %d places at once" (length ranges)))
      (earwig--apply-verb-ranges verb ranges))
     (t
      (pcase-let ((`(,beg ,end ,line-p ,regexp) (car ranges)))
        (when (and (= beg end) (not (eq verb 'select)))
          (user-error "Nothing there: %s" (earwig--spec-text (earwig-target-spec target))))
        (setq earwig--edit-last (and regexp (eq verb 'select)
                                     (list (current-buffer) regexp 'select beg end)))
        (earwig--apply-verb verb beg end line-p))))))

(defun earwig-cmd-format (style target)
  "Format TARGET in STYLE, a symbol of `earwig--format-styles', or take it off.
`plain' takes all markup off.  See the commentary of earwig-edit.el."
  (let* ((ranges (earwig--ranges target))
         (done (earwig--one-undo-step
                 (car (last (mapcar (pcase-lambda (`(,beg ,end)) (earwig--format style beg end))
                                    (reverse ranges)))))))
    (earwig--done-with-region)
    (message "%s%s" done (if (cdr ranges) (format ", %d places" (length ranges)) ""))))

(defun earwig--go (kind beg end)
  "Put point before (KIND `before') or after BEG to END."
  (goto-char (if (eq kind 'before) beg end)))

(defun earwig-cmd-go (kind target)
  "Move point before or after (KIND `before' or `after') TARGET.
TARGET is an `earwig-target'."
  (pcase-let ((`(,beg ,end ,_ ,regexp) (earwig--target target)))
    (push-mark nil t)
    (earwig--go kind beg end)
    (setq earwig--edit-last (list (current-buffer) regexp kind beg end))))

(defun earwig-cmd-go-to (target)
  "Move point to TARGET, an `earwig-target', as \"the end of this paragraph\"."
  (push-mark nil t)
  (goto-char (car (earwig--target target))))

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
DIRECTION is `next' or `previous'."
  (pcase-let ((`(,buffer ,regexp ,kind ,beg ,end) earwig--edit-last))
    (unless (and regexp (eq buffer (current-buffer)))
      (user-error "Nothing selected by voice here"))
    (let* ((case-fold-search t)
           (match (save-excursion
                    (if (eq direction 'next)
                        (progn (goto-char end) (earwig--search regexp nil))
                      (goto-char beg) (earwig--search regexp nil t)))))
      (unless match
        (user-error "No %s match" direction))
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

(defconst earwig--replace-region-words
  '("that" "this" "it" "the region" "region" "the selection" "selection")
  "What \"replace A with B\" can say as A for the region.")

(defun earwig--replace-plan (old part everywhere)
  "Return what to replace for \"replace OLD with ...\", or nil if nothing.
In PART, an `earwig-part' value, or with EVERYWHERE, every OLD there:
that's (scope RANGES); otherwise the nearest OLD, (nearest BEG END),
or the region for \"replace that\", (region BEG END)."
  (let ((scopes (cond (everywhere (list (list (point-min) (point-max))))
                      (part (earwig--ranges part))))
        (regexp (earwig--phrase-regexp old))
        ;; The whitespace around a selection stays
        (region (let ((r (earwig--region))) (and r (earwig--trim (car r) (cdr r))))))
    (cond
     ((and region (null scopes) (member (downcase old) earwig--replace-region-words))
      (list 'region (car region) (cdr region)))
     (scopes
      (and (cl-some (pcase-lambda (`(,beg ,end)) (earwig--matches regexp beg end)) scopes)
           (list 'scope scopes)))
     (t
      (let ((range (earwig--nearest regexp)))
        (and range (list 'nearest (car range) (cdr range))))))))

(defun earwig-cmd-replace (old new part everywhere)
  "Replace OLD with NEW: the nearest OLD, or every one in PART or EVERYWHERE.
PART is an `earwig-part' value.  \"replace that with B\" replaces the
region when there is one."
  (barf-if-buffer-read-only)
  (pcase-let ((`(,kind ,beg ,end) (or (earwig--replace-plan old part everywhere)
                                      (user-error "Nothing to replace: \"%s\"" old))))
    (undo-boundary)
    (message "Replaced %d"
             (pcase kind
               ('region
                (let ((text (buffer-substring beg end)))
                  (earwig--done-with-region)
                  (goto-char beg)
                  (delete-region beg end)
                  (insert (earwig--replacement-case (point) text new))
                  1))
               ('scope
                (earwig--one-undo-step
                  (cl-loop for (beg end) in (reverse beg)
                           sum (earwig--replace-in (earwig--phrase-regexp old) new beg end))))
               (_ (earwig--replace-in (earwig--phrase-regexp old) new beg end))))))

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
  "Start a new line, or with WHAT `paragraph', a new paragraph."
  (delete-horizontal-space t)
  (newline (if (eq what 'paragraph) 2 1)))

(defconst earwig-edit-targets-help
  '(("[the] selection"                 "the selection; also when TARGET is left out")
    ("that | this | it"                "the selection, or else what went in last")
    ("[this] UNIT"                     "the one around the cursor")
    ("last | next [N] UNITs"           "before or after the cursor")
    ("the UNIT with | containing WORDS" "\"the paragraph with budget\"")
    ("the whole buffer"                "")
    ("WORDS"                           "the nearest place they're said")
    ("the next | previous WORDS"       "the nearest after or before the cursor")
    ("every | each WORDS [in TARGET]"  "all of them")
    ("[from] A until | through B"      "from words A to words B")
    ("WORDS in TARGET"                 "WORDS, looked for only in TARGET")
    (""                                "(\"meow in the last two sentences\")")
    ("the start | end of TARGET"       "the place before or after it")
    ("A and B, both A and B, each of A B and C" "")
    ("this heading | section"          "its title; it with all under it")
    ("the body of TARGET"              "a heading's own text")
    ("everything under TARGET"         "its text and subheadings")
    ("the subheadings [of TARGET]"     "")
    ("the heading above"               "the parent heading")
    (""                                "UNIT: word, sentence, paragraph, line,")
    (""                                "heading, section, item, link"))
  "What \"what can I say\" shows for TARGET, as (SPOKEN EXPLANATION).")

;;;; The commands' grammar

(phony-define-dictionary earwig-verb
  "An editing verb; its value is a symbol of `earwig--edit-verbs'."
  (cl-loop for (verb . spoken) in earwig--edit-verbs
           append (mapcar (lambda (word) (cons word verb)) spoken)))

(phony-define-dictionary earwig-format-style
  "A style for \"format\"; its value is a symbol of `earwig--format-styles'."
  (cl-loop for (style . spoken) in earwig--format-styles
           append (mapcar (lambda (word) (cons word style)) spoken)))

(earwig-defcommand earwig-say-edit ((verb earwig-verb) (? (target earwig-target)))
  "Do VERB to TARGET, or to the region."
  :help "select | delete | cut | copy | capitalize | uppercase | lowercase | title case TARGET"
  :check (or target (earwig--region))
  (earwig-cmd-edit verb target))

(earwig-defcommand earwig-say-format ("format" (style earwig-format-style)
                                      (? (target earwig-target)))
  "Format TARGET, or the region, in STYLE."
  :help "format bold | italic | underline | code | verbatim | strike through | plain TARGET"
  :check (and (earwig--format-entry) (or target (earwig--region)))
  (earwig-cmd-format style target))

(earwig-defcommand earwig-say-replace
    ("replace" (old earwig-words) "with" (new earwig-text)
     (? (| (seq "in" (part earwig-part)) (everywhere "everywhere"))))
  "Replace OLD with NEW, nearest, in PART or EVERYWHERE."
  :help "replace A with B [in TARGET | everywhere]"
  :check (earwig--replace-plan old part everywhere)
  (earwig-cmd-replace old new part (and everywhere t)))

(earwig-defcommand earwig-say-next-match ((direction (| "next" "previous")) (| "one" "match"))
  "Move the last word target selected or gone to on, in DIRECTION."
  :help "next | previous one    (after select WORDS or go before/after)"
  :go t
  (earwig-cmd-next-match (intern direction)))

(earwig-defcommand earwig-say-go ("go" (kind (| "before" "after")) (target earwig-target))
  "Go before or after (KIND) TARGET."
  :help "go before | after TARGET"
  :go t
  (earwig-cmd-go (intern kind) target))

(earwig-defcommand earwig-say-go-to ("go to" (target earwig-target-edge))
  "Go to the start or end of a target."
  :help "go to the start | end of TARGET"
  :go t
  (earwig-cmd-go-to target))

(earwig-defcommand earwig-say-go-back "go back"
  "Go back to where point was before the last \"go\"."
  :help "go back"
  (earwig-cmd-go-back))

(earwig-defcommand earwig-say-paste ("paste" (? (| "that" "it")))
  "Paste the last kill."
  :help "paste"
  (earwig-cmd-paste))

(earwig-defcommand earwig-say-new-line ("new" (what (| "line" "paragraph")))
  "Start a new line or paragraph (WHAT)."
  :help "new line | paragraph"
  (earwig-cmd-new-line (intern what)))

(provide 'earwig-edit)
;;; earwig-edit.el ends here
