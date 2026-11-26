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
;;   [QUANTITY] UNIT [FILTER]    units, see below: "this sentence", "last
;;                               two words", "the second paragraph with
;;                               budget", "every item without milk"
;;   PART in | of PART           a part counted in another, to any depth:
;;                               "the first word of the second sentence in
;;                               the paragraph with budget"
;;   the parent heading | headline
;;   the body of | the text under PART
;;                               a heading's own text, without Org's
;;                               planning line and drawers, up to its
;;                               first subheading
;;   everything under PART       its body and subheadings
;;   the subheadings [of PART]
;;   the [whole | entire] buffer | file, everything, all
;;   A through | thru | until B, from A to | until | through B
;;                               from the nearest A that has a B after
;;                               it to the end of the first such B
;;   TARGET through TARGET, from TARGET to TARGET
;;                               from the start of one to the end of the
;;                               other
;;   the next | following | previous | preceding WORDS
;;                               the nearest after or before point
;;   anything else               the nearest occurrence of those words
;;   the word | the words WORDS
;;                               those words, even ones that mean
;;                               something else here: "the word this"
;;   WORDS in PART               words, A through B or the next WORDS,
;;                               looked for only in PART, one of the
;;                               parts of the buffer above: "meow in the
;;                               last two sentences"; otherwise "in" is a
;;                               word, as in "log in screen".  For words,
;;                               every place they are in PART; commands
;;                               that act on one place take the nearest
;;   every | each WORDS [in PART]
;;                               all of them
;;   the start | beginning | end of TARGET
;;                               the place before or after it
;;   A and B, both A and B, each of A B and C
;;                               several targets; "A and B" only where
;;                               "A and B" isn't in the buffer as words.
;;                               Parts of them that overlap are one
;; The body of, everything under and the subheadings of take a PART that
;; names a heading: "this heading", "the section with budget".
;;
;; UNIT is word, sentence, paragraph, line, heading (or headline: its
;; title, without stars, TODO keyword, priority or tags), section (or
;; subtree: a heading with all under it), item (or bullet: a list item
;; with its sub-items), checkbox (an item with one) or link, singular or
;; plural.  A paragraph is lines between blank lines, a list, or a
;; heading's title (see "Listing units" below).  QUANTITY:
;;   (none), this, the, current  the one around point; with a FILTER the
;;                               nearest one, and for a plural every one
;;   next | previous [N]         after or before point: headings and
;;                               items at any level, sections at the
;;                               level of the one point is in
;;   last [N]                    before point; with a FILTER or in a
;;                               PART, the last N there
;;   first [N], second ... twentieth, 21st ..., second to last ...,
;;   ORDINAL through ORDINAL     counted from the start or end of where
;;                               UNIT counts: the PART it's in, or else
;;                               its natural container ("Listing units")
;;   every, each, all [the]      all of them
;; FILTER is with | containing, without, starting with or ending with
;; WORDS.  Units are filtered, then counted: "the second paragraph with
;; budget".  Words match a word unit in part, other units as whole
;; words; a heading or section by its title, a link by its visible text
;; or URL.  Units next to each other are one range; filtered, each is
;; one.  A plural PART is each of its parts: "the first word of every
;; item", one per item, counting its own text.
;;
;; Several places, as "every" and "and" give, are acted on together, one
;; undo step; "select" takes one only.  "last word" leaves the
;; punctuation after it alone, and in evil's normal state the character
;; under the cursor counts as before point.  Words and phrases match
;; ignoring case and the punctuation between them ("end of file" finds
;; "end-of-file"), as whole words.  Markup around words doesn't get in
;; the way, nor do word units include it: "heading" is found in Org's
;; _underlined heading_ even with `_' in the syntax table as part of
;; words.  An underscore between letters joins them: foo_bar is one
;; word.  The nearest is looked for in the window, then in the whole
;; buffer: a match around point wins, then the closest before point,
;; then the closest after.
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
;;   replace A with B in PART    every A in PART, one of the parts of the
;;                               buffer above, not words; or "replace A
;;                               in PART with B"
;;   replace A with B everywhere every A in the buffer
;;   replace that with B         the region itself, if there is one
;;   replace PART with B         the text of PART: "replace the second
;;                               word with moon"; punctuation that ended
;;                               it stays, unless B has its own
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
A word comes without the punctuation after it.  A sentence point is at
the end of counts, also when point is just before its period; one point
is inside doesn't, so it's those before it.  In evil's normal state the
character under the cursor counts as before it."
  (cond
   ((equal unit "line")
    (cons (line-beginning-position (- 1 n)) (line-end-position 0)))
   ((equal unit "sentence")
    (earwig--sentences-near
     n (if (and (earwig--evil-state-p 'normal 'visual) (not (eolp))) (1+ (point)) (point))
     nil))
   (t
    (save-excursion
      (when (and (earwig--evil-state-p 'normal 'visual) (not (eolp)))
        (forward-char))
      (if (equal unit "word")
          (while (and (not (bobp)) (not (earwig--letter-p (char-before))))
            (backward-char))
        (skip-chars-backward " \t\n"))
      (let ((end (point)))
        (pcase unit
          ("word" (backward-word n))
          ("paragraph" (backward-paragraph n) (skip-chars-forward " \t\n")))
        (if (equal unit "word") (earwig--unmarked (point) end) (cons (point) end)))))))

(defun earwig--next-units (n unit)
  "Return (BEG . END) of the N UNITs (a string) after point.
Not a sentence point is inside: those after it."
  (cond
   ((equal unit "line")
    (cons (line-beginning-position 2) (line-end-position (1+ n))))
   ((equal unit "sentence") (earwig--sentences-near n (point) t))
   (t
    (save-excursion
      (if (equal unit "word")
          (while (and (not (eobp)) (not (earwig--letter-p (char-after))))
            (forward-char))
        (skip-chars-forward " \t\n"))
      (let ((beg (point)))
        (pcase unit
          ("word" (forward-word n))
          ("paragraph" (forward-paragraph n) (skip-chars-backward " \t\n")))
        (if (equal unit "word") (earwig--unmarked beg (point)) (cons beg (point))))))))

(defun earwig--sentences-near (n pos after)
  "Return (BEG . END) of the N sentences before POS, or AFTER it.
Those of the paragraphs (`earwig--blocks') up to the heading before POS,
or after it: a list item or an Org planning line doesn't run into the
text after it, and a heading isn't one.  Before POS, the sentence POS is
at the end of counts, also when it's just before its period; after, the
one POS is at the start of.  Fewer if there aren't N; signals a
`user-error' if there's none."
  (let ((lines 8) found)
    (while (let* ((from (if after pos (save-excursion (goto-char pos) (forward-line (- lines)) (point))))
                  (to (if after (save-excursion (goto-char pos) (forward-line lines) (point)) pos))
                  (blocks (earwig--blocks from to))
                  (heading nil))
             ;; Only those of this section
             (if after
                 (let ((rest (cl-member-if (lambda (block)
                                             (and (eq (nth 2 block) 'heading) (> (car block) pos)))
                                           blocks)))
                   (setq heading (and rest t)
                         blocks (butlast blocks (length rest))))
               (let ((rest (cl-member-if (lambda (block)
                                           (and (eq (nth 2 block) 'heading) (<= (cadr block) pos)))
                                         (reverse blocks))))
                 (setq heading (and rest t)
                       blocks (nthcdr (length rest) blocks))))
             (let ((sentences (cl-loop for (beg end kind) in blocks
                                       unless (eq kind 'heading)
                                       append (earwig--block-sentences beg end))))
               (setq found (if after
                               (cl-remove-if (pcase-lambda (`(,beg ,_))
                                               (and (< beg pos)
                                                    (string-match-p "[[:alnum:]]"
                                                                    (buffer-substring beg pos))))
                                             sentences)
                             (cl-remove-if (pcase-lambda (`(,_ ,end))
                                             (and (> end pos)
                                                  (string-match-p "[[:alnum:]]"
                                                                  (buffer-substring pos end))))
                                           sentences))))
             (and (< (length found) n)
                  (not heading)
                  (if after (< to (point-max)) (> from (point-min)))
                  (setq lines (* 2 lines)))))
    (setq found (if after (seq-take found n) (last found n)))
    (unless found
      (user-error "No %s sentence in this section" (if after "later" "earlier")))
    (cons (car (car found)) (cadr (car (last found))))))

;; The text that went in last, for "that": dictation sets
;; `earwig--last-dictation' (earwig.el), commands that put text in call
;; `earwig--put'.

(defcustom earwig-flash t
  "Non-nil to flash the text a command put in, moved or wrapped.
So you see where it went.  \"where is TARGET\" flashes either way."
  :type 'boolean
  :group 'earwig)

(defcustom earwig-flash-duration 1.5
  "How long, in seconds, text flashes: what a command put in, or \"where is\" found."
  :type 'number
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
      (run-at-time earwig-flash-duration nil #'delete-overlay overlay))))

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

(defun earwig--ordinal-text (ordinal)
  "Return ORDINAL, (N . FROM), in words: \"second\", \"21st\", \"third to last\"."
  (pcase-let ((`(,n . ,from) ordinal))
    (if (and (= n 1) (eq from 'end))
        "last"
      (concat (if (<= n (length earwig--ordinal-words))
                  (nth (1- n) earwig--ordinal-words)
                (format "%d%s" n (cond ((memq (% n 100) '(11 12 13)) "th")
                                       ((= (% n 10) 1) "st")
                                       ((= (% n 10) 2) "nd")
                                       ((= (% n 10) 3) "rd")
                                       (t "th"))))
              (if (eq from 'end) " to last" "")))))

(defun earwig--filter-text (filter)
  "Return FILTER, (KIND WORDS) or nil, in words, with a space before it."
  (pcase filter
    (`(,kind ,words)
     (format " %s \"%s\"" (pcase kind
                            ('starting "starting with")
                            ('ending "ending with")
                            (_ (symbol-name kind)))
             words))
    (_ "")))

(defun earwig--spec-text (spec)
  "Return the target SPEC in words, for a message."
  (let ((text (lambda (target) (earwig--spec-text (earwig-target-spec target))))
        (units (lambda (n unit) (if (= n 1) unit (format "%s %s" n (earwig--plural unit))))))
    (pcase spec
      ('(region) "the region")
      ('(that) "that")
      ('(buffer) "the buffer")
      (`(units ,quantity ,unit ,filter ,scope)
       (concat (pcase quantity
                 ('(this) (concat "this " unit))
                 ('(every) (concat "every " unit))
                 ('nil (concat "the " unit))
                 (`(range ,from ,to)
                  (if (equal from to)
                      (format "the %s %s" (earwig--ordinal-text from) unit)
                    (format "the %s through %s %s" (earwig--ordinal-text from)
                            (earwig--ordinal-text to) (earwig--plural unit))))
                 (`(,direction ,n) (format "%s %s" direction (funcall units n unit))))
               (earwig--filter-text filter)
               (if scope (concat " in " (funcall text scope)) "")))
      ('(parent) "the parent heading")
      (`(body ,heading) (concat "the body of " (funcall text heading)))
      (`(under ,heading) (concat "everything under " (funcall text heading)))
      (`(subheadings ,heading)
       (if heading (concat "the subheadings of " (funcall text heading)) "the subheadings"))
      (`(words ,words) words)
      (`(through ,a ,b) (format "%s through %s" a b))
      (`(span ,a ,b) (format "%s through %s" (funcall text a) (funcall text b)))
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

(defun earwig--plural (unit)
  "Return the plural of UNIT, a value of `earwig-unit'."
  (if (equal unit "checkbox") "checkboxes" (concat unit "s")))

(defun earwig--checkbox-item-p (item)
  "Non-nil if ITEM, (START . END), has a checkbox."
  (save-excursion
    (goto-char (car item))
    (and (looking-at earwig--md-item-regexp) (match-beginning 5) t)))

(defun earwig--items-of (unit)
  "Return the list items for UNIT: all for \"item\", those with a checkbox
for \"checkbox\"."
  (if (equal unit "checkbox")
      (cl-remove-if-not #'earwig--checkbox-item-p (earwig--items))
    (earwig--items)))

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

(defun earwig--items-near (n after &optional unit)
  "Return the range of N list items before point, or AFTER it.
By position, at any level; not the items point is in.  UNIT
\"checkbox\" counts only items with one."
  (let* ((items (earwig--items-of unit))
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
      (user-error "%s %s" (format "%s %s" (if found (format "Only %d" (length found)) "No")
                                  (if (= (length found) 1) (or unit "item")
                                    (earwig--plural (or unit "item"))))
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

;;;; Listing units

;; To count units ("the second paragraph with budget") they're listed
;; in a range.  A paragraph is lines of text between blank lines, a
;; list or a heading's title; for the sentences in them, each list
;; item's own text is a paragraph of its own.  Org's planning lines and
;; drawers aren't any.  Without a scope, a unit is counted in its natural
;; container (`earwig--containers'):
;;
;;   word                 its sentence
;;   sentence, line       its paragraph
;;   item, checkbox       its list
;;   heading, section     the section of its parent, or the buffer
;;   paragraph, link      the heading's own text, or the buffer where
;;                        there are no headings
;;
;; A filter that lets too few through there widens it to the next one
;; out, up to the buffer.  Ordinals count headings, sections, items and
;; checkboxes only at the outermost level there, siblings, unless a
;; filter picks them.

(defvar-local earwig--units-cache nil
  "(TICK . TABLE) of the units listed since the buffer last changed.")

(defun earwig--cached (key compute)
  "Return the value cached for KEY while the buffer is as it is, or COMPUTE's."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eql (car earwig--units-cache) tick)
      (setq earwig--units-cache (cons tick (make-hash-table :test #'equal))))
    (let* ((table (cdr earwig--units-cache))
           (key (cons major-mode key))
           (value (gethash key table 'none)))
      (if (eq value 'none)
          (puthash key (funcall compute) table)
        value))))

(defun earwig--heading-line-p ()
  "Non-nil if the line at point is an Org or Markdown heading."
  (and (earwig--structure-mode-p)
       (save-excursion
         (beginning-of-line)
         (if (derived-mode-p 'org-mode)
             (looking-at-p "\\*+[ \t]")
           (and (looking-at-p "#+[ \t]") (not (earwig--md-code-p (point))))))))

(defun earwig--meta-line-p ()
  "Non-nil if the line at point is Org's planning line, or in a drawer."
  (and (derived-mode-p 'org-mode)
       (save-excursion
         (beginning-of-line)
         (let ((case-fold-search nil))
           (looking-at-p "[ \t]*\\(?:\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):\
\\|:[[:alnum:]_-]+:\\(?:[ \t]\\|$\\)\\)")))))

(defun earwig--blocks (beg end)
  "Return the paragraphs on the lines from BEG to END, (BEG END KIND) each.
See \"Listing units\" above; KIND is `heading', `item' or `text'.  Each
is whole, so it can start before BEG or end after END."
  (save-excursion
    (goto-char beg)
    (beginning-of-line)
    (let (blocks block)
      (catch 'done
        (while (not (eobp))
          (let ((kind (cond ((looking-at-p "[ \t]*$") 'blank)
                            ((earwig--heading-line-p) 'heading)
                            ((earwig--meta-line-p) 'meta)
                            ((earwig--item-line-p) 'item)
                            (block 'more)
                            (t 'text))))
            (when (and (>= (point) end) (not (eq kind 'more)))
              (throw 'done nil))
            (unless (eq kind 'more)
              (when block (push block blocks))
              (setq block nil))
            (pcase kind
              ('heading (let ((title (earwig--heading-title (list (point)))))
                          (push (list (car title) (cadr title) 'heading) blocks)))
              ('item (setq block (list (earwig--line-prefix-end) (line-end-position) 'item)))
              ('text (setq block (list (save-excursion (back-to-indentation) (point))
                                       (line-end-position) 'text)))
              ('more (setf (nth 1 block) (line-end-position))))
            (forward-line 1))))
      (when block (push block blocks))
      (delq nil (mapcar (pcase-lambda (`(,beg ,end ,kind))
                          (let ((range (earwig--trim beg end)))
                            (and (< (car range) (cdr range)) (list (car range) (cdr range) kind))))
                        (nreverse blocks))))))

(defun earwig--pick-at (pos ranges &optional lines)
  "Return the one of RANGES, in order, that POS is in.
Else the last before it, else the first.  With LINES, one is around
POS from the start of its first line."
  (or (cl-find-if (lambda (range)
                    (<= (if lines (save-excursion (goto-char (car range)) (line-beginning-position))
                          (car range))
                        pos (cadr range)))
                  ranges)
      (car (last (cl-remove-if-not (lambda (range) (< (cadr range) pos)) ranges)))
      (car ranges)))

(defun earwig--paragraph-blocks (blocks)
  "Return BLOCKS, from `earwig--blocks', with each list as one paragraph.
That's KIND `list', from the start of its first item's line."
  (let (paragraphs)
    (dolist (block blocks)
      (cond ((not (eq (nth 2 block) 'item)) (push block paragraphs))
            ((eq (nth 2 (car paragraphs)) 'list) (setcar paragraphs (list (car (car paragraphs))
                                                                           (cadr block) 'list)))
            (t (push (list (save-excursion (goto-char (car block)) (line-beginning-position))
                           (cadr block) 'list)
                     paragraphs))))
    (nreverse paragraphs)))

(defun earwig--block-at (pos &optional paragraphs)
  "Return the paragraph POS is in, see `earwig--blocks'.
Or else the one before it, or else the one after; nil if there's none.
With PARAGRAPHS, a list is one, see `earwig--paragraph-blocks'."
  (save-excursion
    (goto-char pos)
    (let* ((from (progn (beginning-of-line)
                        (skip-chars-backward " \t\n")
                        (if (re-search-backward "^[ \t]*$" nil t) (point) (point-min))))
           (to (progn (goto-char pos)
                      (end-of-line)
                      (skip-chars-forward " \t\n")
                      (if (re-search-forward "^[ \t]*$" nil t) (point) (point-max)))))
      (earwig--pick-at pos (if paragraphs
                               (earwig--paragraph-blocks (earwig--blocks from to))
                             (earwig--blocks from to))
                       t))))

(defun earwig--paragraph-range (beg end)
  "Return the range of the paragraph from BEG to END: whole lines if it is."
  (list beg end
        (save-excursion (and (progn (goto-char beg) (bolp)) (progn (goto-char end) (eolp))))
        nil "paragraph"))

(defun earwig--sentence-end-base ()
  "Return `sentence-end-base' for this buffer.
In Org and Markdown, emphasis that closes after the punctuation is part
of the sentence, as in *Done.*"
  (cond ((derived-mode-p 'org-mode) (concat sentence-end-base "[*_/=~+]*"))
        ((derived-mode-p 'markdown-mode) (concat sentence-end-base "[*_~`]*"))
        (t sentence-end-base)))

(defun earwig--block-sentences (beg end)
  "Return (BEG END) of each sentence of the paragraph from BEG to END."
  (earwig--cached
   (list 'sentences beg end)
   (lambda ()
     (save-excursion
       (save-restriction
         (narrow-to-region beg end)
         (goto-char beg)
         (let ((sentence-end-base (earwig--sentence-end-base))
               sentences)
           (while (progn (skip-chars-forward " \t\n") (< (point) end))
             (let ((start (point)))
               (forward-sentence)
               (when (<= (point) start)
                 (goto-char end))
               (let ((range (earwig--trim start (point))))
                 (when (string-match-p "[[:alnum:]]" (buffer-substring (car range) (cdr range)))
                   (push (list (car range) (cdr range)) sentences)))))
           (nreverse sentences)))))))

(defun earwig--sentence-at (pos)
  "Return (BEG END) of the sentence POS is in, or the one before or after it.
Nil if there's none."
  (let ((block (earwig--block-at pos)))
    (and block (earwig--pick-at pos (earwig--block-sentences (car block) (cadr block))))))

(defun earwig--words-in (beg end)
  "Return (BEG END) of each word wholly from BEG to END, without markup."
  (save-excursion
    (goto-char beg)
    (let (words)
      (while (progn (while (and (< (point) end) (not (earwig--letter-p (char-after))))
                      (forward-char))
                    (< (point) end))
        (let ((start (point)))
          (forward-word 1)
          (when (<= (point) start)
            (goto-char (1+ start)))
          (let ((word (earwig--unmarked start (point))))
            (when (and (<= (point) end) (< (car word) (cdr word))
                       (not (and (= start beg) (earwig--letter-p (char-before beg)))))
              (push (list (car word) (cdr word)) words)))))
      (nreverse words))))

(defun earwig--lines-in (beg end)
  "Return the ranges of the lines with text from BEG to END.
Whole lines, or the part of one that's there."
  (save-excursion
    (goto-char beg)
    (beginning-of-line)
    (let (lines)
      (while (and (< (point) end) (not (eobp)))
        (let* ((bol (point))
               (eol (line-end-position))
               (text (earwig--trim (max beg bol) (min end eol)))
               (whole (earwig--trim bol eol)))
          (when (< (car text) (cdr text))
            (push (if (and (<= beg (car whole)) (<= (cdr whole) end))
                      (list bol eol t nil "line")
                    (list (car text) (cdr text) nil nil "line"))
                  lines)))
        (forward-line 1))
      (nreverse lines))))

(defun earwig--indentation (item)
  "Return the indentation of ITEM, (START . END)."
  (save-excursion (goto-char (car item)) (current-indentation)))

(defun earwig--item-own-end (beg end)
  "Return where the text of the item from BEG to END ends, before its sub-items."
  (save-excursion
    (goto-char beg)
    (let ((own (line-end-position)))
      (forward-line 1)
      (while (and (< (point) end) (not (eobp)) (not (earwig--item-line-p)))
        (unless (looking-at-p "[ \t]*$")
          (setq own (line-end-position)))
        (forward-line 1))
      (min own end))))

(defun earwig--outermost (things level)
  "Return those of THINGS whose LEVEL is the least among them."
  (let ((least (and things (apply #'min (mapcar level things)))))
    (cl-remove-if-not (lambda (thing) (= (funcall level thing) least)) things)))

(defun earwig--list-units (unit scope &optional siblings)
  "Return the ranges of the UNITs wholly in SCOPE, a range, in order.
With SIBLINGS, headings, sections, items and checkboxes only at the
outermost level there.  A section's own heading isn't in it, nor are
an item's sub-items, for units other than items: only its own text."
  (pcase-let ((`(,beg ,end ,_ ,_ ,kind) scope))
    (when (and (member kind '("item" "checkbox")) (not (member unit '("item" "checkbox"))))
      (setq end (earwig--item-own-end beg end)
            beg (save-excursion (goto-char beg) (earwig--line-prefix-end))))
    (earwig--cached
     (list unit beg end kind siblings)
     (lambda ()
       (let ((inside (lambda (things &optional from)
                       (cl-remove-if-not (lambda (thing) (and (<= (or from beg) (car thing))
                                                              (<= (cdr thing) end)))
                                         things))))
         (pcase unit
           ("word" (mapcar (lambda (word) (list (car word) (cadr word) nil nil "word"))
                           (earwig--words-in beg end)))
           ((or "sentence" "paragraph")
            (let* ((blocks (cl-remove-if-not (lambda (block) (and (<= beg (car block))
                                                                  (<= (cadr block) end)))
                                             (earwig--blocks beg end)))
                   ;; Titles only where there's nothing else, as in a heading
                   (blocks (or (cl-remove-if (lambda (block) (eq (nth 2 block) 'heading)) blocks)
                               blocks)))
              (if (equal unit "paragraph")
                  (mapcar (lambda (block) (earwig--paragraph-range (car block) (cadr block)))
                          (earwig--paragraph-blocks blocks))
                (cl-loop for (bbeg bend) in blocks
                         append (mapcar (lambda (sentence)
                                          (list (car sentence) (cadr sentence) nil nil "sentence"))
                                        (earwig--block-sentences bbeg bend))))))
           ("line" (earwig--lines-in beg end))
           ((or "heading" "section")
            (let* ((headings (earwig--headings))
                   (own (equal kind "section"))
                   (found (cl-remove-if-not (lambda (h) (and (if own (< beg (car h)) (<= beg (car h)))
                                                             (< (car h) end)))
                                            headings)))
              (mapcar (lambda (h) (if (equal unit "heading")
                                      (earwig--heading-title h)
                                    (earwig--section h headings)))
                      (if siblings (earwig--outermost found #'cdr) found))))
           ((or "item" "checkbox")
            (let ((found (cl-remove-if
                          (lambda (item) (and (member kind '("item" "checkbox")) (= (car item) beg)))
                          (funcall inside (earwig--items-of unit)
                                   (save-excursion (goto-char beg) (line-beginning-position))))))
              (mapcar #'earwig--item-range
                      (if siblings (earwig--outermost found #'earwig--indentation) found))))
           ("link" (mapcar #'earwig--link-range (funcall inside (earwig--links))))))))))

(defun earwig--next-text-line (pos)
  "Return the start of the first line with text after the line of POS, or nil."
  (save-excursion
    (goto-char pos)
    (forward-line 1)
    (skip-chars-forward " \t\n")
    (and (not (eobp)) (line-beginning-position))))

(defun earwig--list-range (item items)
  "Return the range of the list ITEM is in.
That's it and the items next to it at its level.  ITEM is one of
ITEMS, from `earwig--items'."
  (let* ((indent (earwig--indentation item))
         (same (cl-remove-if-not (lambda (other) (= (earwig--indentation other) indent)) items))
         (first (cl-position item same :test #'equal))
         (last first))
    (while (and (> first 0)
                (eql (earwig--next-text-line (cdr (nth (1- first) same))) (car (nth first same))))
      (cl-decf first))
    (while (and (< (1+ last) (length same))
                (eql (earwig--next-text-line (cdr (nth last same))) (car (nth (1+ last) same))))
      (cl-incf last))
    (list (car (nth first same)) (cdr (nth last same)) t nil "list")))

(defun earwig--same-heading-p (a b)
  "Non-nil if positions A and B are under the same heading, or there are none."
  (or (not (earwig--structure-mode-p))
      (let ((headings (earwig--headings)))
        (equal (earwig--heading-at a headings) (earwig--heading-at b headings)))))

(defun earwig--lists-at (pos)
  "Return the ranges of the lists POS is in, innermost first.
Not in a list, those of the list before POS under the same heading."
  (let* ((items (earwig--items))
         (item (or (earwig--item-at pos items)
                   (let ((before (cl-remove-if-not (lambda (item) (< (cdr item) pos)) items)))
                     (when before
                       (let* ((end (apply #'max (mapcar #'cdr before)))
                              (outer (cl-find-if (lambda (item) (<= (car item) end (cdr item)))
                                                 items)))
                         (and (earwig--same-heading-p (car outer) pos) outer))))))
         lists)
    (while item
      (push (earwig--list-range item items) lists)
      (setq item (let (parent)
                   (dolist (other items parent)
                     (when (and (< (car other) (car item)) (<= (cdr item) (cdr other)))
                       (setq parent other))))))
    (nreverse lists)))

(defun earwig--containers (unit pos)
  "Return the ranges UNIT is counted in at POS, its natural container first.
Then each one around it, out to the buffer; see \"Listing units\"."
  (let* ((headings (and (earwig--structure-mode-p) (earwig--headings)))
         (heading (and headings (earwig--heading-at pos headings)))
         (ancestors (cl-loop for h = heading then (earwig--parent h headings)
                             while h collect h))
         (sections (mapcar (lambda (h) (earwig--section h headings)) ancestors))
         (body (cond (heading (earwig--body heading headings))
                     ;; Before the first heading
                     (headings (let ((range (earwig--trim (point-min) (caar headings))))
                                 (list (car range) (cdr range) nil nil "body")))))
         (buffer (list (point-min) (point-max) nil nil "buffer"))
         (outer (append (and body (< (car body) (cadr body)) (list body)) sections (list buffer)))
         (paragraph (let ((block (earwig--block-at pos)))
                      (and block (list (car block) (cadr block) nil nil "paragraph")))))
    (delq nil
          (pcase unit
            ("word" (append (list (let ((sentence (earwig--sentence-at pos)))
                                    (and sentence (list (car sentence) (cadr sentence)
                                                        nil nil "sentence")))
                                  paragraph)
                            outer))
            ((or "sentence" "line") (cons paragraph outer))
            ((or "item" "checkbox") (append (earwig--lists-at pos) outer))
            ((or "heading" "section")
             (unless headings
               (earwig--headings))
             (append (cdr sections) (list buffer)))
            (_ outer)))))

;;;; Filters

(defun earwig--link-parts (beg end)
  "Return the visible text and the URL of the link from BEG to END.
As (BEG . END) each."
  (save-excursion
    (goto-char beg)
    (let ((case-fold-search t)
          (group (lambda (n) (and (match-beginning n) (cons (match-beginning n) (match-end n))))))
      (cond ((looking-at "\\[\\[\\([^]\n]+\\)\\]\\(?:\\[\\([^]\n]+\\)\\]\\)?\\]")
             (delq nil (list (funcall group 2) (funcall group 1))))
            ((looking-at "!?\\[\\([^]\n]*\\)\\](\\([^)\n]*\\))")
             (delq nil (list (funcall group 1) (funcall group 2))))
            ((looking-at "<\\([^>\n]+\\)>") (list (funcall group 1)))
            (t (list (cons beg end)))))))

(defun earwig--filter-parts (range)
  "Return the parts of RANGE a filter looks at, (BEG . END) each.
A section's title, a link's visible text and URL, else all of it."
  (pcase (nth 4 range)
    ("section" (let ((title (earwig--heading-title (list (car range)))))
                 (list (cons (car title) (cadr title)))))
    ("link" (earwig--link-parts (car range) (cadr range)))
    (_ (list (cons (car range) (cadr range))))))

(defun earwig--text-has-p (kind words beg end partial)
  "Non-nil if the text from BEG to END has WORDS, or starts or ends with them.
KIND is `with', `starting' or `ending'.  PARTIAL non-nil matches parts
of words too, else whole words only."
  (let ((regexp (earwig--phrase-regexp words))
        (case-fold-search t))
    (save-excursion
      (pcase kind
        ('starting
         (goto-char beg)
         (skip-chars-forward "^[:alnum:]" end)
         (and (looking-at regexp)
              (<= (match-end 0) end)
              (or partial (earwig--whole-words-p (match-beginning 0) (match-end 0)))))
        ('ending
         (goto-char end)
         (skip-chars-backward "^[:alnum:]" beg)
         (and (looking-back regexp beg)
              (or partial (earwig--whole-words-p (match-beginning 0) (match-end 0)))))
        (_
         (goto-char beg)
         (if partial (re-search-forward regexp end t) (earwig--search regexp end)))))))

(defun earwig--passes-p (filter range)
  "Non-nil if RANGE passes FILTER, (KIND WORDS); see `earwig-target'.
Words match parts of a word unit (\"the word starting with moon\"),
whole words of others."
  (pcase-let* ((`(,kind ,words) filter)
               (partial (equal (nth 4 range) "word"))
               (found (cl-some (pcase-lambda (`(,beg . ,end))
                                 (earwig--text-has-p (if (eq kind 'without) 'with kind)
                                                     words beg end partial))
                               (earwig--filter-parts range))))
    (if (eq kind 'without) (not found) found)))

;;;; Selecting units

(defun earwig--passing (unit scope filter &optional siblings)
  "Return the UNITs in SCOPE that FILTER lets through.
SIBLINGS is for `earwig--list-units', when there's no filter."
  (let ((all (earwig--list-units unit scope (and siblings (not filter)))))
    (cond ((null filter) all)
          ;; With or without words: their matches once, not per unit
          ((and all (memq (car filter) '(with without)) (not (member unit '("section" "link"))))
           (let* ((regexp (earwig--phrase-regexp (cadr filter)))
                  (beg (apply #'min (mapcar #'car all)))
                  (end (apply #'max (mapcar #'cadr all)))
                  (matches (if (equal unit "word")
                               (let ((case-fold-search t) found)
                                 (save-excursion
                                   (goto-char beg)
                                   (while (re-search-forward regexp end t)
                                     (push (cons (match-beginning 0) (match-end 0)) found)
                                     (when (= (match-beginning 0) (match-end 0))
                                       (forward-char))))
                                 (nreverse found))
                             (earwig--matches regexp beg end)))
                  (with (eq (car filter) 'with)))
             ;; Units are in order of their start, so the first match from
             ;; one's start on only moves forward
             (cl-remove-if-not (lambda (range)
                                 (while (and matches (< (car (car matches)) (car range)))
                                   (pop matches))
                                 (eq with (and matches (<= (cdr (car matches)) (cadr range)) t)))
                               all)))
          (t (cl-remove-if-not (lambda (range) (earwig--passes-p filter range)) all)))))

(defun earwig--units-count-text (n unit filter)
  "Return N UNITs with FILTER in words, for a message: \"Only 2 sentences with ...\"."
  (format "%s %s%s" (if (zerop n) "No" (format "Only %d" n))
          (if (= n 1) unit (earwig--plural unit)) (earwig--filter-text filter)))

(defun earwig--join (ranges unit)
  "Return RANGES, of UNITs next to each other, as one range.
Headings and links stay as they are, as there's text between them."
  (if (or (null (cdr ranges)) (member unit '("heading" "link")))
      ranges
    (list (list (car (car ranges)) (apply #'max (mapcar #'cadr ranges)) (nth 2 (car ranges)) nil
                (if (equal unit "checkbox") "item" unit)))))

(defun earwig--merge-ranges (ranges)
  "Return RANGES in buffer order, those that overlap as one."
  (let (merged)
    (dolist (range (sort (copy-sequence ranges) (lambda (a b) (< (car a) (car b)))))
      (let ((previous (car merged)))
        (if (and previous (< (car range) (cadr previous)))
            (setcar merged (list (car previous) (max (cadr previous) (cadr range))
                                 (and (nth 2 previous) (nth 2 range)) nil (nth 4 previous)))
          (push range merged))))
    (nreverse merged)))

(defun earwig--count-in (unit filter scope)
  "Return the ranges to count UNITs in: SCOPE, or else UNIT's natural container.
With FILTER, the containers around that too, to widen to."
  (cond (scope (list scope))
        (filter (earwig--containers unit (point)))
        (t (seq-take (earwig--containers unit (point)) 1))))

(defun earwig--select-counted (from to unit filter scope)
  "Return the FROMth through the TOth UNIT that FILTER lets through, in SCOPE.
FROM and TO are (N . START-OR-END).  Without SCOPE, in UNIT's natural
container, or with FILTER the first container around point with
enough.  Without FILTER, one range, as they're next to each other."
  (let ((needed (max (car from) (car to)))
        listed)
    (cl-loop for container in (or (earwig--count-in unit filter scope)
                                  (user-error "No %s here" unit))
             do (setq listed (earwig--passing unit container filter t))
             until (>= (length listed) needed))
    (let* ((n (length listed))
           (index (lambda (ordinal) (if (eq (cdr ordinal) 'start) (1- (car ordinal)) (- n (car ordinal)))))
           (i (funcall index from))
           (j (funcall index to)))
      (when (> i j)
        (cl-rotatef i j))
      (when (or (< n needed) (< i 0) (>= j n))
        (user-error "%s there" (earwig--units-count-text n unit filter)))
      (let ((found (seq-subseq listed i (1+ j))))
        (if filter found (earwig--join found unit))))))

(defun earwig--select-near (direction n unit filter scope)
  "Return the N UNITs FILTER lets through after point, or before it.
DIRECTION is `next' or `previous'.  In SCOPE, a range, if given; at
any level."
  (let* ((pt (point))
         (after (if (member unit '("heading" "section" "item" "checkbox"))
                    (save-excursion (goto-char pt) (line-end-position))
                  pt))
         (listed (earwig--passing unit (or scope (list (point-min) (point-max) nil nil "buffer"))
                                  filter))
         (found (if (eq direction 'next)
                    (seq-take (cl-remove-if-not (lambda (range) (> (car range) after)) listed) n)
                  (last (cl-remove-if-not (lambda (range) (< (cadr range) pt)) listed) n))))
    (when (< (length found) n)
      (user-error "%s %s" (earwig--units-count-text (length found) unit filter)
                  (if (eq direction 'next) "after this" "before this")))
    (if filter found (earwig--join found unit))))

(defun earwig--nearest-range (ranges)
  "Return the one of RANGES nearest point, or nil.
One around point, else the closest before it, else the closest after."
  (let ((pt (point)) before)
    (or (cl-find-if (lambda (range) (<= (car range) pt (cadr range))) ranges)
        (dolist (range ranges before)
          (when (and (< (cadr range) pt) (or (null before) (> (cadr range) (cadr before))))
            (setq before range)))
        (cl-find-if (lambda (range) (> (car range) pt)) ranges))))

(defun earwig--select-nearest (unit filter scope)
  "Return the UNIT that FILTER lets through nearest point, in SCOPE if given.
Else in the window first, then in the whole buffer."
  (or (if (and (not scope) (eq (car filter) 'with) (not (equal unit "word")))
          (let ((range (earwig--unit-with unit (cadr filter) t)))
            (and range (list range)))
        (let ((window (get-buffer-window (current-buffer)))
              (buffer (list (point-min) (point-max) nil nil "buffer")))
          (cl-loop for range in (cond (scope (list scope))
                                      (window (list (list (window-start window) (window-end window t))
                                                    buffer))
                                      (t (list buffer)))
                   for found = (earwig--nearest-range (earwig--passing unit range filter))
                   when found return (list found))))
      (user-error "No %s%s %s" unit (earwig--filter-text filter) (if scope "there" "here"))))

(defun earwig--select-every (unit filter scope)
  "Return every UNIT FILTER lets through in SCOPE.
Or else in its natural container, with FILTER widening as
`earwig--select-counted' does.  At any level."
  (let (found)
    (cl-loop for container in (earwig--count-in unit filter scope)
             do (setq found (earwig--passing unit container filter))
             until found)
    (or found
        (user-error "No %s%s there" (earwig--plural unit) (earwig--filter-text filter)))))

(defun earwig--select-units (quantity unit filter scope)
  "Return the ranges of the UNITs QUANTITY and FILTER pick, see `earwig-target'.
In SCOPE, one range, or nil for UNIT's natural container."
  (pcase quantity
    ('(this)
     (when (and scope (not (<= (car scope) (point) (cadr scope))))
       (user-error "This %s isn't there" unit))
     (list (earwig--unit-at unit (point))))
    ('(every) (earwig--select-every unit filter scope))
    ('nil (earwig--select-nearest unit filter scope))
    (`(range ,from ,to) (earwig--select-counted from to unit filter scope))
    ;; "last" alone is before point; qualified, from the end
    (`(last ,n) (if (or filter scope)
                    (earwig--select-counted (cons n 'end) '(1 . end) unit filter scope)
                  (earwig--units-near n unit nil)))
    (`(,direction ,n) (if (or filter scope)
                          (earwig--select-near direction n unit filter scope)
                        (earwig--units-near n unit (eq direction 'next))))))

(defun earwig--resolve-units (quantity unit filter scope &optional overlapping)
  "Return the ranges of the UNITs QUANTITY and FILTER pick in SCOPE, a target.
In each of SCOPE's ranges, skipping those with too few; nil SCOPE is
UNIT's natural container.  Those that overlap are one, unless
OVERLAPPING, as for a scope: every item, each with its own text."
  (let ((found
         (if (null scope)
             (earwig--select-units quantity unit filter nil)
           (let ((spec (earwig-target-spec scope))
                 found failed)
             (dolist (range (if (eq (car spec) 'units)
                                (apply #'earwig--resolve-units (append (cdr spec) '(t)))
                              (earwig--ranges scope)))
               (condition-case err
                   (setq found (append found (earwig--select-units quantity unit filter range)))
                 (user-error (setq failed (or failed err)))))
             (or found (signal (car failed) (cdr failed)))))))
    (if overlapping found (earwig--merge-ranges found))))

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
    ((or "word" "line")
     (save-excursion
       (goto-char pos)
       (let ((range (earwig--this-unit unit)))
         (list (car range) (cdr range) (equal unit "line") nil unit))))
    ((or "sentence" "paragraph")
     (let ((range (if (equal unit "sentence") (earwig--sentence-at pos) (earwig--block-at pos t))))
       (unless range
         (user-error "No %s here" unit))
       (if (equal unit "paragraph")
           (earwig--paragraph-range (car range) (cadr range))
         (list (car range) (cadr range) nil nil unit))))
    ((or "heading" "section")
     (let* ((headings (earwig--headings))
            (heading (or (earwig--heading-at pos headings) (user-error "No heading here"))))
       (if (equal unit "heading")
           (earwig--heading-title heading)
         (earwig--section heading headings))))
    ((or "item" "checkbox")
     (earwig--item-range (or (earwig--item-at pos (earwig--items-of unit))
                             (user-error "No %s here" (if (equal unit "item") "list item" unit)))))
    ("link" (earwig--link-range (or (cl-find-if (lambda (link) (<= (car link) pos (cdr link)))
                                                (earwig--links))
                                    (user-error "No link here"))))))

(defun earwig--units-near (n unit after)
  "Return the ranges of the N UNITs before point, or AFTER it."
  (pcase unit
    ((or "heading" "section") (earwig--headings-near n unit after))
    ((or "item" "checkbox") (earwig--items-near n after unit))
    ("link" (earwig--links-near n after))
    (_ (let ((range (if after (earwig--next-units n unit) (earwig--last-units n unit))))
         (list (list (car range) (cdr range) (equal unit "line") nil unit))))))

(defun earwig--unit-with (unit words &optional noerror)
  "Return the range of the UNIT with WORDS in it nearest point.
For a heading or section, the words must be in its title.  If there's
none, signal a `user-error', or with NOERROR return nil."
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
    (or range (unless noerror (user-error "No %s with \"%s\"" unit words)))))

(defconst earwig--part-kinds
  '(region that units buffer parent body under subheadings span)
  "The kinds of `earwig-target' spec that name a part of the buffer.")

(defun earwig--resolve (spec &optional empty-ok)
  "Return the ranges of the target SPEC, in buffer order.
See `earwig-target' for SPEC.  Signals a `user-error' if it isn't there,
or if it's a part of the buffer with nothing in it, unless EMPTY-OK."
  (let ((ranges
         (pcase spec
           ('(region) (list (earwig--region-range
                             (or (earwig--region) (user-error "No region")))))
           ('(that) (list (if (earwig--region)
                              (earwig--region-range (earwig--region))
                            (let ((that (earwig--that)))
                              (list (car that) (cdr that) nil nil nil)))))
           (`(units ,quantity ,unit ,filter ,scope)
            (earwig--resolve-units quantity unit filter scope))
           ('(buffer) (list (list (point-min) (point-max) nil nil nil)))
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
            (let* ((ranges (earwig--choose (earwig-target-spec target)
                                           (earwig--resolve (earwig-target-spec target) t)))
                   (pos (if (eq edge 'start) (car (car ranges)) (cadr (car (last ranges))))))
              ;; An empty body stays one, so text put there gets a line
              (list (list pos pos nil nil (if (and (equal (nth 4 (car ranges)) "body")
                                                   (= (car (car ranges)) (cadr (car ranges))))
                                              "body"
                                            "edge")))))
           (`(span ,first ,last)
            (let ((a (earwig--target first))
                  (b (earwig--target last)))
              (list (list (min (car a) (car b)) (max (cadr a) (cadr b))
                          (and (nth 2 a) (nth 2 b)) nil nil))))
           (`(and ,forced . ,targets) (earwig--resolve-and forced targets))
           (_ (error "Not a target: %S" spec)))))
    (when (and (not empty-ok) (memq (car spec) earwig--part-kinds) (not (eq (car spec) 'body)))
      (dolist (range ranges)
        (when (>= (car range) (cadr range))
          (user-error "Nothing there: %s" (earwig--spec-text spec)))))
    ranges))

(defun earwig--region-range (region)
  "Return the range of REGION, (BEG . END).
Whole lines are lines, as a line or item target is, so they move and
delete as lines; list items if the first is one."
  (pcase-let* ((`(,beg . ,end) region)
               ;; A region that takes the last line break, as evil's line-wise one
               (end (if (and (> end beg) (eq (char-before end) ?\n)) (1- end) end)))
    (if (and (< beg end)
             (save-excursion (goto-char beg) (bolp))
             (save-excursion (goto-char end) (eolp)))
        (list beg end t nil (and (save-excursion (goto-char beg) (earwig--item-line-p)) "item"))
      (list (car region) (cdr region) nil nil nil))))

(defun earwig--resolve-in (what scopes)
  "Return the ranges of the target spec WHAT, looked for only in SCOPES.
For words, every place they are there."
  (pcase what
    (`(words ,words)
     (let ((regexp (earwig--phrase-regexp words)))
       (or (cl-loop for (beg end) in scopes
                    append (mapcar (lambda (match) (list (car match) (cdr match) nil regexp "words"))
                                   (earwig--matches regexp beg end)))
           (user-error "No \"%s\" there" words))))
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
  "Return the ranges of TARGETS, `earwig-target's, all of them, in order.
Those that overlap are merged.  Unless FORCED, not when they're all
words and \"A and B\" is there as words, which is the one target then."
  (let ((specs (mapcar #'earwig-target-spec targets)))
    (when (and (not forced) (cl-every (lambda (spec) (eq (car spec) 'words)) specs))
      (let ((phrase (mapconcat #'cadr specs " and ")))
        (when (earwig--nearest (earwig--phrase-regexp phrase))
          (user-error "\"%s\" is there as words" phrase))))
    ;; Those that overlap are one
    (earwig--merge-ranges (mapcan (lambda (target) (copy-sequence (earwig--ranges target)))
                                  targets))))

(defun earwig--ranges (target)
  "Return the ranges of TARGET, an `earwig-target', in buffer order.
Nil is the region.  Each is (BEG END LINE-P REGEXP UNIT), see
\"Targets\" above.  Signals a `user-error' if it isn't there."
  (earwig--resolve (if target (earwig-target-spec target) '(region))))

(defun earwig--choose (spec ranges)
  "Return RANGES, of the target SPEC, or the nearest of them if they're choices.
They are for WORDS in PART, every place they are there, where a command
that acts on one place takes the nearest."
  (if (and (cdr ranges) (eq (car spec) 'in) (eq (car (earwig-target-spec (nth 1 spec))) 'words))
      (let ((nearest (earwig--first-nearest
                      (lambda (match)
                        (cl-find-if (lambda (range) (and (= (car range) (car match))
                                                         (= (cadr range) (cdr match))))
                                    ranges))
                      (mapcar (lambda (range) (cons (car range) (cadr range))) ranges))))
        (list nearest))
    ranges))

(defun earwig--target (target)
  "Return the one range of TARGET, an `earwig-target'; nil is the region.
The nearest of WORDS in PART.  Signals a `user-error' if it isn't there,
or is several places."
  (let ((ranges (earwig--choose (if target (earwig-target-spec target) '(region))
                                (earwig--ranges target))))
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

(defun earwig--tidy-sentence-start (pos deleted)
  "Tidy the start of a sentence that deleting DELETED at POS left.
Punctuation left there goes, with the space after it, as \"Yeah! Igor
owns it\" leaves \"! Igor owns it\" without \"Yeah\"; after an opening
parenthesis too.  If DELETED started with a capital and wasn't whole
lines, the next word gets it."
  (save-excursion
    (goto-char pos)
    (skip-chars-forward " \t")
    (let ((paren (eq (char-before (save-excursion (skip-chars-backward " \t") (point))) ?\()))
      (when (or paren (earwig--sentence-start-p (point)))
        (when (looking-at "[,;:.!?]+[ \t]*")
          (delete-region (point) (match-end 0)))
        (when (and (not paren)
                   (not (string-search "\n" deleted))
                   (let ((case-fold-search nil))
                     (and (string-match-p "\\`[^[:alnum:]]*[[:upper:]]" deleted)
                          (looking-at-p "[[:lower:]]"))))
          (upcase-region (point) (1+ (point))))))))

(defconst earwig--empty-pairs
  '(("(" . ")") ("[" . "]") ("{" . "}") ("\"" . "\"") ("'" . "'")
    ("“" . "”") ("‘" . "’") ("«" . "»") ("„" . "“") ("‚" . "‘"))
  "Brackets and quotes that go when deleting leaves nothing between them.")

(defconst earwig--emphasis-markers
  '((org-mode "*" "/" "_" "=" "~" "+")
    (markdown-mode "**" "__" "~~" "*" "_" "`"))
  "Emphasis markers in each mode, longest first.")

(defun earwig--tidy-empty-pairs (pos)
  "Delete emphasis, brackets and quotes left around nothing at POS.
As the \"__\" that cutting all of \"_unveil it_\" leaves; spaces count
as nothing.  From the inside out, as in (\"\").  Return where POS is
then."
  (let ((markers (cdr (cl-find-if (lambda (mode) (derived-mode-p (car mode)))
                                  earwig--emphasis-markers)))
        (found t))
    (cl-flet ((at-p (pos string)
                (let ((end (+ pos (length string))))
                  (and (<= (point-min) pos) (<= end (point-max))
                       (equal (buffer-substring pos end) string)))))
      (save-excursion
        (while found
          (let ((beg (progn (goto-char pos) (skip-chars-backward " \t") (point)))
                (end (progn (goto-char pos) (skip-chars-forward " \t") (point))))
            (setq found
                  (or (cl-loop for marker in markers
                               for open = (- beg (length marker))
                               for close = (+ end (length marker))
                               thereis (and (at-p open marker)
                                            (at-p end marker)
                                            ;; Not inside words, as in snake_case
                                            (not (earwig--letter-p (char-before open)))
                                            (not (earwig--letter-p (char-after close)))
                                            (cons open close)))
                      (cl-loop for (open . close) in earwig--empty-pairs
                               thereis (and (at-p (- beg (length open)) open)
                                            (at-p end close)
                                            (cons (- beg (length open)) (+ end (length close)))))))
            (when found
              (delete-region (car found) (cdr found))
              (setq pos (car found)))))))
    pos))

(defun earwig--tidy-punctuation (pos)
  "Drop a comma, semicolon or colon at POS that deleting left before more.
As \"loud,.\" left from \"loud, because they cried.\": the stronger
one stays, as the period there, or a closing parenthesis, or the first
of two commas."
  (save-excursion
    (goto-char pos)
    (let ((rank (lambda (char)
                  (cond ((memq char '(?. ?! ?? ?\))) 3)
                        ((memq char '(?\; ?:)) 2)
                        ((eq char ?,) 1)))))
      (when-let* ((before (and (not (bobp)) (funcall rank (char-before))))
                  (after (and (not (eobp)) (funcall rank (char-after)))))
        (when (<= before 2)
          (if (> after before)
              (delete-char -1)
            (when (<= after 2)
              (delete-char 1))))))))

(defun earwig--tidy-gap (pos &optional deleted)
  "Fix the spacing at POS, where text was just deleted.
With DELETED, the text deleted, the start of a sentence it was is
tidied too, see `earwig--tidy-sentence-start'; not when something takes
its place.  Emphasis, brackets or quotes left around nothing go (see
`earwig--tidy-empty-pairs'), and so does a comma left before a period
or another comma (see `earwig--tidy-punctuation')."
  (save-excursion
    (when deleted
      (earwig--tidy-sentence-start pos deleted)
      (setq pos (earwig--tidy-empty-pairs pos)))
    (goto-char pos)
    (let ((space '(?\s ?\t)))
      (cond
       ((and (memq (char-before) space) (memq (char-after) space))
        (delete-char 1))
       ((and (memq (char-before) space)
             (or (eolp) (memq (char-after) '(?. ?, ?\; ?: ?! ?? ?\)))))
        (delete-char -1))
       ((and (or (bolp) (eq (char-before) ?\()) (memq (char-after) space))
        (delete-char 1))))
    (when deleted
      (earwig--tidy-punctuation (point)))))

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
    ;; Whole lines leave no gap to tidy: the next line's indentation stays
    ('delete (let ((text (buffer-substring-no-properties beg end)))
               (delete-region beg end)
               (unless line-p (earwig--tidy-gap beg text))))
    ('cut (let ((text (buffer-substring-no-properties beg end)))
            (kill-region beg end)
            (when line-p (earwig--kill-lines))
            (unless line-p (earwig--tidy-gap beg text))))
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
        ((or 'delete 'cut) (let ((text (buffer-substring-no-properties beg end)))
                             (delete-region beg end)
                             (unless line-p (earwig--tidy-gap beg text))))
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
  (let ((ranges (if (eq verb 'select)
                    (earwig--choose (if target (earwig-target-spec target) '(region))
                                    (earwig--ranges target))
                  (earwig--ranges target))))
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

(defun earwig--replace-words (old)
  "Return the words \"replace OLD with ...\" replaces, or nil for a part.
OLD is words, or a target: words in it, as the next, previous or every
place they are, or a part of the buffer."
  (if (earwig-target-p old)
      (pcase (earwig-target-spec old)
        (`(near ,_ ,words) words)
        (`(every ,words ,_) words)
        (`(words ,words) words)
        (`(in ,what ,_) (pcase (earwig-target-spec what)
                          (`(words ,words) words))))
    old))

(defun earwig--replace-plan (old part everywhere)
  "Return what to replace for \"replace OLD with ...\", or nil if nothing.
In PART, an `earwig-part' value, or with EVERYWHERE, every OLD there:
that's (scope RANGES); otherwise the nearest OLD, (nearest BEG END),
or the region for \"replace that\", (region BEG END).  OLD can also be
the next or previous WORDS, the nearest that way in PART if given, or
every WORDS, as with EVERYWHERE or in its own part; \"the word WORDS\";
or WORDS in a part of its own, every place there.  Any other target is
replaced whole, (ranges RANGES), without PART or EVERYWHERE; not the
region or \"that\", which are the words then."
  (if (not (earwig-target-p old))
      (earwig--replace-plan-words old part everywhere)
    (pcase (earwig-target-spec old)
      (`(near ,direction ,words)
       (let ((scopes (cond (everywhere nil) (part (earwig--ranges part)))))
         (pcase (ignore-error user-error (earwig--resolve-near direction words scopes))
           (`((,beg ,end . ,_)) (list 'nearest beg end)))))
      (`(every ,words ,own)
       (earwig--replace-plan words (or own part) (not (or own part))))
      (`(words ,words) (earwig--replace-plan-words words part everywhere t))
      ((and `(in ,what ,own) (guard (eq (car (earwig-target-spec what)) 'words)))
       (and (not part) (not everywhere)
            (earwig--replace-plan-words (cadr (earwig-target-spec what)) own nil t)))
      ((or '(region) '(that)) nil)
      (_ (and (not part) (not everywhere)
              (let ((ranges (ignore-error user-error (earwig--ranges old))))
                (and ranges (list 'ranges ranges))))))))

(defun earwig--replace-plan-words (old part everywhere &optional literal)
  "Return what to replace for the words OLD, see `earwig--replace-plan'.
LITERAL non-nil means OLD is words even if it could be the region."
  (let ((scopes (cond (everywhere (list (list (point-min) (point-max))))
                      (part (earwig--ranges part))))
        (regexp (earwig--phrase-regexp old))
        ;; The whitespace around a selection stays
        (region (let ((r (earwig--region))) (and r (earwig--trim (car r) (cdr r))))))
    (cond
     ((and region (not literal) (null scopes) (member (downcase old) earwig--replace-region-words))
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
region when there is one.  OLD can be any target, see
`earwig--replace-plan'."
  (barf-if-buffer-read-only)
  (pcase-let ((`(,kind ,beg ,end)
               (or (earwig--replace-plan old part everywhere)
                   (user-error "Nothing to replace: \"%s\""
                               (if (earwig-target-p old)
                                   (earwig--spec-text (earwig-target-spec old))
                                 old))))
              (old (earwig--replace-words old)))
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
               ('ranges
                (earwig--one-undo-step
                  (cl-loop for (rbeg rend line-p _ unit) in (reverse beg)
                           ;; A bullet or heading stars stay, and sub-items
                           do (when line-p
                                (when (member unit '("item" "checkbox"))
                                  (setq rend (earwig--item-own-end rbeg rend)))
                                (setq rbeg (save-excursion (goto-char rbeg)
                                                           (earwig--line-prefix-end))))
                              (let ((text (buffer-substring rbeg rend)))
                                (goto-char rbeg)
                                (delete-region rbeg rend)
                                (insert (earwig--replacement-case (point) text new))
                                ;; Punctuation that ends it stays, as a sentence's
                                (when (and (string-match "[.?!]+\\'" text)
                                           (not (string-match-p "[.?!]\\'" new)))
                                  (insert (match-string 0 text))))
                           count t)))
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
    ("[QUANTITY] UNIT [FILTER]"        "\"this sentence\", \"last two words\",")
    (""                                "\"the second paragraph with budget\"")
    ("PART in | of PART"               "\"the first word of the second sentence\"")
    (""                                "(QUANTITY: this, next, previous, last [N],")
    (""                                "first [N], second, 21st, second to last,")
    (""                                "third through fifth, every, all)")
    (""                                "(FILTER: with, without, starting with,")
    (""                                "ending with WORDS)")
    ("the whole buffer"                "")
    ("WORDS"                           "the nearest place they're said")
    ("the next | previous WORDS"       "the nearest after or before the cursor")
    ("every | each WORDS [in PART]"    "all of them")
    ("[from] A until | through B"      "from words A to words B, or parts")
    ("WORDS in PART"                   "every place WORDS are in PART")
    (""                                "(\"meow in the last two sentences\")")
    ("the start | end of TARGET"       "the place before or after it")
    ("A and B, both A and B, each of A B and C" "")
    ("this heading | section"          "its title; it with all under it")
    ("the body of PART"                "a heading's own text")
    ("everything under PART"           "its text and subheadings")
    ("the subheadings [of PART]"       "")
    ("the parent heading | headline"   "")
    ("the word | the words WORDS"     "those words, even \"this\" or \"next\"")
    (""                                "UNIT: word, sentence, paragraph, line,")
    (""                                "heading, section, item, checkbox, link"))
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
  :help "format bold | italic | underline | code | verbatim | strike through | plain TARGET,
      format TARGET bold | italic | ..."
  :check (and (earwig--format-entry) (or target (earwig--region)))
  (earwig-cmd-format style target))

(earwig-defcommand earwig-say-format-after ("format" (target earwig-target)
                                            (style earwig-format-style))
  "Format TARGET in STYLE, said after it: \"format that bold\"."
  :check (earwig--format-entry)
  (earwig-cmd-format style target))

(earwig-defcommand earwig-say-replace
    ("replace" (old (| earwig-words earwig-target-literal earwig-target-near earwig-target-every
                       earwig-target-in earwig-target-through earwig-target-from
                       earwig-target-part))
     "with" (new earwig-text) (? (| (seq "in" (part earwig-part)) (everywhere "everywhere"))))
  "Replace OLD with NEW, nearest, in PART or EVERYWHERE.
OLD is words, the next, previous or every place they are, or any other
target, whose text NEW replaces."
  :help "replace [the next | previous | every] A with B [in TARGET | everywhere],
      replace TARGET with B   (\"replace the second word with moon\")"
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
