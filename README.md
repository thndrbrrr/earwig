# Earwig

[![License: GPL v3](https://img.shields.io/badge/License-GPL_v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Earwig is a dictation and voice commands package for Emacs, inspired by [Sacha Chua's speech recognition setup](https://sachachua.com/blog/category/speech-recognition/).

Earwig supports push-to-talk, streaming transcription that shows words as you say them, a grammar of editing commands, and corrections it learns. Speech is transcribed locally by [Orukeet](https://github.com/Oruk-AI/orukeet).

Tap a key to talk and tap it again to stop, or use push-to-talk and hold the space bar down while you talk. Dictation is cleaned up and fitted to where it goes, and spoken commands edit text by a verb and a target: "select last two words", "replace Monday with Tuesday in this paragraph", "move the item with eggs under the heading with shopping".

Earwig is made for writing structured text: notes, plans, drafts and documents, in Org and Markdown above all, where you dictate headings, lists and paragraphs, and edit by word, sentence, paragraph, item and section. It isn't made for writing code. Its targets are words and sentences, not expressions or identifiers, and while you can dictate into a code buffer, nothing there knows the code's syntax.

Earwig runs on macOS. Other platforms are [on the roadmap](docs/roadmap/README.md).

This README covers installing, setting up and using Earwig. The [manual](docs/manual.md) has the full reference.

> [!NOTE]
> [Claude](https://claude.ai) wrote most of it, while I spent decades in software engineering learning what to make, what to keep, and what to throw away. ¯\\_(ツ)\_/¯

## Demo

https://github.com/user-attachments/assets/c98e9aa4-047d-4ef0-beb1-6defd6b9202d

## What's new in 0.3.0

Voice commands are now a [phony.el](https://github.com/ErikPrantare/phony.el) grammar. Targets compose ("the first word of the second sentence in the paragraph with moonbase"), commands follow one another without "and then", a voice command runs when you pause, and there are new ones to move, copy, swap and wrap text.

If you wrote commands of your own: `earwig-extra-commands` and its regexps are no longer used. Rewrite them with `phony-defun`, as in [Commands of your own](#commands-of-your-own). Earwig now needs phony.el 4.0.0. The [changelog](CHANGELOG.md) has the rest.

## Features

- **Dictation** into any buffer, cleaned up as it goes in: filler words like "uhm" dropped, spoken punctuation turned into symbols, capitals and spacing fitted to where the text goes.
- **Structure as you talk:** in Org and Markdown, "new heading" and "new item" start a heading or list item mid-dictation.
- **Streaming:** words appear while you talk and settle at each pause.
- **Tap or hold:** tap a key to start and stop, or hold the space bar to talk.
- **Voice commands** to select, delete, move, copy, swap, wrap, format and replace text by a verb and a target, to add headings and list items, and to get around Emacs.
- **Easy targeting and navigating:** "the first word of every item in the section with risks", "the second through fourth items", "the paragraph with budget".
- **Commands one after another**, with or without "and then": "select last sentence format bold".
- **Commands while dictating:** pause, say "okay" and one or more commands, and carry on dictating.
- **Corrections** that Earwig learns, so a word misheard once is right from then on.
- **Commands of your own**, as [phony.el](https://github.com/ErikPrantare/phony.el) grammar rules.
- **Local transcription** by [Orukeet](https://github.com/Oruk-AI/orukeet).

## Requirements

- macOS
- Emacs 29.1 or newer
- [phony.el](https://github.com/ErikPrantare/phony.el) 4.0.0, from MELPA (installed with Earwig when MELPA is in `package-archives`). Earwig currently uses some of its internals, so a later version may need a later Earwig
- curl
- sox (recommended) for recording; or ffmpeg (which doesn't support streaming though)
- [Orukeet](https://github.com/Oruk-AI/orukeet) with its speech server (requires Python 3.12)

## Installation

Install Earwig from its repository, with `use-package` (Emacs 30) or `M-x package-vc-install`. Earwig also needs to know where the speech server is and how to start it: the settings below assume the server is installed in `~/.local/share/orukeet` and listens on port 18178, as set up in step 2 of [Setup](#setup).

```elisp
(use-package earwig
  :vc (:url "https://github.com/thndrbrrr/earwig" :rev :newest)
  :custom
  (earwig-speech-server-directory "~/.local/share/orukeet")
  (earwig-speech-server-command '(".venv/bin/python" "local_server.py"
                                  "--installation" "installation.json"
                                  "--port" "18178"))
  (earwig-speech-server-base-url "http://127.0.0.1:18178")
  :config
  (earwig-mode 1))
```

`:rev :newest` installs the latest commit; without it, `use-package` installs the last release, the commit that last changed the version number. `M-x package-vc-install` installs the latest commit too; set the options with `setopt` as below.

Alternatively, clone the repository, add its directory to your `load-path`, and turn Earwig on:

```elisp
(add-to-list 'load-path "/path/to/earwig")
(require 'earwig)
(setopt earwig-speech-server-directory "~/.local/share/orukeet"
        earwig-speech-server-command '(".venv/bin/python" "local_server.py"
                                       "--installation" "installation.json"
                                       "--port" "18178")
        earwig-speech-server-base-url "http://127.0.0.1:18178")
(earwig-mode 1)
```

## Setup

1. **Recorder.** Install sox. Earwig can record with ffmpeg instead, but only sox starts recording quickly enough not to lose your first words, and only sox can stream:

   ```sh
   brew install sox
   ```

2. **Speech server.** Install Orukeet and its example server, `local_server.py`, in a directory of their own, the one the configuration under [Installation](#installation) names (see Orukeet's [local server guide](https://github.com/Oruk-AI/orukeet/blob/main/examples/local-server.md)):

   ```sh
   mkdir -p ~/.local/share/orukeet && cd ~/.local/share/orukeet

   # Orukeet itself
   python3.12 -m venv .venv
   .venv/bin/pip install https://github.com/Oruk-AI/orukeet/releases/download/v0.1.1/orukeet-0.1.1-py3-none-any.whl
   .venv/bin/orukeet install --device cpu --cache ./orukeet-cache --output installation.json

   # The server, from Orukeet's examples/
   curl -fLO https://raw.githubusercontent.com/Oruk-AI/orukeet/main/examples/local_server.py
   curl -fLO https://raw.githubusercontent.com/Oruk-AI/orukeet/main/examples/local-server-requirements.txt
   .venv/bin/pip install -r local-server-requirements.txt
   ```

   The runtime and model take about 700 MB. With the configuration from [Installation](#installation), Earwig starts the server for you: dictating while no server answers offers to start it, or use `M-x earwig-speech-server-start` (`-stop`, `-toggle`, `-log`). The server's default port, 8000, is a common one, so the configuration starts it on port 18178 instead. To run it yourself, or to use another server, see [The speech server](docs/manual.md#the-speech-server) in the manual.

3. **Keyboard and microphone.** For push-to-talk, holding a key must repeat it rather than show the accent menu (restart Emacs afterwards):

   ```sh
   defaults write org.gnu.Emacs ApplePressAndHoldEnabled -bool false
   ```

   A fast key repeat (System Settings › Keyboard) makes push-to-talk notice a hold and its release sooner; see [Microphone and keyboard timing](docs/manual.md#microphone-and-keyboard-timing). macOS asks for microphone access the first time Emacs records; if it was denied, allow Emacs under System Settings › Privacy & Security › Microphone.

4. **Check.** Run `M-x earwig-check-setup` until everything is ✓. It records half a second from the microphone, sends it to the server, and checks the keyboard settings. Orukeet takes up to about 20 seconds to load after it starts.

## Usage

### Keys

| Key                         | Tap                                                                | Hold                     |
|-----------------------------|--------------------------------------------------------------------|--------------------------|
| Cmd-d, keypad 0             | start dictation; tap again to stop                                 |                          |
| Cmd-f, keypad Enter         | start a voice command; it runs at a pause, or tap again           |                          |
| Cmd-e, keypad `.`           | correct the word before point (or the region) and remember the fix |                          |
| Space, with push-to-talk on | types a space                                                      | dictate until you let go |
| C-g, while recording        | cancel a command, or dictation that doesn't stream                 |                          |

Push-to-talk is off until you turn it on with `(setopt earwig-push-to-talk t)`. To use other keys, see [Configuration](#configuration).

### Ways of working

| Mode                    | How                                                                   | For                                         |
|-------------------------|-----------------------------------------------------------------------|---------------------------------------------|
| Dictation               | Tap Cmd-d, talk, tap Cmd-d again                                      | Writing                                     |
| Push-to-talk            | Hold the space bar while you talk                                     | Short bursts of writing                     |
| Voice command           | Tap Cmd-f, say the command, pause (or tap Cmd-f again)                | Editing, moving around, running commands    |
| Command while dictating | Pause, say "okay" and the command, pause, carry on                    | Editing without leaving dictation           |
| Correction              | Put point after a misheard word and press Cmd-e                       | Fixing a mishearing for good                |

- **Text appears as you talk**, grey until a pause, then final. A command said after "okay" shows in blue and runs at the next pause.
- **Dictation follows point:** click somewhere else, or say "okay, go before moonbase", and what you say next goes there.
- **A voice command runs when you pause.** Recording stops after 1.5 seconds of silence once what you said is a complete command, or after 3 seconds if it isn't one yet. Tap Cmd-f again to run it sooner. To stop commands only with the key, set `(setopt earwig-command-auto-stop nil)`.
- **Several commands in a row:** "select last sentence format bold", or with "and then" between them. End with "never mind" or "cancel" and nothing runs.
- **Undo:** each command, and each stretch of dictation, is one undo step. "scratch that" or "undo" takes back the last dictation.

The manual has the details: [how a command is recognized](docs/manual.md#how-a-command-is-recognized), [commands while dictating](docs/manual.md#commands-while-dictating), and [streaming](docs/manual.md#streaming-and-provisional-text).

### Commands

Editing commands combine a verb with a target: "select last two words", "delete that", "capitalize deadline", "cut because through Friday". A target is built the way you'd say it: a unit (word, sentence, paragraph, line, heading, section, item, checkbox, link), with a quantity before it ("last two", "the third", "every") and a filter after it ("with budget", "without a date", "ending with Friday"), and parts nested in each other with "in" or "of", as deep as you like.

Take this Org buffer, with the cursor at the end of the last line:

```org
* Launch plan
** Risks
- Venue may fall through
- Catering is late
- Speakers cancel
- Budget overruns
** Open questions
- Who hosts?
** Timeline
The venue opens at nine. Doors close at noon. Everyone leaves by five.
```

| Say                                                                  | Gives                                                                    |
|----------------------------------------------------------------------|--------------------------------------------------------------------------|
| delete the second sentence                                           | The venue opens at nine. Everyone leaves by five.                        |
| select last sentence format bold                                     | The venue opens at nine. Doors close at noon. *Everyone leaves by five.* |
| move last sentence to the start of this paragraph                    | Everyone leaves by five. The venue opens at nine. Doors close at noon.   |
| uppercase the second sentence through the end of this paragraph      | The venue opens at nine. DOORS CLOSE AT NOON. EVERYONE LEAVES BY FIVE.   |
| delete the last two items of the section with risks                  | Risks keeps "Venue may fall through" and "Catering is late"              |
| duplicate the item with catering and then replace catering with parking in that | "Parking is late" under "Catering is late"                    |
| swap the section with timeline with the section with risks           | the two sections trade places, with everything under them                |

You never had to go to the risks to work on them. And you don't have to stop dictating for any of it. Pause, say "okay" and the commands, pause, and carry on:

> …so that's where we stand. *(pause)* Okay, move the second through fourth items of the section with risks under the heading with open questions and then format bold the first word of every item in that. *(pause)* Next, the budget…

```org
** Risks
- Venue may fall through
** Open questions
- Who hosts?
- *Catering* is late
- *Speakers* cancel
- *Budget* overruns
```

Three items picked by position in a section picked by its words, moved under another heading, and marked up through "that", which is always what the last command put in. Then "Next, the budget…" goes on at the end of the timeline, where you were.

Say "what can I say" for the full list:

| Kind                                                                                            | Say                                                                                                                                                                                          |
|-------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [Edit](docs/manual.md#editing-a-verb-and-a-target)                                              | select, delete, cut, copy, capitalize, uppercase, lowercase, title case + TARGET                                                                                                             |
| [Targets](docs/manual.md#editing-a-verb-and-a-target)                                           | that · [QUANTITY] UNIT [FILTER] · PART in / of PART · WORDS · every WORDS · WORDS in PART · A and B · A through B · TARGET through TARGET · the end of TARGET · the parent heading |
| [Units, quantities, filters](docs/manual.md#units-quantities-and-filters)                       | word, sentence, paragraph, line, heading, section, item, checkbox, link · this, next, last [N], first [N], the third, second to last, the third through fifth, every · with, without, starting with, ending with WORDS |
| [Format](docs/manual.md#formatting) (Org, Markdown)                                             | format bold, italic, underline, code, verbatim, strike through, plain + TARGET                                                                                                               |
| [Replace](docs/manual.md#replacing)                                                             | replace A with B · replace A with B in TARGET · replace A with B everywhere · replace the next / every A with B · replace TARGET with B |
| [Move](docs/manual.md#moving-and-other-editing)                                                 | go before TARGET · go after TARGET · go to the end of TARGET · go to top · go to line N · go to heading NAME · go back |
| [Rearrange](docs/manual.md#moving-copying-and-wrapping)                                         | move TARGET after TARGET · copy TARGET under TARGET · swap A with B · duplicate · rewrite · wrap TARGET in quotes · unwrap · replace the commas around TARGET with dashes |
| [Clipboard and undo](docs/manual.md#moving-and-other-editing)                                   | paste · scratch that · undo · redo                                                                                                                                                           |
| [Headings and lists](docs/manual.md#headings-and-lists-org-and-markdown) (Org, Markdown)        | new heading · new subheading · new item · new sub item · new checkbox, each with optional TEXT                                                                                               |
| [Headings and lists](docs/manual.md#headings-and-lists-org-and-markdown)                        | new heading after TARGET · new item under TARGET · new paragraph before TARGET · go into TARGET |
| [Sentences](docs/manual.md#joining-sentences)                                                   | join last sentence · join last sentence with comma                                                                                                                                           |
| [Emacs](docs/manual.md#emacs-and-org-commands)                                                  | save · search · switch to buffer NAME · other window · scroll down · close buffer · comment that · run command NAME                                                                          |
| [Emacs](docs/manual.md#emacs-and-org-commands)                                                  | focus on TARGET · show everything · where is TARGET · open the link with WORDS |
| [Org](docs/manual.md#emacs-and-org-commands)                                                    | mark done · toggle todo · schedule for tomorrow · open agenda                                                                                                                                |

### Dictation

Dictation drops "um" and "uh", applies your corrections, and fits the text to where it goes. Say punctuation and breaks where you want them:

| Say                                              | Gives                       |
|--------------------------------------------------|-----------------------------|
| comma, period, colon, semicolon                  | `,` `.` `:` `;`             |
| question mark, exclamation mark                  | `?` `!`                     |
| open quote, close quote, open paren, close paren | `"` `"` `(` `)`             |
| em dash, ellipsis                                | `—` `…`                     |
| new line, new paragraph                          | a line break, a blank line  |
| new sentence                                     | a capital for the next word |

Say "literal" before one of these to keep it as words: "a literal period of time". The manual lists [all spoken punctuation](docs/manual.md#spoken-punctuation), quotes and dialogue included.

**Structure.** In Org and Markdown, "new heading", "new subheading", "new item", "new sub item" and "new checkbox" at the start of a sentence start one, without "okay", so you can dictate a whole outline in one go. "That's all for now. New heading. Next steps. First we plan it. New item, buy milk. New item, call mum." gives

```org
That's all for now.
** Next steps
First we plan it.
- Buy milk
- Call mum
```

**Fixing as you go.** Pause, say "okay" and a command, and carry on:

| Say                                       | For                                                               |
|-------------------------------------------|-------------------------------------------------------------------|
| okay, scratch that                        | taking back what you just dictated                                |
| okay, delete last three words             | a false start                                                     |
| okay, join last sentence                  | a sentence a pause split in two                                   |
| okay, rewrite last sentence … okay, go back | saying a sentence again: it goes, you dictate its replacement, and "go back" returns to where you were |
| okay, go into the heading with budget … okay, go back | adding to another section, and coming back              |
| okay, new item under the item with eggs   | a sub-item somewhere else, dictated next                          |

A word that's misheard again and again: put the cursor after it, press Cmd-e and type the right one. Earwig remembers it from then on (see [corrections](docs/manual.md#corrections)).

## Configuration

All options are in `M-x customize-group RET earwig RET`. These are the ones most worth knowing:

| Option                                                           | Default                     | What it does                                                         |
|------------------------------------------------------------------|-----------------------------|----------------------------------------------------------------------|
| `earwig-speech-server-command`, `earwig-speech-server-directory` | nil                         | How and where Earwig starts the speech server; nil to start it yourself |
| `earwig-speech-server-base-url`                                | `"http://127.0.0.1:18178"`  | Where the speech server listens                                      |
| `earwig-input-device`                                          | `"default"`                 | The microphone, as named in the system's sound settings              |
| `earwig-recorder`                                              | `auto`                      | `sox`, `ffmpeg`, `pincer` (experimental, see the manual), or `auto` for sox if it's installed |
| `earwig-toggle-keys`                                           | Cmd-d, keypad 0; Cmd-f, keypad Enter | Keys tapped to start and stop dictation or a command        |
| `earwig-push-to-talk`                                          | nil                         | Turns push-to-talk on                                                |
| `earwig-push-to-talk-keys`                                     | Space                       | Keys held down to talk                                               |
| `earwig-correct-keys`                                          | Cmd-e, keypad `.`           | Keys that correct a misheard word                                    |
| `earwig-streaming`                                             | t                           | Show text while you talk (needs sox)                                 |
| `earwig-stream-pause`                                          | 1.5                         | Seconds of silence that end a stretch of dictation                   |
| `earwig-wake-word-commands`                                    | t                           | Give commands while dictating by saying "okay" first                 |
| `earwig-command-auto-stop`                                     | 1.5                         | Seconds of silence that end a voice command; nil to stop it with its key |
| `earwig-provisional-command-display`                           | `buffer`                    | Show a command said while dictating in the buffer, or in the `echo-area` |
| `earwig-flash`                                                 | t                           | Flash the text a command put in, moved or wrapped                    |
| `earwig-dictation-structure`                                   | t                           | "new heading" and "new item" in dictation                            |
| `earwig-corrections`                                           | nil                         | Your own "wrong => right" corrections                                |
| `earwig-hold-*`                                                |                             | Push-to-talk timing, to fit your key repeat                          |
| `sentence-end-double-space`                                    | t (Emacs's)                 | Set it to nil unless you end sentences with two spaces: otherwise Earwig sees a paragraph of single-spaced sentences as one |

For example, to dictate by holding the space bar or Cmd-d, give commands by holding F6, and pick a microphone:

```elisp
(setopt earwig-push-to-talk      t
        earwig-push-to-talk-keys '(("SPC" . dictate) ("s-d" . dictate) ("<f6>" . command))
        earwig-input-device      "Display Audio"
        sentence-end-double-space nil)
```

The manual has [every option](docs/manual.md#customization-reference).

## Commands of your own

Voice commands, Earwig's and yours, are rules of a [phony.el](https://github.com/ErikPrantare/phony.el) grammar. Define yours with `phony-defun`: a name, a pattern of words, an optional docstring and the body that runs. They're found in what's said like Earwig's, and win over Earwig's for the same words.

```elisp
(with-eval-after-load 'earwig
  (phony-defun my/toggle-margins ("toggle" (? "the") (| "margin" "margins"))
    "Toggle the margins."
    (call-interactively #'olivetti-mode))

  ;; "find note emacs" opens find-file with "emacs" filled in
  (phony-defun my/find-note ("find note" (? (name earwig-text)))
    "Find a note."
    (earwig-with-input (earwig-downcase-first-word name) #'find-file)))
```

Earwig has rules and helpers for commands like these, such as `earwig-number` for spoken numbers and `earwig-part` for targets like "this paragraph". The manual describes [all of them, with more examples](docs/manual.md#commands-of-your-own). Commands of your own used to be regexps in `earwig-extra-commands`, which is no longer used: rewrite them with `phony-defun`.

## Troubleshooting

Run `M-x earwig-check-setup` first. Beyond what it finds:

| Symptom                                 | What to do                                                                                              |
|-----------------------------------------|---------------------------------------------------------------------------------------------------------|
| Recording shows, but no text ever comes | Start the server, `M-x earwig-speech-server-start`; `M-x earwig-speech-server-log` shows its output     |
| The first words are cut off             | Install sox; ffmpeg starts recording late                                                               |
| Holding the space bar only types spaces | Turn on `earwig-push-to-talk`, and turn off press and hold (Setup, step 3)                              |
| The same word keeps coming out wrong    | Fix it once with Cmd-e; Earwig remembers it                                                             |
| A voice command does nothing            | It runs once you stop it: pause, or tap Cmd-f again. With `earwig-command-auto-stop` nil, only the key stops it |
| A command runs before you've finished   | Say it without pausing, or raise `earwig-command-auto-stop`; commands that take any words, like "select WORDS", are complete after the first word |
| A command isn't recognized              | Say "what can I say"; all of what you say has to read as commands                                       |
| "this sentence" is the whole paragraph  | `(setopt sentence-end-double-space nil)`, unless you end sentences with two spaces                      |

The manual has [more](docs/manual.md#troubleshooting), on streaming and push-to-talk timing among others.

## Development

Run the tests from the repository, with phony.el installed. `earwig-test-stream` and `earwig-test-record-runs-whole` send speech made by macOS's `say` through the server, and are skipped unless both are there. `earwig-test-paste-evil` is skipped unless evil is on the load path (add `-L path/to/evil`).

```sh
emacs -Q --batch -L . \
  --eval '(progn (package-initialize) (require (quote phony)))' \
  -l test/earwig-test.el -f ert-run-tests-batch-and-exit
```

The manual lists the [source files](docs/manual.md#source-files), and [docs/roadmap](docs/roadmap/README.md) what's planned.

## Acknowledgements

Many thanks to [Sacha Chua](https://sachachua.com), who has shared her Emacs knowledge with the community for many years, among them the speech recognition setup that got Earwig started.

Also a big thank you to [Erik Präntare](https://github.com/ErikPrantare) of the [Emacslisten](https://emacslisten.org/) project for his work on [phony.el](https://github.com/ErikPrantare/phony.el), which provides the grammar that enables the many ways you can\ talk to Earwig.

## License

Distributed under the terms of the GNU General Public License Version 3. See `LICENSE` for details.
