;;; earwig-phony.el --- What Earwig needs from phony.el, until Phony has it  -*- lexical-binding: t; -*-

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

;; Earwig parses what's said with phony.el, without `phony-mode' or a
;; speech engine, and needs more of Phony than its public API has in
;; 4.0.0.  This file is the only place Earwig uses Phony's private
;; functions and variables, written against phony.el 4.0.0.
;;
;; Each function here stands for one proposed to Phony
;; (docs/roadmap/phony-grammar.md, "Upstream requests") and is named
;; after it: `earwig--phony-grammar' for `phony-grammar', and so on.
;; Once Phony has them, this file goes, and each use is renamed.
;;
;; Nothing here changes Phony: no advice, no methods on its generic
;; functions, no setting its variables globally.  Other packages using
;; Phony see it as it is.  Phony's grammar is copied and prepared here
;; when it's asked for and has changed since, and a few of Phony's
;; variables are bound around a parse.
;;
;; What can't be done this way: Phony 4.0.0 builds a rule's parser
;; eagerly, so a rule can't refer to itself, and Earwig's targets
;; avoid it (earwig-grammar.el, "Targets").

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'phony)

;;;; The grammar

(defvar earwig--phony-grammar nil
  "Phony's grammar as `earwig--phony-grammar' prepared it.
A list (STATE LATEST VALID): STATE is from `earwig--phony-grammar-state'
when it was prepared, LATEST the grammar prepared then, and VALID the
most recent one without errors, or nil.")

(defun earwig--phony-grammar-state ()
  "Return what Phony's grammar as defined is made of now.
That's its rules, its modules and whether each is enabled, and which
module provides another's interfaces.  Defining or removing a rule, or
enabling a module, changes it; changing a dictionary's entries doesn't,
as a prepared grammar shares them.  Compare two with
`earwig--phony-same-state-p'."
  (let* ((grammar phony--default-grammar)
         (state (list grammar)))
    (maphash (lambda (_name rule) (push rule state))
             (phony--grammar-rules grammar))
    (maphash (lambda (_name module)
               (push module state)
               (push (phony--module-enabled-p module) state))
             (phony--grammar-modules grammar))
    (maphash (lambda (interface provider)
               (push interface state)
               (push provider state))
             (phony--grammar-module-provision grammar))
    state))

