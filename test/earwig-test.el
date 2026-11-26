;;; earwig-test.el --- Tests for Earwig  -*- lexical-binding: t; -*-

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

;; Run from the repository, with phony.el and simulacrum on the load
;; path (here installed by package.el):
;;
;;   emacs -Q --batch -L . \
;;     --eval '(progn (package-initialize) (require (quote phony)))' \
;;     -l test/earwig-test.el -f ert-run-tests-batch-and-exit
;;
;; `earwig-test-stream' streams speech made by macOS's say through the
;; Orukeet server; it's skipped unless sox, say and the server are there.

;;; Code:

(require 'ert)
(require 'org)
(require 'earwig)

(defmacro earwig-test-buffer (text mode &rest body)
  "Run BODY in a buffer in MODE with TEXT, point where TEXT has a |.
Return the buffer's text afterwards."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (funcall ,mode)
     (goto-char (point-min))
     (when (search-forward "|" nil t)
       (delete-char -1))
     ,@body
     (buffer-string)))

(defmacro earwig-test-corrections (corrections &rest body)
  "Run BODY with CORRECTIONS and none learned yet; return BODY's value.
Learned ones are saved to a temporary `custom-file'."
  (declare (indent 1))
  `(let* ((earwig-corrections ,corrections)
          (earwig-corrections-commands nil)
          (earwig-corrections-learned nil)
          (custom-file (make-temp-file "earwig-test-" nil ".el"))
          ;; Customize saves nothing under emacs -Q otherwise
          (user-init-file custom-file))
     (unwind-protect
         (progn ,@body)
       (delete-file custom-file))))

(defmacro earwig-test-with-rules (names &rest body)
  "Run BODY, then remove the Phony rules NAMES it defines."
  (declare (indent 1))
  `(unwind-protect
       (progn ,@body)
     (dolist (name ',names)
       (phony-remove-rule name))))

(defun earwig-test-target (spec)
  "Return the `earwig-target' with SPEC."
  (earwig--target-make spec))

(defun earwig-test-command (text mode command)
  "Return TEXT in MODE after the voice COMMAND, point where TEXT has a |."
  (let ((inhibit-message t))
    (earwig-test-buffer text mode (earwig-run-command command))))

;;;; Cleaning up dictation

(ert-deftest earwig-test-fillers ()
  (should (equal (earwig-remove-fillers "Um, so I think, uh, we should go.")
                 "So I think we should go.")))

