;;; earwig-move.el --- Moving, copying and wrapping text by voice  -*- lexical-binding: t; -*-

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

;; Commands that move text about, put marks around it, make room next
;; to it or take you to it, on the targets of earwig-edit.el:
;;
;;   move TARGET before | after | under DEST, or to the start | end of DEST
;;   copy TARGET before | after | under DEST, or to the start | end of DEST
;;   swap TARGET with TARGET
;;   duplicate TARGET            a copy right after it
;;   rewrite TARGET              delete it, to dictate in its place
;;   put PAIR around TARGET, wrap TARGET in PAIR
;;   remove the PAIR around TARGET, unwrap TARGET
;;   replace the PAIR around TARGET with PAIR,
;;   change the PAIR around TARGET to PAIR
;;   new | add a paragraph | item | heading before | after | under DEST,
;;   new | add a subheading under DEST
;;   go into DEST, add to DEST   to the end of a heading's own text
;;   open the link with WORDS, open that link, open the link in TARGET
;;   focus on TARGET, narrow to TARGET; show everything, widen
;;   where is TARGET, show me TARGET
;;
;; What moves goes as what it is: a section with its subheadings, their
;; levels set for where it goes ("under" makes it a subheading); whole
;; lines and list items as lines, indented as the item they go next to
;; or under; paragraphs as paragraphs; other text spaced from the words
;; around it, as dictation is.  Afterwards "that" is the text put in,
;; and it flashes (`earwig-flash').  Each command is one undo step.
;;
;; PAIR is quotes, single quotes, parentheses or brackets, square
;; brackets, dashes (`earwig-dash') or commas.  Quotes are typographic
;; where the buffer already has some.  "unwrap" takes off the nearest
;; quotes or brackets around the target; dashes and commas only go when
;; named.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'earwig-grammar)
(require 'earwig-edit)
(require 'earwig-structure)

(defvar evil-state)
(declare-function evil-insert-state "evil-states" (&optional arg))
(declare-function org-list-repair "org-list" ())
(declare-function org-at-item-p "org-list" ())
(declare-function org-open-at-point "org" (&optional arg))
(declare-function markdown-follow-thing-at-point "markdown-mode" (arg))

(defcustom earwig-dash " — "
  "The dash \"wrap TARGET in dashes\" puts on either side, with its spaces."
  :type 'string
  :group 'earwig)

;;;; Where text goes

(defun earwig--shape (range)
  "Return how the text of RANGE moves: `section', `lines', `paragraph' or `text'."
  (pcase (nth 4 range)
    ("section" 'section)
    ("paragraph" 'paragraph)
    (_ (if (nth 2 range) 'lines 'text))))

(defun earwig--ranges-shape (ranges)
  "Return the shape of RANGES, which must all be the same."
  (let ((shapes (delete-dups (mapcar #'earwig--shape ranges))))
    (when (cdr shapes)
      (user-error "Those are different kinds of text: %s"
                  (mapconcat #'symbol-name shapes ", ")))
    (car shapes)))

(defun earwig--section-gap ()
  "Return what goes between two sections: a blank line in Markdown."
  (if (derived-mode-p 'org-mode) "\n" "\n\n"))

(defun earwig--heading-there (pos)
  "Return (HEADING . HEADINGS) for the heading POS is under, or signal."
  (let ((headings (earwig--headings)))
    (cons (or (earwig--heading-at pos headings) (user-error "No heading there"))
          headings)))

(defun earwig--into-heading (heading headings gap)
  "Return (POS BEFORE AFTER) for text at the end of HEADING's own text.
GAP goes before it when there's text already; otherwise it's on a line
of its own, after Org's planning line and drawers.  HEADING is one of
HEADINGS."
  (pcase-let ((`(,beg ,end) (earwig--body heading headings)))
    (cond ((< beg end) (list end gap ""))
          ((save-excursion (goto-char beg) (bolp)) (list beg "" "\n"))
          (t (list beg "\n" "")))))

(defun earwig--item-column (pos)
  "Return the column the text of the list item at POS starts in."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (if (looking-at earwig--md-item-regexp)
        (- (or (match-beginning 5) (match-end 0)) (match-beginning 0))
      (current-indentation))))

(defun earwig--paragraph-edge (pos end)
  "Return the start of the paragraph at POS, or its END."
  (let ((range (ignore-errors (earwig--unit-at "paragraph" pos))))
    (cond (range (if end (cadr range) (car range)))
          (end (save-excursion (goto-char pos) (line-end-position)))
          (t (save-excursion (goto-char pos) (line-beginning-position))))))

(defun earwig--placement (kind range shape)
  "Return (POS BEFORE AFTER LEVEL INDENT) for text of SHAPE put KIND of RANGE.
KIND is `before', `after', `under', `start' or `end'; RANGE is the
target's.  The text goes at POS, BEFORE and AFTER around it.  LEVEL
is the level for a section's first heading, INDENT the column for
lines, or nil to leave them as they are."
  (pcase-let ((`(,beg ,end ,_ ,_ ,unit) range))
    (pcase shape
      ('section
       (pcase-let* ((`(,heading . ,headings) (earwig--heading-there beg))
                    (gap (earwig--section-gap))
                    (section-end (earwig--section-end heading headings))
                    (child (cl-find-if (lambda (h) (< (car heading) (car h) section-end))
                                       headings)))
         (pcase kind
           ('before (list (car heading) "" gap (cdr heading)))
           ('after (list section-end gap "" (cdr heading)))
           ((guard (and (eq kind 'start) child)) (list (car child) "" gap (1+ (cdr heading))))
           (_ (list section-end gap "" (1+ (cdr heading)))))))
      ('text
       (if (or (eq kind 'under) (and (equal unit "body") (= beg end)))
           ;; An empty body starts where the next heading does
           (pcase-let ((`(,heading . ,headings)
                        (earwig--heading-there (if (equal unit "body") (max (point-min) (1- beg)) beg))))
             (earwig--into-heading heading headings ""))
         (list (if (memq kind '(before start)) beg end) "" "")))
      (_
       (let ((gap (if (eq shape 'paragraph) "\n\n" "\n"))
             (indent (and (equal unit "item") (save-excursion (goto-char beg)
                                                              (current-indentation)))))
         (pcase kind
           ('under
            (if (equal unit "item")
                (list end "\n" "" nil (earwig--item-column beg))
              (pcase-let ((`(,heading . ,headings) (earwig--heading-there beg)))
                (append (earwig--into-heading heading headings gap) (list nil nil)))))
           ((or 'before 'start)
            (list (if (eq shape 'paragraph)
                      (earwig--paragraph-edge beg nil)
                    (save-excursion (goto-char beg) (line-beginning-position)))
                  "" gap nil indent))
           (_
            (list (if (eq shape 'paragraph)
                      (earwig--paragraph-edge end t)
                    (save-excursion (goto-char end) (line-end-position)))
                  gap "" nil indent))))))))

(defun earwig--range-text (range shape level headings)
  "Return the text of RANGE, of SHAPE; a section's headings moved to LEVEL.
HEADINGS are the buffer's, for a section."
  (pcase-let ((`(,beg ,end) range))
    (let ((text (buffer-substring-no-properties beg end)))
      (when (and (eq shape 'section) level)
        (let* ((inside (cl-remove-if-not (lambda (h) (<= beg (car h) end)) headings))
               (delta (if inside (- level (cdar inside)) 0))
               (char (if (derived-mode-p 'org-mode) ?* ?#)))
          (dolist (heading (reverse inside))
            (let ((offset (- (car heading) beg)))
              (setq text (concat (substring text 0 offset)
                                 (make-string (max 1 (+ (cdr heading) delta)) char)
                                 (substring text (+ offset (cdr heading)))))))))
      text)))

(defun earwig--ranges-text (ranges shape level)
  "Return the text of RANGES, of SHAPE, joined as SHAPE is.
LEVEL is for sections, see `earwig--range-text'."
  (let ((headings (and (eq shape 'section) (earwig--headings))))
    (mapconcat (lambda (range) (earwig--range-text range shape level headings))
               ranges
               (pcase shape
                 ('text " ")
                 ('paragraph "\n\n")
                 ('section (earwig--section-gap))
                 (_ "\n")))))

(defun earwig--squeeze-blank-lines (pos)
  "Leave at most one blank line around POS."
  (save-excursion
    (goto-char pos)
    (let ((beg (progn (skip-chars-backward " \t\n") (point)))
          (end (progn (skip-chars-forward " \t\n") (point))))
      (let ((newlines (cl-count ?\n (buffer-substring beg end))))
        (cond ((= end (point-max))
               (when (> newlines 1)
                 (delete-region beg end)
                 (unless (= beg (point-min))
                   (insert "\n"))))
              ((= beg (point-min))
               (delete-region beg end))
              ((> newlines 2)
               (delete-region beg end)
               (goto-char beg)
               (insert "\n\n")))))))

(defun earwig--delete-ranges (ranges shape)
  "Delete RANGES, of SHAPE, the last first, with the line breaks or space around."
  (pcase-dolist (`(,beg ,end) (reverse ranges))
    (pcase shape
      ((or 'lines 'section)
       (cond ((< end (point-max)) (delete-region beg (1+ end)))
             ((> beg (point-min)) (delete-region (1- beg) end))
             (t (delete-region beg end)))
       (earwig--squeeze-blank-lines (min beg (point-max))))
      ('paragraph
       (let ((after (save-excursion (goto-char end) (skip-chars-forward " \t\n") (point))))
         (if (< after (point-max))
             (delete-region beg after)
           (delete-region (save-excursion (goto-char beg) (skip-chars-backward " \t\n") (point))
                          end))))
      (_ (delete-region beg end)
         (earwig--tidy-gap beg)))))

(defun earwig--repair-list (pos)
  "In Org, renumber the list at POS, if there is one."
  (when (and (derived-mode-p 'org-mode) (fboundp 'org-list-repair))
    (save-excursion
      (goto-char (min pos (point-max)))
      (when (ignore-errors (org-at-item-p))
        (ignore-errors (org-list-repair))))))

(defun earwig--insert-placed (text shape placement)
  "Insert TEXT, of SHAPE, at PLACEMENT, from `earwig--placement'.
Returns (BEG . END) of TEXT as it went in."
  (pcase-let ((`(,pos ,before ,after ,_ ,indent) placement))
    (save-excursion
      (goto-char pos)
      (insert before)
      (let ((beg (point)))
        (insert text)
        (let ((end (point-marker)))
          (insert after)
          (when (and indent (memq shape '(lines paragraph)))
            (indent-rigidly beg end (- indent (save-excursion (goto-char beg)
                                                              (current-indentation)))))
          (when (eq shape 'text)
            (earwig--space-pasted beg end))
          (earwig--repair-list beg)
          (prog1 (cons (save-excursion (goto-char beg) (skip-chars-forward " " end) (point))
                       (marker-position end))
            (set-marker end nil)))))))

;;;; Moving and copying

(defun earwig--transfer (what destination delete)
  "Put the text of WHAT at DESTINATION; with DELETE, take it from where it was.
WHAT is an `earwig-target', DESTINATION an `earwig-destination' value."
  (barf-if-buffer-read-only)
  (pcase-let* ((ranges (earwig--ranges what))
               (shape (earwig--ranges-shape ranges))
               (`(,kind ,target) destination)
               (range (earwig--target target))
               (placement (earwig--placement kind range shape))
               (text (earwig--ranges-text ranges shape (nth 3 placement)))
               (pos (copy-marker (car placement))))
    (dolist (from ranges)
      (when (and delete (< (car from) pos (cadr from)))
        (user-error "It can't go inside itself")))
    (undo-boundary)
    (let ((put (save-excursion
                 (earwig--one-undo-step
                   (when delete
                     (earwig--delete-ranges ranges shape))
                   (earwig--insert-placed text shape (cons pos (cdr placement)))))))
      (set-marker pos nil)
      (earwig--done-with-region)
      (earwig--put (car put) (cdr put)))))

(defun earwig-cmd-move (what destination)
  "Move WHAT, an `earwig-target', to DESTINATION, an `earwig-destination' value."
  (earwig--transfer what destination t))

(defun earwig-cmd-copy-to (what destination)
  "Copy WHAT, an `earwig-target', to DESTINATION, an `earwig-destination' value."
  (earwig--transfer what destination nil))

(defun earwig-cmd-duplicate (what)
  "Put a copy of WHAT, an `earwig-target', right after it.
\"that\" is the copy then, the first if WHAT is several places."
  (barf-if-buffer-read-only)
  (let ((ranges (earwig--ranges what))
        put)
    (undo-boundary)
    (save-excursion
      (earwig--one-undo-step
        (dolist (range (reverse ranges))
          (let* ((shape (earwig--shape range))
                 (placement (earwig--placement 'after range shape)))
            (setq put (earwig--insert-placed
                       (earwig--ranges-text (list range) shape (nth 3 placement))
                       shape placement))))))
    (earwig--done-with-region)
    (earwig--put (car put) (cdr put))))

(defun earwig-cmd-swap (a b)
  "Swap the text of A and B, `earwig-target's.
Sections swap levels too."
  (barf-if-buffer-read-only)
  (let* ((ra (earwig--target a))
         (rb (earwig--target b))
         (first (if (< (car ra) (car rb)) ra rb))
         (second (if (eq first ra) rb ra))
         (sections (and (eq (earwig--shape ra) 'section) (eq (earwig--shape rb) 'section)))
         (headings (and sections (earwig--headings)))
         (level (lambda (range) (and sections (cdr (earwig--heading-at (car range) headings)))))
         (first-text (earwig--range-text first (earwig--shape first)
                                         (funcall level second) headings))
         (second-text (earwig--range-text second (earwig--shape second)
                                          (funcall level first) headings)))
    (when (> (cadr first) (car second))
      (user-error "Those overlap"))
    (undo-boundary)
    (let ((a-first (eq first ra))
          (beg (copy-marker (car first)))
          (end (copy-marker (cadr first) t)))
      (save-excursion
        (earwig--one-undo-step
          (goto-char (car second))
          (delete-region (car second) (cadr second))
          (insert first-text)
          (goto-char beg)
          (delete-region beg end)
          (insert second-text)))
      ;; "that" is where A went
      (let ((first-end (+ beg (length second-text))))
        (if a-first
            (let ((shift (- first-end (cadr first))))
              (earwig--put (+ (car second) shift) (+ (car second) shift (length first-text))))
          (earwig--put beg first-end)))
      (set-marker beg nil)
      (set-marker end nil)
      (earwig--done-with-region))))

(defun earwig-cmd-rewrite (target)
  "Delete TARGET, an `earwig-target', leaving point there to dictate in its place.
Of whole lines, a list item's bullet or a heading's stars stay, and the
dictation fills a heading or item as for a new one."
  (barf-if-buffer-read-only)
  (pcase-let ((`(,beg ,end ,line-p ,_ ,unit) (earwig--target target)))
    (when line-p
      (setq beg (save-excursion (goto-char beg) (earwig--line-prefix-end))))
    (undo-boundary)
    (earwig--done-with-region)
    (delete-region beg end)
    (goto-char beg)
    (unless (or line-p (member unit '("heading" "section" "item")))
      (earwig--tidy-gap beg))
    (pcase unit
      ;; Dictation fills them as a new heading or item, with a capital
      ((or "heading" "section") (earwig--open-structure-here 'heading))
      ("item" (earwig--open-structure-here 'item))
      (_ (earwig--insert-state)))))

;;;; Pairs around text

(defconst earwig--pairs
  '((quotes "[\"“]" "[\"”]")
    (single-quotes "['‘]" "['’]")
    (parentheses "(" ")")
    (square-brackets "\\[" "]")
    (dashes "[ \t]*\\(?:—\\|–\\|--\\)[ \t]*" "[ \t]*\\(?:—\\|–\\|--\\)[ \t]*")
    (commas "," ","))
  "Pairs of marks as (PAIR OPEN CLOSE): regexps for the marks found around text.")

(defun earwig--typographic-p ()
  "Non-nil if the buffer has typographic quotes or apostrophes."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "[“”‘’]" nil t)))

(defun earwig--pair-marks (pair)
  "Return (OPEN . CLOSE), the marks to put in for PAIR here."
  (pcase pair
    ('quotes (if (earwig--typographic-p) '("“" . "”") '("\"" . "\"")))
    ('single-quotes (if (earwig--typographic-p) '("‘" . "’") '("'" . "'")))
    ('parentheses '("(" . ")"))
    ('square-brackets '("[" . "]"))
    ('dashes (cons earwig-dash earwig-dash))
    ('commas '(", " . ", "))))

(defun earwig--wrap (pair beg end)
  "Put PAIR around BEG to END; return (BEG . END) of it with its marks.
Dashes and commas take the place of the spaces around it, and none goes
at the start or end of a line, or before punctuation."
  (pcase-let ((`(,open . ,close) (earwig--pair-marks pair))
              (separator (memq pair '(dashes commas))))
    (save-excursion
      (goto-char end)
      (cond ((not separator) (insert close))
            ((looking-at-p "[ \t]*\\([.,;:!?)]\\|$\\)"))
            (t (delete-region (point) (progn (skip-chars-forward " \t") (point)))
               (insert close)))
      (setq end (point))
      (goto-char beg)
      (cond ((not separator) (insert open))
            ((save-excursion (skip-chars-backward " \t") (or (bolp) (memq (char-before) '(?, ?\;))))
             (setq open ""))
            (t (let ((space (- (point) (progn (skip-chars-backward " \t") (point)))))
                 (delete-region (point) (+ (point) space))
                 (setq end (- end space))
                 (setq beg (point))
                 (insert open))))
      (cons beg (+ end (length open))))))

(defun earwig--word-before-p (pos)
  "Non-nil if a letter or digit is right before POS."
  (earwig--letter-p (char-before pos)))

(defun earwig--pair-around (pair beg end)
  "Return (OBEG OEND CBEG CEND), PAIR's marks around BEG to END, or nil.
In the paragraph; brackets nest.  A target that starts and ends with
the marks has them."
  (pcase-let* ((`(,open ,close) (alist-get pair earwig--pairs))
               (limits (save-excursion
                         (cons (progn (goto-char beg) (backward-paragraph) (point))
                               (progn (goto-char end) (forward-paragraph) (point)))))
               (quote-p (memq pair '(quotes single-quotes)))
               (ok (lambda (at-open)
                     ;; Not an apostrophe: no letter on the inner side's other side
                     (or (not quote-p)
                         (if at-open
                             (not (earwig--word-before-p (match-beginning 0)))
                           (not (earwig--letter-p (char-after (match-end 0)))))))))
    (save-excursion
      (let ((case-fold-search nil))
        (or
         (and (memq pair '(dashes commas))
              (earwig--separators-around pair beg end))
         ;; The marks are the target's own ends
         (and (progn (goto-char beg) (looking-at open))
              (let ((obeg (match-beginning 0)) (oend (match-end 0)))
                (and (progn (goto-char end) (looking-back close beg))
                     (< oend (match-beginning 0))
                     (list obeg oend (match-beginning 0) (match-end 0)))))
         (let ((nest (memq pair '(parentheses square-brackets)))
               obeg oend)
           (goto-char beg)
           (let ((depth 0))
             (while (and (not obeg)
                         (re-search-backward (if nest (concat open "\\|" close) open)
                                             (car limits) t))
               (cond ((and nest (looking-at close)) (cl-incf depth))
                     ((and nest (> depth 0)) (cl-decf depth))
                     ((funcall ok t) (setq obeg (match-beginning 0) oend (match-end 0))))))
           (when obeg
             (goto-char end)
             (let ((depth 0) found)
               (while (and (not found)
                           (re-search-forward (if nest (concat open "\\|" close) close)
                                              (cdr limits) t))
                 (save-excursion
                   (goto-char (match-beginning 0))
                   (cond ((and nest (looking-at open)) (cl-incf depth))
                         ((and nest (> depth 0)) (cl-decf depth))
                         ((progn (looking-at close) (funcall ok nil))
                          (setq found (list obeg oend (match-beginning 0) (match-end 0)))))))
               (if (and found (eq pair 'dashes))
                   ;; A dash's spaces go with it
                   (pcase-let ((`(,obeg ,oend ,cbeg ,cend) found))
                     (list (progn (goto-char obeg) (skip-chars-backward " \t") (point))
                           (progn (goto-char oend) (skip-chars-forward " \t") (point))
                           (progn (goto-char cbeg) (skip-chars-backward " \t") (point))
                           (progn (goto-char cend) (skip-chars-forward " \t") (point))))
                 found)))))))))

(defun earwig--separators-around (pair beg end)
  "Return (OBEG OEND CBEG CEND), the dashes or commas (PAIR) around BEG to END.
Only spaces between them and the text.  At the end of a sentence or
line there's no closing one, so CBEG and CEND are END then; at the
start of a line, no opening one.  A dash's marks have its spaces."
  (let ((mark (if (eq pair 'dashes) "\\(?:—\\|–\\|--\\)" ","))
        open close)
    (save-excursion
      (goto-char beg)
      (skip-chars-backward " \t")
      (cond ((looking-back mark (line-beginning-position))
             (setq open (list (if (eq pair 'dashes)
                                  (save-excursion (goto-char (match-beginning 0))
                                                  (skip-chars-backward " \t")
                                                  (point))
                                (match-beginning 0))
                              (if (eq pair 'dashes) beg (match-end 0)))))
            ((bolp) (setq open (list beg beg))))
      (goto-char end)
      (cond ((looking-at (concat "[ \t]*" mark))
             (setq close (list (if (eq pair 'dashes) end (match-beginning 0))
                               (if (eq pair 'dashes)
                                   (progn (goto-char (match-end 0))
                                          (skip-chars-forward " \t")
                                          (point))
                                 (match-end 0)))))
            ((looking-at-p "[ \t]*\\([.;:!?)]\\|$\\)") (setq close (list end end)))))
    (and open close
         (or (< (car open) (cadr open)) (< (car close) (cadr close)))
         (append open close))))

(defun earwig--any-pair-around (beg end)
  "Return (PAIR OBEG OEND CBEG CEND), the nearest quotes or brackets around.
Around BEG to END."
  (let (best)
    (dolist (pair '(quotes single-quotes parentheses square-brackets))
      (let ((found (earwig--pair-around pair beg end)))
        (when (and found (or (null best) (> (car found) (nth 1 best))))
          (setq best (cons pair found)))))
    best))

(defun earwig--unwrap (pair marks)
  "Take off PAIR's MARKS, (OBEG OEND CBEG CEND); return the text's (BEG . END)."
  (pcase-let ((`(,obeg ,oend ,cbeg ,cend) marks))
    (let ((between (lambda (beg end)
                         ;; A dash between words leaves a space
                     (if (and (eq pair 'dashes)
                              (save-excursion (goto-char beg) (not (bolp)))
                              (save-excursion (goto-char end)
                                              (not (looking-at-p "[ \t]*\\([.,;:!?)]\\|$\\)"))))
                         " " ""))))
      (let ((close (funcall between cbeg cend))
            (open (funcall between obeg oend)))
        (save-excursion
          (goto-char cbeg)
          (delete-region cbeg cend)
          (insert close)
          (goto-char obeg)
          (delete-region obeg oend)
          (insert open))
        (earwig--trim (+ obeg (length open))
                      (+ obeg (length open) (- cbeg oend)))))))

(defun earwig--marks-around (pair target)
  "Return (PAIR . MARKS) of PAIR around TARGET, an `earwig-target', or signal.
Nil PAIR is the nearest quotes or brackets."
  (pcase-let ((`(,beg ,end) (earwig--target target)))
    (or (if pair
            (let ((marks (earwig--pair-around pair beg end)))
              (and marks (cons pair marks)))
          (earwig--any-pair-around beg end))
        (user-error "No %s around it" (if pair (string-replace "-" " " (symbol-name pair))
                                        "quotes or brackets")))))

(defun earwig-cmd-wrap (pair target)
  "Put PAIR around TARGET, an `earwig-target', each place it is."
  (barf-if-buffer-read-only)
  (let* ((ranges (earwig--ranges target))
         ;; Point at the end of what's wrapped stays after the marks
         (pt (copy-marker (point) (cl-some (lambda (range) (= (point) (cadr range))) ranges)))
         put)
    (undo-boundary)
    (earwig--one-undo-step
      (pcase-dolist (`(,beg ,end) (reverse ranges))
        (setq put (earwig--wrap pair beg end))))
    (goto-char pt)
    (set-marker pt nil)
    (earwig--done-with-region)
    (earwig--put (car put) (cdr put))))

(defun earwig-cmd-unwrap (pair target)
  "Take PAIR off from around TARGET, an `earwig-target'.
Nil PAIR is the nearest quotes or brackets."
  (barf-if-buffer-read-only)
  (pcase-let ((`(,pair . ,marks) (earwig--marks-around pair target)))
    (undo-boundary)
    (let ((text (earwig--unwrap pair marks)))
      (earwig--done-with-region)
      (earwig--put (car text) (cdr text)))))

(defun earwig-cmd-rewrap (old target new)
  "Replace the pair OLD around TARGET, an `earwig-target', with the pair NEW."
  (barf-if-buffer-read-only)
  (pcase-let ((`(,old . ,marks) (earwig--marks-around old target)))
    (undo-boundary)
    (let ((put (earwig--one-undo-step
                 (pcase-let ((`(,beg . ,end) (earwig--unwrap old marks)))
                   (earwig--wrap new beg end)))))
      (earwig--done-with-region)
      (earwig--put (car put) (cdr put)))))

;;;; Making room, going in

(defun earwig--insert-state ()
  "Enter evil's insert state, if it's in normal or visual state."
  (when (and (bound-and-true-p evil-local-mode) (memq evil-state '(normal visual)))
    (evil-insert-state)))

(defun earwig--open-structure-here (kind)
  "Have the next dictation fill the heading or item (KIND) made at point."
  (setq earwig--open-structure (cons (copy-marker (point)) kind))
  (earwig--insert-state))

(defun earwig--new-heading (where heading)
  "Make a heading WHERE (`before', `after' or `under') HEADING, at point."
  (pcase where
    ('before
     (goto-char (car heading))
     (insert (make-string (cdr heading) (if (derived-mode-p 'org-mode) ?* ?#)) " ")
     (save-excursion (insert "\n" (if (derived-mode-p 'org-mode) "" "\n")))
     (earwig--open-structure-here 'heading))
    (_
     (goto-char (car heading))
     (end-of-line)
     (earwig-cmd-structure (if (eq where 'under) 'subheading 'heading) nil))))

(defun earwig--new-item (where item)
  "Make a list item WHERE (`before', `after' or `under') ITEM, (START . END)."
  (pcase where
    ('before
     (goto-char (car item))
     (looking-at earwig--md-item-regexp)
     (let ((indent (match-string 1))
           (bullet (or (match-string 2) (concat (match-string 3) (match-string 4))))
           (checkbox (and (match-beginning 5) "[ ] ")))
       (insert indent bullet " " (or checkbox ""))
       (save-excursion (insert "\n"))
       (earwig--repair-list (point))
       (earwig--open-structure-here 'item)))
    (_
     (goto-char (car item))
     (end-of-line)
     (earwig-cmd-structure (if (eq where 'under) 'sub-item 'item) nil))))

(defun earwig--new-paragraph (where range)
  "Make an empty paragraph WHERE (`before', `after' or `under') RANGE, at point.
Next to a paragraph, section or list item, beside it; in other text,
splitting its paragraph there; under a heading, at the end of its text."
  (pcase-let ((`(,beg ,end ,line-p ,_ ,unit) range))
    (if (eq where 'under)
        (pcase-let* ((`(,heading . ,headings) (earwig--heading-there beg))
                     (`(,pos ,before) (earwig--into-heading heading headings "\n\n")))
          (goto-char pos)
          (insert before)
          (save-excursion (insert (if (equal before "") "\n" ""))))
      (let ((block (or line-p (member unit '("paragraph" "section" "item" "body")))))
        (goto-char (cond ((not block) (if (eq where 'before) beg end))
                         ((eq where 'before) (earwig--paragraph-edge beg nil))
                         (t (earwig--paragraph-edge end t))))
        (unless block
          (delete-horizontal-space))
        (cond ((eq where 'before)
               (save-excursion (insert (if block "\n\n" "\n\n\n\n")))
               (unless block (forward-char 2)))
              (t
               (insert "\n\n")
               (unless block
                 (save-excursion (insert "\n\n")))))))
    (earwig--insert-state)))

(defun earwig-cmd-new-at (what where target)
  "Make a WHAT, WHERE TARGET, an `earwig-target', for dictation to fill.
WHAT is `paragraph', `item', `heading' or `subheading'; WHERE is
`before', `after' or `under'."
  (barf-if-buffer-read-only)
  (let ((range (earwig--target target)))
    (undo-boundary)
    (push-mark nil t)
    (earwig--done-with-region)
    (pcase what
      ('paragraph (earwig--new-paragraph where range))
      ('item
       (unless (earwig--structure-mode-p)
         (user-error "No lists in %s" major-mode))
       (earwig--new-item where (or (earwig--item-at (car range) (earwig--items))
                                   (user-error "No list item there"))))
      (_
       (earwig--new-heading (if (eq what 'subheading) 'under where)
                            (car (earwig--heading-there (car range))))))))

(defun earwig--into (range)
  "Return where text goes at the end of RANGE's own text.
Opens a line for it if need be.
A heading's own text ends before its first subheading, a list item's
before its first sub-item."
  (pcase-let ((`(,beg ,end ,_ ,_ ,unit) range))
    (cond
     ((or (member unit '("heading" "section" "body"))
          (and (earwig--structure-mode-p)
               (let ((heading (earwig--heading-at beg (earwig--headings))))
                 (and heading (= (car heading) (save-excursion (goto-char beg)
                                                               (line-beginning-position)))))))
      (pcase-let* ((`(,heading . ,headings) (earwig--heading-there beg))
                   (`(,pos ,before ,after) (earwig--into-heading heading headings "")))
        (goto-char pos)
        (insert before)
        (save-excursion (insert after))
        (point)))
     ((equal unit "item")
      (save-excursion
        (goto-char beg)
        (let ((own (line-end-position)))
          (while (and (zerop (forward-line 1)) (< (point) end) (not (earwig--item-line-p)))
            (unless (looking-at-p "[ \t]*$")
              (setq own (line-end-position))))
          own)))
     (t end))))

(defun earwig-cmd-go-into (target)
  "Go to the end of TARGET's own text, an `earwig-target', to add to it."
  (let ((range (earwig--target target)))
    (push-mark nil t)
    (earwig--done-with-region)
    (goto-char (earwig--into range))
    (earwig--insert-state)))

;;;; Links, focus, where

(defun earwig--link-in (range)
  "Return (BEG . END) of the first link in RANGE, or around it, or nil."
  (pcase-let ((`(,beg ,end) range))
    (cl-find-if (lambda (link) (and (<= (car link) end) (>= (cdr link) beg)))
                (earwig--links))))

(defun earwig--link-url (link)
  "Return the URL or file LINK, (BEG . END), points to, outside Org."
  (let ((text (buffer-substring-no-properties (car link) (cdr link))))
    (cond ((string-match "\\](\\([^) ]*\\)" text) (match-string 1 text))
          ((string-match "\\`<\\(.*\\)>\\'" text) (match-string 1 text))
          (t text))))

(defun earwig-cmd-open-link (target &optional in)
  "Open the link TARGET, an `earwig-target', is; or with IN, the first in it."
  (let* ((range (earwig--target target))
         (link (or (if (or in (not (equal (nth 4 range) "link")))
                       (earwig--link-in range)
                     (cons (car range) (cadr range)))
                   (user-error "No link there"))))
    (push-mark nil t)
    (goto-char (car link))
    (cond ((derived-mode-p 'org-mode) (org-open-at-point))
          ((and (derived-mode-p 'markdown-mode) (fboundp 'markdown-follow-thing-at-point))
           (markdown-follow-thing-at-point nil))
          (t (let ((url (earwig--link-url link)))
               (if (string-match-p "\\`[a-z]+:" url)
                   (browse-url url)
                 (find-file url)))))))

(defun earwig-cmd-focus (target)
  "Show only TARGET, an `earwig-target': narrow to it."
  (let* ((ranges (earwig--ranges target))
         (beg (car (car ranges)))
         (last (car (last ranges)))
         (end (if (and (nth 2 last) (< (cadr last) (point-max))) (1+ (cadr last)) (cadr last))))
    (when (nth 2 (car ranges))
      (setq beg (save-excursion (goto-char beg) (line-beginning-position))))
    (earwig--done-with-region)
    (unless (<= beg (point) end)
      (goto-char beg))
    (narrow-to-region beg end)))

(defun earwig-cmd-where (target)
  "Flash TARGET, an `earwig-target', going there if it's out of sight."
  (let ((ranges (earwig--ranges target))
        (window (get-buffer-window)))
    (unless (and window (pos-visible-in-window-p (car (car ranges)) window))
      (push-mark nil t)
      (goto-char (car (car ranges)))
      (when (eq window (selected-window))
        (recenter)))
    (pcase-dolist (`(,beg ,end) ranges)
      (earwig--flash beg (max end (min (1+ beg) (point-max)))))
    (when (cdr ranges)
      (message "%d places" (length ranges)))))

;;;; The commands' grammar

(phony-define-dictionary earwig-pair
  "A pair of marks to put around text; its value is a symbol of `earwig--pairs'."
  '(("quotes" . quotes) ("quote marks" . quotes) ("quotation marks" . quotes)
    ("double quotes" . quotes)
    ("single quotes" . single-quotes)
    ("parentheses" . parentheses) ("parens" . parentheses) ("brackets" . parentheses)
    ("round brackets" . parentheses)
    ("square brackets" . square-brackets)
    ("dashes" . dashes)
    ("commas" . commas)))

(earwig-defcommand earwig-say-move ("move" (what earwig-target) (to earwig-destination))
  "Move WHAT to TO."
  :help "move TARGET before | after | under TARGET, or to the start | end of TARGET"
  (earwig-cmd-move what to))

(earwig-defcommand earwig-say-copy-to ("copy" (what earwig-target) (to earwig-destination))
  "Copy WHAT to TO."
  :help "copy TARGET before | after | under TARGET, or to the start | end of TARGET"
  (earwig-cmd-copy-to what to))

(earwig-defcommand earwig-say-swap ("swap" (a earwig--one-target) "with" (b earwig--one-target))
  "Swap A with B."
  :help "swap TARGET with TARGET"
  (earwig-cmd-swap a b))

(earwig-defcommand earwig-say-duplicate ("duplicate" (what earwig-target))
  "Put a copy of WHAT after it."
  :help "duplicate TARGET"
  (earwig-cmd-duplicate what))

(earwig-defcommand earwig-say-rewrite ("rewrite" (what earwig--one-target))
  "Delete WHAT, to dictate in its place."
  :help "rewrite TARGET         (delete it, and dictate in its place)"
  :go t
  (earwig-cmd-rewrite what))

(earwig-defcommand earwig-say-put-around ("put" (pair earwig-pair) "around" (what earwig-target))
  "Put PAIR around WHAT."
  :help "put PAIR around TARGET, wrap TARGET in PAIR
      (PAIR: quotes, single quotes, parentheses, brackets, square brackets, dashes, commas)"
  (earwig-cmd-wrap pair what))

(earwig-defcommand earwig-say-wrap ("wrap" (what earwig-target) "in" (pair earwig-pair))
  "Put PAIR around WHAT."
  (earwig-cmd-wrap pair what))

(earwig-defcommand earwig-say-unwrap ("unwrap" (what earwig--one-target))
  "Take the nearest quotes or brackets off from around WHAT."
  :help "remove the PAIR around TARGET, unwrap TARGET"
  :check (earwig--marks-around nil what)
  (earwig-cmd-unwrap nil what))

(earwig-defcommand earwig-say-remove-pair ("remove" (? "the") (pair earwig-pair) "around"
                                           (what earwig--one-target))
  "Take PAIR off from around WHAT."
  :check (earwig--marks-around pair what)
  (earwig-cmd-unwrap pair what))

(earwig-defcommand earwig-say-replace-pair ("replace" (? "the") (old earwig-pair) "around"
                                            (what earwig--one-target) "with" (new earwig-pair))
  "Replace the pair OLD around WHAT with NEW."
  :help "replace the PAIR around TARGET with PAIR, change the PAIR around TARGET to PAIR"
  :check (earwig--marks-around old what)
  (earwig-cmd-rewrap old what new))

(earwig-defcommand earwig-say-change-pair ("change" (? "the") (old earwig-pair) "around"
                                           (what earwig--one-target) "to" (new earwig-pair))
  "Replace the pair OLD around WHAT with NEW."
  :check (earwig--marks-around old what)
  (earwig-cmd-rewrap old what new))

(earwig-defcommand earwig-say-new-at ((| "new" "add a" "add an")
                                      (what (| "paragraph" "item" "bullet" "heading"))
                                      (where (| "before" "after" "under"))
                                      (target earwig--one-target))
  "Make a WHAT WHERE TARGET, for dictation to fill."
  :help "new | add a paragraph | item | heading before | after | under TARGET,
      new subheading under TARGET"
  :go t
  (earwig-cmd-new-at (if (equal what "bullet") 'item (intern what)) (intern where) target))

(earwig-defcommand earwig-say-new-subheading ((| "new" "add a") (| "subheading" "sub heading")
                                              "under" (target earwig--one-target))
  "Make a subheading under TARGET, for dictation to fill."
  :go t
  (earwig-cmd-new-at 'subheading 'under target))

(earwig-defcommand earwig-say-go-into ((| "go into" "add to") (target earwig--one-target))
  "Go to the end of TARGET's own text."
  :help "go into TARGET, add to TARGET  (the end of a heading's own text)"
  :go t
  (earwig-cmd-go-into target))

(earwig-defcommand earwig-say-open-link ("open" (link earwig-part))
  "Open LINK, as \"the link with roadmap\"."
  :help "open the link with WORDS, open that link, open the link in TARGET"
  :check (equal (nth 4 (earwig--target link)) "link")
  (earwig-cmd-open-link link))

(earwig-defcommand earwig-say-open-that-link ("open" (| "that" "this" "it") "link")
  "Open the link in what went in last, or the selection."
  (earwig-cmd-open-link (earwig--target-make '(that)) t))

(earwig-defcommand earwig-say-open-link-in ("open the link in" (target earwig--one-target))
  "Open the first link in TARGET."
  :check (earwig--link-in (earwig--target target))
  (earwig-cmd-open-link target t))

(earwig-defcommand earwig-say-focus ((| "focus on" "narrow to") (target earwig-target))
  "Show only TARGET."
  :help "focus on TARGET, narrow to TARGET; show everything, widen"
  (earwig-cmd-focus target))

(earwig-defcommand earwig-say-widen ((| "show everything" "widen"))
  "Show the whole buffer again."
  (widen))

(earwig-defcommand earwig-say-where ((| "where is" "show me") (target earwig-target))
  "Flash TARGET, going there if it's out of sight."
  :help "where is TARGET, show me TARGET"
  :go t
  (earwig-cmd-where target))

(provide 'earwig-move)
;;; earwig-move.el ends here