(defun earwig--phony-same-state-p (a b)
  "Non-nil if A and B, from `earwig--phony-grammar-state', are the same."
  (and (length= a (length b))
       (cl-every #'eq a b)))

(defun earwig--phony-grammar ()
  "Return the grammar of the Phony rules defined now, ready for parsing.
It's prepared again the first time it's asked for after a rule, module
or interface provider has changed, without `phony-mode' or a speech
engine.  If the rules have errors, they're displayed as warnings, and
the most recent grammar without errors is returned instead, or an empty
one if there's none.  The grammar must not be modified.

Stands for `phony-grammar'."
  (let ((state (earwig--phony-grammar-state)))
    (unless (earwig--phony-same-state-p state (car earwig--phony-grammar))
      (let* ((grammar (phony--finalize-grammar))
             (diagnostics (phony--grammar-diagnostics grammar)))
        (dolist (diagnostic diagnostics)
          (display-warning 'earwig (format "Phony's grammar: %s"
                                           (phony--diagnostic-message diagnostic))))
        (setq earwig--phony-grammar
              (list state grammar
                    (if diagnostics (nth 2 earwig--phony-grammar) grammar)))))
    (or (nth 2 earwig--phony-grammar)
        (let ((grammar (phony--make-grammar)))
          (phony-ag--initialize grammar)
          (setf (nth 2 earwig--phony-grammar) grammar)))))

(defun earwig--phony-rule (name grammar &optional procedure)
  "Return the rule NAME of GRAMMAR, or signal an error if there's none.
PROCEDURE non-nil means it must be a procedure rule."
  (let ((rule (or (phony--get-rule name grammar)
                  (error "No Phony rule named `%s'" name))))
    (when (and procedure (not (phony--procedure-rule-p rule)))
      (error "Phony rule `%s' is not a procedure rule" name))
    rule))

;;;; Parsing

(defmacro earwig--phony-with-literal-normalizer (normalizer &rest body)
  "Run BODY, which parses, with Phony comparing words after NORMALIZER.
NORMALIZER is a function from a string to a string, as `downcase'.
Parse a grammar from `earwig--phony-grammar' always with the same one:
Phony 4.0.0 keeps a dictionary's parser, which holds its words
normalized, until the dictionary changes.

Stands for binding `phony-literal-normalizer'."
  (declare (indent 1) (debug t))
  `(let ((phony-parser--literal-normalizer ,normalizer))
     ,@body))

(defun earwig--phony-new-parse ()
  "Start a parse, so Phony forgets what earlier ones found.
They depended on the buffer's modes and the normalizer then."
  (cl-incf phony-parser--current-generation))

(defun earwig--phony-parse-rule (rule words grammar)
  "Return every reading of WORDS, a list of strings, as RULE of GRAMMAR.
RULE is the name of any rule, interactive or not.  Each reading is an
AST, to evaluate with `earwig--phony-evaluate-ast'; those with the
fewest words of free text come first.

Stands for `phony-parse-rule'."
  (earwig--phony-new-parse)
  (mapcar #'car (seq-sort-by #'cdr #'<
                             (phony-parser--parse
                              (phony-parser--parser (earwig--phony-rule rule grammar))
                              words))))

(defvar earwig--phony-command-parsers (make-hash-table :test #'eq :weakness 'key)
  "For each grammar, parsers for one command, by anchors.
See `earwig--phony-command-parsers'.")

(defun earwig--phony-command-parsers (grammar)
  "Return parsers for one command of GRAMMAR, an interactive rule.
An alist from anchors, (BEGINNING-P . END-P), to a parser for the
commands with those anchors, whose results are their ASTs."
  (with-memoization (gethash grammar earwig--phony-command-parsers)
    (thread-last
      (phony--interactive-rules grammar)
      (seq-group-by (lambda (rule)
                      (cons (and (phony--procedure-rule-anchor-beginning-p rule) t)
                            (and (phony--procedure-rule-anchor-end-p rule) t))))
      (mapcar (pcase-lambda (`(,anchors . ,rules))
                (cons anchors
                      (phony-parser--alternative
                       (mapcar (lambda (rule)
                                 ;; Preparing a grammar wraps each command
                                 ;; in a rule of its own, which is
                                 ;; active in the command's modes.
                                 (let ((parser (phony-parser--parser rule)))
                                   (if (phony--rule-generated-p rule)
                                       (phony-parser--map #'cadr parser)
                                     parser)))
                               rules))))))))

