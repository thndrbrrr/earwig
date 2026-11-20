;;; earwig-structure.el --- Headings and lists by voice, in Org and Markdown  -*- lexical-binding: t; -*-

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

;; Commands, also said inside dictation (see below):
;;   new heading [TEXT]          a heading at the level of the one point
;;                               is under, in it or in its body, after
;;                               its subtree
;;   new subheading [TEXT]       one level deeper, as its last child
;;   new item | bullet [TEXT]    the next item of the list point is in,
;;                               after the item's own sub-items; outside
;;                               a list, starts a "- " list on the next
;;                               line ("new list", "start a list" too)
;;   new sub item [TEXT]         an item one level deeper
;;   new checkbox [TEXT]         an item with a "[ ] " checkbox
;; As commands "next heading" and "next item | bullet" work too.  A
;; numbered list goes on numbering, and an item gets a checkbox when the
;; one before has one.  TEXT goes there, with a capital: "new heading
;; introduction".  In Org these use Org's own commands, so the blank lines
;; and numbering follow Org's settings; in Markdown they work on # headings
;; outside code blocks and on -, +, * and numbered lists.
;;
;; Inside dictation the same phrases work where they start a sentence or
;; follow a comma, as Orukeet writes a pause before one: "That's all.
;; New heading. Next steps. First we..."; "a new item" stays words, and
;; so does "literal new item".  The first sentence after "new heading" is
;; the heading, without its period, and the rest goes into its body; a
;; single sentence after "new item" loses its period.  That carries over
;; to the next dictation or streamed segment, so "New heading." can be
;; said on its own.  Only in Org and Markdown buffers.  Like "new
;; paragraph", these write forward where dictation goes, so they need no
;; wake word; what changes text already there needs one.
;;
;; In any buffer, as a command:
;;   join [the] last sentence    join it to the one before
;;   join [the] last N sentences make them one (N as a word or digits)
;;   ... with [a] comma          with a comma where each sentence ended
;; The sentence that follows loses its capital, unless it's a name or
;; "I"; sentences aren't joined across a blank line or into a list item
;; or heading.  So when a pause split a sentence while streaming, "okay,
;; join last sentence" mends it without leaving dictation (see
;; `earwig-wake-word-commands').
;;
;; `earwig-dictation-structure' nil keeps the heading and list phrases as
;; words in dictation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'earwig-cleanup)

(defvar earwig--last-dictation)
(defvar evil-state)
(defvar org-M-RET-may-split-line)
(declare-function org-insert-heading-respect-content "org" (&optional invisible-ok))
(declare-function org-insert-subheading "org" (arg))
(declare-function org-insert-item "org-list" (&optional checkbox))
(declare-function org-in-item-p "org-list" ())
(declare-function org-indent-item "org-list" ())
(declare-function org-at-item-checkbox-p "org-list" ())
(declare-function markdown-code-block-at-pos "markdown-mode" (pos))
(declare-function evil-insert-state "evil-states" (&optional arg))
(declare-function earwig-parse-number "earwig-commands" (text &optional whole noerror))

(defcustom earwig-dictation-structure t
  "Non-nil to act on heading and list item phrases in dictation.
See the commentary of earwig-structure.el."
  :type 'boolean
  :group 'earwig)

(defconst earwig--structure-actions
  '((heading "new heading")
    (subheading "new subheading" "new sub heading" "new sub-heading")
    (item "new item" "new bullet" "new list" "start a list")
    (sub-item "new sub item" "new subitem" "new sub-item" "new sub bullet")
    (checkbox "new checkbox" "new check box"))
  "Structure phrases, in dictation and as commands, as (ACTION PHRASE...).")

(defconst earwig--structure-command-actions
  (append earwig--structure-actions
          '((heading "next heading")
            (item "next item" "next bullet")))
  "Structure phrases as commands: also ones too common in speech to dictate.")

