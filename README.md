# Earwig

[![License: GPL v3](https://img.shields.io/badge/License-GPL_v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Earwig is a dictation and voice commands package for Emacs, inspired by [Sacha Chua's speech recognition setup](https://sachachua.com/blog/category/speech-recognition/).

Earwig supports push-to-talk, streaming transcription that shows words as you say them, a grammar of editing commands, and corrections it learns. Speech is transcribed locally by [Orukeet](https://github.com/Oruk-AI/orukeet).

Tap a key to talk and tap it again to stop, or use push-to-talk and hold the space bar down while you talk. Dictation is cleaned up and fitted to where it goes, and spoken commands edit text by a verb and a target: "select last two words", "replace Monday with Tuesday in this paragraph", "format bold from results until breakthrough". 

Earwig runs on macOS. Other platforms are [on the roadmap](docs/roadmap/README.md).

This README covers installing, setting up and using Earwig. The [manual](docs/manual.md) has the full reference.

> [!NOTE]
> [Claude](https://claude.ai) wrote most of it, while I spent decades in software engineering learning what to make, what to keep, and what to throw away. ¯\\_(ツ)\_/¯

## Features

- **Dictation** into any buffer, cleaned up as it goes in: filler words like "uhm" dropped, spoken punctuation turned into symbols, capitals and spacing fitted to where the text goes.
- **Streaming:** words appear while you talk and settle at each pause.
- **Tap or hold:** tap a key to start and stop, or hold the space bar to talk.
- **Voice commands** to select, delete, move, format and replace text by a verb and a target, to add headings and list items in Org and Markdown, and to get around Emacs.
- **Commands while dictating:** pause, say "okay" and one or more commands, and carry on dictating.
- **Corrections** that Earwig learns, so a word misheard once is right from then on.
- **Commands of your own**, a regexp and a function each.
- **Local transcription** by [Orukeet](https://github.com/Oruk-AI/orukeet).

## Requirements

- macOS
- Emacs 29.1 or newer
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
| Cmd-f, keypad Enter         | start a voice command; tap again to stop                           |                          |
| Cmd-e, keypad `.`           | correct the word before point (or the region) and remember the fix |                          |
| Space, with push-to-talk on | types a space                                                      | dictate until you let go |
| C-g, while recording        | cancel a command, or dictation that doesn't stream                 |                          |

Push-to-talk is off until you turn it on with `(setopt earwig-push-to-talk t)`. To use other keys, see [Configuration](#configuration).

### Ways of working

| Mode                    | How                                                                   | For                                         |
|-------------------------|-----------------------------------------------------------------------|---------------------------------------------|
| Dictation               | Tap Cmd-d, talk, tap Cmd-d again                                      | Writing                                     |
| Push-to-talk            | Hold the space bar while you talk                                     | Short bursts of writing                     |
| Voice command           | Tap Cmd-f, say the command, tap Cmd-f again                           | Editing, moving around, running commands    |
| Command while dictating | Pause, say "okay" and the command, pause, carry on                    | Editing without leaving dictation           |
| Correction              | Put point after a misheard word and press Cmd-e                       | Fixing a mishearing for good                |

- **Text appears as you talk**, grey until a pause, then final. A command said after "okay" shows in blue and runs at the next pause.
- **Dictation follows point:** click somewhere else, or say "okay, go to top", and what you say next goes there.
- **A voice command runs only when you stop it.** Forgot to tap Cmd-f again? Nothing happens, as Earwig is still listening. To have a pause end the command instead, set `(setopt earwig-command-auto-stop 1.5)`: recording stops after 1.5 seconds of silence once what you said is a complete command.
- **Chain commands** with "and then": "select last sentence and then format bold". End with "never mind" or "cancel" and nothing runs.
- **Undo:** each command, and each stretch of dictation, is one undo step. "scratch that" takes back the last dictation.

The manual has the details: [how a command is recognized](docs/manual.md#how-a-command-is-recognized), [commands while dictating](docs/manual.md#commands-while-dictating), and [streaming](docs/manual.md#streaming-and-provisional-text).

### Commands

Say "what can I say" for the full list. Editing commands combine a verb with a target: "select last two words", "delete that", "capitalize deadline", "cut because through Friday".

| Kind                                                                                            | Say                                                                                                                                                                                          |
|-------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [Edit](docs/manual.md#editing-a-verb-and-a-target)                                              | select, delete, cut, copy, capitalize, uppercase, lowercase, title case + TARGET                                                                                                             |
| [Targets](docs/manual.md#editing-a-verb-and-a-target)                                           | that · this sentence · last two words · next line · everything · WORDS · A through B · WORDS in TARGET                                                                                       |
| [Format](docs/manual.md#formatting) (Org, Markdown)                                             | format bold, italic, underline, code, verbatim, strike through, plain + TARGET                                                                                                               |
| [Replace](docs/manual.md#replacing)                                                             | replace A with B · replace A with B in TARGET · replace A with B everywhere                                                                                                                  |
| [Move](docs/manual.md#moving-and-other-editing)                                                 | go before WORDS · go after WORDS · go to end of line · go to top · go to line N · go to heading NAME · go back                                                                              |
| [Clipboard and undo](docs/manual.md#moving-and-other-editing)                                   | paste · scratch that · undo · redo                                                                                                                                                           |
| [Headings and lists](docs/manual.md#headings-and-lists-org-and-markdown) (Org, Markdown)        | new heading · new subheading · new item · new sub item · new checkbox, each with optional TEXT                                                                                               |
| [Sentences](docs/manual.md#joining-sentences)                                                   | join last sentence · join last sentence with comma                                                                                                                                           |
| [Emacs](docs/manual.md#emacs-and-org-commands)                                                  | save · search · switch to buffer NAME · other window · scroll down · close buffer · comment that · run command NAME                                                                          |
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

Say "literal" before one of these to keep it as words: "a literal period of time". In Org and Markdown, "new heading" and "new item" at the start of a sentence start a heading or list item. The manual lists [all spoken punctuation](docs/manual.md#spoken-punctuation), quotes and dialogue included, and how [corrections](docs/manual.md#corrections) work.

## Configuration

All options are in `M-x customize-group RET earwig RET`. These are the ones most worth knowing:

| Option                                                           | Default                     | What it does                                                         |
|------------------------------------------------------------------|-----------------------------|----------------------------------------------------------------------|
| `earwig-speech-server-command`, `earwig-speech-server-directory` | nil                         | How and where Earwig starts the speech server; nil to start it yourself |
| `earwig-speech-server-base-url`                                | `"http://127.0.0.1:18178"`  | Where the speech server listens                                      |
| `earwig-input-device`                                          | `"default"`                 | The microphone, as named in the system's sound settings              |
| `earwig-recorder`                                              | `auto`                      | `sox`, `ffmpeg`, or `auto` for sox if it's installed                 |
| `earwig-toggle-keys`                                           | Cmd-d, keypad 0; Cmd-f, keypad Enter | Keys tapped to start and stop dictation or a command        |
| `earwig-push-to-talk`                                          | nil                         | Turns push-to-talk on                                                |
| `earwig-push-to-talk-keys`                                     | Space                       | Keys held down to talk                                               |
| `earwig-correct-keys`                                          | Cmd-e, keypad `.`           | Keys that correct a misheard word                                    |
| `earwig-streaming`                                             | t                           | Show text while you talk (needs sox)                                 |
| `earwig-stream-pause`                                          | 1.5                         | Seconds of silence that end a stretch of dictation                   |
| `earwig-wake-word-commands`                                    | t                           | Give commands while dictating by saying "okay" first                 |
| `earwig-command-auto-stop`                                     | nil                         | Seconds of silence that end a voice command; nil to stop it with its key |
| `earwig-corrections`                                           | nil                         | Your own "wrong => right" corrections                                |
| `earwig-hold-*`                                                |                             | Push-to-talk timing, to fit your key repeat                          |

For example, to dictate by holding the space bar or Cmd-d, give commands by holding F6, and pick a microphone:

```elisp
(setopt earwig-push-to-talk      t
        earwig-push-to-talk-keys '(("SPC" . dictate) ("s-d" . dictate) ("<f6>" . command))
        earwig-input-device      "Display Audio")
```

The manual has [every option](docs/manual.md#customization-reference).

## Commands of your own

Add voice commands to `earwig-extra-commands`, each as `(PATTERN FUNCTION HELP)`. PATTERN is a regexp matched against the whole command, ignoring case and punctuation. FUNCTION gets the regexp's groups as arguments, or is called interactively if there are none. HELP is what "what can I say" shows. Your commands are tried before Earwig's own.

```elisp
(with-eval-after-load 'earwig
  (setq earwig-extra-commands
        '(("toggle \\(?:the \\)?margins?" olivetti-mode
           "toggle margins")
          ;; "find note emacs" opens find-file with "emacs" filled in
          ("find note\\(?: \\(.+\\)\\)?" my/find-note
           "find note [NAME]"))))

(defun my/find-note (name)
  (earwig-with-input (earwig-downcase-first-word name) #'find-file))
```

Earwig has helpers for commands like these, such as `earwig-parse-number` for spoken numbers and `earwig-part-range` for targets like "this paragraph". The manual describes [all the helpers, with more examples](docs/manual.md#commands-of-your-own).

## Troubleshooting

Run `M-x earwig-check-setup` first. Beyond what it finds:

| Symptom                                 | What to do                                                                                              |
|-----------------------------------------|---------------------------------------------------------------------------------------------------------|
| Recording shows, but no text ever comes | Start the server, `M-x earwig-speech-server-start`; `M-x earwig-speech-server-log` shows its output     |
| The first words are cut off             | Install sox; ffmpeg starts recording late                                                               |
| Holding the space bar only types spaces | Turn on `earwig-push-to-talk`, and turn off press and hold (Setup, step 3)                              |
| The same word keeps coming out wrong    | Fix it once with Cmd-e; Earwig remembers it                                                             |
| A voice command does nothing            | It runs only once you stop it: tap Cmd-f again, or set `earwig-command-auto-stop` to have a pause stop it |
| A command isn't recognized              | Say "what can I say"; a command has to match the whole phrase                                           |

The manual has [more](docs/manual.md#troubleshooting), on streaming and push-to-talk timing among others.

## Development

Run the tests from the repository. `earwig-test-stream` and `earwig-test-record-runs-whole` send speech made by macOS's `say` through the server, and are skipped unless both are there. `earwig-test-paste-evil` is skipped unless evil is on the load path (add `-L path/to/evil`).

```sh
emacs -Q --batch -L . \
  -l test/earwig-test.el -f ert-run-tests-batch-and-exit
```

The manual lists the [source files](docs/manual.md#source-files), and [docs/roadmap](docs/roadmap/README.md) what's planned.

## Acknowledgements

Many thanks to [Sacha Chua](https://sachachua.com), who has shared her Emacs knowledge
with the community for many years, among them the speech recognition
setup that got Earwig started.

## License

Distributed under the terms of the GNU General Public License Version 3. See `LICENSE` for details.
