;;; earwig-grammar.el --- Voice commands as a phony.el grammar  -*- lexical-binding: t; -*-

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

;; Voice commands, Earwig's and your own, are rules of a phony.el
;; grammar: Earwig's with `earwig-defcommand', yours with
;; `phony-defun'.  Every interactive Phony rule is a voice command.
;;
;; What's said is split into commands without anything between them:
;; "select last sentence cut that go to bottom paste".  Phony finds
;; every way to read it.  Where there's more than one, as for "select
;; budget cut that" (select "budget cut that", or select "budget" and
;; then cut that), the commands are chosen one at a time, against the
;; buffer as it is when each runs, ranked by (`earwig--rank'):
;;
;;  1. what can be checked: the words a target names must be in the
;;     buffer, numbers must parse, and what a command checks itself
;;     (`earwig-defcommand' :check), as "replace" does that there's
;;     something to replace;
;;  2. free text that can't be checked, as "search TEXT" takes, runs to
;;     the end of what was said or to one of `earwig-chain-words';
;;  3. `earwig-chain-words' ("and then") split commands where they can:
;;     "replace and then with so" is one command only because nothing
;;     else reads;
;;  4. pauses, where Orukeet writes punctuation, go between commands;
;;  5. the fewest commands;
;;  6. your commands before Earwig's, so yours can take over a phrase;
;;  7. the fewest words of free text: "select last two words" is the
;;     last two words before point, not those words wherever they are;
;;  8. free text split as early as possible: "replace A with B with C"
;;     tries A first.
;;
;; Phony's parser is private, and it has a few other gaps for Earwig's
;; use; Earwig works around them here, under "Workarounds", until
;; Phony has them (docs/roadmap/phony-grammar.md, "Upstream requests").

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'phony)

(declare-function earwig-apply-corrections "earwig-cleanup" (text &optional commands))
(declare-function earwig-parse-number "earwig-commands" (text &optional whole noerror))
(declare-function earwig--ranges "earwig-edit" (target))

(defvar earwig-raw-command nil
  "While a voice command runs, its text before it was normalized.
That's with its punctuation, which matching ignores; for commands that
pass on what was said, like a prompt.")

(defcustom earwig-chain-words '("and then")
  "Words that can go between voice commands, which run one after another.
Commands are found without them too: \"select last sentence cut that\".
They split commands where that's possible, so free text such as \"search
budget and then go to top\" ends there.  Where the phrase reads only as
one command they're words, as in \"replace and then with so\"."
  :type '(repeat string)
  :group 'earwig)

;;;; Workarounds for what Phony lacks

;; Each of these is to go once Phony has what it works around.
;;
;; - All readings (upstream request 1): `phony-evaluate' picks one at
;;   random.  Earwig steps Phony's private parser,
;;   `phony-parser--parser', itself, and evaluates the readings with
;;   `earwig--evaluate', as `phony--evaluate-ast' only knows the
;;   grammar exported to Talon.
;; - No speech backend (request 2): `phony--exported-grammar' is only
;;   set by an export to Talon, which needs `phony-mode', the Emacs
;;   server and a timer.  Earwig never turns on `phony-mode', and
;;   prepares its own copy of the grammar, `earwig--prepared', again
;;   whenever a rule changes (`phony-request-export' is called then).
;; - Guarded words (request 3): numbers in digits, "42", match any word
;;   in `earwig-number', and a reading whose number doesn't parse is
;;   ruled out when it's evaluated (`earwig--candidates').
;; - Case (request 4): words are compared lowercased by binding
;;   `phony-parser--literal-normalizer', the experimental normalizer's
;;   variable, while parsing, and incrementing
;;   `phony-parser--current-generation' so Phony's cache is cleared.
;; - Rules that refer to themselves (request 5): Phony builds its
;;   parsers eagerly, so it can't.  Targets are layered, and a part's
;;   chain is a repeated `earwig--link' that `earwig--fold-chain' nests
;;   (see "Targets").
;; - Rules and patterns (request 6): help, `earwig--pattern-help' and
;;   `earwig--user-commands' (earwig-commands.el), reads them with
;;   Phony's private `phony--' and `phony-pattern--' functions.
;; - Extending `phony-defun' (request 7): `earwig-defcommand' gets the
;;   arguments for :check with `phony--collect-arguments' and
;;   `phony--expand-implicit-arguments'.
;; - Built-in patterns (request 8): `earwig-number', `earwig-words' and
;;   `earwig-text' use the private `phony--builtin-word' and
;;   `phony--builtin-phrase'.

(defvar earwig--prepared nil
  "Phony's grammar prepared for parsing, or nil once a rule has changed.
A plist: :grammar, the prepared grammar; :parser, a parser for one
interactive rule; :free, a hash table from the names of rules that take
any words to `phrase' or `word'.")

(defun earwig--grammar-changed (&rest _)
  "Forget the prepared grammar, as a rule has changed."
  (setq earwig--prepared nil))

(advice-add 'phony-request-export :before #'earwig--grammar-changed)

(defun earwig--free-kind (rule)
  "Return `phrase' or `word' if RULE takes any words itself, else nil."
  (when (phony--procedure-rule-p rule)
    (let ((builtins (phony-pattern--collect
                     (lambda (pattern)
                       (or (phony-pattern--builtin-phrase-p pattern)
                           (phony-pattern--builtin-word-p pattern)))
                     (phony--procedure-rule-pattern rule))))
      (cond ((seq-some #'phony-pattern--builtin-phrase-p builtins) 'phrase)
            (builtins 'word)))))

(defun earwig--prepared ()
  "Return Phony's grammar prepared for parsing, see `earwig--prepared'."
  (or earwig--prepared
      (let* ((grammar (phony--prepare-grammar phony--default-grammar))
             (rules (seq-filter (lambda (rule)
                                  (and (phony--procedure-rule-p rule)
                                       (phony--procedure-rule-interactive-p rule)))
                                (phony--get-rules grammar)))
             (free (make-hash-table :test #'eq)))
        (dolist (rule (phony--get-rules grammar))
          (let ((kind (earwig--free-kind rule)))
            (when kind
              (puthash (phony--rule-name rule) kind free))))
        (when (bound-and-true-p earwig-extra-commands)
          (display-warning 'earwig "`earwig-extra-commands' is no longer used: \
voice commands of your own are `phony-defun' rules now, see \"Commands of your own\" \
in Earwig's manual"))
        (setq earwig--prepared
              (list :grammar grammar
                    :parser (phony-parser--alternative
                             (mapcar #'phony-parser--parser rules))
                    :free free)))))

(defun earwig--evaluate (ast grammar)
  "Return the value of AST, a reading of a rule of the prepared GRAMMAR."
  (if (atom ast)
      ast
    (let* ((type (car ast))
           (rule (phony--get-rule type grammar)))
      (cond
       ((eq type 'list)
        (mapcar (lambda (arg) (earwig--evaluate arg grammar)) (cdr ast)))
       ((phony--dictionary-p rule)
        (phony-dictionary-get (cadr ast) type))
       ((phony--procedure-rule-p rule)
        (apply (phony--procedure-rule-function rule)
               (mapcar (lambda (arg) (earwig--evaluate arg grammar)) (cdr ast))))
       ((phony--open-rule-p rule)
        (earwig--evaluate (cadr ast) grammar))
       (t (error "Can't evaluate the voice command reading %S" ast))))))

(defmacro earwig--parsing (&rest body)
  "Run BODY, which parses with Phony, comparing words lowercased."
  (declare (indent 0))
  `(let ((phony-parser--literal-normalizer #'downcase))
     (cl-incf phony-parser--current-generation)
     ,@body))

(defun earwig--parse-rule (rule text)
  "Return the values of the readings of TEXT as the Phony RULE, a symbol.
Readings whose value can't be had, as a number that doesn't parse,
signal their `user-error' if no reading has a value; nil if none reads."
  (let* ((grammar (plist-get (earwig--prepared) :grammar))
         (object (phony--get-rule rule grammar))
         (asts (and object
                    (earwig--parsing
                      (phony-parser--parse (phony-parser--parser object)
                                           (split-string text))))))
    (let (values failed)
      (dolist (ast asts)
        (condition-case err
            (push (earwig--evaluate ast grammar) values)
          (user-error (setq failed err))))
      (cond (values (nreverse values))
            (failed (signal (car failed) (cdr failed)))))))

;;;; Defining commands

(defvar earwig--commands nil
  "Names of Earwig's own command rules, in the order they were defined.")

(defmacro earwig-defcommand (name pattern &rest rest)
  "Define NAME as a voice command of Earwig's, a `phony-defun' rule.
PATTERN, a docstring and BODY are as for `phony-defun', as are its
keywords; these go with them:

  :help STRING   the command as \"what can I say\" shows it
  :check FORM    evaluated with PATTERN's arguments bound before the
                 command runs, against the buffer as it is then; nil
                 means it can't run there, so another reading of what
                 was said is preferred
  :go t          \"go back\" returns to where point was before it

\(fn NAME PATTERN [DOCSTRING] [KEY VALUE]... BODY...)"
  (declare (indent 2) (doc-string 3))
  (let ((doc (and (stringp (car rest)) (pop rest)))
        (keys nil) help check go)
    (while (keywordp (car rest))
      (let ((key (pop rest)) (value (pop rest)))
        (pcase key
          (:help (setq help value))
          (:check (setq check value))
          (:go (setq go value))
          (_ (setq keys (append keys (list key value)))))))
    (let ((args (phony--collect-arguments
                 (phony--expand-implicit-arguments (cons 'seq (ensure-list pattern))))))
      `(progn
         (phony-defun ,name ,pattern ,@(and doc (list doc)) ,@keys ,@rest)
         (put ',name 'earwig-help ,help)
         (put ',name 'earwig-check ,(and check `(lambda ,args (ignore ,@args) ,check)))
         (put ',name 'earwig-go ,go)
         (unless (memq ',name earwig--commands)
           (setq earwig--commands (append earwig--commands (list ',name))))
         ',name))))

;;;; Rules for commands to use

(phony-defun earwig-number ((words (+ phony--builtin-word)))
  "A number, in digits or words: \"42\", \"forty two\", \"a hundred\".
Its value is the number, see `earwig-parse-number'; a reading where it
says no number is ruled out."
  :interactive nil
  (earwig-parse-number (string-join words " ") t))

(phony-defun earwig-words ((words phony--builtin-phrase))
  "Words to look for in the buffer; a reading is preferred where they're there."
  :interactive nil
  words)

(phony-defun earwig-text ((text phony--builtin-phrase))
  "Free text, as for a search: it goes on to the end, or to `earwig-chain-words'."
  :interactive nil
  text)

;; How each counts as free text in ranking
(put 'earwig-number 'earwig-free 'closed)
(put 'earwig-words 'earwig-free 'checked)

(phony-define-dictionary earwig--chain-word
  "One of `earwig-chain-words'."
  '(("and then" . t)))

(earwig-defcommand earwig-say-and-then earwig--chain-word
  "Nothing: it goes between commands, see `earwig-chain-words'."
  (ignore earwig--chain-word))

(put 'earwig-say-and-then 'earwig-separator t)

(defun earwig--sync-chain-words ()
  "Make the rule for `earwig-chain-words' match them."
  (let ((words (mapcar #'downcase earwig-chain-words)))
    (unless (equal (sort (mapcar #'car (phony-dictionary-alist 'earwig--chain-word)) #'string<)
                   (sort (copy-sequence words) #'string<))
      (phony-set-dictionary-alist 'earwig--chain-word
                                  (mapcar (lambda (word) (cons word t)) words)))))

;;;; Targets

;; What an editing verb acts on.  `earwig-part' names a part of the
;; buffer, `earwig-target' is those, words to find in it, and targets
;; made of others: "the end of TARGET", "every WORDS", "A and B", "A
;; through B".  Their values are `earwig-target' objects, which
;; `earwig-target-ranges' and `earwig-part-range' (earwig-edit.el) turn
;; into positions.
;;
;; A part is a chain of selectors joined by "in" or "of", to any depth:
;; "the first word of the second sentence in the paragraph with
;; budget".  A selector is a unit with an optional quantity before it
;; ("the second", "the last three", "every", "the third through fifth")
;; and an optional filter after it ("with", "starting with", "ending
;; with", "without" WORDS).  After a filter only "in" joins, as "of" is
;; often part of the words.  Phony can't parse a rule that refers to
;; itself, so the chain is a list, `earwig--link' repeated, which
;; `earwig--fold-chain' makes into nested specs, each selector the scope
;; of the one before it.  "the body of", "everything under" and "the
;; subheadings of" are links too, taking the rest of the chain as their
;; heading.  Words (WORDS, the next WORDS, A through B, every WORDS) can
;; only come first, joined by "in".

(cl-defstruct (earwig-target (:constructor earwig--target-make (spec))
                             (:copier nil))
  "What a voice command acts on.
SPEC is one of these, where UNIT is a value of `earwig-unit', WORDS,
A and B are words, and PART, SCOPE, TARGET, FIRST and LAST other
`earwig-target's:
  parts of the buffer: (units QUANTITY UNIT FILTER SCOPE), (region),
    (that), (buffer), (parent), (body PART), (under PART),
    (subheadings PART)
  words in it: (words WORDS), (through A B), (in TARGET PART), (every
    WORDS PART), (near DIRECTION WORDS)
  made of others: (edge EDGE TARGET), (span FIRST LAST), (and FORCED
    TARGET...)
For `units', QUANTITY picks among the UNITs FILTER lets through, in
SCOPE, or nil for UNIT's natural container (earwig-edit.el): nil is
the one with FILTER nearest point, (this) the one around point, (next
N) and (previous N) those from point, (last N) those before point, or
with FILTER or SCOPE the last N there, (range FROM TO) the FROMth
through the TOth there, each (N . START-OR-END), and (every) all of
them.  FILTER is nil or (KIND WORDS), KIND `with', `without',
`starting' or `ending'.  DIRECTION is `next' or `previous', EDGE
`start' or `end'.  FORCED non-nil means \"both\" or \"each of\" was
said, so it's several targets even if \"A and B\" is in the buffer as
words."
  spec)

(phony-define-open-rule earwig-part
  "A part of the buffer, as \"this paragraph\" or \"the section with budget\".")

(phony-define-open-rule earwig-target
  "What an editing verb acts on: a part of the buffer, or words in it.")

(defconst earwig--units
  '(("word" . "word") ("words" . "word")
    ("sentence" . "sentence") ("sentences" . "sentence")
    ("paragraph" . "paragraph") ("paragraphs" . "paragraph")
    ("line" . "line") ("lines" . "line")
    ("heading" . "heading") ("headings" . "heading")
    ("headline" . "heading") ("headlines" . "heading")
    ("section" . "section") ("sections" . "section")
    ("subtree" . "section") ("subtrees" . "section")
    ("item" . "item") ("items" . "item") ("bullet" . "item") ("bullets" . "item")
    ("checkbox" . "checkbox") ("checkboxes" . "checkbox")
    ("check box" . "checkbox") ("check boxes" . "checkbox")
    ("link" . "link") ("links" . "link"))
  "Units as said, and the singular each is.  The plurals end in s.")

(phony-define-dictionary earwig-unit
  "A unit of text, singular or plural; its value is the singular."
  earwig--units)

(phony-define-dictionary earwig--unit-said
  "A unit as said: (UNIT . PLURAL), UNIT the singular, PLURAL non-nil
for a plural."
  (mapcar (pcase-lambda (`(,said . ,unit)) (cons said (cons unit (string-suffix-p "s" said))))
          earwig--units))

(defconst earwig--ordinal-words
  '("first" "second" "third" "fourth" "fifth" "sixth" "seventh" "eighth" "ninth" "tenth"
    "eleventh" "twelfth" "thirteenth" "fourteenth" "fifteenth" "sixteenth" "seventeenth"
    "eighteenth" "nineteenth" "twentieth")
  "Ordinals in words, from one on.")

(phony-define-dictionary earwig--ordinal-word
  "An ordinal in words, \"first\" to \"twentieth\"; its value is the number."
  (cl-loop for word in earwig--ordinal-words for n from 1 collect (cons word n)))

(phony-defun earwig--ordinal-digits ((word phony--builtin-word))
  "An ordinal in digits, as \"21st\"; a reading where it's another word is ruled out."
  :interactive nil
  (if (string-match "\\`\\([0-9]+\\)\\(?:st\\|nd\\|rd\\|th\\)\\'" word)
      (max 1 (string-to-number (match-string 1 word)))
    (user-error "Not an ordinal: \"%s\"" word)))

(put 'earwig--ordinal-digits 'earwig-free 'closed)

(phony-defun earwig-ordinal ((| (seq (n (| earwig--ordinal-word earwig--ordinal-digits))
                                     (? (from (| "to last" "from last" "from the end"))))
                                (penultimate (| "next to last" "penultimate"))))
  "An ordinal, as (N . FROM): FROM `start', or `end' for \"second to
last\" and the like."
  :interactive nil
  (if penultimate '(2 . end) (cons n (if from 'end 'start))))

(phony-define-dictionary earwig--determiner
  "What can go before a unit: \"the\", \"this\", \"current\", and \"that\"
or \"a\", often heard for \"the\"."
  '(("the" . t) ("this" . t) ("that" . t) ("a" . t) ("current" . t) ("the current" . t)))

(phony-defun earwig--quantity
    ((| (seq (direction (| "next" "following" "previous" "preceding" "last"))
             (? (count earwig-number)))
        (seq "first" (first earwig-number))
        (seq (from earwig-ordinal) (? (| "through" "thru") (? "the") (to earwig-ordinal)))
        (every (| "every" "each" "all" "all the" "all of the"))))
  "How many UNITs and which: see `earwig-target'."
  :interactive nil
  (cond (every '(every))
        (from (list 'range from (or to from)))
        (first (list 'range '(1 . start) (cons first 'start)))
        (t (list (pcase direction
                   ((or "next" "following") 'next)
                   ((or "previous" "preceding") 'previous)
                   (_ 'last))
                 (or count 1)))))

(phony-defun earwig--filter ((kind (| "with" "containing" "starting with" "ending with" "without"))
                             (words earwig-words))
  "Which UNITs count: those with, without, starting or ending with WORDS."
  :interactive nil
  (list (pcase kind
          ("starting with" 'starting)
          ("ending with" 'ending)
          ("without" 'without)
          (_ 'with))
        words))

(defun earwig--units-target (quantity unit filter)
  "Return the target for UNIT, (UNIT . PLURAL), with QUANTITY and FILTER.
Without a quantity, a plural is every one, a singular with a filter the
nearest, and one without the one around point."
  (earwig--target-make
   (list 'units
         (or quantity (cond ((cdr unit) '(every)) (filter nil) (t '(this))))
         (car unit) filter nil)))

(phony-defun earwig--selector ((? (_the earwig--determiner)) (? (quantity earwig--quantity))
                               (unit earwig--unit-said))
  "UNITs picked by QUANTITY: \"the second paragraph\", \"last two words\"."
  :interactive nil
  (earwig--units-target quantity unit nil))

(phony-defun earwig--selector-filtered ((? (_the earwig--determiner))
                                        (? (quantity earwig--quantity))
                                        (unit earwig--unit-said) (filter earwig--filter))
  "UNITs picked by QUANTITY among those FILTER lets through."
  :interactive nil
  (earwig--units-target quantity unit filter))

(phony-defun earwig-part-region ((| "region" "the region" "selection" "the selection"))
  "The region, or evil's visual selection."
  :interactive nil
  (earwig--target-make '(region)))

(phony-defun earwig-part-that ((| "that" "this" "it"))
  "The region, or else the text that went in last, dictated or not."
  :interactive nil
  (earwig--target-make '(that)))

(phony-defun earwig-part-buffer ((| (seq (? "the") (? (| "whole" "entire")) (| "buffer" "file"))
                                    "everything" "all"))
  "The whole buffer."
  :interactive nil
  (earwig--target-make '(buffer)))

(phony-defun earwig-part-parent ((? (| "the" "this")) "parent" (| "heading" "headline"))
  "The parent of the heading point is under."
  :interactive nil
  (earwig--target-make '(parent)))

(phony-defun earwig-part-subheadings ((? (| "the" "this")) "subheadings")
  "The subheadings of the heading point is under."
  :interactive nil
  (earwig--target-make '(subheadings nil)))

(phony-defun earwig--link
    ((| (seq (plain earwig--selector) (| "in" "of"))
        (seq (filtered earwig--selector-filtered) "in")
        (seq (? (| "the" "this")) (body (| "body of" "text under")))
        (under "everything under")
        (seq (? (| "the" "this")) (subheadings "subheadings of"))))
  "A selector and the word that joins it to the next: \"the first word of\".
\"the body of\", \"everything under\" and \"the subheadings of\" take
the rest of the chain as their heading."
  :interactive nil
  (cond (plain plain)
        (filtered filtered)
        (body (earwig--target-make '(body nil)))
        (under (earwig--target-make '(under nil)))
        (subheadings (earwig--target-make '(subheadings nil)))))

(defun earwig--fold-chain (links last)
  "Return the target of LINKS, from `earwig--link', and LAST, each the
scope of the one before."
  (let ((scope last))
    (dolist (link (reverse links) scope)
      (let ((spec (copy-sequence (earwig-target-spec link))))
        (if (eq (car spec) 'units)
            (setf (nth 4 spec) scope)
          (setf (nth 1 spec) scope))
        (setq scope (earwig--target-make spec))))))

(phony-defun earwig-part-chain ((links (* earwig--link))
                                (last (| earwig--selector earwig--selector-filtered
                                         earwig-part-region earwig-part-that earwig-part-buffer
                                         earwig-part-parent earwig-part-subheadings)))
  "A part of the buffer, each selector in the next: \"this paragraph\",
\"the first word of the second sentence in the section with budget\"."
  :contributes-to earwig-part
  (earwig--fold-chain links last))

(phony-defun earwig-target-part ((part earwig-part))
  "A part of the buffer."
  :contributes-to earwig-target
  part)

(phony-defun earwig-target-words ((words earwig-words))
  "The nearest place WORDS are."
  :contributes-to earwig-target
  (earwig--target-make (list 'words words)))

(phony-defun earwig-target-literal ((| "the word" "the words")
                                    (words earwig-words))
  "The nearest place WORDS are, even words that mean something else in a
target, like \"this\" or \"next\": \"wrap the word this in quotes\"."
  :contributes-to earwig-target
  (earwig--target-make (list 'words words)))

(phony-defun earwig-target-through ((from earwig-words) (| "through" "thru" "until")
                                    (to earwig-words))
  "From the words FROM to the words TO."
  :contributes-to earwig-target
  (earwig--target-make (list 'through from to)))

(phony-defun earwig-target-from ("from" (from earwig-words) (| "to" "through" "thru" "until")
                                 (to earwig-words))
  "From the words FROM to the words TO."
  :contributes-to earwig-target
  (earwig--target-make (list 'through from to)))

(phony-defun earwig-target-near ((? "the") (direction (| "next" "following" "previous" "preceding"))
                                 (words earwig-words))
  "The next or previous place WORDS are, from point."
  :contributes-to earwig-target
  (earwig--target-make (list 'near (if (member direction '("next" "following")) 'next 'previous)
                             words)))

(phony-defun earwig-target-in ((what (| earwig-target-words earwig-target-literal
                                        earwig-target-through earwig-target-from
                                        earwig-target-near))
                               "in" (part earwig-part))
  "WHAT, looked for only in PART: every place WORDS are there."
  :contributes-to earwig-target
  (earwig--target-make (list 'in what part)))

(phony-defun earwig--simple-target ((target (| earwig-target-part earwig-target-words
                                               earwig-target-literal earwig-target-through earwig-target-from
                                               earwig-target-near earwig-target-in)))
  "A target that isn't made of other targets."
  :interactive nil
  target)

(phony-defun earwig-target-edge ((? (| "the" "this")) (edge (| "start" "beginning" "end")) "of"
                                 (target earwig--simple-target))
  "The start or end of TARGET, an empty place."
  :contributes-to earwig-target
  (earwig--target-make (list 'edge (if (equal edge "end") 'end 'start) target)))

(phony-defun earwig-target-every ((| "every" "each") (words earwig-words)
                                  (? "in" (part earwig-part)))
  "Every place WORDS are, in PART if given."
  :contributes-to earwig-target
  (earwig--target-make (list 'every words part)))

(defun earwig--span-target (first last)
  "Return the target from FIRST to LAST, or the words FIRST through LAST."
  (let ((a (earwig-target-spec first))
        (b (earwig-target-spec last)))
    (earwig--target-make (if (and (eq (car a) 'words) (eq (car b) 'words))
                             (list 'through (cadr a) (cadr b))
                           (list 'span first last)))))

(phony-defun earwig-target-span ((first (| earwig--simple-target earwig-target-edge))
                                 (| "through" "thru" "until")
                                 (last (| earwig--simple-target earwig-target-edge)))
  "From the start of FIRST to the end of LAST: \"the second sentence
through the end of this paragraph\"."
  :contributes-to earwig-target
  (earwig--span-target first last))

(phony-defun earwig-target-span-from ("from" (first (| earwig--simple-target earwig-target-edge))
                                      (| "to" "through" "thru" "until")
                                      (last (| earwig--simple-target earwig-target-edge)))
  "From the start of FIRST to the end of LAST."
  :contributes-to earwig-target
  (earwig--span-target first last))

(phony-defun earwig--one-target ((target (| earwig--simple-target earwig-target-edge
                                            earwig-target-every earwig-target-span
                                            earwig-target-span-from)))
  "A target that isn't several joined by \"and\"."
  :interactive nil
  target)

(phony-defun earwig-target-and ((a earwig--one-target) "and" (b earwig--one-target))
  "A and B, where \"A and B\" isn't in the buffer as words."
  :contributes-to earwig-target
  (earwig--target-make (list 'and nil a b)))

(phony-defun earwig-target-both ("both" (a earwig--one-target) "and" (b earwig--one-target))
  "A and B, even where \"A and B\" is in the buffer as words."
  :contributes-to earwig-target
  (earwig--target-make (list 'and t a b)))

(phony-defun earwig-target-each ("each of" (a earwig--one-target) (more (* earwig--one-target))
                                 "and" (b earwig--one-target))
  "A, MORE and B, each of them."
  :contributes-to earwig-target
  (earwig--target-make (append (list 'and t a) more (list b))))

;; Where a command puts text: (KIND TARGET), KIND `before', `after',
;; `under', `start' or `end'

(phony-define-open-rule earwig-destination
  "Where to put text: \"before TARGET\", \"under TARGET\", \"to the end of TARGET\".")

(phony-defun earwig-destination-beside ((where (| "before" "after")) (target earwig--one-target))
  "Before or after TARGET."
  :contributes-to earwig-destination
  (list (intern where) target))

(phony-defun earwig-destination-under ((| "under" "as a subheading of" "as a sub heading of"
                                          "as a sub item of" "as a subitem of" "as a sub-item of")
                                       (target earwig--one-target))
  "As the last child of TARGET, a heading or list item."
  :contributes-to earwig-destination
  (list 'under target))

(phony-defun earwig-destination-into ((| "to" "into") (target earwig--simple-target))
  "As \"under\" TARGET: \"move that to the section with plans\".
Not the start or end of a target, which \"to the start of\" says."
  :contributes-to earwig-destination
  (list 'under target))

(phony-defun earwig-destination-edge ("to the" (edge (| "start" "beginning" "end")) "of"
                                      (target earwig--one-target))
  "At the start or end of TARGET."
  :contributes-to earwig-destination
  (list (if (equal edge "end") 'end 'start) target))

;;;; Reading what's said

(defun earwig--tokens (text)
  "Return the words of the command TEXT, as a list of (WORD BEG END PAUSE).
WORD is without the punctuation that ends a sentence; it's from BEG to
END in TEXT, with it.  PAUSE is non-nil if punctuation follows, where
Orukeet heard a pause.  Commas and the like separate words; a dot
inside one, as in \"init.el\", doesn't."
  (let ((pos 0) tokens)
    (while (string-match "[^ \t\n,;:]+" text pos)
      (let* ((beg (match-beginning 0))
             (end (match-end 0))
             (word (match-string 0 text)))
        (setq pos end)
        (when (string-match "[.?!]+\\'" word)
          (setq word (substring word 0 (match-beginning 0))))
        (if (string-empty-p word)
            (when tokens
              (setf (nth 3 (car tokens)) t))
          (when (and tokens (string-match-p "[,;:]" (substring text (nth 2 (car tokens)) beg)))
            (setf (nth 3 (car tokens)) t))
          (push (list word beg end (and (< (length word) (- end beg)) t)) tokens))))
    (nreverse tokens)))

(cl-defstruct (earwig--candidate (:constructor earwig--candidate-make) (:copier nil))
  "A reading of some of what was said as one command."
  start end ast rule values error
  greedy free signature separator user
  cost)                                 ; static cost of the best path on

(defun earwig--ast-free (ast free)
  "Return (WORDS SIGNATURE GREEDY) for the free text in AST.
FREE is the prepared grammar's :free.  WORDS counts the words, SIGNATURE
lists them per stretch of free text; GREEDY is non-nil if some of it
can't be checked, so runs to the end."
  (let ((words 0) signature greedy)
    (cl-labels ((walk (node)
                  (when (consp node)
                    (let ((kind (gethash (car node) free))
                          (how (get (car node) 'earwig-free)))
                      (cond
                       ((eq how 'closed))
                       (kind
                        (let ((count (length (split-string
                                              (mapconcat (lambda (x) (if (stringp x) x ""))
                                                         (flatten-tree (cdr node)) " ")))))
                          (cl-incf words count)
                          (push count signature)
                          (when (and (eq kind 'phrase) (not (eq how 'checked)))
                            (setq greedy t))))
                       (t (mapc #'walk (cdr node))))))))
      (walk ast))
    (list words (nreverse signature) greedy)))

(defun earwig--candidates (tokens prepared)
  "Return a vector: for each position in TOKENS, the commands that start there.
Each is an `earwig--candidate', its arguments evaluated.  PREPARED is
from `earwig--prepared'."
  (let* ((n (length tokens))
         (words (mapcar #'car tokens))
         (grammar (plist-get prepared :grammar))
         (free (plist-get prepared :free))
         (table (make-vector (1+ n) nil)))
    (earwig--parsing
      (dotimes (start n)
        (let ((parser (plist-get prepared :parser))
              (rest (nthcdr start words))
              (pos start)
              found)
          (while (and rest (not (phony-parser--empty-p parser)))
            (setq parser (phony-parser--step parser (pop rest)))
            (cl-incf pos)
            (dolist (ast (phony-parser--parses parser))
              (unless (member (cons pos ast) found)
                (push (cons pos ast) found))))
          (dolist (entry (nreverse found))
            (pcase-let* ((`(,end . ,ast) entry)
                         (rule (phony--get-rule (car ast) grammar))
                         (`(,count ,signature ,greedy) (earwig--ast-free ast free))
                         (values nil)
                         (error nil))
              (condition-case err
                  (setq values (mapcar (lambda (arg) (earwig--evaluate arg grammar))
                                       (cdr ast)))
                (error (setq error (error-message-string err))))
              (when (and (or (not (phony--procedure-rule-anchor-beginning-p rule)) (= start 0))
                         (or (not (phony--procedure-rule-anchor-end-p rule)) (= end n)))
                (push (earwig--candidate-make
                       :start start :end end :ast ast :rule (car ast)
                       :values values :error error
                       :greedy greedy :free count :signature signature
                       :separator (get (car ast) 'earwig-separator)
                       :user (not (memq (car ast) earwig--commands)))
                      (aref table start))))))
        (setf (aref table start) (nreverse (aref table start)))))
    table))

(defun earwig--chain-starts (tokens)
  "Return (POS . LENGTH) of each of `earwig-chain-words' in TOKENS."
  (let ((words (mapcar (lambda (token) (downcase (car token))) tokens))
        (chains (mapcar (lambda (chain) (split-string (downcase chain))) earwig-chain-words))
        starts)
    (cl-loop for tail on words
             for pos from 0
             do (dolist (chain chains)
                  (when (equal (seq-take tail (length chain)) chain)
                    (push (cons pos (length chain)) starts))))
    starts))

(defun earwig--cost+ (a b)
  "Return the costs A and B added, element by element."
  (cl-mapcar #'+ a b))

(defun earwig--cost< (a b)
  "Non-nil if the cost A is less than B, the first element first."
  (cl-loop for x in a for y in b
           when (< x y) return t
           when (> x y) return nil))

(defun earwig--plan (tokens table &optional static limit)
  "Work out the best way on from each position of TOKENS, without the buffer.
TABLE is from `earwig--candidates'.  Sets each candidate's cost to that
of the best way to the end, LIMIT tokens if given, through it, and
returns a vector of the least cost from each position, nil where
there's no way on.

A cost is (ERRORS CHAINS PAUSES COMMANDS FREE): commands that can't be
evaluated, as a number that doesn't parse, which run only to say so;
words of `earwig-chain-words' inside commands, pauses inside commands,
commands, and words of free text.  STATIC, for when the buffer won't
be checked, swaps the last two: as words to find can't be ruled out
then, a reading with fewer of them is likelier."
  (let* ((n (or limit (length tokens)))
         (best (make-vector (1+ n) nil))
         (chains (earwig--chain-starts tokens))
         (pauses (vconcat (mapcar (lambda (token) (nth 3 token)) tokens))))
    (aset best n '(0 0 0 0 0))
    (cl-loop
     for start from (1- n) downto 0
     do (dolist (candidate (aref table start))
          (setf (earwig--candidate-cost candidate) nil)
          (let ((end (earwig--candidate-end candidate)))
            (when (<= end n)
              (let* ((own (list (if (earwig--candidate-error candidate) 1 0)
                                (cl-count-if (lambda (chain)
                                               (and (not (earwig--candidate-separator candidate))
                                                    (<= start (car chain))
                                                    (<= (+ (car chain) (cdr chain)) end)))
                                             chains)
                                (cl-loop for i from start below (1- end)
                                         count (aref pauses i))
                                (if (earwig--candidate-separator candidate) 0 1)
                                (earwig--candidate-free candidate)))
                     (own (if static
                              (append (seq-take own 3) (list (nth 4 own) (nth 3 own)))
                            own))
                     (on (if (and (earwig--candidate-greedy candidate) (< end n))
                             ;; Free text only stops at a chain word
                             (let (on)
                               (dolist (next (aref table end))
                                 (let ((cost (and (earwig--candidate-separator next)
                                                  (earwig--candidate-cost next))))
                                   (when (and cost (or (null on) (earwig--cost< cost on)))
                                     (setq on cost))))
                               on)
                           (aref best end))))
                (when on
                  (let ((cost (earwig--cost+ own on)))
                    (setf (earwig--candidate-cost candidate) cost)
                    (when (or (null (aref best start)) (earwig--cost< cost (aref best start)))
                      (aset best start cost)))))))))
    best))

(defun earwig--check (candidate)
  "Non-nil if CANDIDATE can act on the buffer as it is now.
Its targets must be there, and its rule's :check must pass."
  (and (not (earwig--candidate-error candidate))
       (condition-case nil
           (let ((values (earwig--candidate-values candidate))
                 (check (get (earwig--candidate-rule candidate) 'earwig-check)))
             (cl-labels ((targets-ok (value)
                           (cond ((earwig-target-p value) (earwig--ranges value) t)
                                 ((consp value) (and (targets-ok (car value))
                                                     (targets-ok (cdr value))))
                                 (t t))))
               (and (targets-ok values)
                    (or (null check) (apply check values)))))
         (error nil))))

(defun earwig--rank (candidates &optional check)
  "Return CANDIDATES, ones with a way to the end, best first.
With CHECK, those that pass `earwig--check' come first.  See the
commentary for the order."
  (let* ((index 0)
         (keyed (mapcar (lambda (candidate)
                          (list (if (and check (not (earwig--candidate-separator candidate)))
                                    (if (earwig--check candidate) 0 1)
                                  0)
                                (earwig--candidate-cost candidate)
                                (if (earwig--candidate-user candidate) 0 1)
                                (earwig--candidate-signature candidate)
                                (cl-incf index)
                                candidate))
                        (seq-filter #'earwig--candidate-cost candidates))))
    (mapcar
     (lambda (key) (car (last key)))
     (sort keyed
           (lambda (a b)
             (cl-loop for x in a for y in b
                      for result = (cond ((and (numberp x) (numberp y))
                                          (cond ((< x y) 'less) ((> x y) 'more)))
                                         ((and (listp x) (listp y))
                                          (cond ((earwig--cost< x y) 'less)
                                                ((earwig--cost< y x) 'more))))
                      when result return (eq result 'less)))))))

(defun earwig--path (table best start)
  "Return the best commands from START on, without the buffer, or nil.
TABLE and BEST are from `earwig--candidates' and `earwig--plan'."
  (when (aref best start)
    (let ((path nil) (pos start) (end (1- (length best))))
      (while (< pos end)
        (let ((next (car (earwig--rank (aref table pos)))))
          (push next path)
          (setq pos (earwig--candidate-end next))))
      (nreverse path))))

;;;; Finding and running commands

(defun earwig--command-text (text)
  "Return TEXT as a command, without punctuation and with single spaces.
Dots inside words, as in \"init.el\", stay."
  (mapconcat #'car (earwig--tokens text) " "))

(defun earwig--reading (text &optional static)
  "Return (TOKENS TABLE BEST READ) for the voice commands TEXT, or nil.
Nil if it doesn't read.  TEXT is read as said, then with
`earwig-corrections-commands' applied; READ is the one that reads.
STATIC is for `earwig--plan'."
  (earwig--sync-chain-words)
  (let ((prepared (earwig--prepared)))
    (cl-some (lambda (text)
               (let* ((tokens (earwig--tokens text))
                      (table (and tokens (earwig--candidates tokens prepared)))
                      (best (and tokens (earwig--plan tokens table static))))
                 (and best (aref best 0) (list tokens table best text))))
             (delete-dups (list text (earwig-apply-corrections text t))))))

(defun earwig--raw (text tokens candidate)
  "Return the part of TEXT, read as TOKENS, that CANDIDATE was read from."
  (substring text (nth 1 (nth (earwig--candidate-start candidate) tokens))
             (nth 2 (nth (1- (earwig--candidate-end candidate)) tokens))))

(defun earwig--command-path (text)
  "Return the commands TEXT reads as, without the buffer: (RAW CANDIDATE)...
Separators, `earwig-chain-words', are in it too.  Nil if it doesn't read."
  (pcase (earwig--reading text t)
    (`(,tokens ,table ,best ,read)
     (mapcar (lambda (candidate) (list (earwig--raw read tokens candidate) candidate))
             (earwig--path table best 0)))))

(defun earwig-find-commands (text)
  "Return ((RAW RULE . ARGS)...) for the voice commands TEXT reads as, or nil.
RULE is a command's Phony rule and ARGS the values of its arguments;
RAW is its part of TEXT.  Where TEXT reads more than one way, this is
the best reading without looking at the buffer, as words to find
aren't looked for; running it can choose another."
  (cl-loop for (raw candidate) in (earwig--command-path text)
           unless (earwig--candidate-separator candidate)
           collect (cons raw (cons (earwig--candidate-rule candidate)
                                   (earwig--candidate-values candidate)))))

(defun earwig-find-command (text)
  "Return (RULE . ARGS) if TEXT, all of it, reads as one voice command, else nil.
As for `earwig-find-commands'."
  (let ((commands (earwig-find-commands text)))
    (when (and commands (null (cdr commands))
               (pcase (earwig--command-path text)
                 (`((,_ ,candidate)) (not (earwig--candidate-separator candidate)))))
      (cdar commands))))

(defvar earwig--go-from)
(defvar earwig--edit-last)

(defun earwig--run-candidate (candidate)
  "Run the command CANDIDATE, a reading's `earwig--candidate'.
For one defined with :go that moves point, \"go back\" returns to where
point was; not for \"next one\" after \"select WORDS\"."
  (let* ((rule (earwig--candidate-rule candidate))
         (object (phony--get-rule rule (plist-get (earwig--prepared) :grammar)))
         (from (point-marker)))
    (unwind-protect
        (progn
          (when (earwig--candidate-error candidate)
            (user-error "%s" (earwig--candidate-error candidate)))
          (apply (phony--procedure-rule-function object) (earwig--candidate-values candidate))
          (when (and (get rule 'earwig-go)
                     (eq (marker-buffer from) (current-buffer))
                     (/= from (point))
                     (not (and (eq rule 'earwig-say-next-match)
                               (eq (nth 2 earwig--edit-last) 'select))))
            (when (markerp earwig--go-from)
              (set-marker earwig--go-from nil))
            (setq earwig--go-from from
                  from nil)))
      (when from
        (set-marker from nil)))))

(defun earwig-run-command (text)
  "Run the voice commands TEXT reads as, or say that it reads as none.
Each is chosen when it's its turn, against the buffer as it is then,
see the commentary.  They run in turn, each its own undo step, and stop
at one that fails.  One that selects another buffer, as \"other window\"
does, leaves the rest to run there."
  (pcase (earwig--reading text)
    ('nil (message "No voice command for \"%s\"" (earwig--command-text text)))
    (`(,tokens ,table ,best ,read)
     (let* ((total (cl-count-if-not #'earwig--candidate-separator
                                    (earwig--path table best 0)))
            (n (length tokens))
            (pos 0)
            (step 0)
            (mode major-mode))
       (while (< pos n)
         ;; The commands a buffer has can differ by mode
         (unless (eq major-mode mode)
           (setq mode major-mode
                 table (earwig--candidates tokens (earwig--prepared))
                 best (earwig--plan tokens table)))
         (let ((candidate (car (earwig--rank (aref table pos) t))))
           (if (null candidate)
               (progn
                 (message "No voice command for \"%s\""
                          (mapconcat #'car (nthcdr pos tokens) " "))
                 (setq pos n))
             (setq pos (earwig--candidate-end candidate))
             (unless (earwig--candidate-separator candidate)
               (cl-incf step)
               (let ((buffer (window-buffer))
                     (raw (earwig--raw read tokens candidate)))
                 (condition-case err
                     (let ((earwig-raw-command raw))
                       (earwig--run-candidate candidate))
                   (error
                    (message "Voice command \"%s\" failed%s: %s"
                             (earwig--command-text raw)
                             (if (> total 1) (format " (step %d of %d)" step (max step total)) "")
                             (error-message-string err))
                    (setq pos n)))
                 (unless (eq (window-buffer) buffer)
                   (set-buffer (window-buffer)))
                 (undo-boundary))))))))))

(defun earwig--command-parts (text)
  "Return (COMMANDS . REST) for as much of TEXT as reads as voice commands.
COMMANDS are the words of each command, in turn, without
`earwig-chain-words' between them; REST is the words after them, that
don't read (yet), or nil.  The most is read that doesn't take more of
`earwig-chain-words' into commands, so in \"select last sentence and
then cu\" the last word doesn't read yet."
  (earwig--sync-chain-words)
  (let* ((tokens (earwig--tokens text))
         (table (and tokens (earwig--candidates tokens (earwig--prepared))))
         (n (length tokens))
         (limit (cl-loop with chosen = nil and chains = nil
                         for limit from n downto 1
                         for best = (aref (earwig--plan tokens table t limit) 0)
                         ;; Errors and chain words taken into commands
                         for key = (and best (seq-take best 2))
                         when (and key (or (null chains) (earwig--cost< key chains)))
                         do (setq chosen limit chains key)
                         finally return chosen)))
    (if (null limit)
        (cons nil (and tokens (mapconcat #'car tokens " ")))
      (let ((best (earwig--plan tokens table t limit)))
        (cons (cl-loop for candidate in (earwig--path table best 0)
                       unless (earwig--candidate-separator candidate)
                       collect (mapconcat #'car
                                          (seq-subseq tokens
                                                      (earwig--candidate-start candidate)
                                                      (earwig--candidate-end candidate))
                                          " "))
              (and (< limit n)
                   (mapconcat #'car (nthcdr limit tokens) " ")))))))

(defun earwig-commands-complete-p (text)
  "Non-nil if TEXT, all of it, reads as voice commands not waiting for more.
That's not ending with one of `earwig-chain-words'."
  (let ((path (earwig--command-path text)))
    (and path (not (earwig--candidate-separator (cadr (car (last path))))))))

(provide 'earwig-grammar)
;;; earwig-grammar.el ends here