(defvar earwig--open-structure nil
  "(MARKER . KIND) of a heading or item just made, for the text that goes in.
KIND is `heading' or `item', or `body' once a heading has its text.
Dictation inserted at MARKER fills it.")

(defun earwig--structure-mode-p ()
  "Non-nil if this buffer has headings and lists to make."
  (derived-mode-p 'org-mode 'markdown-mode))

;;;; Markdown

(defconst earwig--md-item-regexp
  "^\\([ \t]*\\)\\(?:\\([-+*]\\)\\|\\([0-9]+\\)\\([.)]\\)\\)[ \t]+\\(\\[[ xX]\\][ \t]+\\)?"
  "A Markdown list item: indentation, bullet or number and delimiter, checkbox.")

(defun earwig--md-code-p (pos)
  "Non-nil if POS is in a Markdown code block."
  (save-match-data
    (syntax-propertize (min (point-max) (1+ pos)))
    (markdown-code-block-at-pos pos)))

(defun earwig--md-heading-at ()
  "Return (POS . LEVEL) of the # heading point is under, or nil."
  (save-excursion
    (end-of-line)
    (let (found)
      (while (and (not found) (re-search-backward "^\\(#+\\)[ \t]" nil t))
        (let ((level (length (match-string 1))))
          (unless (earwig--md-code-p (point))
            (setq found (cons (point) level)))))
      found)))

(defun earwig--md-section-end (from level)
  "Return where the section of a LEVEL heading at FROM ends.
That's before the next heading at LEVEL or above, or the end of the buffer."
  (save-excursion
    (goto-char from)
    (end-of-line)
    (let (end)
      (while (and (not end) (re-search-forward (format "^#\\{1,%d\\}[ \t]" level) nil t))
        (unless (earwig--md-code-p (match-beginning 0))
          (setq end (match-beginning 0))))
      (or end (point-max)))))

(defun earwig--md-heading (deeper)
  "Make a Markdown heading after the section point is in, DEEPER levels down.
Without a heading above, a level 1 heading after the current line."
  (let* ((at (earwig--md-heading-at))
         (level (if at (min 6 (+ (cdr at) deeper)) 1)))
    (if at
        (goto-char (earwig--md-section-end (car at) (cdr at)))
      (end-of-line))
    (skip-chars-backward " \t\n")
    (unless (bobp)
      (insert "\n\n"))
    (insert (make-string level ?#) " ")
    (unless (looking-at-p "\n*\\'\\|\n[ \t]*\n")
      (save-excursion (insert "\n")))))

(defun earwig--md-item-start ()
  "Return the start of the Markdown list item point is in, or nil."
  (save-excursion
    (beginning-of-line)
    (catch 'done
      (while t
        (cond ((looking-at-p earwig--md-item-regexp) (throw 'done (point)))
              ((looking-at-p "[ \t]*$"))
              ((not (looking-at-p "[ \t]")) (throw 'done nil)))
        (when (bobp) (throw 'done nil))
        (forward-line -1)))))

(defun earwig--md-item-end (start)
  "Return the end of the item at START, with its continuation and sub-items."
  (save-excursion
    (goto-char start)
    (let ((indent (current-indentation))
          (end (line-end-position)))
      (while (and (zerop (forward-line 1)) (not (eobp))
                  (or (looking-at-p "[ \t]*$") (> (current-indentation) indent)))
        (unless (looking-at-p "[ \t]*$")
          (setq end (line-end-position))))
      end)))

(defun earwig--md-item (action)
  "Make the next Markdown list item for ACTION, or start a list."
  (let ((start (earwig--md-item-start)))
    (if (not start)
        (earwig--start-list (eq action 'checkbox))
      (goto-char start)
      (looking-at earwig--md-item-regexp)
      (let ((indent (match-string 1))
            (bullet (match-string 2))
            (number (match-string 3))
            (delim (match-string 4))
            (checkbox (or (eq action 'checkbox) (match-beginning 5)))
            (content (- (or (match-beginning 5) (match-end 0)) (match-beginning 0))))
        (goto-char (earwig--md-item-end start))
        (insert "\n"
                (if (eq action 'sub-item) (make-string content ?\s) indent)
                (cond ((and number (eq action 'sub-item)) (concat "1" delim))
                      (number (format "%d%s" (1+ (string-to-number number)) delim))
                      (t bullet))
                " "
                (if checkbox "[ ] " ""))))))

;;;; Both

(defun earwig--start-list (checkbox)
  "Start a \"- \" list on the next line, or on this one if it's empty.
With CHECKBOX, the item gets a \"[ ] \".  In Markdown, a list after a
paragraph gets a blank line before it."
  (end-of-line)
  (unless (string-blank-p (buffer-substring (line-beginning-position) (point)))
    (insert (if (and (derived-mode-p 'markdown-mode)
                     (not (save-excursion (beginning-of-line)
                                          (looking-at-p (concat earwig--md-item-regexp
                                                                "\\|#+[ \t]")))))
                "\n\n"
              "\n")))
  (delete-horizontal-space)
  (insert "- " (if checkbox "[ ] " "")))

(defun earwig-structure-do (action)
  "Do what ACTION from `earwig--structure-action' says, here.
Leaves point where text goes next."
  (barf-if-buffer-read-only)
  (unless (earwig--structure-mode-p)
    (user-error "No headings or lists in %s" major-mode))
  (pcase action
    ('heading (if (derived-mode-p 'org-mode)
                  (org-insert-heading-respect-content)
                (earwig--md-heading 0)))
    ('subheading (if (derived-mode-p 'org-mode)
                     (org-insert-subheading '(4))
                   (earwig--md-heading 1)))
    (_ (if (not (derived-mode-p 'org-mode))
           (earwig--md-item action)
         (let ((item (org-in-item-p)))
           (if (not item)
               (earwig--start-list (eq action 'checkbox))
             (let ((checkbox (or (eq action 'checkbox)
                                 (save-excursion (goto-char item) (org-at-item-checkbox-p))))
                   (org-M-RET-may-split-line nil))
               (org-insert-item checkbox)
               (when (eq action 'sub-item)
                 (org-indent-item)))))))))

;;;; Dictation

(defun earwig--structure-action (phrase actions)
  "The action of ACTIONS that PHRASE, as transcribed, is said for."
  (let ((phrase (string-join (split-string (downcase phrase) "[ \t\n,;:]+" t) " ")))
    (car (cl-find-if (lambda (entry) (member phrase (cdr entry))) actions))))

(defun earwig-structure-parts (text &optional actions)
  "Split dictated TEXT at structure phrases into a list of strings and actions.
A phrase counts at the start of TEXT or after Orukeet's punctuation; a
sentence end before it stays with the text before, a comma goes, and so
does the punctuation after it.  After `earwig-literal-word' it stays
words.  ACTIONS are the phrases, by default all of them."
  (let* ((actions (or actions earwig--structure-actions))
         (phrases (sort (mapcan (lambda (entry) (copy-sequence (cdr entry))) actions)
                        (lambda (a b) (> (length a) (length b)))))
         (regexp (concat "\\(?:\\`\\|\\([.?!,;:]\\)\\)[ \t]*\\(\\(?:\\("
                         (regexp-quote earwig-literal-word) "\\)[ \t]+\\)?\\("
                         (mapconcat (lambda (phrase)
                                      (earwig--correction-regexp phrase "[,;:]?[ \t\n]+"))
                                    phrases "\\|")
                         "\\)\\)[.?!,;:]*[ \t]*"))
         (case-fold-search t)
         (start 0) (from 0) parts)
    (while (and (< start (length text)) (string-match regexp text start))
      (if (match-beginning 3)
          ;; Literal: drop the word, keep the phrase as text
          (let* ((literal-start (match-beginning 3))
                 (phrase-end (match-end 4))
                 (phrase (substring text (match-beginning 4) phrase-end))
                 (case-fold-search nil))
            ;; "Literal new heading" passes its capital on
            (when (string-match-p "\\`[[:upper:]]" (match-string 3 text))
              (setq phrase (earwig--capitalize-first phrase)))
            (setq start (+ literal-start (length phrase))
                  text (concat (substring text 0 literal-start) phrase
                               (substring text phrase-end))))
        (let* ((beg (match-beginning 0))
               (end (match-end 0))
               (punct (match-string 1 text))
               ;; Last, as it changes the match data
               (action (earwig--structure-action (match-string 4 text) actions)))
          (push (concat (substring text from beg)
                        (if (member punct '("." "?" "!")) punct ""))
                parts)
          (push action parts)
          (setq from end
                start (max (1+ start) end)))))
    (push (substring text from) parts)
    (cl-remove-if (lambda (part) (and (stringp part) (string-blank-p part)))
                  (nreverse parts))))

(defun earwig-structure-split (text buffer pos)
  "Return the parts of dictated TEXT for BUFFER at POS, or nil if it's plain text.
Parts are from `earwig-structure-parts'; nil also when nothing in TEXT
makes structure and no heading or item made before waits at POS."
  (with-current-buffer buffer
    (when (and earwig-dictation-structure (earwig--structure-mode-p))
      (let ((parts (earwig-structure-parts text)))
        ;; Also when only a literal phrase was there, to take the word out
        (and (or (cl-notevery #'stringp parts) (earwig--open-at pos)
                 (not (equal parts (list text))))
             parts)))))

(defun earwig--open-at (pos)
  "Return the kind of heading or item made by voice that waits at POS, or nil."
  (pcase earwig--open-structure
    (`(,marker . ,kind)
     (and (eq (marker-buffer marker) (current-buffer)) (= marker pos) kind))))

(defun earwig--capitalize-first (text)
  "Return TEXT with its first letter upper case."
  (if (string-match "[[:alpha:]]" text)
      (concat (substring text 0 (match-beginning 0))
              (upcase (match-string 0 text))
              (substring text (match-end 0)))
    text))

(defun earwig--insert-chunk (text pos)
  "Insert the dictated TEXT at POS, cleaned up and fitted in; return its end.
Text for a heading made by voice fills it up to the first sentence end,
and the rest goes into its body, now or with the next dictation."
  (let ((open (earwig--open-at pos))
        (text (earwig-apply-format text nil (current-buffer) pos))
        rest next)
    (when open
      (setq earwig--open-structure nil
            text (earwig--capitalize-first text))
      (pcase open
        ('heading
         (if (not (string-match "\\([.?!]\\)\\(?:[ \t]+\\|\\'\\)\\|\n" text))
             (setq next 'heading)       ; it goes on in the next part
           (unless (equal (match-string 0 text) "\n")
             (setq rest (substring text (match-end 0))
                   text (concat (substring text 0 (match-beginning 0))
                                (if (equal (match-string 1 text) ".") "" (match-string 1 text))))
             (when (string-blank-p rest)
               (setq rest nil next 'body)))))
        ('body
         (setq rest text text nil))
        ('item
         (when (and (string-match-p "\\`[^\n]*[^.?!\n]\\.\\'" text)
                    (not (string-match-p "[.?!][ \t]" text)))
           (setq text (substring text 0 -1))))))
    (when text
      (let ((pos (earwig-absorb-before text (current-buffer) pos)))
        (goto-char pos)
        (insert (earwig-fit-to-context text (current-buffer) pos))))
    (cond
     (rest
      (insert (if (derived-mode-p 'org-mode) "\n" "\n\n"))
      (earwig--insert-chunk rest (point)))
     (t
      (when next
        (setq earwig--open-structure (cons (copy-marker (point)) next)))
      (point)))))

(defun earwig-insert-parts (parts pos)
  "Insert the dictation PARTS at POS in the current buffer.
PARTS are from `earwig-structure-split'.  Returns (START . END) of
the text after the last heading or item made, or of all of it."
  (let ((start (copy-marker pos)))
    (dolist (part parts)
      (cond
       ((stringp part)
        (setq pos (earwig--insert-chunk part pos)))
       (t
        (goto-char pos)
        (earwig-structure-do part)
        (setq pos (point)
              start (copy-marker pos)
              earwig--open-structure
              (cons (copy-marker pos) (if (memq part '(heading subheading)) 'heading 'item))))))
    (cons start pos)))

(defun earwig-insert-dictation (parts buffer pos)
  "Insert the dictation PARTS into BUFFER at POS, as one undo step.
Point goes to the end, and \"scratch that\" takes the text after the
last heading or item made."
  (with-current-buffer buffer
    (let ((group (prepare-change-group))
          (windows (cl-remove-if-not (lambda (window) (= (window-point window) pos))
                                     (get-buffer-window-list buffer nil t))))
      (activate-change-group group)
      (unwind-protect
          (pcase-let ((`(,start . ,end) (earwig-insert-parts parts pos)))
            (goto-char end)
            (dolist (window windows)
              (set-window-point window end))
            (setq earwig--last-dictation
                  (list (copy-marker start t) (copy-marker end)
                        (buffer-substring-no-properties start end))))
        (accept-change-group group)
        (undo-amalgamate-change-group group)))))

;;;; Joining sentences

(defconst earwig--sentence-join-regexp
  "\\([.?!]+\\)[\"'”’)]*\\([ \t]+\\|[ \t]*\n[ \t]*\\)"
  "Where one sentence ends and the next starts: its punctuation, the space.")

(defun earwig-join-sentences (joins comma)
  "Join the sentences before point at the last JOINS sentence ends.
With COMMA, a comma goes where each ended.  The next sentence's first
word loses its capital, unless it keeps it mid-sentence.  Stops at a
blank line, a list item or a heading.  Point stays after the text."
  (let ((end (point-marker))
        (case-fold-search nil)
        (done 0))
    (save-excursion
      ;; Back into the last sentence, past its own end
      (skip-chars-backward " \t\n")
      (skip-chars-backward ".?!\"'”’)")
      (let ((limit (save-excursion
                     (if (re-search-backward "^[ \t]*$" nil t) (match-end 0) (point-min)))))
        (while (and (< done joins)
                    (re-search-backward earwig--sentence-join-regexp limit t)
                    ;; A line break into a list item or heading isn't a sentence
                    (not (and (string-search "\n" (match-string 2))
                              (save-excursion
                                (goto-char (match-end 0))
                                (looking-at-p "\\(?:[-+*#]+\\|[0-9]+[.)]\\)[ \t]")))))
          (save-excursion
            (goto-char (match-end 0))
            (save-match-data
              (when (and (looking-at "[[:upper:]][[:alnum:]']*")
                         (not (earwig--keep-capital-p (match-string 0))))
                (downcase-region (point) (1+ (point))))))
          (unless (string-search "\n" (match-string 2))
            (replace-match " " t t nil 2))
          (replace-match (if comma "," "") t t nil 1)
          (goto-char (match-beginning 0))
          (setq done (1+ done)))))
    (goto-char end)
    (when (zerop done)
      (user-error "No sentence before it to join"))
    (message "Joined %d sentences" (1+ done))))

;;;; Commands

(defun earwig-cmd-structure (phrase text)
  "Make the heading or item PHRASE says, with TEXT in it if given."
  (let ((action (earwig--structure-action phrase earwig--structure-command-actions)))
    (earwig-insert-dictation (if text (list action text) (list action))
                               (current-buffer) (point))
    (when (and (bound-and-true-p evil-local-mode) (memq evil-state '(normal visual)))
      (evil-insert-state))))

(defun earwig-cmd-join (count comma)
  "Join the last COUNT sentences, or the last one to the one before it.
With COMMA, by commas."
  (undo-boundary)
  (barf-if-buffer-read-only)
  (earwig-join-sentences
   (if count
       (max 1 (1- (earwig-parse-number count t)))
     1)
   (and comma t)))

(defconst earwig-structure-commands
  `(("join \\(?:the \\)?last\\(?: \\(.+?\\)\\)? sentences?\\( with \\(?:a \\)?comma\\)?"
     earwig-cmd-join
     "join [the] last [N] sentence[s] [with comma]")
    (,(concat "\\(" (regexp-opt (mapcan (lambda (entry) (copy-sequence (cdr entry)))
                                         earwig--structure-command-actions))
              "\\)\\(?: \\(.+\\)\\)?")
     earwig-cmd-structure
     "new heading | subheading | item | sub item | checkbox [TEXT]
      (Org, Markdown; also in dictation, after a pause)"))
  "Structure entries for `earwig-commands'.")

(provide 'earwig-structure)
;;; earwig-structure.el ends here