(ert-deftest earwig-test-corrections ()
  (earwig-test-corrections '(("Maggot" . "Magit") ("in it yell" . "init.el"))
    (should (equal (earwig-apply-corrections "open maggot and in it yell")
                   "open Magit and init.el"))
    ;; Learned ones win for the same wrong
    (let ((earwig-corrections-learned '(("maggot" . "magit-status"))))
      (should (equal (earwig-apply-corrections "Maggot") "Magit-status")))))

(ert-deftest earwig-test-corrections-commands ()
  (earwig-test-corrections nil
    (let ((earwig-corrections-commands '(("kut" . "cut")))
          (earwig-wake-word-commands t)
          (earwig--mode 'dictate))
      (should (equal (earwig-find-command "Kut that.")
                     `(earwig-say-edit cut ,(earwig-test-target '(that)))))
      ;; Only when the command as said reads as none
      (earwig-test-with-rules (earwig-test-find-note)
        (phony-defun earwig-test-find-note ("find note" (name earwig-text))
          (ignore name))
        (should (equal (earwig-find-command "Find note Kut.") '(earwig-test-find-note "Kut"))))
      ;; Not in dictation, around a command or not
      (should (equal (earwig-apply-corrections "Kut said hi.") "Kut said hi."))
      (should (equal (earwig-test-buffer "|" #'fundamental-mode
                       (insert (earwig--process-text "Kut said hi." (current-buffer) (point))))
                     "Kut said hi.")))))

(ert-deftest earwig-test-spoken-format ()
  (let ((format (lambda (text) (substring-no-properties (earwig-apply-format text)))))
    (should (equal (funcall format "Hello comma world period") "Hello, world."))
    (should (equal (funcall format "See you tomorrow, period.") "See you tomorrow."))
    (should (equal (funcall format "A literal period of time.") "A period of time."))
    (should (equal (funcall format "Call open paren maybe close paren now.")
                   "Call (maybe) now."))
    (should (equal (funcall format "Call open parent maybe close parent now.")
                   "Call (maybe) now."))
    (let ((earwig-spoken-format (cons '(punct "," "coma") earwig-spoken-format)))
      (should (equal (funcall format "Yes coma no.") "Yes, no.")))))

(ert-deftest earwig-test-fit-to-context ()
  (should (equal (earwig-test-buffer "We went |home" #'fundamental-mode
                   (insert (earwig-fit-to-context "To the store." (current-buffer) (point))))
                 "We went to the store home"))
  ;; A sentence ends before markup that closes after its period
  (dolist (markup '("*" "**" "/" "=" "_"))
    (should (equal (earwig-test-buffer (format "%sDone.%s|" markup markup) #'fundamental-mode
                     (insert (earwig-fit-to-context "Next one." (current-buffer) (point))))
                   (format "%sDone.%s Next one." markup markup))))
  (should (equal (earwig-test-buffer "a *b*|" #'fundamental-mode
                   (insert (earwig-fit-to-context "Next one." (current-buffer) (point))))
                 "a *b* next one.")))

;; Dictation at a heading or item, in Org
(defun earwig-test-title (before text &optional after)
  "Return BEFORE with TEXT dictated after it, and AFTER after that, in Org."
  (earwig-test-buffer (concat before "|" after) #'org-mode
    (insert (earwig--process-text text (current-buffer) (point)))))

(ert-deftest earwig-test-fit-titles ()
  ;; A heading starts with a capital, after a TODO keyword and priority too
  (should (equal (earwig-test-title "* TODO " "Buy milk.") "* TODO Buy milk"))
  (should (equal (earwig-test-title "** DONE [#A] " "buy milk.") "** DONE [#A] Buy milk"))
  (should (equal (earwig-test-title "* TODO " "Buy milk." "  :shop:") "* TODO Buy milk  :shop:"))
  ;; A heading and a checkbox item have no period of Orukeet's, but
  ;; keep one that's said, a question mark, and more than one sentence
  (should (equal (earwig-test-title "* " "Buy milk, period.") "* Buy milk."))
  (should (equal (earwig-test-title "* " "Is it ready?") "* Is it ready?"))
  (should (equal (earwig-test-title "* " "Call Bob. He's waiting.") "* Call Bob. He's waiting."))
  (should (equal (earwig-test-title "* Call Bob. " "He's waiting.") "* Call Bob. He's waiting."))
  (should (equal (earwig-test-title "* Release 2.0" " and more.") "* Release 2.0 and more"))
  ;; A segment going on with the title
  (should (equal (earwig-test-title "* Buy milk" "And eggs.") "* Buy milk and eggs"))
  (should (equal (earwig-test-title "- [ ] " "buy milk.") "- [ ] Buy milk"))
  ;; Other items keep it, and get a capital, unless the word has its own
  (should (equal (earwig-test-title "- " "buy milk.") "- Buy milk."))
  (should (equal (earwig-test-title "1. " "iPhone case.") "1. iPhone case."))
  ;; Elsewhere, the capital is up to Orukeet
  (should (equal (earwig-test-title "Done.\n" "buy milk.") "Done.\nbuy milk."))
  (should (equal (earwig-test-title "* TODOS " "list.") "* TODOS list")))

(ert-deftest earwig-test-fit-quotes ()
  (let ((fit (lambda (before text)
               (earwig-test-buffer before #'text-mode
                 (goto-char (point-max))
                 (let* ((text (earwig-apply-format text nil (current-buffer) (point)))
                        (pos (earwig-absorb-before text (current-buffer) (point))))
                   (goto-char pos)
                   (insert (earwig-fit-to-context text (current-buffer) pos))))))
        (earwig-curly-quotes t))
    ;; No space after an opening quote, and a capital where it starts a sentence
    (should (equal (funcall fit "“" "Hello there.") "“Hello there."))
    (should (equal (funcall fit "He said, “" "Hello there.") "He said, “Hello there."))
    (should (equal (funcall fit "the so-called “" "Experts.") "the so-called “experts."))
    (should (equal (funcall fit "He said \"" "hello") "He said \"hello"))
    ;; After a closing quote, a new sentence only after a period
    (should (equal (funcall fit "“Hi,” " "He said.") "“Hi,” he said."))
    (should (equal (funcall fit "“Some people!” " "Exclaimed Frodo.") "“Some people!” exclaimed Frodo."))
    (should (equal (funcall fit "“He is resting.” " "He left.") "“He is resting.” He left."))
    ;; Spoken quotes and apostrophes curled
    (should (equal (funcall fit "" "Open quote, hello there, comma close quote he said.")
                   "“Hello there,” he said."))
    (should (equal (funcall fit "Then he said, " "Open quote. Don't go. Close quote.")
                   "Then he said, “Don’t go.”"))
    (should (equal (funcall fit "" "Open single quote I may come, comma close single quote he said.")
                   "‘I may come,’ he said."))
    (let ((earwig-curly-quotes nil))
      (should (equal (funcall fit "" "Open quote, don't go, close quote.") "\"Don't go.\"")))
    ;; "quote" closes a quote open in the paragraph, else opens one
    (should (equal (funcall fit "" "Quote fiddlesticks exclamation mark quote he snapped.")
                   "“Fiddlesticks!” he snapped."))
    (should (equal (funcall fit "“Fiddlesticks!" "Quote. He snapped.")
                   "“Fiddlesticks!” he snapped."))
    (should (equal (funcall fit "“Hello,” he said. " "Quote. How are you? Quote.")
                   "“Hello,” he said. “How are you?”"))
    (should (equal (funcall fit "“First.”\n\n" "Quote second period quote")
                   "“First.”\n\n“Second.”"))
    (should (equal (funcall fit "‘I don’t know" "Single quote, he said.")
                   "‘I don’t know,’ he said."))
    ;; "new sentence" gives the word after a capital
    (should (equal (funcall fit "" "Quote fiddlesticks exclamation mark quote new sentence he snapped.")
                   "“Fiddlesticks!” He snapped."))
    (should (equal (funcall fit "“Fiddlesticks!”" "New sentence. He snapped.")
                   "“Fiddlesticks!” He snapped."))
    ;; Orukeet's punctuation goes inside a closing quote, spoken punctuation wins
    (should (equal (funcall fit "" "Kurt said comma quote it will be painful for her quote.")
                   "Kurt said, “It will be painful for her.”"))
    (should (equal (funcall fit "Kurt said, “It will be painful for her." "Quote.")
                   "Kurt said, “It will be painful for her.”"))
    (should (equal (funcall fit "“It will be painful for her" "Quote.")
                   "“It will be painful for her.”"))
    (should (equal (funcall fit "" "Quote. Only one thing is clear to me, comma quote, said Otho continue, quote, and that is that you are doing well out of it.")
                   "“Only one thing is clear to me,” said Otho, “and that is that you are doing well out of it."))
    ;; "continue quote" opens one after a comma, with no capital
    (should (equal (funcall fit "" "Quote I may be able comma quote he said continue quote to tell you.")
                   "“I may be able,” he said, “to tell you."))
    (dolist (before '("“I may,” he said." "“I may,” he said" "“I may,” he said, "))
      (should (equal (funcall fit before "Continue quote. To tell you.")
                     "“I may,” he said, “to tell you."))))
  ;; Curly where electric-quote-mode would curl what's typed
  (let ((earwig-curly-quotes 'electric))
    (with-temp-buffer
      (text-mode)
      (should-not (earwig--curly-quotes-p (point)))
      (electric-quote-local-mode 1)
      (should (earwig--curly-quotes-p (point))))))

(ert-deftest earwig-test-correct ()
  (earwig-test-corrections nil
    (let ((inhibit-message t))
      (should (equal (earwig-test-buffer "open maggot" #'fundamental-mode
                       (earwig-correct 6 12 "Magit"))
                     "open Magit"))
      (should (equal earwig-corrections-learned '(("maggot" . "Magit"))))
      (earwig-test-buffer "open maggot" #'fundamental-mode
        (earwig-correct 6 12 "magit"))
      (should (equal earwig-corrections-learned '(("maggot" . "magit"))))
      (should (with-temp-buffer
                (insert-file-contents custom-file)
                (search-forward "(earwig-corrections-learned '((\"maggot\" . \"magit\")))" nil t))))))

;;;; Commands

(ert-deftest earwig-test-find-command ()
  (should (equal (earwig-find-command "Delete last two words.")
                 `(earwig-say-edit delete ,(earwig-test-target '(units (last 2) "word" nil nil)))))
  (should (equal (earwig-find-command "go to line forty two") '(earwig-say-goto-line 42)))
  (should (equal (earwig-find-command "go to line 42") '(earwig-say-goto-line 42)))
  (should (equal (earwig-find-command "What can I say?") '(earwig-say-help)))
  (should-not (earwig-find-command "nonsense blah"))
  ;; Two commands are no one command
  (should-not (earwig-find-command "go to top paste")))

(ert-deftest earwig-test-user-commands ()
  "Phony rules of your own are commands, and win over Earwig's for the same words."
  (earwig-test-with-rules (earwig-test-close earwig-test-remind)
    (phony-defun earwig-test-close ("close" (? "buffer"))
      "Close it my way."
      (ignore))
    (should (equal (earwig-find-command "Close buffer.") '(earwig-test-close)))
    ;; Earwig's rules for parts of commands, and its dates
    (phony-defun earwig-test-remind ("remind me" (? (time earwig-when)) "to" (task earwig-text))
      (list time task))
    (should (equal (earwig-find-command "Remind me on Friday to call mum")
                   '(earwig-test-remind "on friday" "call mum")))
    (should (equal (earwig-find-commands "go to top remind me to call mum")
                   '(("go to top" earwig-say-top)
                     ("remind me to call mum" earwig-test-remind nil "call mum"))))
    ;; "what can I say" shows them
    (let ((inhibit-message t))
      (save-window-excursion
        (earwig-cmd-help)
        (with-current-buffer "*Voice commands*"
          (should (string-search "remind me [TIME] to TASK" (buffer-string)))
          (should (string-search "Close it my way." (buffer-string))))))))

(ert-deftest earwig-test-find-commands ()
  (should (equal (earwig-find-commands
                  "Format bold results, and then select the last sentence and then cut that. And then go to bottom, and then paste.")
                 `(("Format bold results" earwig-say-format bold
                    ,(earwig-test-target '(words "results")))
                   ("select the last sentence" earwig-say-edit select
                    ,(earwig-test-target '(units (last 1) "sentence" nil nil)))
                   ("cut that." earwig-say-edit cut ,(earwig-test-target '(that)))
                   ("go to bottom" earwig-say-bottom)
                   ("paste." earwig-say-paste))))
  ;; Split only where every part is a command
  (should (equal (earwig-find-commands "replace and then with so")
                 '(("replace and then with so" earwig-say-replace "and then" "so" nil nil))))
  (should-not (earwig-find-commands "nonsense and then blah"))
  ;; Without "and then" too
  (should (equal (mapcar #'car (earwig-find-commands
                                "select last sentence cut that go to bottom paste"))
                 '("select last sentence" "cut that" "go to bottom" "paste")))
  ;; Free text that can't be checked runs to the end, or to "and then"
  (should (equal (earwig-find-commands "search budget go to top")
                 '(("search budget go to top" earwig-say-search "budget go to top"))))
  (should (equal (mapcar #'car (earwig-find-commands "search budget and then go to top"))
                 '("search budget" "go to top")))
  ;; Parts of the buffer before words, and a scope before more words
  (should (equal (earwig-find-commands "replace one with two in this paragraph")
                 `(("replace one with two in this paragraph" earwig-say-replace "one" "two"
                    ,(earwig-test-target '(units (this) "paragraph" nil nil)) nil))))
  (should (equal (earwig-find-commands "meow in the last two sentences")
                 nil))
  (should (equal (cdar (earwig-find-commands "copy meow in the last two sentences"))
                 `(earwig-say-edit copy
                                   ,(earwig-test-target
                                     `(in ,(earwig-test-target '(words "meow"))
                                          ,(earwig-test-target '(units (last 2) "sentence" nil nil))))))))

(ert-deftest earwig-test-run-commands-by-buffer ()
  "Which reading runs depends on what's in the buffer then."
  ;; "budget cut that" isn't there: select budget, then cut that
  (should (equal (earwig-test-command "The budget is final.|" #'text-mode
                                      "select budget cut that")
                 "The is final."))
  ;; It is: one command, select it all
  (should (equal (earwig-test-buffer "The budget cut that we made.|" #'text-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "select budget cut that"))
                   (should (equal (buffer-substring (region-beginning) (region-end))
                                  "budget cut that")))
                 "The budget cut that we made."))
  ;; A pause splits them, even then
  (should (equal (earwig-test-command "The budget cut that we made.|" #'text-mode
                                      "Select budget. Cut that.")
                 "The cut that we made."))
  ;; "with" is split at the first place where there's something to replace
  (should (equal (earwig-test-command "Tea with milk.|" #'text-mode
                                      "replace tea with milk with coffee")
                 "Milk with coffee with milk."))
  (should (equal (earwig-test-command "Some tea.|" #'text-mode
                                      "replace coffee with milk with tea")
                 "Some tea."))
  ;; Each command against the buffer as the one before left it
  (should (equal (earwig-test-buffer "one two three|" #'text-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "cut last word go to top paste select three"))
                   ;; "three" is only there again once pasted
                   (should (equal (buffer-substring (region-beginning) (region-end)) "three")))
                 "three one two"))
  ;; A number that doesn't parse says so
  (with-temp-buffer
    (let (said)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq said (apply #'format-message format args)))))
        (earwig-run-command "go to line lots"))
      (should (equal said "Voice command \"go to line lots\" failed: \
Can’t parse number \"lots\": \"lots\" is no number")))))

(ert-deftest earwig-test-chain-words-custom ()
  (let ((earwig-chain-words '("then")))
    (should (equal (mapcar #'car (earwig-find-commands "search budget then go to top"))
                   '("search budget" "go to top"))))
  (should (equal (mapcar #'car (earwig-find-commands "search budget then go to top"))
                 '("search budget then go to top"))))

(ert-deftest earwig-test-cancel-words ()
  (should (equal (earwig--strip-cancel-word "Select last sentence and then cut that, cancel.")
                 '("Select last sentence and then cut that" . "cancel")))
  (should (equal (earwig--strip-cancel-word "Save, never mind.") '("Save" . "never mind")))
  (should (equal (earwig--strip-cancel-word "Never mind.") '("" . "Never mind")))
  (should-not (earwig--strip-cancel-word "Cancel the meeting."))
  (should-not (earwig--strip-cancel-word "No cancellation"))
  (let ((ran nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args) (setq ran (cons function args))))
              ((symbol-function 'message) #'ignore))
      (with-temp-buffer
        ;; With a command key, a wake word said anyway is dropped
        (let ((earwig--mode 'command))
          (should-not (earwig--process-text "Okay, go to top." (current-buffer) 1))
          (should (equal (cadr ran) "go to top."))
          (setq ran nil)
          (should-not (earwig--process-text "Go to top and then save, cancel." (current-buffer) 1))
          (should-not ran))
        ;; After a wake word: neither run nor dictated
        (let ((earwig--mode 'dictate)
              (earwig-wake-word-commands t))
          (should-not (earwig--process-text "Okay, go to top, never mind." (current-buffer) 1))
          (should-not (earwig--process-text "Okay, cancel." (current-buffer) 1))
          (should-not ran)
          ;; Without one it's dictation
          (should (equal (earwig--process-text "We had to cancel." (current-buffer) 1)
                         "We had to cancel.")))))))

(ert-deftest earwig-test-provisional-command-text ()
  (let ((earwig-command-icon ">")
        (earwig-provisional-chain-mark nil))
    (let ((text (earwig--provisional-command-text "Okay, go to top and then sav")))
      (should (equal (substring-no-properties text) "go to top > sav"))
      ;; What isn't a command yet is grey
      (should-not (get-text-property 0 'face text))
      (should (eq (get-text-property (1- (length text)) 'face text) 'earwig-provisional)))
    ;; Said with a command key, there's no wake word, but one said anyway goes
    (should (equal (substring-no-properties (earwig--provisional-command-text "go to top" t))
                   "go to top"))
    (should (equal (substring-no-properties
                    (earwig--provisional-command-text "okay, go to top" t))
                   "go to top"))
    ;; Cancelled: struck through
    (let ((text (earwig--provisional-command-text "go to top and then save, never mind." t)))
      (should (equal (substring-no-properties text) "go to top > save never mind"))
      (should (equal (get-text-property 0 'face text) '(:strike-through t)))
      (should (eq (get-text-property (1- (length text)) 'face text) 'earwig-mode-line-command)))))

(ert-deftest earwig-test-command-preview ()
  "A command key's recording is shown as it's said, and C-g drops it."
  (let ((file (make-temp-file "earwig-test-" nil ".wav"))
        (earwig-command-icon ">")
        shown)
    (unwind-protect
        (progn
          ;; What the recorder has written so far, after the header
          (with-temp-file file
            (set-buffer-multibyte nil)
            (insert (earwig--wav-header 0) (make-string 5 ?a)))
          (should (equal (earwig--recorded-so-far file) "aaaa"))
          (cl-letf (((symbol-function 'message)
                     (lambda (_format &rest args) (setq shown (car args)))))
            (earwig--show-command-preview "Go to top and then save.")
            (should (equal (substring-no-properties shown) "> go to top > save"))))
      (delete-file file)))
  (let ((earwig--record-process nil))
    (should-not (earwig--cancel-key-filter 'earwig-cancel-recording))))

(ert-deftest earwig-test-paste ()
  "Voice paste spaces text as dictation, and puts lines in as lines."
  (let ((sentence-end-double-space nil)
        (kill-ring nil)
        (interprogram-cut-function nil)
        (interprogram-paste-function nil))
    ;; A sentence moved before another
    (should (equal (earwig-test-command "Mercy is a premium feature. Ask about our pricing!|"
                                        #'text-mode
                                        "cut last sentence and then go before mercy and then paste")
                   "Ask about our pricing! Mercy is a premium feature."))
    ;; A word between two, but not before punctuation
    (should (equal (earwig-test-command "one three four|" #'text-mode
                                        "cut four and then go after one and then paste")
                   "one four three"))
    (should (equal (earwig-test-command "one, two|" #'text-mode
                                        "cut one and then go after two and then paste")
                   "two one"))
    ;; A line cut whole goes before the line point is in, or after it from its end
    (let ((items "- Igor owns the lightning\n- The sharks get their lasers back\n- A cat|"))
      (should (equal (earwig-test-command
                      items #'org-mode
                      "go after sharks and then cut this line and then go before Igor and then paste")
                     "- The sharks get their lasers back\n- Igor owns the lightning\n- A cat"))
      (should (equal (earwig-test-command
                      items #'org-mode
                      "go after Igor and then cut this line and then go after a cat and then paste")
                     "- The sharks get their lasers back\n- A cat\n- Igor owns the lightning\n"))
      ;; Copied, too
      (should (equal (earwig-test-command
                      items #'org-mode
                      "go after Igor and then copy this line and then go before a cat and then paste")
                     "- Igor owns the lightning\n- The sharks get their lasers back\n- Igor owns the lightning\n- A cat")))))

(ert-deftest earwig-test-paste-evil ()
  "In evil, lines cut whole are line-wise, and paste goes where \"go\" said."
  (skip-unless (require 'evil nil t))
  (let ((sentence-end-double-space nil)
        (kill-ring nil)
        (interprogram-cut-function nil)
        (interprogram-paste-function nil))
    (dolist (state '(evil-normal-state evil-insert-state))
      (with-temp-buffer
        (insert "- Igor\n- Sharks\nMercy is free. Ask us!")
        (org-mode)
        (set-window-buffer nil (current-buffer))
        (evil-local-mode 1)
        (funcall state)
        (let ((inhibit-message t))
          (earwig-run-command "go after sharks and then cut this line")
          ;; For evil's own paste too
          (should (equal (get-text-property 0 'yank-handler (car kill-ring))
                         '(evil-yank-line-handler nil t)))
          (earwig-run-command "go before Igor and then paste")
          (goto-char (point-max))
          (earwig-run-command "cut last sentence and then go before mercy and then paste"))
        (should (equal (buffer-string) "- Sharks\n- Igor\nAsk us! Mercy is free."))))))

(ert-deftest earwig-test-chain ()
  (let ((transient-mark-mode t)
        (sentence-end-double-space nil))
    (should (equal (earwig-test-command "The results are in. Move me.|\n\nLast line." #'org-mode
                                        "format bold results and then select the last sentence and then cut that, and then go to bottom, and then paste")
                   "The *results* are in.\n\nLast line. Move me.")))
  ;; A step that fails stops the rest
  (should (equal (earwig-test-command "one two three four|" #'fundamental-mode
                                      "delete last word and then select zzz and then delete last word")
                 "one two three"))
  ;; Said after a wake word while dictating, a chain is a command too
  (let ((earwig-wake-word-commands t)
        (earwig--mode 'dictate)
        ran)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args) (setq ran (cons function args)))))
      (should-not (earwig--process-text "Okay, delete last word and then go to top."
                                          (current-buffer) (point))))
    (should (equal ran (list #'earwig--run-command-in "delete last word and then go to top."
                             (current-buffer))))))

;; As its provisional text shows, with a command key or after a wake word
(ert-deftest earwig-test-log-commands ()
  (let ((earwig-log-commands t)
        (earwig-wake-word-commands t)
        (earwig-provisional-icons t)
        (earwig-provisional-chain-mark nil)
        (earwig-command-icon "▶")
        (start (with-current-buffer (messages-buffer) (point-max))))
    (cl-flet ((logged ()
                (with-current-buffer (messages-buffer)
                  (prog1 (seq-filter (lambda (line) (string-prefix-p "Voice command" line))
                                     (split-string (buffer-substring start (point-max)) "\n" t))
                    (setq start (point-max))))))
      (cl-letf (((symbol-function 'run-at-time) #'ignore)
                ((symbol-function 'earwig--stream-command-heard) #'ignore))
        (earwig-test-buffer "|" #'fundamental-mode
          (let ((earwig--mode 'dictate))
            (earwig--process-text "Okay, select last sentence, and then cut that."
                                  (current-buffer) (point))
            ;; Dictation isn't logged
            (earwig--process-text "Hello there." (current-buffer) (point)))
          (let ((earwig--mode 'command))
            (earwig--process-text "Go to top, never mind." (current-buffer) (point))))
        (let ((lines (logged)))
          (should (equal (mapcar #'substring-no-properties lines)
                         '("Voice command: ▶ select last sentence ▶ cut that"
                           "Voice command: ▶ Go to top never mind"
                           "Voice command cancelled: Go to top")))
          ;; With the faces of the provisional text
          (should (eq (get-text-property 15 'face (car lines)) 'earwig-mode-line-command))
          (should (memq :strike-through
                        (flatten-tree (get-text-property 17 'face (nth 1 lines))))))
        ;; Off by default
        (let ((earwig-log-commands (eval (car (get 'earwig-log-commands 'standard-value))))
              (earwig--mode 'command))
          (earwig-test-buffer "|" #'fundamental-mode
            (earwig--process-text "Go to top." (current-buffer) (point))))
        (should-not (logged))))))

;; As Orukeet wrote it, and what it gave
(ert-deftest earwig-test-log-transcriptions ()
  (let ((earwig-log-transcriptions t)
        (earwig-wake-word-commands t)
        (earwig--mode 'dictate)
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args) (push (apply #'format format args) messages)))
              ((symbol-function 'run-at-time) #'ignore))
      (earwig-test-buffer "|" #'fundamental-mode
        (should (equal (earwig--process-text "Kurt said, comma quote, hi quote." (current-buffer)
                                             (point))
                       "Kurt said, \"Hi.\""))
        (should-not (earwig--process-text "Okay, go to top." (current-buffer) (point)))
        (let ((buffer-read-only t))
          (earwig--process-text "Hi." (current-buffer) (point)))))
    (should (equal (reverse messages)
                   '("Orukeet: \"Kurt said, comma quote, hi quote.\" => \"Kurt said, \\\"Hi.\\\"\""
                     "Orukeet: \"Okay, go to top.\" => command"
                     "Buffer is read-only, dictation not inserted: Hi."
                     "Orukeet: \"Hi.\" => nothing inserted")))
    ;; Off by default
    (setq messages nil)
    (let ((earwig-log-transcriptions nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (earwig-test-buffer "|" #'fundamental-mode
          (earwig--process-text "Hi." (current-buffer) (point)))))
    (should-not messages)))

(ert-deftest earwig-test-parse-number ()
  (dolist (case '(("42" . 42) ("forty two" . 42) ("Forty-Two" . 42) ("forty 2" . 42)
                  ("one hundred and five" . 105) ("one hundred five" . 105)
                  ("a hundred" . 100) ("hundred" . 100) ("a thousand and one" . 1001)
                  ("two thousand and five" . 2005) ("two thousand 5" . 2005)
                  ("one hundred thousand" . 100000) ("twenty one hundred" . 2100)
                  ("nineteen hundred eighty four" . 1984)
                  ("one million two hundred thousand and three" . 1200003)
                  ("2 million" . 2000000) ("42 thousand" . 42000)
                  ("zero" . 0) ("42." . 42) ("007" . 7)
                  ;; Separators, as Orukeet writes them, or after `earwig--command-text'
                  ("1,000" . 1000) ("1 000" . 1000) ("1,234,567" . 1234567)
                  ;; Said digit by digit or in parts
                  ("one one" . 11) ("1, 1" . 11) ("two three" . 23) ("1 05" . 105)
                  ("nineteen eighty-four" . 1984) ("nineteen oh five" . 1905)
                  ("twenty twenty" . 2020) ("five twenty" . 520)
                  ;; Decimals
                  ("two point five" . 2.5) ("2.5" . 2.5) (".5" . 0.5) ("point five" . 0.5)
                  ("three point one four" . 3.14) ("two decimal zero five" . 2.05)
                  ("2.0" . 2.0)))
    (should (equal (cons (car case) (earwig-parse-number (car case))) case)))
  (dolist (case '(("lots" . "\"lots\" is no number")
                  ("minus three" . "\"minus\" is no number")
                  ("-3" . "\"-3\" is no number")
                  ("third" . "\"third\" is no number")
                  ("" . "there's no number")
                  ("five hundred hundred" . "\"hundred\" after \"hundred\"")
                  ("one thousand thousand" . "\"thousand\" after \"thousand\"")
                  ("two thousand hundred" . "\"hundred\" after \"thousand\"")
                  ("one and two" . "\"and\" after \"one\"")
                  ("one hundred and" . "nothing after \"and\"")
                  ("one hundred and and five" . "\"and\" after \"and\"")
                  ("a five" . "\"a\" before \"five\"")
                  ("five a hundred" . "\"a\" goes only first")
                  ("two point" . "nothing after \"point\"")
                  ("1.2.3" . "a second decimal point")
                  ("1.5 million" . "\"million\" after a decimal point")))
    (let ((err (should-error (earwig-parse-number (car case)) :type 'user-error)))
      (should (string-match-p (concat "\\`Can.t parse number \"" (regexp-quote (car case))
                                      "\": " (regexp-quote (cdr case)))
                              (error-message-string err)))))
  ;; WHOLE refuses decimals; NOERROR returns nil
  (should (equal (error-message-string
                  (should-error (earwig-parse-number "two point five" t) :type 'user-error))
                 "Not a whole number: \"two point five\""))
  (should (equal (earwig-parse-number "two" t) 2))
  (should-not (earwig-parse-number "lots" nil t))
  (should-not (earwig-parse-number "2.5" t t))
  ;; The match data stays, for the groups after the number
  (should (string-match "\\(.+\\) \\(words\\)" "twenty one words"))
  (earwig-parse-number "twenty one")
  (should (equal (match-string 2 "twenty one words") "words"))
  ;; Commands say why
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (let (said)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq said (apply #'format-message format args)))))
        (earwig-run-command "go to line two point five"))
      (should (string-search "Not a whole number" said)))
    (let ((inhibit-message t))
      (earwig-run-command "go to line two"))
    (should (= (line-number-at-pos) 2))))

(ert-deftest earwig-test-heard-words ()
  "A dash or dot written for silence is nothing heard."
  (should-not (earwig-heard-words-p "-"))
  (should-not (earwig-heard-words-p " — . "))
  (should (earwig-heard-words-p "Dash."))
  (should (earwig-heard-words-p "42")))

(ert-deftest earwig-test-wake-word ()
  (should (equal (earwig--strip-wake-word "Okay, delete that") "delete that"))
  (should-not (earwig--strip-wake-word "delete that")))

;;;; Editing

(ert-deftest earwig-test-edit ()
  (should (equal (earwig-test-command "The quick brown fox jumps|" #'fundamental-mode
                                      "delete last two words")
                 "The quick brown"))
  (should (equal (earwig-test-command "I like emacs lisp a lot|" #'fundamental-mode
                                      "capitalize emacs lisp")
                 "I like Emacs Lisp a lot"))
  (should (equal (earwig-test-command "the lord of the rings|" #'fundamental-mode
                                      "title case this line")
                 "The Lord of the Rings")))

(ert-deftest earwig-test-replace ()
  (should (equal (earwig-test-command "Monday we meet. On monday too." #'fundamental-mode
                                      "replace monday with tuesday everywhere")
                 "Tuesday we meet. On tuesday too."))
  ;; The next, previous or every place the words are
  (should (equal (earwig-test-command "sharks a sharks| b sharks c sharks" #'text-mode
                                      "replace next sharks with dolphins")
                 "sharks a sharks b dolphins c sharks"))
  (should (equal (earwig-test-command "sharks a sharks| b sharks c sharks" #'text-mode
                                      "replace previous sharks with dolphins")
                 "dolphins a sharks b sharks c sharks"))
  (should (equal (earwig-test-command "sharks a| sharks" #'text-mode
                                      "replace every sharks with dolphins")
                 "dolphins a dolphins"))
  (should (equal (earwig-test-command "One sharks.\n\nTwo sharks| and sharks." #'text-mode
                                      "replace every sharks in this paragraph with dolphins")
                 "One sharks.\n\nTwo dolphins and dolphins.")))

(ert-deftest earwig-test-format ()
  (should (equal (earwig-test-command "Some important words|" #'org-mode
                                      "format bold last word")
                 "Some important *words*"))
  (should (equal (earwig-test-command "Some important *words*|" #'org-mode
                                      "format bold last word")
                 "Some important words"))
  ;; The style after the target
  (should (equal (earwig-test-command "Some important words|" #'org-mode
                                      "format last word bold")
                 "Some important *words*"))
  ;; WORDS in PART is every place they are there
  (should (equal (earwig-test-command "Moon one. Moon base two. The moon base three.|" #'org-mode
                                      "format italic moon base in the last three sentences")
                 "Moon one. /Moon base/ two. The /moon base/ three."))
  ;; A command that acts on one place takes the nearest
  (should (equal (earwig-test-region "Moon one. The moon base. Moon base two.|" #'org-mode
                                     "select moon base in the last three sentences")
                 "Moon base")))

(ert-deftest earwig-test-last-sentence ()
  "The sentence point ends, or is just before the period of, counts whole.
One point is inside doesn't: the last and the next are the ones around it."
  (let ((sentence-end-double-space nil))
    (dolist (text '("One two. Three four|." "One two. Three four.|"))
      (should (equal (earwig-test-command text #'fundamental-mode "delete last sentence")
                     "One two.")))
    (should (equal (earwig-test-command "One two. Three four|. Five." #'fundamental-mode
                                        "delete last two sentences")
                   "Five."))
    (should (equal (earwig-test-command "One two. Three| four. Five six." #'fundamental-mode
                                        "delete last sentence")
                   "Three four. Five six."))
    (should (equal (earwig-test-command "One two. Three| four. Five six." #'fundamental-mode
                                        "delete next sentence")
                   "One two. Three four."))
    ;; As scopes
    (dolist (case '(("this sentence" . "A moon. A /moon/ costs more.")
                    ("previous sentence" . "A /moon/. A moon costs more.")
                    ("last sentence" . "A /moon/. A moon costs more.")))
      (should (equal (earwig-test-command "A moon. A moon costs| more." #'org-mode
                                          (concat "format italic moon in " (car case)))
                     (cdr case))))
    ;; Not past a planning line or a heading
    (let ((text "* TODO Laugh\nSCHEDULED: <2026-11-20 Fri>\nLoud, not too loud. It| should be menacing.\n* Next\nMore.\n"))
      (earwig-test-buffer text #'org-mode
        (let ((inhibit-message t))
          (earwig-run-command "select last sentence"))
        (should (equal (buffer-substring (region-beginning) (region-end)) "Loud, not too loud.")))
      (should (equal (earwig-test-command text #'org-mode "delete last two sentences")
                     "* TODO Laugh\nSCHEDULED: <2026-11-20 Fri>\nIt should be menacing.\n* Next\nMore.\n"))
      (should (equal (earwig-test-command text #'org-mode "delete next two sentences")
                     "* TODO Laugh\nSCHEDULED: <2026-11-20 Fri>\nLoud, not too loud. It should be menacing.\n* Next\nMore.\n")))
    ;; A period inside emphasis ends the sentence
    (should (equal (earwig-test-command "*It is tight.* Mercy| is extra." #'org-mode
                                        "delete last sentence")
                   "Mercy is extra."))))

(ert-deftest earwig-test-part-range ()
  "Parts of the buffer give their range, words to look for nil."
  (let ((sentence-end-double-space nil)
        (earwig--last-dictation nil)
        range)
    (earwig-test-buffer "One two. Three four. Five six|." #'fundamental-mode
      (setq range (earwig-part-range "Last two sentences")))
    (should (equal range '(10 . 31)))
    ;; Counts of more than one word, in parts, and decimals
    (earwig-test-buffer "a b c d e f g h i j k l m n o p q r s t u v w x y|" #'fundamental-mode
      (should (equal (earwig-part-range "last twenty one words") '(9 . 50)))
      (should (equal (earwig-part-range "last one one words") '(29 . 50)))
      (should (equal (error-message-string
                      (should-error (earwig-part-range "last two point five words")
                                    :type 'user-error))
                     "Not a whole number: \"two point five\""))
      (should-error (earwig-part-range "last few words") :type 'user-error))
    (earwig-test-buffer "One two. Three| four." #'fundamental-mode
      (setq range (list (earwig-part-range "the whole buffer")
                        (earwig-part-range "three four"))))
    (should (equal range '((1 . 21) nil)))
    (earwig-test-buffer "One two|" #'fundamental-mode
      (transient-mark-mode 1)
      (should-error (earwig-part-range nil) :type 'user-error)
      (set-mark 1)
      (activate-mark)
      (setq range (earwig-part-range "selection")))
    (should (equal range '(1 . 8)))))

(ert-deftest earwig-test-go-back ()
  "\"go back\" returns from the last go, whatever moved the mark since."
  (let ((inhibit-message t)
        (earwig--go-from nil))
    (earwig-test-buffer "One two| three" #'fundamental-mode
      (transient-mark-mode 1)
      (earwig-run-command "go after three")
      (should (= (point) 14))
      (earwig-run-command "select last word")
      (deactivate-mark)
      (earwig-run-command "go back")
      (should (= (point) 8))
      ;; And again, back to where it went
      (earwig-run-command "go back")
      (should (= (point) 14))
      ;; Not after "next one" that selects
      (earwig-run-command "go to top")
      (earwig-run-command "select one")
      (earwig-run-command "next one")
      (earwig-run-command "go back")
      (should (= (point) 14)))
    (with-temp-buffer
      (should-error (earwig-cmd-go-back) :type 'user-error))))

;;;; Targets and commands of phase 2

(defconst earwig-test-org "* Plans
SCHEDULED: <2026-11-24 Tue>
Some plans here.
** Budget review
Numbers are in.
*** Open questions
Who pays?
** Timeline
It is late|.
* Other
- milk
- eggs
  - brown
- bread
"
  "An Org buffer for the tests of headings, sections and items.")

(defun earwig-test-region (text mode command)
  "Return the region in TEXT in MODE after the voice COMMAND."
  (let (region)
    (earwig-test-buffer text mode
      (transient-mark-mode 1)
      (let ((inhibit-message t))
        (earwig-run-command command))
      (setq region (and (use-region-p) (buffer-substring (region-beginning) (region-end)))))
    region))

(ert-deftest earwig-test-heading-targets ()
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select this heading") "Timeline"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select the previous heading")
                 "Open questions"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select the next heading") "Other"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select the parent heading") "Plans"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select the parent headline") "Plans"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select the previous section")
                 "** Budget review\nNumbers are in.\n*** Open questions\nWho pays?"))
  ;; The body is without the planning line and the subheadings
  (should (equal (earwig-test-region earwig-test-org #'org-mode
                                     "select the body of the heading with plans")
                 "Some plans here."))
  (should (equal (earwig-test-region earwig-test-org #'org-mode
                                     "select the subheadings of the heading with budget")
                 "*** Open questions\nWho pays?"))
  (should (equal (earwig-test-command earwig-test-org #'org-mode
                                      "delete everything under the heading with budget")
                 (replace-regexp-in-string "|" "" (string-replace "Numbers are in.
*** Open questions
Who pays?
" "" earwig-test-org))))
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select the item with eggs")
                 "- eggs\n  - brown"))
  ;; The words of "the heading with" must be in a title
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select the section with pays")
                 nil))
  ;; The first or last of a section count what's under its heading
  (should (equal (earwig-test-region earwig-test-org #'org-mode
                                     "select the last item of the section with other")
                 "- bread"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode
                                     "select the last heading of the section with plans")
                 "Timeline"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode
                                     "select the first section of the section with plans")
                 "** Budget review\nNumbers are in.\n*** Open questions\nWho pays?"))
  ;; "this", "that" or "a" heard for "the"
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select this section with budget")
                 "** Budget review\nNumbers are in.\n*** Open questions\nWho pays?"))
  (should (equal (earwig-test-region earwig-test-org #'org-mode "select a heading with budget")
                 "Budget review"))
  ;; "next heading" is a target, no longer a command of its own
  (should-not (earwig-find-command "next heading"))
  (should-not (earwig-find-command "next item")))

(ert-deftest earwig-test-word-targets ()
  (let ((sentence-end-double-space nil))
    (should (equal (earwig-test-command "a meow b meow c|" #'text-mode "uppercase every meow")
                   "a MEOW b MEOW c"))
    (should (equal (earwig-test-command "One meow. Two meow. Three meow.|" #'text-mode
                                        "uppercase every meow in the last two sentences")
                   "One meow. Two MEOW. Three MEOW."))
    (should (equal (earwig-test-command "one two three four two|" #'text-mode
                                        "capitalize each of one three and four")
                   "One two Three Four two"))
    ;; "A and B" is one target when it's there as words, two otherwise
    (should (equal (earwig-test-command "Salt and pepper. Salt. Pepper.|" #'text-mode
                                        "delete salt and pepper")
                   "Salt. Pepper."))
    (should (equal (earwig-test-command "We need salt. Also pepper.|" #'text-mode
                                        "delete salt and pepper")
                   "We need. Also."))
    (should (equal (earwig-test-command "Salt and pepper. Salt. Pepper.|" #'text-mode
                                        "delete both salt and pepper")
                   "Salt and pepper."))
    ;; The next and previous, from point
    (should (equal (earwig-test-buffer "two one |two three two" #'text-mode
                     (let ((inhibit-message t))
                       (earwig-run-command "go before the previous two")
                       (should (= (point) 1))
                       (earwig-run-command "go after the next two")
                       (should (= (point) 12))
                       (earwig-run-command "go to the end of this line")
                       (should (= (point) (point-max)))))
                   "two one two three two"))
    (should (equal (earwig-test-region "First one. The sentence with however here. Last.|"
                                       #'text-mode "select the sentence with however")
                   "The sentence with however here."))
    ;; The first or last of a part; "first" alone counts from the start of
    ;; this sentence, its natural container
    (should (equal (earwig-test-command "Who pays? Does the moat| need a lifeguard?" #'text-mode
                                        "delete the first word of this sentence")
                   "Who pays? The moat need a lifeguard?"))
    (should (equal (earwig-test-region "Who pays? Does the moat| need a lifeguard? Yes." #'text-mode
                                       "select the last two words of this sentence")
                   "a lifeguard"))
    (should (equal (earwig-test-command "Who pays? Does the moat| need a lifeguard?" #'text-mode
                                        "go to the beginning of this sentence delete first word")
                   "Who pays? The moat need a lifeguard?"))
    ;; The second, third ... of a part, from its start or its end
    (should (equal (earwig-test-region "One a. Two b. Three c. Four d.|" #'text-mode
                                       "select the second sentence of this paragraph")
                   "Two b."))
    (should (equal (earwig-test-region "One a. Two b. Three c. Four d.|" #'text-mode
                                       "select the third to last sentence in this paragraph")
                   "Two b."))
    (should (equal (earwig-test-region "One a. Two b. Three c. Four d.|" #'text-mode
                                       "select the next to last word of this paragraph")
                   "Four"))
    (should (equal (earwig-test-region "- a\n- b\n- c|\n" #'org-mode
                                       "select the 2nd item of the whole buffer")
                   "- b"))
    ;; "the word" for words that mean something else in a target
    (should (equal (earwig-find-command "wrap the word this in single quotes")
                   `(earwig-say-wrap ,(earwig-test-target '(words "this")) single-quotes)))))

(ert-deftest earwig-test-delete-tidies ()
  "Deleting the start of a sentence takes punctuation left there, passing on a capital."
  (let ((sentence-end-double-space nil))
    (should (equal (earwig-test-command "- Yeah! Igor owns the lightning|" #'org-mode "delete yeah")
                   "- Igor owns the lightning"))
    (should (equal (earwig-test-command "Done. So, the plan works.|" #'text-mode "delete so")
                   "Done. The plan works."))
    (should (equal (earwig-test-command "f(a, b)|" #'text-mode "delete a")
                   "f(b)"))
    ;; Not in the middle of a sentence
    (should (equal (earwig-test-command "It works now.|" #'text-mode "delete now")
                   "It works."))
    ;; Nor when dictation takes its place
    (should (equal (earwig-test-command "Yeah! Igor owns it.|" #'text-mode "rewrite yeah")
                   "! Igor owns it."))))

(ert-deftest earwig-test-delete-tidies-leftovers ()
  "Deleting takes punctuation left doubled, and markup or brackets left around nothing."
  (let ((sentence-end-double-space nil))
    (dolist (case '(("Not too loud, because they cried.|" "cut because through cried"
                     "Not too loud.")
                    ("Loud, really loud, but quiet.|" "delete really loud"
                     "Loud, but quiet.")
                    ("Values: speed, rigor.|" "delete speed" "Values: rigor.")
                    ("Tea, milk; sugar.|" "delete milk" "Tea; sugar.")
                    ("Lasers (red, green) here.|" "delete green" "Lasers (red) here.")
                    ("A (\"premium feature\") ok.|" "delete premium feature" "A ok.")))
      (should (equal (earwig-test-command (car case) #'text-mode (cadr case))
                     (caddr case))))
    (should (equal (earwig-test-command "We agreed to _unveil it on Monday_. Yes.|" #'org-mode
                                        "cut from unveil through Monday")
                   "We agreed to. Yes."))
    (when (require 'markdown-mode nil t)
      (should (equal (earwig-test-command "We agreed to **unveil it** today.|" #'markdown-mode
                                          "delete unveil it")
                     "We agreed to today.")))
    ;; Markers inside words aren't markup
    (should (equal (earwig-test-command "Use a_b_c and more.|" #'org-mode "delete and more")
                   "Use a_b_c."))))

(ert-deftest earwig-test-move ()
  (let ((sentence-end-double-space nil)
        (earwig-flash nil))
    ;; A section takes the level of where it goes
    (should (equal (earwig-test-command "* A\n** B|\n* C\n" #'org-mode
                                        "move this section after the section with c")
                   "* A\n* C\n* B\n"))
    (should (equal (earwig-test-command "* A\n** B|\nb\n* C\n" #'org-mode
                                        "move this section under the heading with c")
                   "* A\n* C\n** B\nb\n"))
    (should (equal (earwig-test-command earwig-test-org #'org-mode
                                        "move this section before the section with budget")
                   "* Plans
SCHEDULED: <2026-11-24 Tue>
Some plans here.
** Timeline
It is late.
** Budget review
Numbers are in.
*** Open questions
Who pays?
* Other
- milk
- eggs
  - brown
- bread
"))
    ;; Items as lines, indented where they go
    (should (equal (earwig-test-command "- milk\n- eggs\n  - brown\n- bread|\n" #'org-mode
                                        "move the item with milk after the item with bread")
                   "- eggs\n  - brown\n- bread\n- milk\n"))
    (should (equal (earwig-test-command "- milk\n- eggs\n- bread|\n" #'org-mode
                                        "move the item with bread under the item with milk")
                   "- milk\n  - bread\n- eggs\n"))
    ;; Paragraphs as paragraphs, other text spaced as dictation is
    (should (equal (earwig-test-command "First.\n\nSecond here.\n\nThird|." #'text-mode
                                        "move this paragraph before the paragraph with second")
                   "First.\n\nThird.\n\nSecond here."))
    (should (equal (earwig-test-command "one two three four|" #'text-mode "move two after four")
                   "one three four two"))
    (should (equal (earwig-test-command "one two three four|" #'text-mode
                                        "copy two to the start of this line")
                   "two one two three four"))
    ;; Into an empty body, on a line of its own
    (should (equal (earwig-test-command "* A\nSome text.\n* B\n* C|\n" #'org-mode
                                        "copy some text to the end of the body of the heading with b")
                   "* A\nSome text.\n* B\nSome text\n* C\n"))
    ;; "that" is what went in last
    (should (equal (earwig-test-command "- call mum\n- buy milk|\n" #'org-mode
                                        "duplicate the item with call mum and then replace mum with dad in that")
                   "- call mum\n- call dad\n- buy milk\n"))
    (should (equal (earwig-test-command "one two three four|" #'text-mode
                                        "swap two with four uppercase that")
                   "one four three TWO"))
    (should (equal (earwig-test-command "* A\n** B\nb\n** C\nc|\n" #'org-mode
                                        "swap this section with the section with b")
                   "* A\n** C\nc\n** B\nb\n"))
    ;; One undo step
    (should (equal (earwig-test-buffer "one two three four|" #'text-mode
                     (buffer-enable-undo)
                     (let ((inhibit-message t))
                       (earwig-run-command "move two after four"))
                     (undo-boundary)
                     (undo))
                   "one two three four"))))

(ert-deftest earwig-test-markdown-sections ()
  "Markdown's # headings, not those in code blocks, and blank lines between sections."
  (skip-unless (require 'markdown-mode nil t))
  (let ((earwig-flash nil)
        (text "# Plans\n\n## Budget\n\nNumbers.\n\n```sh\n# not a heading\n```\n\n## Timeline\n\nLate|.\n"))
    (should (equal (earwig-test-command text #'markdown-mode
                                        "move this section before the section with budget")
                   "# Plans\n\n## Timeline\n\nLate.\n\n## Budget\n\nNumbers.\n\n```sh\n# not a heading\n```\n"))
    (should (equal (earwig-test-region text #'markdown-mode "select the previous heading")
                   "Budget"))))

(ert-deftest earwig-test-rewrite ()
  (should (equal (earwig-test-buffer "A big dog|" #'text-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "rewrite big"))
                   (should (= (point) 3)))
                 "A dog"))
  ;; A list item keeps its bullet
  (should (equal (earwig-test-command "- milk\n- eggs|\n" #'org-mode "rewrite this item")
                 "- milk\n- \n"))
  ;; A heading keeps its stars and space, and the dictation is its title
  (should (equal (earwig-test-buffer "* Notes\n* Old title|\n" #'org-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "rewrite this heading"))
                   (earwig-insert-dictation (list "lessons learned.") (current-buffer) (point)))
                 "* Notes\n* Lessons learned\n")))

(ert-deftest earwig-test-wrap ()
  (let ((earwig-flash nil))
    (should (equal (earwig-test-command "The budget is final.|" #'text-mode
                                        "wrap budget in quotes")
                   "The \"budget\" is final."))
    (should (equal (earwig-test-command "He said “hi”. The budget|" #'text-mode
                                        "put quotes around budget")
                   "He said “hi”. The “budget”"))
    (should (equal (earwig-test-command "Some words here and there|" #'text-mode
                                        "wrap words here in dashes")
                   "Some — words here — and there"))
    (should (equal (earwig-test-command "Some which words context here|" #'text-mode
                                        "wrap from which until context into parenthesis")
                   "Some (which words context) here"))
    (should (equal (earwig-test-command "A dog the big one barks.|" #'text-mode
                                        "wrap the big one in commas")
                   "A dog, the big one, barks."))
    (should (equal (earwig-test-command "f(a, (b c), d)|" #'text-mode "unwrap b")
                   "f(a, b c, d)"))
    (should (equal (earwig-test-command "Say 'go' but don't.|" #'text-mode "unwrap go")
                   "Say go but don't."))
    (should (equal (earwig-test-command "A dog, the big one, barks.|" #'text-mode
                                        "replace the commas around the big one with dashes")
                   "A dog — the big one — barks."))
    (should (equal (earwig-test-command "It is (as noted) final.|" #'text-mode
                                        "change the parentheses around as noted to commas")
                   "It is, as noted, final."))
    (should (equal (earwig-test-command "An aside at the end, like this.|" #'text-mode
                                        "remove the commas around like this")
                   "An aside at the end like this."))))

(ert-deftest earwig-test-move-to ()
  "\"to\" or \"into\" a target is \"under\" it, and a selection of whole items moves as items."
  (let ((earwig-flash nil)
        (sentence-end-double-space nil))
    (should (equal (earwig-test-buffer "* A\n1. one\n2. two\n3. three\n* B\nText.|\n" #'org-mode
                     (transient-mark-mode 1)
                     (let ((inhibit-message t))
                       (earwig-run-command "select the first two items of the section with a")
                       (earwig-run-command "move that to the section with b")))
                   "* A\n1. three\n* B\nText.\n1. one\n2. two\n"))
    (should (equal (earwig-test-command "* A\n- one\n* B|\n" #'org-mode
                                        "move the item with one into the heading with b")
                   "* A\n* B\n- one\n"))
    ;; "to the end of" is still the end of
    (should (equal (earwig-test-command "One. Two.|" #'text-mode
                                        "move the first sentence of this paragraph to the end of this paragraph")
                   "Two. One."))))

(ert-deftest earwig-test-checkbox-targets ()
  "\"checkbox\" is an item with one; items and checkboxes move under each other."
  (let ((earwig-flash nil)
        (list "* T\n- [ ] Find a cat\n- Feed the cat\n- [ ] Pet the cat|\n"))
    (should (equal (earwig-test-command list #'org-mode
                                        "move the checkbox with pet the cat under the item with feed the cat")
                   "* T\n- [ ] Find a cat\n- Feed the cat\n  - [ ] Pet the cat\n"))
    (should (equal (earwig-test-command list #'org-mode
                                        "move the item with feed the cat under the checkbox with find a cat")
                   "* T\n- [ ] Find a cat\n  - Feed the cat\n- [ ] Pet the cat\n"))
    (should (equal (earwig-test-region list #'org-mode "select the previous checkbox")
                   "- [ ] Find a cat"))
    ;; An item without one isn't a checkbox
    (should-not (earwig-test-region list #'org-mode "select the checkbox with feed"))
    ;; Deleting a sub-item leaves the next one's indentation alone
    (should (equal (earwig-test-command "- [ ] a\n  - [ ] feed\n  - [ ] pet|\n" #'org-mode
                                        "delete the checkbox with feed")
                   "- [ ] a\n  - [ ] pet\n"))
    ;; A sub-item put under a heading goes to the margin, its own sub-items with it
    (should (equal (earwig-test-command "* A\n- a\n  - feed\n    - more\n* B|\n" #'org-mode
                                        "copy the item with feed to the heading with b")
                   "* A\n- a\n  - feed\n    - more\n* B\n- feed\n  - more\n"))))

(ert-deftest earwig-test-new-sub-checkbox ()
  "A checkbox or item one level deeper, by its phrase in dictation or under a target."
  (dolist (case '(("new item under this item" . "- [ ] a\n  - \n")
                  ("new checkbox under this item" . "- [ ] a\n  - [ ] \n")
                  ("new sub checkbox" . "- [ ] a\n  - [ ] \n")
                  ("new checkbox after this item" . "- [ ] a\n- [ ] \n")))
    (should (equal (earwig-test-command "- [ ] a|\n" #'org-mode (car case)) (cdr case)))))

(ert-deftest earwig-test-new-item-no-checkbox ()
  "Only \"new checkbox\" makes a checkbox, even in a list of them."
  (dolist (mode '(org-mode markdown-mode))
    (when (fboundp mode)
      (should (equal (earwig-test-buffer "- [ ] one|\n" mode
                       (earwig-structure-do 'item))
                     "- [ ] one\n- \n"))
      (should (equal (earwig-test-buffer "- [ ] one|\n" mode
                       (earwig-structure-do 'checkbox))
                     "- [ ] one\n- [ ] \n"))))
  (should (equal (earwig-test-command "* A\n- [ ] one\n* B|\n" #'org-mode
                                      "new item under the heading with a")
                 "* A\n- [ ] one\n- \n* B\n"))
  (should (equal (earwig-test-command "- [ ] one\n- [ ] two|\n" #'org-mode
                                      "new item before the item with two")
                 "- [ ] one\n- \n- [ ] two\n")))

(ert-deftest earwig-test-new-item-under-heading ()
  ;; The list the heading's text ends with goes on, at its outer level
  (should (equal (earwig-test-command "* A\nText.\n- one\n  - sub\n- two\n* B|\n" #'org-mode
                                      "new item under the heading with a")
                 "* A\nText.\n- one\n  - sub\n- two\n- \n* B\n"))
  (should (equal (earwig-test-command "* A\n1. one\n2. two\n* B|\n" #'org-mode
                                      "new item under heading with a")
                 "* A\n1. one\n2. two\n3. \n* B\n"))
  ;; Else a list starts, after the text or in an empty body
  (should (equal (earwig-test-command "* A\nText.\n* B|\n" #'org-mode
                                      "new item under the heading with a")
                 "* A\nText.\n\n- \n* B\n"))
  (should (equal (earwig-test-command "* A\n* B|\n" #'org-mode
                                      "new item under the heading with a")
                 "* A\n- \n* B\n"))
  ;; Dictation fills it
  (should (equal (earwig-test-buffer "* Lessons\n* B|\n" #'org-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "new item under the heading with lessons"))
                   (earwig-insert-dictation (list "denied.") (current-buffer) (point)))
                 "* Lessons\n- Denied\n* B\n")))

(ert-deftest earwig-test-new-at ()
  (should (equal (earwig-test-command earwig-test-org #'org-mode
                                      "new heading after the heading with budget")
                 (string-replace "** Timeline" "** \n** Timeline"
                                 (string-replace "|" "" earwig-test-org))))
  (should (equal (earwig-test-command "* A\n* B|\n" #'org-mode "new heading before the heading with a")
                 "* \n* A\n* B\n"))
  (should (equal (earwig-test-command "- milk\n- eggs|\n" #'org-mode
                                      "new item before the item with eggs")
                 "- milk\n- \n- eggs\n"))
  (should (equal (earwig-test-command "- milk\n- eggs|\n" #'org-mode
                                      "add an item under the item with milk")
                 "- milk\n  - \n- eggs\n"))
  ;; Dictation fills it
  (should (equal (earwig-test-buffer "* A\n* B|\n" #'org-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "new heading before the heading with b"))
                   (earwig-insert-dictation (list "next steps.") (current-buffer) (point)))
                 "* A\n* Next steps\n* B\n"))
  ;; Without that heading, the words are the new heading's title
  (should (equal (earwig-test-command "* A|\n" #'org-mode "new heading after the heading with zebra")
                 "* A\n* After the heading with zebra\n"))
  (should (equal (earwig-test-command "First.\n\nSecond however here.|" #'text-mode
                                      "new paragraph before however")
                 "First.\n\nSecond\n\n\n\nhowever here.")))

(ert-deftest earwig-test-go-into-focus-where ()
  (should (equal (earwig-test-buffer earwig-test-org #'org-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "go into the heading with budget"))
                   (should (looking-back "Numbers are in\\." nil)))
                 (string-replace "|" "" earwig-test-org)))
  ;; An empty body gets a line of its own, after the planning line
  (should (equal (earwig-test-buffer "* A\nSCHEDULED: <2026-11-24 Tue>\n* B|\n" #'org-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "go into the heading with a"))
                   (insert "Text"))
                 "* A\nSCHEDULED: <2026-11-24 Tue>\nText\n* B\n"))
  (should (equal (earwig-test-buffer earwig-test-org #'org-mode
                   (let ((inhibit-message t))
                     (earwig-run-command "focus on the section with budget")
                     (should (equal (buffer-string)
                                    "** Budget review\nNumbers are in.\n*** Open questions\nWho pays?\n"))
                     (earwig-run-command "replace numbers with digits everywhere and then show everything")))
                 (string-replace "Numbers" "Digits" (string-replace "|" "" earwig-test-org))))
  (let ((earwig-flash t)
        (earwig-flash-duration 2.5)
        times)
    (earwig-test-buffer "a meow b meow c|" #'text-mode
      (let ((inhibit-message t))
        (cl-letf* ((run-at-time (symbol-function 'run-at-time))
                   ((symbol-function 'run-at-time)
                    (lambda (time &rest args) (push time times) (apply run-at-time time args))))
          (earwig-run-command "where is every meow")))
      (should (equal times '(2.5 2.5)))
      (should (= (length (cl-remove-if-not (lambda (o) (eq (overlay-get o 'face) 'earwig-flash))
                                           (overlays-in (point-min) (point-max))))
                 2)))))

(ert-deftest earwig-test-links ()
  (let (opened)
    (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
      (earwig-test-buffer "See https://example.com/a and https://example.org/roadmap now.|"
          #'text-mode
        (let ((inhibit-message t))
          (earwig-run-command "open the link with roadmap")))
      (should (equal opened "https://example.org/roadmap"))
      (earwig-test-buffer "Plain. See https://example.com/a now.|" #'text-mode
        (let ((inhibit-message t))
          (earwig-run-command "open the link in this line")))
      (should (equal opened "https://example.com/a")))
    (should (equal (earwig-test-region "Budget: see [[https://x.org][the roadmap]] now.|" #'org-mode
                                       "select the link with roadmap")
                   "[[https://x.org][the roadmap]]"))))

;;;; Composable targets

(defconst earwig-test-chain "* Plans
Some plans| here. The moonbase is near.

Second para with moonbase. Another sentence here.

Third para without it.
- one first item
  - sub item
- two moonbase item
** Budget review
Numbers are in. Moonbase costs.
** Timeline
It is late.
** Extras
* Other
See [[https://x.org/report.pdf][Annual report]] and [[https://y.org/plan][the plan]].
"
  "An Org buffer for the tests of composable targets.")

(ert-deftest earwig-test-chain-grammar ()
  "Selectors chain with \"in\" or \"of\" to any depth, each the scope of the one before."
  (should (equal (earwig-find-command "delete the first word of the second sentence of this paragraph")
                 `(earwig-say-edit
                   delete
                   ,(earwig-test-target
                     `(units (range (1 . start) (1 . start)) "word" nil
                             ,(earwig-test-target
                               `(units (range (2 . start) (2 . start)) "sentence" nil
                                       ,(earwig-test-target
                                         '(units (this) "paragraph" nil nil)))))))))
  ;; Ranges of units, not the words "the third" through "fifth words"
  (should (equal (earwig-find-command "select the third through the fifth word")
                 `(earwig-say-edit select ,(earwig-test-target
                                            '(units (range (3 . start) (5 . start)) "word" nil nil)))))
  ;; A filter, then a scope; plurals are every one; ordinals in digits
  (should (equal (earwig-find-command "select the sentence with moonbase in the 21st paragraph")
                 `(earwig-say-edit select
                                   ,(earwig-test-target
                                     `(units nil "sentence" (with "moonbase")
                                             ,(earwig-test-target
                                               '(units (range (21 . start) (21 . start))
                                                       "paragraph" nil nil)))))))
  (should (equal (earwig-find-command "delete the paragraphs without moonbase")
                 `(earwig-say-edit delete ,(earwig-test-target
                                            '(units (every) "paragraph" (without "moonbase") nil)))))
  ;; The body of a heading in a chain
  (should (equal (earwig-find-command "select the first sentence of the body of the heading with budget")
                 `(earwig-say-edit select
                                   ,(earwig-test-target
                                     `(units (range (1 . start) (1 . start)) "sentence" nil
                                             ,(earwig-test-target
                                               `(body ,(earwig-test-target
                                                        '(units nil "heading" (with "budget") nil))))))))))

(ert-deftest earwig-test-natural-containers ()
  "Without a scope, a unit is counted in its natural container; a filter widens it."
  (let ((sentence-end-double-space nil)
        (org earwig-test-chain))
    ;; A word in its sentence, a sentence in its paragraph, a paragraph in the heading's text
    (should (equal (earwig-test-region org #'org-mode "select the second word") "plans"))
    (should (equal (earwig-test-region org #'org-mode "select the first sentence") "Some plans here."))
    (should (equal (earwig-test-region org #'org-mode "select the second paragraph")
                   "Second para with moonbase. Another sentence here."))
    ;; A list is one paragraph, an item's own text one for its sentences
    (should (equal (earwig-test-region org #'org-mode "select the fourth paragraph")
                   "- one first item\n  - sub item\n- two moonbase item"))
    ;; Siblings for ordinals: Extras is the third under Plans
    (should (equal (earwig-test-region org #'org-mode "select the third heading of the section with plans")
                   "Extras"))
    (should (equal (earwig-test-region org #'org-mode "select the second item of the section with plans")
                   "- two moonbase item"))
    ;; Filter first, then count, widening from the paragraph to the heading's text
    (should (equal (earwig-test-region org #'org-mode "select the second sentence with moonbase")
                   "Second para with moonbase."))
    (should (equal (earwig-test-region org #'org-mode "select the first sentence with moonbase")
                   "The moonbase is near."))
    ;; "last" alone is before point; with a filter or scope, from the end
    (should (equal (earwig-test-region org #'org-mode "select the last two words") "Some plans"))
    (should (equal (earwig-test-region org #'org-mode "select the last sentence of the second paragraph")
                   "Another sentence here."))
    (should (equal (earwig-test-region org #'org-mode
                                       "select the second to last sentence with moonbase in the section with plans")
                   "two moonbase item"))
    ;; Reversed ranges are swapped
    (should (equal (earwig-test-region "One two three four five six.|" #'text-mode
                                       "select the fifth through third words")
                   "three four five"))))

(ert-deftest earwig-test-chain-targets ()
  (let ((sentence-end-double-space nil)
        (org earwig-test-chain))
    (should (equal (earwig-test-region org #'org-mode
                                       "select the sentence with moonbase in the second paragraph")
                   "Second para with moonbase."))
    (should (equal (earwig-test-region org #'org-mode
                                       "select the first word of the second sentence of the second paragraph")
                   "Another"))
    (should (equal (earwig-test-region org #'org-mode
                                       "select moonbase in the first sentence of the second paragraph")
                   "moonbase"))
    (should (equal (earwig-test-region org #'org-mode
                                       "select the first sentence of the body of the heading with budget")
                   "Numbers are in."))
    (should (equal (earwig-test-region org #'org-mode
                                       "select everything under the second heading of this section")
                   "It is late."))
    ;; A plural scope is each of its parts, skipping those with too few
    (should (equal (earwig-test-command "One a. Two b.\n\nThree c.\n\nFour d. Five e.|" #'text-mode
                                        "uppercase the second sentence of every paragraph")
                   "One a. TWO B.\n\nThree c.\n\nFour d. FIVE E."))
    ;; An item's own text, not its sub-items
    (should (equal (earwig-test-command "- one a\n  - two b\n- three c|\n" #'org-mode
                                        "uppercase the first word of every item")
                   "- ONE a\n  - TWO b\n- THREE c\n"))
    ;; "this" in a scope only if point is there; "next" from point in it
    (should-not (earwig-test-region org #'org-mode "select this sentence in the second paragraph"))
    (should (equal (earwig-test-region org #'org-mode "select the next sentence in the second paragraph")
                   "Second para with moonbase."))
    ;; From one target to another
    (should (equal (earwig-test-region org #'org-mode
                                       "select the second sentence through the end of the second paragraph")
                   "The moonbase is near.\n\nSecond para with moonbase. Another sentence here."))
    ;; Overlapping parts are one
    (should (equal (earwig-test-command "one two three|" #'text-mode
                                        "delete the first two words and the second word")
                   "three"))))

(ert-deftest earwig-test-filters ()
  (let ((sentence-end-double-space nil)
        (org earwig-test-chain))
    (should (equal (earwig-test-region org #'org-mode "select the sentence ending with near")
                   "The moonbase is near."))
    (should (equal (earwig-test-region org #'org-mode "select the sentence starting with another")
                   "Another sentence here."))
    ;; Parts of words for the unit "word", whole words for others
    (should (equal (earwig-test-region org #'org-mode "select the word starting with moon") "moonbase"))
    (should (equal (earwig-test-region org #'org-mode "select the word containing oonb") "moonbase"))
    (should-not (earwig-test-region org #'org-mode "select the sentence starting with moon"))
    ;; Without, and every one with a filter
    (should (equal (error-message-string
                    (should-error (earwig-test-buffer org #'org-mode
                                    (earwig-cmd-edit 'select (earwig-test-target
                                                              '(units nil "sentence" (with "zebras") nil))))
                                  :type 'user-error))
                   "No sentence with \"zebras\" here"))
    (should (equal (earwig-test-region org #'org-mode "select the paragraph without moonbase")
                   "Third para without it."))
    (should (equal (earwig-test-command "A moon. B. C moon.|" #'text-mode
                                        "delete every sentence without moon")
                   "A moon. C moon."))
    ;; Several with gaps between: the verb acts on each, select can't
    (should (equal (earwig-test-command "A moon. B. C moon. D moon.|" #'text-mode
                                        "uppercase the first through second sentences with moon")
                   "A MOON. B. C MOON. D moon."))
    (should-not (earwig-test-region "A moon. B. C moon.|" #'text-mode
                                    "select the first through second sentences with moon"))
    ;; Links by their visible text or URL, headings by their title
    (should (equal (earwig-test-region org #'org-mode "select the link ending with pdf")
                   "[[https://x.org/report.pdf][Annual report]]"))
    (should (equal (earwig-test-region org #'org-mode "select the link starting with the")
                   "[[https://y.org/plan][the plan]]"))
    (should (equal (earwig-test-region org #'org-mode "select the heading ending with review")
                   "Budget review"))))

(ert-deftest earwig-test-replace-targets ()
  "\"replace\" takes any target, whose text the new words replace."
  (let ((sentence-end-double-space nil))
    (should (equal (earwig-test-command "One two three.|" #'text-mode "replace the second word with moon")
                   "One moon three."))
    (should (equal (earwig-test-command "Hello there. All done.|" #'text-mode
                                        "replace the second sentence with see you then")
                   "Hello there. See you then."))
    (should (equal (earwig-test-command "A moonbase.\n\nB moonbase and moonbase.|" #'text-mode
                                        "replace moonbase in the second paragraph with base")
                   "A moonbase.\n\nB base and base."))
    ;; A bullet stays, and sub-items
    (should (equal (earwig-test-command "- milk\n- Brian owns it\n  - sub\n- eggs|\n" #'org-mode
                                        "replace the item with brian with Igor owns the thunder")
                   "- milk\n- Igor owns the thunder\n  - sub\n- eggs\n"))
    ;; "the word" is words, even one that's a target
    (should (equal (earwig-test-command "Say this now.|" #'text-mode "replace the word this with that")
                   "Say that now."))
    ;; The words "that" without a region, as before
    (should (equal (earwig-test-command "Not that one.|" #'text-mode "replace that with this")
                   "Not this one."))))

;;;; Headings, lists and joins

(ert-deftest earwig-test-structure-parts ()
  (should (equal (earwig-structure-parts
                  "That's all for now. New heading. Next steps. First we plan it.")
                 '("That's all for now." heading "Next steps. First we plan it."))))

(ert-deftest earwig-test-dictate-structure ()
  (should (equal (earwig-test-buffer "* Notes\nThat's all for now.|" #'org-mode
                   (let ((earwig--mode 'dictate))
                     (earwig-insert-dictation
                      (earwig--process-text "New heading. Next steps. First we plan it. \
New item, buy milk. New item, call mum." (current-buffer) (point))
                      (current-buffer) (point))))
                 "* Notes
That's all for now.
* Next steps
First we plan it.
- Buy milk
- Call mum
")))

(ert-deftest earwig-test-dictate-join-is-words ()
  ;; "join last sentence" changes text already there, so it needs a wake word
  (should-not (earwig-structure-split "Join last sentence." (current-buffer) (point)))
  (with-temp-buffer
    (org-mode)
    (insert "We went to the. Store today.")
    (let ((earwig--mode 'dictate))
      (should (equal (earwig--process-text "Join last sentence." (current-buffer) (point))
                     " Join last sentence.")))))

(ert-deftest earwig-test-join ()
  (should (equal (earwig-test-command "We went to the. Store today.|" #'fundamental-mode
                                      "join last sentence")
                 "We went to the store today."))
  (should (equal (earwig-test-command "I think so. Then we go.|" #'fundamental-mode
                                      "join last sentence with comma")
                 "I think so, then we go.")))

;;;; The mode

(ert-deftest earwig-test-mode ()
  (let ((dictate (caar earwig-toggle-keys))
        (correct (car earwig-correct-keys)))
    (unwind-protect
        (progn
          (earwig-mode -1)
          (should-not (eq (key-binding (kbd dictate)) #'earwig-voice-key))
          (earwig-mode 1)
          (should (eq (key-binding (kbd dictate)) #'earwig-voice-key))
          (should (eq (key-binding (kbd "<kp-enter>")) #'earwig-voice-key))
          (should (eq (key-binding (kbd correct)) #'earwig-correct))
          ;; Push-to-talk is off by default
          (should-not (eq (key-binding (kbd "SPC")) #'earwig-voice-key)))
      (earwig-mode -1))
    (should-not (eq (key-binding (kbd dictate)) #'earwig-voice-key))))

(ert-deftest earwig-test-keys ()
  (let ((push-to-talk earwig-push-to-talk-keys)
        (toggle earwig-toggle-keys)
        (correct (car earwig-correct-keys)))
    (unwind-protect
        (progn
          (keymap-set earwig-mode-map "C-c v" #'earwig-dictate)
          (setopt earwig-push-to-talk-keys '(("SPC" . dictate) ("s-f" . command))
                  earwig-toggle-keys '(("<f5>" . dictate)))
          (should-not (keymap-lookup earwig-mode-map "SPC"))
          (should (equal (earwig--mode-keys 'dictate) '("<f5>")))
          (setopt earwig-push-to-talk t)
          (should (eq (keymap-lookup earwig-mode-map "SPC") #'earwig-voice-key))
          (should (eq (keymap-lookup earwig-mode-map "<f5>") #'earwig-voice-key))
          (should-not (keymap-lookup earwig-mode-map (caar toggle)))
          (should (eq (keymap-lookup earwig-mode-map correct) #'earwig-correct))
          ;; A binding of your own stays
          (should (eq (keymap-lookup earwig-mode-map "C-c v") #'earwig-dictate))
          (should (eq (earwig--key-mode (kbd "s-f") earwig-push-to-talk-keys) 'command))
          (should-not (earwig--key-mode (kbd "s-f") earwig-toggle-keys))
          (should (equal (earwig--mode-keys 'dictate) '("<f5>" "SPC"))))
      (keymap-unset earwig-mode-map "C-c v" t)
      (setopt earwig-push-to-talk nil
              earwig-push-to-talk-keys push-to-talk
              earwig-toggle-keys toggle))
    (should (eq (keymap-lookup earwig-mode-map (caar toggle)) #'earwig-voice-key))
    (should-not (keymap-lookup earwig-mode-map "<f5>"))
    (should-not (keymap-lookup earwig-mode-map "SPC"))))

(defmacro earwig-test-presses (&rest body)
  "Run BODY with recording faked; `earwig-test-press' presses a key.
`recording' is the mode being recorded for, if any, and `toggles' how
often recording was started or stopped, `timer' what the last timer
would call.  Starting to record resets `earwig--stream-pushed-to-talk',
as `earwig-stream-start' does."
  (declare (indent 0) (debug t))
  `(let ((recording nil) (toggles 0) (time 100.0) (timer nil)
         (earwig--press nil) (earwig--typed-run nil)
         (earwig--stream-pushed-to-talk nil))
     (cl-letf (((symbol-function 'earwig--hold-now) (lambda () time))
               ((symbol-function 'earwig--recording-p) (lambda () recording))
               ((symbol-function 'earwig--toggle-recording)
                (lambda (mode)
                  (cl-incf toggles)
                  (setq recording (and (not recording) mode))
                  (when recording
                    (setq earwig--stream-pushed-to-talk nil))))
               ((symbol-function 'run-at-time)
                (lambda (_secs _repeat function &rest _) (setq timer function) nil)))
       (cl-flet ((earwig-test-press (key after)
                   (setq time (+ time after)
                         last-command-event (aref (key-parse key) 0))
                   (earwig--voice-key-press (key-parse key))))
         ,@body))))

(ert-deftest earwig-test-push-to-talk ()
  (let ((earwig-push-to-talk t)
        (earwig-push-to-talk-keys '(("s-d" . dictate) ("<f6>" . command) ("SPC" . dictate)))
        (earwig-toggle-keys '(("s-d" . dictate) ("<f5>" . command))))
    ;; Push to talk only: a tap does nothing, a hold records until let go
    (earwig-test-presses
      (earwig-test-press "<f6>" 0)
      (earwig--hold-end)
      (should (= toggles 0))
      (earwig-test-press "<f6>" 0)
      (earwig-test-press "<f6>" 0.5)
      (should (eq recording 'command))
      (earwig-test-press "<f6>" 0.03)
      (earwig--hold-release)
      (should-not recording)
      (should (= toggles 2)))
    ;; Toggle only: a hold is one press, letting go doesn't stop it
    (earwig-test-presses
      (earwig-test-press "<f5>" 0)
      (earwig-test-press "<f5>" 0.5)
      (earwig-test-press "<f5>" 0.03)
      (earwig--hold-release)
      (should (eq recording 'command))
      (should-not earwig--stream-pushed-to-talk)
      (earwig-test-press "<f5>" 2)
      (should-not recording))
    ;; Toggle only: a second tap soon after is a tap, as no repeat follows
    (earwig-test-presses
      (earwig-test-press "<f5>" 0)
      (should (eq recording 'command))
      (earwig-test-press "<f5>" 0.6)
      (should recording)
      (funcall timer)
      (should-not recording)
      (should (= toggles 2)))
    ;; Both: a tap toggles, a hold pushes to talk
    (earwig-test-presses
      (earwig-test-press "s-d" 0)
      (earwig--hold-end)
      (should (eq recording 'dictate))
      (should-not earwig--stream-pushed-to-talk)
      (earwig-test-press "s-d" 2)
      (should-not recording)
      (earwig-test-press "s-d" 2)
      (earwig-test-press "s-d" 0.5)
      (should earwig--stream-pushed-to-talk)
      (earwig--hold-release)
      (should-not recording))
    ;; With push-to-talk off, a key in both is a toggle key only
    (let ((earwig-push-to-talk nil))
      (earwig-test-presses
        (earwig-test-press "s-d" 0)
        (earwig-test-press "s-d" 0.5)
        (earwig--hold-release)
        (should (eq recording 'dictate))))
    ;; A key that types: tapped it types, held it takes that back and records
    (with-temp-buffer
      (earwig-test-presses
        (earwig-test-press "SPC" 0)
        (earwig--hold-end)
        (should (equal (buffer-string) " "))
        (should-not recording)
        (earwig-test-press "SPC" 2)
        (dolist (after '(0.5 0.03 0.03 0.03))
          (earwig-test-press "SPC" after))
        (should (equal (buffer-string) " "))
        (should (eq recording 'dictate))
        (should earwig--stream-pushed-to-talk)
        (earwig--hold-release)
        (should-not recording)))
    ;; Also where a mode types it with a command of its own, as Org does
    (with-temp-buffer
      (org-mode)
      (should (eq (key-binding (kbd "SPC")) 'org-self-insert-command))
      (earwig-test-presses
        (earwig-test-press "SPC" 0)
        (earwig--hold-end)
        (should (equal (buffer-string) " "))
        (earwig-test-press "SPC" 2)
        (dolist (after '(0.5 0.03 0.03 0.03))
          (earwig-test-press "SPC" after))
        (should (equal (buffer-string) " "))
        (should (eq recording 'dictate))
        (earwig--hold-release)
        (should-not recording)))))

;;;; Platforms
;; The Linux branches of earwig-platform.el, run here whatever the
;; system, with `system-type' bound and what the programs would say
;; given as their output.

(defmacro earwig-test-system (system outputs &rest body)
  "Run BODY as if on SYSTEM, a `system-type'.
OUTPUTS is an alist of (PROGRAM . OUTPUT): `earwig--run' gives
\(0 . OUTPUT) for PROGRAM, and fails for any other.  `ran' is the list
of commands run, the last first."
  (declare (indent 2))
  `(let ((system-type ,system)
         (earwig--sox-drivers-cache nil)
         (ran nil))
     (cl-letf (((symbol-function 'earwig--run)
                (lambda (program &rest args)
                  (push (cons program args) ran)
                  (let ((output (assoc program ,outputs)))
                    (if output (cons 0 (cdr output)) (cons -1 "not found"))))))
       ,@body)))

(defconst earwig-test-sox-help
  "SoX v14.4.2\n\nAUDIO FILE FORMATS: 8svx aif raw wav\nPLAYLIST FORMATS: m3u pls\nAUDIO DEVICE DRIVERS: alsa pulseaudio\n\nEFFECTS: allpass band\n"
  "What sox -h says, as on Ubuntu with libsox-fmt-pulse and libsox-fmt-alsa.")

(ert-deftest earwig-test-sox-drivers ()
  (should (equal (earwig--parse-sox-drivers earwig-test-sox-help) '(alsa pulseaudio)))
  (should (equal (earwig--parse-sox-drivers "AUDIO DEVICE DRIVERS: coreaudio\n") '(coreaudio)))
  ;; A sox built without any
  (should-not (earwig--parse-sox-drivers "AUDIO FILE FORMATS: wav\n")))

(ert-deftest earwig-test-audio-driver ()
  (let ((earwig-audio-driver 'auto)
        (drivers '(alsa pulseaudio))
        (pulse t))
    (cl-letf (((symbol-function 'earwig--sox-drivers) (lambda () drivers))
              ((symbol-function 'earwig--pulse-server-p) (lambda () pulse)))
      (let ((system-type 'darwin))
        (should (eq (earwig--audio-driver) 'coreaudio))
        (should (equal (earwig--ffmpeg-input-format) "avfoundation")))
      (let ((system-type 'gnu/linux))
        (should (eq (earwig--audio-driver) 'pulseaudio))
        (should (equal (earwig--ffmpeg-input-format) "pulse"))
        ;; No sound server: ALSA
        (setq pulse nil)
        (should (eq (earwig--audio-driver) 'alsa))
        (should (equal (earwig--ffmpeg-input-format) "alsa"))
        ;; A sox without PulseAudio: ALSA for it, but ffmpeg has its own
        (setq pulse t drivers '(alsa))
        (should (eq (earwig--audio-driver) 'alsa))
        (should (equal (earwig--ffmpeg-input-format) "pulse"))
        ;; Chosen
        (let ((earwig-audio-driver 'pulseaudio))
          (should (eq (earwig--audio-driver) 'pulseaudio)))))))

(ert-deftest earwig-test-pulse-server ()
  (let ((dir (make-temp-file "earwig-test-" t)))
    (unwind-protect
        (let ((process-environment (append (list (concat "XDG_RUNTIME_DIR=" dir) "PULSE_SERVER")
                                           process-environment)))
          (should-not (earwig--pulse-server-p))
          (make-directory (expand-file-name "pulse" dir))
          (write-region "" nil (expand-file-name "pulse/native" dir) nil 'silent)
          (should (earwig--pulse-server-p)))
      (delete-directory dir t))))

(ert-deftest earwig-test-record-commands ()
  "The commands recording dictation, on Linux and macOS."
  (let ((earwig-input-device "default")
        (earwig-recorder 'sox)
        (earwig-pulse-latency 30)
        (earwig-audio-driver 'pulseaudio)
        (earwig--stream-dir "/tmp/stream")
        (earwig--stream-input nil)
        (earwig-recording-timeout nil))
    (let ((system-type 'gnu/linux))
      (should (equal (earwig--stream-command)
                     '("env" "PULSE_LATENCY_MSEC=30" "sox" "-S" "-V1" "--buffer" "1920"
                       "-t" "pulseaudio" "default"
                       "-t" "raw" "-r" "16000" "-c" "1" "-b" "16" "-e" "signed-integer"
                       "/tmp/stream/audio.raw")))
      (should (equal (earwig--record-command "/tmp/out.wav")
                     '("env" "PULSE_LATENCY_MSEC=30" "sox" "-S" "-V1" "-t" "pulseaudio" "default"
                       "-r" "16000" "-c" "1" "-b" "16" "/tmp/out.wav")))
      (let ((earwig-recording-timeout 300))
        (should (equal (last (earwig--record-command "/tmp/out.wav") 3)
                       '("trim" "0" "300"))))
      ;; ffmpeg, with PulseAudio's input format
      (let ((earwig-recorder 'ffmpeg))
        (should (equal (earwig--record-command "/tmp/out.wav")
                       '("ffmpeg" "-probesize" "32" "-analyzeduration" "0" "-fflags" "nobuffer"
                         "-progress" "pipe:1" "-stats_period" "0.1" "-nostats"
                         "-f" "pulse" "-i" "default"
                         "-ar" "16000" "-ac" "1" "-y" "/tmp/out.wav"))))
      ;; PulseAudio's own latency
      (let ((earwig-pulse-latency nil))
        (should (equal (seq-take (earwig--stream-command) 2) '("sox" "-S"))))
      ;; ALSA, with a device of its own
      (let ((earwig-audio-driver 'alsa)
            (earwig-input-device "hw:CARD=PCH,DEV=0"))
        (should (equal (seq-take (earwig--stream-command) 7)
                       '("sox" "-S" "-V1" "--buffer" "1920" "-t" "alsa")))
        (should (equal (earwig--ffmpeg-input-device) "hw:CARD=PCH,DEV=0"))))
    (let ((system-type 'darwin)
          (earwig-audio-driver 'auto))
      (should (equal (seq-take (earwig--record-command "/tmp/out.wav") 6)
                     '("sox" "-S" "-V1" "-t" "coreaudio" "default")))
      (let ((earwig-recorder 'ffmpeg))
        (should (equal (seq-take (member "-f" (earwig--record-command "/tmp/out.wav")) 4)
                       '("-f" "avfoundation" "-i" ":default"))))
      (should (equal (earwig--ffmpeg-input-device) ":default")))))

(ert-deftest earwig-test-record-runs ()
  "The Linux streaming command, through env, records with this sox.
From a file in place of the microphone."
  (skip-unless (and (executable-find "sox") (executable-find "env")))
  (let* ((dir (make-temp-file "earwig-test-" t))
         (input (expand-file-name "tone.wav" dir))
         (system-type 'gnu/linux)
         (earwig-audio-driver 'pulseaudio)
         (earwig-pulse-latency 30)
         (earwig--stream-dir dir)
         (earwig--stream-input (list input)))
    (unwind-protect
        (progn
          (call-process "sox" nil nil nil "-n" "-r" "16000" "-c" "1" "-b" "16"
                        input "synth" "0.5" "sine" "440")
          (let ((command (earwig--stream-command)))
            (should (equal (car command) "env"))
            (should (eql (apply #'call-process (car command) nil nil nil (cdr command)) 0)))
          ;; Half a second of 16 kHz, 16-bit samples
          (should (= (file-attribute-size (file-attributes (earwig--stream-raw))) 16000)))
      (delete-directory dir t))))

(ert-deftest earwig-test-recorder-stopped ()
  (let ((system-type 'gnu/linux))
    (should (earwig--recorder-stopped-p "interrupt\n"))
    (should (earwig--recorder-stopped-p "finished\n"))
    ;; ffmpeg's, once interrupted
    (should (earwig--recorder-stopped-p "exited abnormally with code 255\n"))
    (should-not (earwig--recorder-stopped-p "exited abnormally with code 2\n"))
    (should-not (earwig--recorder-stopped-p "killed\n")))
  (let ((system-type 'windows-nt))
    (should (earwig--recorder-stopped-p "killed\n"))))

(ert-deftest earwig-test-default-keys ()
  (let ((system-type 'gnu/linux))
    (should (equal (earwig--default-keys 'toggle)
                   '(("<f7>" . dictate) ("<kp-0>" . dictate)
                     ("<f8>" . command) ("<kp-enter>" . command))))
    (should (equal (earwig--default-keys 'correct) '("<f9>" "<kp-decimal>")))
    ;; Each a key `keymap-set' takes
    (dolist (key (append (mapcar #'car (earwig--default-keys 'toggle))
                         (earwig--default-keys 'correct)))
      (should (key-valid-p key))))
  (let ((system-type 'darwin))
    (should (equal (caar (earwig--default-keys 'toggle)) "s-d"))
    (should (equal (car (earwig--default-keys 'correct)) "s-e"))))

(ert-deftest earwig-test-input-devices ()
  (let ((pactl "49\talsa_output.pci-0000_00_1f.3.analog-stereo.monitor\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED
50\talsa_input.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts32le 2ch 48000Hz\tRUNNING
51\talsa_input.usb-Blue_Yeti-00.analog-stereo\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED")
        (arecord "null
    Discard all samples (playback) or generate zero samples (capture)
default
    Default ALSA Output (currently PipeWire Media Server)
sysdefault:CARD=PCH
    HDA Intel PCH, ALC257 Analog
    Default Audio Device
hw:CARD=PCH,DEV=0
    HDA Intel PCH, ALC257 Analog
    Direct hardware device without any conversions"))
    (should (equal (earwig--parse-pactl-sources pactl)
                   '("alsa_input.pci-0000_00_1f.3.analog-stereo"
                     "alsa_input.usb-Blue_Yeti-00.analog-stereo")))
    (should (equal (earwig--parse-arecord-devices arecord)
                   '("default" "sysdefault:CARD=PCH" "hw:CARD=PCH,DEV=0")))
    (should-not (earwig--parse-pactl-sources nil))
    ;; Asked of the sound server sox records from
    (earwig-test-system 'gnu/linux `(("pactl" . ,pactl) ("arecord" . ,arecord))
      (let ((earwig-audio-driver 'pulseaudio))
        (should (= (length (earwig--input-devices)) 2))
        (should (equal (car ran) '("pactl" "list" "short" "sources"))))
      (let ((earwig-audio-driver 'alsa))
        (should (= (length (earwig--input-devices)) 3))
        (should (equal (car ran) '("arecord" "-L")))))
    ;; Neither installed
    (earwig-test-system 'gnu/linux nil
      (let ((earwig-audio-driver 'pulseaudio))
        (should-not (earwig--input-devices))))))

(ert-deftest earwig-test-key-repeat-linux ()
  (should (equal (earwig--parse-xset-repeat "Keyboard Control:
  auto repeat:  on    key click percent:  0    LED mask:  00000000
  auto repeat delay:  660    repeat rate:  25
  auto repeating keys:  00ffffffdffffbbf")
                 '(660 . 40)))
  (should (eq (earwig--parse-xset-repeat "  auto repeat:  off    key click percent:  0
  auto repeat delay:  660    repeat rate:  25")
              'off))
  (should-not (earwig--parse-xset-repeat nil))
  (should (eql (earwig--parse-gsettings-number "uint32 500") 500))
  (let ((x11 '("DISPLAY=:0" "WAYLAND_DISPLAY"))
        (gnome '("WAYLAND_DISPLAY=wayland-0" "XDG_CURRENT_DESKTOP=ubuntu:GNOME"))
        (kde '("WAYLAND_DISPLAY=wayland-0" "XDG_CURRENT_DESKTOP=KDE"))
        (sway '("WAYLAND_DISPLAY=wayland-1" "XDG_CURRENT_DESKTOP=sway")))
    (cl-flet ((repeat (env outputs)
                (let ((process-environment (append env process-environment)))
                  (earwig-test-system 'gnu/linux outputs
                    (earwig--key-repeat)))))
      ;; X11: from the X server
      (should (equal (repeat x11 '(("xset" . "  auto repeat delay:  250    repeat rate:  30")))
                     '(250 . 33)))
      ;; Wayland: from the desktop
      (cl-letf (((symbol-function 'earwig--run)
                 (lambda (_program &rest args)
                   (cons 0 (pcase (car (last args))
                             ("repeat" "true")
                             ("delay" "uint32 500")
                             ("repeat-interval" "uint32 30"))))))
        (let ((process-environment (append gnome process-environment))
              (system-type 'gnu/linux))
          (should (equal (earwig--key-repeat) '(500 . 30)))))
      (cl-letf (((symbol-function 'earwig--run)
                 (lambda (_program &rest args) (cons 0 (if (equal (car (last args)) "false") "false" "x"))))
                ((symbol-function 'earwig--run-output)
                 (lambda (_program &rest args) (and (equal (car (last args)) "repeat") "false"))))
        (let ((process-environment (append gnome process-environment))
              (system-type 'gnu/linux))
          (should (eq (earwig--key-repeat) 'off))))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &rest _) (and (equal name "kreadconfig6") "/usr/bin/kreadconfig6")))
                ((symbol-function 'earwig--run)
                 (lambda (_program &rest args)
                   (cons 0 (if (member "RepeatDelay" args) "600" "25.0")))))
        (let ((process-environment (append kde process-environment))
              (system-type 'gnu/linux))
          (should (equal (earwig--key-repeat) '(600 . 40)))))
      ;; Another Wayland desktop: not known
      (should-not (repeat sway '(("xset" . "  auto repeat delay:  250    repeat rate:  30")))))))

(ert-deftest earwig-test-check-keyboard-linux ()
  "On Linux there's no press and hold to check, only the key repeat."
  (let ((system-type 'gnu/linux)
        (earwig-hold-initial-window 1.5)
        (earwig-hold-repeat-max 0.2)
        (earwig-hold-release-delay 0.3))
    (cl-letf (((symbol-function 'earwig--key-repeat) (lambda () '(500 . 30))))
      (let ((results (earwig--check-keyboard)))
        (should (equal (mapcar #'cadr results) '("Key repeat")))
        (should (eq (caar results) 'ok))))
    (cl-letf (((symbol-function 'earwig--key-repeat) (lambda () 'off)))
      (should (eq (caar (earwig--check-keyboard)) 'fail)))))

(ert-deftest earwig-test-install-hints ()
  (let ((manager 'apt))
    (cl-letf (((symbol-function 'earwig--package-manager) (lambda () manager))
              ((symbol-function 'earwig--sox-drivers) (lambda () '(alsa))))
      (should (equal (earwig--install-hint "sox") "sudo apt install sox libsox-fmt-pulse libsox-fmt-alsa"))
      (should (equal (earwig--install-hint "curl") "sudo apt install curl"))
      (should (equal (earwig--sox-driver-hint 'pulseaudio) "sudo apt install libsox-fmt-pulse"))
      (setq manager 'dnf)
      (should (equal (earwig--install-hint "sox") "sudo dnf install sox"))
      (should (string-match-p "earwig-audio-driver.*: alsa\\'" (earwig--sox-driver-hint 'pulseaudio)))
      (setq manager nil)
      (should (equal (earwig--install-hint "sox") "install sox"))))
  (let ((system-type 'darwin))
    (should (equal (earwig--install-hint "sox") "brew install sox"))))

(ert-deftest earwig-test-check-tools-linux ()
  "A sox without the driver it records with fails the check."
  (let ((system-type 'gnu/linux)
        (earwig-recorder 'sox)
        (earwig-audio-driver 'pulseaudio))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name &rest _) (and (member name '("sox" "curl" "apt")) (concat "/usr/bin/" name))))
              ((symbol-function 'earwig--sox-drivers) (lambda () '(alsa))))
      (let ((driver (assoc "Audio driver" (mapcar #'cdr (earwig--check-tools)))))
        (should (string-match-p "no pulseaudio" (nth 1 driver)))
        (should (equal (nth 2 driver) "sudo apt install libsox-fmt-pulse"))))))

;;;; The server

(ert-deftest earwig-test-server-settings ()
  (let ((earwig-speech-server-base-url "http://127.0.0.1:18178/"))
    (should (equal (earwig-server-url "/v1/audio/transcriptions")
                   "http://127.0.0.1:18178/v1/audio/transcriptions"))
    (should (equal (earwig-server--address) '("127.0.0.1" . 18178))))
  (let ((earwig-speech-server-directory "/opt/orukeet")
        (earwig-speech-server-command '(".venv/bin/python" "local_server.py")))
    (should (equal (earwig-server--program) "/opt/orukeet/.venv/bin/python"))
    (let ((earwig-speech-server-command '("whisper-server" "--port" "18178")))
      (should (equal (earwig-server--program) "whisper-server"))))
  ;; Without a command, starting it is up to you
  (let ((earwig-speech-server-command nil)
        (earwig-server--process nil))
    (should-error (earwig-speech-server-start) :type 'user-error)
    (should-not (earwig--check-server-command))))

;;;; Streaming through the server

(ert-deftest earwig-test-stream-fallback ()
  (let ((earwig-streaming t)
        (earwig--stream-fallback-noted nil)
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args) (push (apply #'format format args) messages))))
      (let ((earwig-recorder 'sox))
        (should (earwig--stream-p 'dictate))
        (should-not (earwig--stream-p 'command)))
      (should-not messages)
      (let ((earwig-recorder 'ffmpeg))
        (should-not (earwig--stream-p 'dictate))
        (should-not (earwig--stream-p 'dictate))))
    ;; Said once, with what streaming would take
    (should (= (length messages) 1))
    (should (string-match-p "streaming is off.*`earwig-recorder' to `sox'" (car messages)))))

(defun earwig-test-frames (&rest runs)
  "Return 16-bit samples for RUNS of (FRAMES . AMPLITUDE), 30 ms frames.
Alternating between plus and minus AMPLITUDE, as a unibyte string."
  (apply #'concat
         (mapcar (lambda (run)
                   (let ((one (earwig--le-bytes (cdr run) 2))
                         (other (earwig--le-bytes (logand (- (cdr run)) 65535) 2)))
                     (apply #'concat (make-list (* (car run) 240) (concat one other)))))
                 runs)))

(ert-deftest earwig-test-command-auto-stop ()
  "A command recorded with a tap stops at a pause after it's complete."
  (let* ((file (make-temp-file "earwig-test-" nil ".wav"))
         (audio nil)
         (write (lambda (&rest runs)
                  (setq audio (apply #'earwig-test-frames runs))
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert (earwig--wav-header (length audio)) audio)
                    (let ((coding-system-for-write 'no-conversion))
                      (write-region nil nil file nil 'silent)))))
         (earwig--record-file file)
         (earwig--record-process 'recorder)
         (earwig--stream-pushed-to-talk nil)
         (earwig-command-auto-stop 1.0)
         (earwig-command-auto-stop-incomplete 2.0)
         (earwig--auto-stop-timer nil)
         (earwig--auto-stop-read 0)
         (earwig--auto-stop-levels nil)
         (earwig--auto-stop-speech nil)
         (earwig--auto-stop-quiet 0)
         (earwig--auto-stop-speech-end 0)
         (earwig--preview-size 0)
         (earwig--preview-heard nil)
         (speech '((60 . 20) (30 . 3000) (20 . 20) (30 . 3000)))
         (heard (lambda (raw) (setq earwig--preview-heard (cons raw (length audio)))))
         previews stopped)
    (unwind-protect
        (cl-letf (((symbol-function 'process-live-p) (lambda (proc) (eq proc 'recorder)))
                  ((symbol-function 'earwig--stop-recorder) (lambda (_) (setq stopped t)))
                  ((symbol-function 'earwig--preview-tick)
                   (lambda ()
                     (cl-incf previews)
                     (setq earwig--preview-size (length audio)))))
          (setq previews 0)
          ;; Silence before speaking doesn't stop it
          (funcall write '(60 . 20))
          (earwig--auto-stop-tick)
          (should-not stopped)
          ;; A pause beginning has what's said transcribed right away
          (apply write (append speech '((15 . 20))))
          (earwig--auto-stop-tick)
          (should earwig--auto-stop-speech)
          (should (= previews 1))
          (should-not stopped)
          ;; Long enough, but not yet a command: it waits
          (apply write (append speech '((40 . 20))))
          (funcall heard "Go to line.")
          (earwig--auto-stop-tick)
          (should-not stopped)
          ;; A command, but heard before the last of it was said
          (setq earwig--preview-heard (cons "Go to top." 100))
          (earwig--auto-stop-tick)
          (should-not stopped)
          ;; A command, all of it: it stops
          (funcall heard "Go to top.")
          (earwig--auto-stop-tick)
          (should stopped)
          ;; Nor does a chain word at the end, until the longer pause
          (setq stopped nil)
          (funcall heard "Select last sentence and then.")
          (earwig--auto-stop-tick)
          (should-not stopped)
          (apply write (append speech '((67 . 20))))
          (earwig--auto-stop-tick)
          (should stopped)
          ;; A cancel word ends it too
          (should (let ((earwig--preview-heard (cons "Go to, never mind." 1.0e9)))
                    (earwig--command-heard-complete-p)))
          ;; Not pushed to talk, which stops when the key is let go
          (setq stopped nil
                earwig--auto-stop-read 0
                earwig--auto-stop-levels nil
                earwig--auto-stop-speech nil
                earwig--auto-stop-quiet 0
                earwig--stream-pushed-to-talk t)
          (earwig--auto-stop-tick)
          (should-not stopped))
      (delete-file file))))

(ert-deftest earwig-test-follow-point ()
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (insert "one two")
    (let ((marker (copy-marker 4)))
      (goto-char 4)
      (should-not (earwig--follow-point marker))
      (goto-char (point-max))
      (should (earwig--follow-point marker))
      (should (= marker (point-max)))
      ;; In a terminal, only to another buffer
      (cl-letf (((symbol-function 'earwig--terminal-p) #'always))
        (goto-char 1)
        (should-not (earwig--follow-point marker))
        (with-temp-buffer
          (set-window-buffer nil (current-buffer))
          (should (earwig--follow-point marker))
          (should (eq (marker-buffer marker) (current-buffer))))))))

(defmacro earwig-test-streaming (&rest body)
  "Run BODY as if streaming dictation into the current buffer at point."
  `(let ((earwig--stream-dir (make-temp-file "earwig-test-" t))
         (earwig--stream-target (copy-marker (point) t))
         (earwig--stream-start (copy-marker (point)))
         (earwig--stream-join nil)
         (earwig--stream-moves nil)
         (earwig--stream-segment-start 0)
         (earwig--stream-speech nil)
         (earwig--stream-queue nil)
         (earwig--stream-change-group nil)
         (earwig--stream-overlay nil)
         (earwig--stream-provisional-for nil)
         (earwig--stream-provisional-raw nil)
         (earwig--stream-flushed nil)
         (earwig--stream-pushed-to-talk nil)
         (earwig--stream-read 0)
         (earwig--stream-levels nil)
         (earwig--stream-quiet 0)
         (earwig--stream-loud 0)
         (earwig--stream-speech-end 0)
         (earwig--stream-provisional-time 0)
         (earwig--stream-provisional-end 0)
         (earwig--stream-provisional-duration 0)
         (earwig--stream-curl nil)
         (earwig--last-dictation nil)
         (earwig--mode 'dictate))
     (unwind-protect
         ;; Recording, unless BODY says otherwise
         (cl-letf (((symbol-function 'earwig-stream-recording-p) #'always))
           ,@body)
       (when earwig--stream-dir
         (delete-directory earwig--stream-dir t)))))

(ert-deftest earwig-test-stream-follow-point ()
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (buffer-enable-undo)
    (insert "First.\n\nLast.")
    (undo-boundary)
    (goto-char 7)
    (earwig-test-streaming
     (earwig--stream-insert "Two." 0)
     (earwig--stream-insert "Three." 100)
     ;; A click elsewhere, before speaking again, takes the dictation along
     (setq earwig--stream-segment-start 200)
     (goto-char (point-max))
     (earwig--stream-insert "Four." 200)
     (should (equal (buffer-string) "First. Two. Three.\n\nLast. Four."))
     (should (= (point) (point-max)))
     ;; "scratch that" takes back what was said here only
     (should (equal (nth 2 earwig--last-dictation) " Four."))
     (earwig--stream-finish)
     ;; and so does undo
     (let ((last-command nil))
       (undo))
     (should (equal (buffer-string) "First. Two. Three.\n\nLast.")))))

(ert-deftest earwig-test-stream-spoken-before-moving ()
  "What was said before point moved goes where it was said."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (insert "First.\n\nLast.")
    (goto-char 7)
    (earwig-test-streaming
     (let ((earwig-stream-provisional t))
       ;; Speaking the segment at byte 0, with its provisional text shown
       (setq earwig--stream-speech t)
       (earwig--stream-show-provisional "Two" 0)
       (should (= (overlay-start earwig--stream-overlay) 7))
       ;; A click elsewhere while it's still provisional
       (goto-char (point-max))
       (earwig--stream-follow-point)
       (earwig--stream-show-provisional "Two." 0)
       (should (= (overlay-start earwig--stream-overlay) 7))
       ;; The pause ends it; its final text goes where it was said
       (setq earwig--stream-segment-start 100
             earwig--stream-speech nil)
       (earwig--stream-insert "Two." 0)
       (should (equal (buffer-string) "First. Two.\n\nLast."))
       (should (= (point) (point-max)))
       ;; What's said after the click goes there
       (earwig--stream-show-provisional "Three" 100)
       (should (= (overlay-start earwig--stream-overlay) (point-max)))
       (earwig--stream-insert "Three." 100)
       (should (equal (buffer-string) "First. Two.\n\nLast. Three."))
       (should (equal (nth 2 earwig--last-dictation) " Three."))
       ;; Once recording has stopped, a click no longer moves anything
       (cl-letf (((symbol-function 'earwig-stream-recording-p) #'ignore))
         (setq earwig--stream-segment-start 200)
         (goto-char 1)
         (earwig--stream-insert "Four." 200))
       (should (equal (buffer-string) "First. Two.\n\nLast. Three. Four."))))))

(ert-deftest earwig-test-stream-cut-at-move ()
  "Point moving ends the segment being spoken there, not at the next pause."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (insert "First.\n\nLast.")
    (goto-char 7)
    (earwig-test-streaming
     (let ((earwig--stream-count 0)
           ;; Every loud frame is speech, to keep the frames few
           (earwig-stream-speech-onset 0.03))
       ;; 20 frames measured: quiet ones, then speech with a dip 4 frames back
       (write-region (make-string 19200 0) nil (earwig--stream-raw) nil 'silent)
       (setq earwig--stream-read 19200
             earwig--stream-speech t
             earwig--stream-levels (append '(100 100 100 2 100 100 100 100 100 100)
                                           (make-list 10 2)))
       (goto-char (point-max))
       (earwig--stream-follow-point)
       ;; Cut in the dip; what's said before goes where it was said
       (should (= earwig--stream-segment-start 15840))
       (should (equal (mapcar #'cdr earwig--stream-queue) '(0)))
       (should (equal (mapcar #'car earwig--stream-moves) '(15840)))
       ;; After it, speech still: the next segment is under way
       (should earwig--stream-speech)
       (setq earwig--stream-queue nil)
       (earwig--stream-insert "Two." 0)
       (earwig--stream-insert "Three." 15840)
       (should (equal (buffer-string) "First. Two.\n\nLast. Three."))))))

;;;; Sparing the speech server

(ert-deftest earwig-test-stream-noise-floor ()
  "Near-silence between words doesn't make every sound speech."
  (let ((earwig-stream-noise-floor 10))
    (should-not (earwig--stream-noise (make-list 9 0)))
    (should (= (earwig--stream-noise (make-list 20 0)) 10))
    (should (= (earwig--stream-noise (make-list 20 50)) 50))))

(ert-deftest earwig-test-stream-speech-onset ()
  "Only a sound that stays loud is speech, not a click."
  (earwig-test-streaming
   (let ((earwig-stream-speech-onset 0.15)
         (earwig-stream-speech-ratio 3.0)
         (frame-end 0))
     (cl-flet ((frames (level count)
                 (dotimes (_ count)
                   (cl-incf frame-end earwig--stream-frame-bytes)
                   (earwig--stream-frame level 10 frame-end))))
       ;; A click of 4 frames
       (frames 5 10)
       (frames 1000 4)
       (frames 5 2)
       (should-not earwig--stream-speech)
       (should (= earwig--stream-quiet 16))
       ;; A word: speech from its fifth frame
       (frames 1000 6)
       (should earwig--stream-speech)
       (should (= earwig--stream-quiet 0))
       (should (= earwig--stream-speech-end frame-end))
       ;; A click in the pause after it doesn't end the pause
       (frames 5 10)
       (frames 1000 3)
       (should (= earwig--stream-quiet 13))))))

(ert-deftest earwig-test-stream-max-segment-silence ()
  "A long stretch without speech isn't sent to the server."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let ((earwig--stream-count 0)
           (earwig-stream-max-segment 1)
           (earwig-stream-provisional t))
       ;; 1.5 s of silence
       (write-region (make-string 48000 0) nil (earwig--stream-raw) nil 'silent)
       (earwig--stream-measure)
       (should-not earwig--stream-queue)
       (should (zerop earwig--stream-count))
       (should-not earwig--stream-speech)
       ;; Past 1 s, at frame 34, all but its last half second was dropped
       (should (= earwig--stream-segment-start (- (* 34 960) 16000)))))))

(ert-deftest earwig-test-stream-provisional-spared ()
  "Provisional passes need new speech, and back off while the server is slow."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let ((earwig-stream-provisional t)
           (earwig-stream-provisional-interval 1.0)
           (earwig-stream-provisional-share 0.5)
           sent)
       (write-region (make-string 64000 0) nil (earwig--stream-raw) nil 'silent)
       (cl-letf (((symbol-function 'earwig--stream-request)
                  (lambda (_file _callback) (push (float-time) sent))))
         (setq earwig--stream-speech t)
         ;; Speech ended before the audio the last pass reached
         (setq earwig--stream-speech-end 30000
               earwig--stream-provisional-end 32000)
         (earwig--stream-maybe-provisional 48000)
         (should-not sent)
         ;; New speech since then
         (setq earwig--stream-speech-end 40000)
         (earwig--stream-maybe-provisional 48000)
         (should (= (length sent) 1))
         ;; The last pass took 1.5 s: none for 3 s after it started
         (setq earwig--stream-speech-end 60000
               earwig--stream-provisional-duration 1.5
               earwig--stream-provisional-time (- (float-time) 2))
         (earwig--stream-maybe-provisional 64000)
         (should (= (length sent) 1))
         (setq earwig--stream-provisional-time (- (float-time) 3.1))
         (earwig--stream-maybe-provisional 64000)
         (should (= (length sent) 2)))))))

(defvar evil-local-mode)
(defvar evil-move-cursor-back)
(defvar evil-state)

(ert-deftest earwig-test-evil-stepped-back ()
  "Leaving evil's insert state moves point back, but not the dictation."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (insert "One.")
    (let ((marker (copy-marker (point-max)))
          (evil-local-mode t)
          (evil-move-cursor-back t)
          (evil-state 'normal))
      (backward-char)
      (should-not (earwig--follow-point marker))
      (should (= marker (point-max)))
      ;; Point goes along onto the last character dictated
      (earwig--insert-text " Two." marker)
      (should (equal (buffer-string) "One. Two."))
      (should (= (point) (1- (point-max))))
      ;; A move of more than that is one
      (goto-char 2)
      (should (earwig--follow-point marker))
      (should (= marker 2)))))

(ert-deftest earwig-test-stream-flush ()
  "A key pressed while provisional text shows puts it in, then does its thing."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (let ((earwig-stream-provisional t)
          (type (lambda (char)
                  (let ((this-command 'self-insert-command)
                        (last-input-event char)
                        (last-command-event char))
                    (run-hooks 'pre-command-hook)
                    (self-insert-command 1 char)))))
      (earwig-test-streaming
       (add-hook 'pre-command-hook #'earwig--stream-flush-on-key nil t)
       ;; The segment being spoken starts anew where its provisional text ends
       (setq earwig--stream-speech t
             earwig--stream-read 48000)
       ;; Punctuation typed replaces the period it ends with
       (earwig--stream-show-provisional "Hello there." 0 32000)
       (funcall type ?!)
       (should (equal (buffer-string) "Hello there!"))
       (should (equal (nth 2 earwig--last-dictation) "Hello there"))
       (should (= earwig--stream-segment-start 32000))
       (should-not earwig--stream-provisional-for)
       (should-not (overlay-get earwig--stream-overlay 'before-string))
       ;; A queued segment is dropped
       (let ((file (expand-file-name "segment.wav" earwig--stream-dir)))
         (write-region "" nil file nil 'silent)
         (setq earwig--stream-queue (list (cons file 32000))
               earwig--stream-segment-start 64000)
         (earwig--stream-show-provisional "Second" 32000 60000)
         (funcall type ?,)
         (should (equal (buffer-string) "Hello there! Second,"))
         (should-not earwig--stream-queue)
         (should-not (file-exists-p file)))
       ;; One in flight has its final text dropped when it comes
       (earwig--stream-show-provisional "Third" 64000 70000)
       (setq earwig--stream-segment-start 80000)
       (funcall type ?.)
       (earwig--stream-transcribed t "Third one." 64000)
       (should (equal (buffer-string) "Hello there! Second, third."))
       (should-not earwig--stream-flushed)
       ;; Not for a mouse event, a voice key or dictation pushed to talk
       (earwig--stream-show-provisional "Fourth" 80000 90000)
       (let ((last-input-event '(mouse-1)))
         (run-hooks 'pre-command-hook))
       (let ((this-command 'earwig-voice-key))
         (run-hooks 'pre-command-hook))
       (let ((earwig--stream-pushed-to-talk t))
         (funcall type ?x))
       (should (equal (buffer-string) "Hello there! Second, third.x"))
       (should (eql earwig--stream-provisional-for 80000))
       ;; The space bar as a push-to-talk key types the space after it
       (let ((earwig-push-to-talk t)
             (earwig-push-to-talk-keys '(("SPC" . dictate)))
             (last-input-event ?\s))
         (earwig-test-presses
           (setq recording 'dictate)
           (earwig-test-press "SPC" 0)))
       (should (equal (buffer-string) "Hello there! Second, third.x fourth "))))))

(ert-deftest earwig-test-punctuation-typed ()
  "Punctuation typed right after a dictation replaces its period or comma."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (add-hook 'post-self-insert-hook #'earwig--punctuation-typed nil t)
    (let ((earwig--last-dictation nil)
          (type (lambda (char)
                  (let ((last-command-event char))
                    (self-insert-command 1 char)))))
      (earwig--insert-text "Is it ready." (point-marker))
      (funcall type ??)
      (should (equal (buffer-string) "Is it ready?"))
      (should (equal (nth 2 earwig--last-dictation) "Is it ready"))
      ;; Typing more goes after it
      (funcall type ?!)
      (should (equal (buffer-string) "Is it ready?!"))
      ;; Not after an edit, nor away from its end, nor for other keys
      (earwig--insert-text " Yes." (point-marker))
      (funcall type ?a)
      (funcall type ?,)
      (should (equal (buffer-string) "Is it ready?! Yes.a,"))
      (earwig--insert-text " No." (point-marker))
      (goto-char 1)
      (funcall type ?,)
      (should (equal (buffer-string) ",Is it ready?! Yes.a, No.")))))

(ert-deftest earwig-test-stream-command ()
  "A command given while dictating ends the dictation so far."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let ((earwig-wake-word-commands t)
           ran)
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (_time _repeat function &rest args) (setq ran (cons function args)))))
         (earwig--stream-insert "One two." 0)
         (earwig--stream-insert "Okay, delete last word." 100))
       (should (equal (buffer-string) "One two."))
       (apply ran)
       (should (equal (buffer-string) "One."))
       (earwig--stream-insert "Three." 200)
       (should (equal (buffer-string) "One. Three."))
       (should (equal (nth 2 earwig--last-dictation) " Three."))))))

(ert-deftest earwig-test-stream-command-moves ()
  "What's said after a command goes where it left point, even while it ran."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (insert "First.")
    (earwig-test-streaming
     (let ((earwig-wake-word-commands t)
           ran)
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (_time _repeat function &rest args) (setq ran (cons function args)))))
         (earwig--stream-insert "Two." 0)
         (earwig--stream-insert "Okay, go to top." 100))
       ;; The next sentence is being said as the command runs
       (setq earwig--stream-segment-start 200
             earwig--stream-speech t)
       (apply ran)
       (should (= (point) 1))
       (earwig--stream-follow-point)
       (earwig--stream-insert "Zero." 200)
       (should (equal (buffer-string) "Zero. First. Two."))))))

(ert-deftest earwig-test-stream-command-markup ()
  "\"scratch that\" after a command that added markup leaves the markup."
  (with-temp-buffer
    (org-mode)
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let ((earwig-wake-word-commands t)
           (inhibit-message t)
           ran)
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (_time _repeat function &rest args) (setq ran (cons function args)))))
         (earwig--stream-insert "That's the plan for today." 0)
         (earwig--stream-insert "Okay, select last sentence and then format bold." 100)
         (apply ran)
         (should (equal (buffer-string) "*That's the plan for today.*"))
         (earwig--stream-insert "Next, the budget needs work." 200)
         (should (equal (buffer-string) "*That's the plan for today.* Next, the budget needs work."))
         (earwig--stream-insert "Okay, scratch that." 300)
         (apply ran)
         (should (equal (buffer-string) "*That's the plan for today.*")))))))

(ert-deftest earwig-test-stream-provisional-refit ()
  "Provisional text is fitted again when final text goes in before it."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let ((earwig-wake-word-commands t))
       ;; The segment at 0 is still being transcribed as the next one shows
       (setq earwig--stream-segment-start 100)
       (earwig--stream-show-provisional "Okay." 100 200)
       (should (equal (overlay-get earwig--stream-overlay 'before-string) "\u25b6"))
       (earwig--stream-insert "That's the plan for today." 0)
       (should (equal (buffer-string) "That's the plan for today."))
       (should (equal (overlay-get earwig--stream-overlay 'before-string) " \u25b6"))))))

(ert-deftest earwig-test-stream-command-heard ()
  "The mode line shows CMD while a command given while dictating shows, then REC."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let ((earwig-wake-word-commands t)
           (earwig--phase 'recording)
           (earwig--mode 'dictate)
           (saved nil)
           ran)
       (setq earwig--audio-flowing t
             earwig--stream-segment-start 0)
       (earwig--stream-show-provisional "There we go" 0)
       (should (string-match-p "REC" (earwig--mode-line)))
       (earwig--stream-show-provisional "Okay, save" 0)
       (should (string-match-p "CMD" (earwig--mode-line)))
       (cl-letf (((symbol-function 'save-buffer) (lambda () (interactive) (setq saved t)))
                 ((symbol-function 'run-at-time)
                  (lambda (_time _repeat function &rest args) (setq ran (cons function args)))))
         (earwig--stream-transcribed t "Okay, save." 0)
         ;; Still CMD until the command has run, then REC
         (should (string-match-p "CMD" (earwig--mode-line)))
         (apply ran))
       (should saved)
       (should (string-match-p "REC" (earwig--mode-line)))
       ;; And when no command matches after all
       (setq earwig--stream-segment-start 100)
       (earwig--stream-show-provisional "Okay, banana" 100)
       (should (string-match-p "CMD" (earwig--mode-line)))
       (earwig--stream-transcribed t "Okay, banana." 100)
       (should (string-match-p "REC" (earwig--mode-line)))))))

(ert-deftest earwig-test-stream-command-echo-area ()
  "A command given while dictating can show in the echo area instead."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let ((earwig-wake-word-commands t)
           (earwig-provisional-command-display 'echo-area)
           (earwig-command-icon "C")
           (earwig-recording-icon "D"))
       (setq earwig--stream-segment-start 0)
       (cl-letf (((symbol-function 'message) #'ignore))
         (earwig--stream-show-provisional "Okay, go to top" 0)
         (should-not (and earwig--stream-overlay
                          (overlay-get earwig--stream-overlay 'before-string)))
         (should (equal (substring-no-properties earwig--stream-echo) "C go to top"))
         ;; Dictation still shows in the buffer
         (earwig--stream-show-provisional "There we go" 0)
         (should (equal (substring-no-properties
                         (overlay-get earwig--stream-overlay 'before-string))
                        "D There we go"))
         (should-not earwig--stream-echo))))))

(ert-deftest earwig-test-stream-provisional-marks ()
  "Provisional text has a mark; a command's has none of the wake or chain words."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (insert "Hello.")
    (earwig-test-streaming
     (let ((earwig-wake-word-commands t)
           (earwig-recording-icon "D")
           (earwig-command-icon "C")
           (earwig-provisional-chain-mark "->"))
       (setq earwig--stream-segment-start 0)
       (dolist (case '(("There we go." " D There we go.")
                       ("Okay" " C")
                       ("Okay, select last sentence and then cu" " C select last sentence -> cu")
                       ("Okay, select last sentence and then cut that and then go to top."
                        " C select last sentence -> cut that -> go to top")
                       ;; Not before a part that's no command
                       ("Okay, replace and then with so." " C replace and then with so")))
         (earwig--stream-show-provisional (car case) 0)
         (should (equal (substring-no-properties
                         (overlay-get earwig--stream-overlay 'before-string))
                        (cadr case))))
       ;; The chain mark is the command icon by default
       (let ((earwig-provisional-chain-mark nil))
         (earwig--stream-show-provisional "Okay, go to top and then save" 0)
         (should (equal (substring-no-properties
                         (overlay-get earwig--stream-overlay 'before-string))
                        " C go to top C save")))
       (let ((earwig-provisional-icons nil))
         (earwig--stream-show-provisional "There we go." 0)
         (should (equal (substring-no-properties
                         (overlay-get earwig--stream-overlay 'before-string))
                        " There we go.")))))))

(ert-deftest earwig-test-record-transcribed ()
  "A whole recording's transcription goes in where point is, for \"scratch that\"."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (insert "First.")
    (let ((earwig--mode 'dictate)
          (earwig--record-target (copy-marker (point)))
          (earwig--record-file nil)
          (earwig--last-dictation nil)
          (earwig--phase 'transcribing)
          (global-mode-string (list earwig--mode-line-entry)))
      (earwig--record-transcribed t "Second sentence.")
      (should (equal (buffer-string) "First. Second sentence."))
      (should (= (point) (point-max)))
      (should (equal (nth 2 earwig--last-dictation) " Second sentence."))
      (should-not earwig--record-target)
      (should-not earwig--phase)
      (should-not global-mode-string))))

(ert-deftest earwig-test-nothing-heard ()
  "An empty transcription, or a failed one, says so and inserts nothing."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (let ((earwig--mode 'dictate)
          (earwig--record-file nil)
          messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (when format
                     (push (apply #'format format args) messages)))))
        (let ((earwig--record-target (point-marker)))
          (earwig--record-transcribed t ""))
        (let ((earwig--record-target (point-marker)))
          (earwig--record-transcribed nil "Server error")))
      (should (equal (reverse messages)
                     '("Nothing heard" "Transcription failed: Server error")))
      (should (equal (buffer-string) "")))))

(ert-deftest earwig-test-record-runs-whole ()
  "A whole recording, from a file in place of the microphone, is transcribed."
  (skip-unless (and (executable-find "sox") (executable-find "say")
                    (earwig-server-ready-p)))
  (let* ((dir (make-temp-file "earwig-test-" t))
         (aiff (expand-file-name "speech.aiff" dir))
         (earwig--mode 'dictate)
         (earwig-recorder 'sox)
         (earwig-recording-timeout nil)
         (inhibit-message t))
    (unwind-protect
        (progn
          (call-process "say" nil nil nil "-o" aiff "Hello world, this is a test.")
          (cl-letf (((symbol-function 'earwig--sox-input-args) (lambda () (list aiff))))
            (with-temp-buffer
              (set-window-buffer nil (current-buffer))
              (earwig--record)
              (with-timeout (60 (error "Recording didn't finish"))
                (while earwig--record-file
                  (condition-case err
                      (sleep-for 0.1)
                    (file-error
                     (unless (equal (cadr err) "Failed select")
                       (signal (car err) (cdr err)))))))
              (should (string-match-p "\\`Hello world[,.] this is a test\\.\\'"
                                      (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest earwig-test-check-quiet ()
  "The microphone check warns when it records almost silence."
  (cl-letf (((symbol-function 'earwig--input-devices) #'ignore)
            ((symbol-function 'earwig--check-server) (lambda () '(fail "Server" "down")))
            ((symbol-function 'earwig--check-record) #'ignore))
    (let ((earwig-input-device "Mic"))
      (dolist (case '((0.0004 warn) (0.02 ok) (0.0 fail) (0.00004 fail)))
        (cl-letf (((symbol-function 'earwig--check-level) (lambda (_) (car case))))
          (should (eq (car (car (earwig--check-microphone))) (cadr case))))))))

(ert-deftest earwig-test-check-sox-hint ()
  "With sox there, the check says to choose it, not to install it."
  (cl-letf (((symbol-function 'executable-find) (lambda (program) (equal program "sox"))))
    (should (equal (earwig--check-sox-hint) "set earwig-recorder to auto or sox")))
  (let ((system-type 'darwin))
    (cl-letf (((symbol-function 'executable-find) (lambda (program) (equal program "brew"))))
      (should (equal (earwig--check-sox-hint)
                     "brew install sox, with earwig-recorder auto or sox")))))

(ert-deftest earwig-test-command-buffer ()
  "A command runs in the buffer it was given for, whatever is current."
  (let ((inhibit-message t))
    (with-temp-buffer
      (set-window-buffer nil (current-buffer))
      (insert "Alpha beta")
      (let ((shown (current-buffer)))
        (with-temp-buffer
          (insert "Other text")
          (earwig--run-command-in "delete last word" shown)
          (should (equal (buffer-string) "Other text")))
        (should (equal (buffer-string) "Alpha"))))))

(ert-deftest earwig-test-stream-in-order ()
  "The next segment is only sent once the last one's text is in.
Not as soon as its request exits, as Emacs may read the output of
several finished requests at once and run their callbacks in any order."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (earwig-test-streaming
     (let (sent)
       (cl-letf (((symbol-function 'earwig-server-transcribe)
                  (lambda (file callback)
                    (push (cons file callback) sent)
                    ;; A request that has exited, its callback not run yet
                    (let ((process (make-process :name "earwig-test" :command '("true")
                                                 :sentinel #'ignore :noquery t
                                                 :connection-type 'pipe)))
                      (while (process-live-p process) (accept-process-output process 0.05))
                      process))))
         (dolist (start '(0 32000))
           (let ((file (expand-file-name (format "%d.wav" start) earwig--stream-dir)))
             (with-temp-file file (insert (make-string 8000 ?a)))
             (setq earwig--stream-queue (append earwig--stream-queue (list (cons file start))))))
         (earwig--stream-next)
         (earwig--stream-next)
         (should (= (length sent) 1))
         (funcall (cdr (car sent)) t "First.")
         (should (= (length sent) 2))
         (funcall (cdr (car sent)) t "Second.")
         (should (equal (buffer-string) "First. Second.")))))))

(ert-deftest earwig-test-terminal-spacing ()
  "Dictations typed into a terminal one after another don't run together."
  (with-temp-buffer
    (let ((earwig--terminal-last nil))
      (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest modes) (memq 'ghostel-mode modes)))
                ;; The terminal echoes what's typed
                ((symbol-function 'ghostel-send-string) #'insert))
        (insert "$ ")
        (earwig--send-to-terminal "Hello there.")
        (earwig--send-to-terminal "And more.")
        (earwig--send-to-terminal ", then this.")
        (should (equal (buffer-string) "$ Hello there. And more., then this."))
        ;; Not after something else was typed
        (insert "x")
        (earwig--send-to-terminal "Next")
        (should (equal (buffer-string) "$ Hello there. And more., then this.xNext"))))))

(ert-deftest earwig-test-provisional-face ()
  (let ((earwig-wake-word-commands t))
    (should (eq (earwig--provisional-face "Hello there") 'earwig-provisional))
    (cl-letf (((symbol-function 'face-foreground)
               (lambda (face &rest _) (and (eq face 'earwig-mode-line-command) "red"))))
      ;; Before anything follows the wake word, too
      (dolist (text '("Okay" "Okay, save the file"))
        (should (equal (earwig--provisional-face text)
                       '(earwig-provisional-command (:foreground "red") earwig-provisional))))))
  (let ((earwig-wake-word-commands nil))
    (should (eq (earwig--provisional-face "Okay, save") 'earwig-provisional))))

(ert-deftest earwig-test-wav-header ()
  (should (= (length (earwig--wav-header 100)) 44)))

(ert-deftest earwig-test-stream ()
  "Stream two sentences with a pause between them, made by say."
  (skip-unless (and (executable-find "sox") (executable-find "say")
                    (earwig-server-ready-p)))
  (let* ((dir (make-temp-file "earwig-test-" t))
         (aiff (expand-file-name "speech.aiff" dir))
         (wav (expand-file-name "speech.wav" dir))
         (earwig--stream-input (list wav))
         (earwig--mode 'dictate)
         (inhibit-message t))
    (unwind-protect
        (progn
          (call-process "say" nil nil nil "-o" aiff
                        "Hello world, this is a test. [[slnc 2500]] And this is the second part.")
          (call-process "sox" nil nil nil aiff "-r" "16000" "-c" "1" "-b" "16" wav)
          (with-temp-buffer
            ;; Dictation goes to the selected window
            (set-window-buffer nil (current-buffer))
            (earwig-stream-start)
            (with-timeout (60 (error "Streaming didn't finish"))
              (while earwig--stream-dir
                ;; Batch Emacs on macOS can fail its select() as a
                ;; subprocess exits; the processes carry on regardless
                (condition-case err
                    (sleep-for 0.1)
                  (file-error
                   (unless (equal (cadr err) "Failed select")
                     (signal (car err) (cdr err)))))))
            (should (> earwig--stream-count 1))
            (should (string-match-p "\\`Hello world[,.] this is a test\\. And this is the second part\\.\\'"
                                    (buffer-string)))))
      (delete-directory dir t))))

(provide 'earwig-test)
;;; earwig-test.el ends here
