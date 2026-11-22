;;; earwig-org.el --- Org TODOs, scheduling and the agenda by voice  -*- lexical-binding: t; -*-

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

;; Commands for the Org entry at point, or the item at point in the
;; agenda:
;;   schedule [it] [for] WHEN    WHEN is today, tomorrow, next week,
;;                               next month or on DAY ("on Friday")
;;   mark [it] done
;;   toggle todo                 the next TODO state
;; and "open agenda", the agenda dispatcher.
;;
;; The rule `earwig-when' and `earwig-spoken-time' are there for
;; commands of your own that take a date, too.

;;; Code:

(require 'subr-x)
(require 'earwig-grammar)

;; Org is only loaded when a command needs it
(declare-function org-read-date "org" (&optional with-time to-time from-string &rest _))
(declare-function org-todo "org" (&optional arg))
(declare-function org-schedule "org" (arg &optional time))
(declare-function org-agenda-todo "org-agenda" (&optional arg))
(declare-function org-agenda-schedule "org-agenda" (arg &optional time))
(declare-function org-agenda "org-agenda" (&optional arg keys restriction))

(defconst earwig--weekdays
  '("monday" "tuesday" "wednesday" "thursday" "friday" "saturday" "sunday")
  "The days of the week, as said.")

(phony-define-dictionary earwig-when
  "A spoken date, as \"tomorrow\" or \"on Friday\".
For commands that take a date; its value is what was said, lowercased,
which `earwig-spoken-time' makes a time."
  (mapcar (lambda (when) (cons when when))
          (append '("today" "tomorrow" "next week" "next month")
                  earwig--weekdays
                  (mapcar (lambda (day) (concat "on " day)) earwig--weekdays))))

(defun earwig-spoken-time (when)
  "Return the time spoken as WHEN (\"tomorrow\", \"on Friday\", ...), or nil.
See the rule `earwig-when'; \"someday\" or no WHEN is nil."
  (require 'org)
  (let ((when (and when (string-remove-prefix "on " (downcase when)))))
    (unless (member when '(nil "someday"))
      (org-read-date nil t (pcase when
                             ("today" ".")
                             ("tomorrow" "+1d")
                             ("next week" "+1w")
                             ("next month" "+1m")
                             (_ (substring when 0 3)))))))

(defun earwig-cmd-schedule (when)
  "Schedule the Org entry at point, or the agenda item, for WHEN."
  (let ((date (format-time-string "%Y-%m-%d" (earwig-spoken-time when))))
    (if (derived-mode-p 'org-agenda-mode)
        (org-agenda-schedule nil date)
      (org-schedule nil date))))

(defun earwig-cmd-mark-done ()
  "Mark the Org entry at point, or the agenda item, as done."
  (if (derived-mode-p 'org-agenda-mode)
      (org-agenda-todo 'done)
    (org-todo 'done)))

(defun earwig-cmd-toggle-todo ()
  "Cycle the TODO state of the Org entry at point, or the agenda item."
  (call-interactively (if (derived-mode-p 'org-agenda-mode) #'org-agenda-todo #'org-todo)))

(earwig-defcommand earwig-say-schedule ("schedule" (? (| "it" "this")) (? "for") (when earwig-when))
  "Schedule the Org entry at point, or the agenda item, for WHEN."
  :help "schedule [it] [for] today | tomorrow | next week | next month | on DAY"
  (earwig-cmd-schedule when))

(earwig-defcommand earwig-say-mark-done ("mark" (? (| "it" "this")) (| "done" "dunn"))
  "Mark the Org entry at point, or the agenda item, as done."
  :help "mark [it] done"
  (earwig-cmd-mark-done))

(earwig-defcommand earwig-say-toggle-todo ("toggle" (| "todo" "toto"))
  "Cycle the TODO state of the Org entry at point, or the agenda item."
  :help "toggle todo"
  (earwig-cmd-toggle-todo))

(earwig-defcommand earwig-say-agenda ("open" (? "the") "agenda")
  "Open the agenda dispatcher."
  :help "open agenda"
  (call-interactively #'org-agenda))

(provide 'earwig-org)
;;; earwig-org.el ends here