(defun earwig--phony-parse-spans (words grammar)
  "Return every reading of each span of WORDS as one command of GRAMMAR.
WORDS is a list of strings.  The value is a vector with an element for
each word: for the word at START, a list of (END AST COST), one for
each reading of the words from START up to END as a command.  AST is
to evaluate with `earwig--phony-evaluate-ast', COST is the number of
words of free text.  A command anchored to the beginning only starts
at the first word, one anchored to the end only ends at the last.

Stands for `phony-parse-spans'."
  (earwig--phony-new-parse)
  (let* ((words (vconcat words))
         (length (length words))
         (spans (make-vector length nil)))
    (dotimes (start length)
      (let ((parsers (seq-keep (pcase-lambda (`(,anchors . ,parser))
                                 (and (or (= start 0) (not (car anchors)))
                                      (cons (cdr anchors) parser)))
                               (earwig--phony-command-parsers grammar)))
            (found (make-hash-table :test #'equal))
            (end start)
            entries)
        (while (and parsers (< end length))
          (let ((word (aref words end)))
            (cl-incf end)
            (setq parsers
                  (seq-keep
                   (pcase-lambda (`(,anchor-end . ,parser))
                     (let ((parser (phony-parser--step parser word)))
                       (unless (phony-parser--empty-p parser)
                         (when (or (not anchor-end) (= end length))
                           (pcase-dolist (`(,ast . ,cost) (phony-parser--parses parser))
                             (let* ((key (cons end ast))
                                    (entry (gethash key found)))
                               (cond ((null entry)
                                      (setq entry (list end ast cost))
                                      (puthash key entry found)
                                      (push entry entries))
                                     ((< cost (nth 2 entry))
                                      (setf (nth 2 entry) cost))))))
                         (cons anchor-end parser))))
                   parsers))))
        (aset spans start (nreverse entries))))
    spans))

(defun earwig--phony-evaluate-ast (ast grammar)
  "Return the value of AST, a reading of a rule of GRAMMAR.
A procedure rule's body is evaluated with the values of its arguments.

Stands for `phony-evaluate-ast'."
  (if (atom ast)
      ast
    (let* ((type (car ast))
           (evaluate (lambda (argument) (earwig--phony-evaluate-ast argument grammar)))
           (rule (phony--get-rule type grammar)))
      (cond
       ((eq type 'list) (mapcar evaluate (cdr ast)))
       ((phony--dictionary-p rule) (phony--dictionary-elt rule (cadr ast)))
       ((phony--procedure-rule-p rule)
        (apply (phony--procedure-rule-function rule) (mapcar evaluate (cdr ast))))
       ((phony--open-rule-p rule) (funcall evaluate (cadr ast)))
       (t (error "Can't evaluate the Phony reading %S" ast))))))

;;;; Rules and patterns

(defun earwig--phony-interactive-rules (grammar)
  "Return the names of the rules of GRAMMAR that can be said as commands.
Those are the interactive procedure rules active in the current buffer,
sorted by name.

Stands for `phony-interactive-rules'."
  (thread-last
    (phony--interactive-rules grammar)
    (seq-filter #'phony--rule-active-p)
    (mapcar (lambda (rule)
              (if (phony--rule-generated-p rule)
                  (car (phony--products rule))
                rule)))
    (seq-filter #'phony--rule-active-p)
    (mapcar #'phony--rule-name)
    (seq-uniq)
    (seq-sort #'string<)))

(defun earwig--phony-rule-documentation (name grammar)
  "Return the docstring of the rule NAME of GRAMMAR, or nil.

Stands for `phony-rule-documentation'."
  (phony--rule-documentation (earwig--phony-rule name grammar)))

(defun earwig--phony-rule-function (name grammar)
  "Return the function of the procedure rule NAME of GRAMMAR.
It takes the values of the rule's arguments, in the order
`earwig--phony-pattern-arguments' gives them.

Stands for `phony-rule-function'."
  (phony--procedure-rule-function (earwig--phony-rule name grammar t)))

(defun earwig--phony-unparse (pattern)
  "Return the Phony PATTERN, an object, as a form for `phony-defun'."
  (pcase pattern
    ((cl-struct phony-pattern--literal string) string)
    ((cl-struct phony-pattern--rule) (phony-pattern--rule-name pattern))
    ((cl-struct phony-pattern--builtin-word) 'phony--builtin-word)
    ((cl-struct phony-pattern--builtin-phrase) 'phony--builtin-phrase)
    ((cl-struct phony-pattern--argument name (pattern sub))
     (list name (earwig--phony-unparse sub)))
    ((cl-struct phony-pattern--sequence patterns)
     (cons 'seq (mapcar #'earwig--phony-unparse patterns)))
    ((cl-struct phony-pattern--alternative patterns)
     (cons '| (mapcar #'earwig--phony-unparse patterns)))
    ((cl-struct phony-pattern--optional (pattern sub))
     (list '\? (earwig--phony-unparse sub)))
    ((cl-struct phony-pattern--one-or-more (pattern sub))
     (list '+ (earwig--phony-unparse sub)))
    ((cl-struct phony-pattern--zero-or-more (pattern sub))
     (list '* (earwig--phony-unparse sub)))
    (_ (error "Can't show the Phony pattern %S" pattern))))

(defun earwig--phony-rule-pattern (name grammar)
  "Return the pattern of the procedure rule NAME of GRAMMAR.
It's a `seq' form, as written in `phony-defun', with every argument
explicit, as in (ARG PATTERN), and one pattern in each optional or
repeated one.

Stands for `phony-rule-pattern'."
  (earwig--phony-unparse
   (phony--procedure-rule-pattern (earwig--phony-rule name grammar t))))

(defun earwig--phony-interface-provider (name grammar)
  "Return the name of the rule that provides the interface NAME in GRAMMAR.
If that's an interface too, its provider, and so on; nil if there's
none, as for an interface that isn't defined.

Stands for `phony-interface-provider'."
  (let ((rule (phony--get-rule name grammar)))
    (while (and rule (phony--interface-rule-p rule))
      (setq rule (phony--interface-resolved-provider rule)))
    (and rule (phony--rule-name rule))))

(eval-and-compile
  (defun earwig--phony-pattern-arguments (pattern)
    "Return the names of the arguments PATTERN binds, in order.
PATTERN is as given to `phony-defun'; the arguments are those of the
rule's body.  For macros that define rules, so it's there at compile
time too.

Stands for `phony-pattern-arguments'."
    (phony--collect-arguments
     (phony--expand-implicit-arguments (cons 'seq (ensure-list pattern))))))

(provide 'earwig-phony)
;;; earwig-phony.el ends here
