# Earwig manual

The [README](../README.md) covers installing Earwig, setting it up and everyday use. This manual is the full reference: every command and its details, how dictation is cleaned up, the speech server, all options, and writing commands of your own.

Earwig is made for writing structured text, prose and notes in Org and Markdown above all, not code: its targets are words, sentences, paragraphs, items and sections, and nothing in it knows a programming language's syntax.

## Contents

- [Recording](#recording)
  - [Keys](#keys)
  - [Push-to-talk](#push-to-talk)
  - [Streaming and provisional text](#streaming-and-provisional-text)
  - [Microphone and keyboard timing](#microphone-and-keyboard-timing)
  - [Checking the setup](#checking-the-setup)
- [Voice commands](#voice-commands)
  - [How a command is recognized](#how-a-command-is-recognized)
  - [Several commands in a row](#several-commands-in-a-row)
  - [Commands while dictating](#commands-while-dictating)
  - [Commands after a wake word (experimental)](#commands-after-a-wake-word-experimental)
  - [Editing: a verb and a target](#editing-a-verb-and-a-target)
  - [Formatting](#formatting)
  - [Headings and lists (Org and Markdown)](#headings-and-lists-org-and-markdown)
  - [Joining sentences](#joining-sentences)
  - [Replacing](#replacing)
  - [Moving, copying and wrapping](#moving-copying-and-wrapping)
  - [Moving and other editing](#moving-and-other-editing)
  - [Emacs and Org commands](#emacs-and-org-commands)
- [Dictation](#dictation)
  - [Cleanup](#cleanup)
  - [Spoken punctuation](#spoken-punctuation)
  - [Corrections](#corrections)
- [The speech server](#the-speech-server)
- [Commands of your own](#commands-of-your-own)
- [Customization reference](#customization-reference)
- [Troubleshooting](#troubleshooting)
- [Source files](#source-files)

## Recording

### Keys

| Key                         | Tap                                                                | Hold                     |
|-----------------------------|--------------------------------------------------------------------|--------------------------|
| Cmd-d, keypad 0             | start dictation; tap again to stop                                 |                          |
| Cmd-f, keypad Enter         | start a voice command; it runs at a pause, or tap again           |                          |
| Cmd-e, keypad `.`           | correct the word before point (or the region) and remember the fix |                          |
| Space, with push-to-talk on | types a space                                                      | dictate until you let go |
| C-g, while recording        | cancel a command, or dictation that doesn't stream                 |                          |

The voice keys are in two options, each a list of `(KEY . MODE)` with MODE `dictate` or `command`. Set them with `setopt` or Customize.

- **`earwig-toggle-keys`**: tapped, the key starts recording, and tapped again stops it. These are Cmd-d and keypad 0 for dictation, Cmd-f and keypad Enter for commands.
- **`earwig-push-to-talk-keys`**: held down, the key records until you let go. This is the space bar for dictation, and it's off until you turn on push-to-talk.

The correction keys are in `earwig-correct-keys`. The commands `earwig-dictate` and `earwig-command` do the same as the voice keys for a key of your own, bound in any keymap, or from `M-x`: tapped they toggle, held they record until you let go.

### Push-to-talk

```elisp
(setopt earwig-push-to-talk t)
```

Then holding the space bar dictates until you let go. Tapped, it still types a space, and it only dictates where it types: in Dired, for one, it does what it always does. Push-to-talk depends on how the keyboard repeats (see [Microphone and keyboard timing](#microphone-and-keyboard-timing)).

The space bar only dictates, but you can give commands without letting go of it: pause, say "okay" and a command, and carry on dictating (see [Commands while dictating](#commands-while-dictating)).

Any key can push to talk, and a key in both lists does either: tapped it toggles, held it records until you let go. A push-to-talk key that doesn't type does nothing when tapped. For instance, to also dictate by holding Cmd-d and give commands by holding F6, and leave the keypad alone:

```elisp
(setopt earwig-push-to-talk      t
        earwig-push-to-talk-keys '(("SPC" . dictate) ("s-d" . dictate) ("<f6>" . command))
        earwig-toggle-keys       '(("s-d" . dictate) ("s-f" . command))
        earwig-correct-keys      '("s-e"))
```

### Streaming and provisional text

- **Streaming** (`earwig-streaming`, on by default): text appears while you talk, provisional (grey, or blue for a command after "okay") until a pause, then final. It needs sox or Pincer (see [Recording through Pincer](#recording-through-pincer-experimental)); when ffmpeg records, dictation is transcribed when you stop instead, and *Messages* says so once.
- **Typing over provisional text:** in dictation started with a tap, pressing a key while provisional text shows puts it in as it stands, and the key does what it does after it. Punctuation you type (`. , : ; ! ? … — – -`, in `earwig-stream-flush-punctuation`) replaces the period or comma the text ends with, so `,` after "Hello there." gives "Hello there,". Typed right after any dictation you haven't edited, streamed or not, it does the same. The space bar as a push-to-talk key does this too, so tapping it ends the segment with a space. What you say next is transcribed on its own. Dictation pushed to talk waits for the final text as usual, and so do the other voice keys, a click, and a command after "okay". `earwig-stream-flush-on-key` turns this off.

### Microphone and keyboard timing

**Microphone.** Earwig records from the input chosen in the system's sound settings. To pick another, set `earwig-input-device` to a CoreAudio input name:

```elisp
(setopt earwig-input-device "Display Audio")
```

macOS asks for microphone access the first time Emacs records. If it was denied, allow Emacs under System Settings › Privacy & Security › Microphone.

**Keyboard.** Push-to-talk tells a held key from a tap by the key repeating, so it depends on the keyboard settings. The defaults of `earwig-hold-*` are on the safe side: they suit a repeat that starts within about 1.1 s and comes every 100 ms or faster, which takes in what macOS starts with. Faster settings let smaller `earwig-hold-*` values notice a hold, and its release, sooner; `earwig-check-setup` reads the settings and suggests the values.

- Holding a key must repeat it rather than show the accent menu:

  ```sh
  defaults write org.gnu.Emacs ApplePressAndHoldEnabled -bool false
  ```

- Key repeat is in System Settings › Keyboard, or:

  ```sh
  defaults write -g InitialKeyRepeat -int 15   # 250 ms until repeat, the shortest in System Settings
  defaults write -g KeyRepeat -int 2           # then every 33 ms, the fastest
  ```

  These take effect after logging out and in again; the press and hold setting only needs Emacs restarted.

**Timing.** To fit the timing to your keyboard and microphone:

```elisp
;; Holding a key: these suit the fastest key repeat, 250 ms then every 33 ms
(setq earwig-hold-initial-window  0.4
      earwig-hold-repeat-max      0.07
      earwig-hold-release-delay   0.15
      earwig-hold-typing-repeats  3)

;; Streaming: pauses and speech depend on the microphone, the rest on the CPU
(setq earwig-stream-pause                1.5
      earwig-stream-speech-ratio         3.0
      earwig-stream-speech-onset         0.15  ; shorter sounds are noise
      earwig-stream-noise-floor          10
      earwig-stream-provisional-interval 1.0
      earwig-stream-provisional-share    0.5   ; of the server's time
      earwig-stream-max-segment          15)
```

### Checking the setup

```
M-x earwig-speech-server-start     ; with earwig-speech-server-command; Orukeet takes up to ~20 s to load
M-x earwig-check-setup
```

`earwig-check-setup` records half a second from the microphone and sends it to the server, so it catches a wrong device name, a missing microphone permission or sox driver, and a server that's down, besides the keyboard settings. When it can't record from `earwig-input-device`, it lists the input devices there are, and when the microphone is all but silent, it says so. Press `g` in its report to check again.

On macOS it reads the press-and-hold setting of the app `org.gnu.Emacs`; for an Emacs built with another bundle identifier, set `earwig-check-app-id` to it, and use it in place of `org.gnu.Emacs` in the `defaults` command above.

## Voice commands

### How a command is recognized

- Tap Cmd-f (or keypad Enter), or use another key with the mode `command`, and say the command. Pause when you're done, or tap it again: recording stops after `earwig-command-auto-stop` seconds of silence (1.5) once what you've said is a complete command (or ends with "cancel"). Set it to nil to stop commands only with the key. Earwig transcribes it as you speak to tell. After "go to line" without its number, or a chain ending in "and then", it waits longer, `earwig-command-auto-stop-incomplete` (3 s), before giving up. Commands that take any words, like "select WORDS", are complete after the first word, so don't pause inside those. All of what you say has to read as commands; case and punctuation don't matter, and if it doesn't read as said, your `earwig-corrections-commands` are applied and it's tried again (all your corrections apply to every transcription anyway). "what can I say" lists the commands.
- While dictating, say "okay" and the command: see [Commands while dictating](#commands-while-dictating).
- Each change a command makes is one undo step.
- Say several commands in a row and they run one after another: "select last sentence cut that go to bottom paste". "and then" between them is optional: "format bold results and then select the last sentence and then cut that". Each is its own undo step, and the chain stops at one that fails. A command that prompts, like "search", waits for you to answer before the next one runs. See [Several commands in a row](#several-commands-in-a-row) for how Earwig tells where one ends.
- While you say a command with a command key, the echo area shows what Earwig has heard so far, about every second: "▶ select last sentence ▶ cut that", the commands it chains in blue, and what isn't (yet) a command in grey. It runs when you stop, as before. An "okay" said out of habit is dropped, here and when it runs. `earwig-command-preview` turns this off.
- Changed your mind, or misheard? End with "cancel" or "never mind" ("select last sentence and then cut that, never mind") and nothing runs; the preview strikes the commands through. This works after "okay" while dictating too, and nothing is dictated then either. The words are in `earwig-cancel-words`. With a tapped command key, C-g while recording cancels too.

### Several commands in a row

Commands are found in what you say without anything between them. Often there's only one way to read it, as in "select last sentence cut that go to bottom paste". Where words can be read more than one way, as in "select budget cut that" (select "budget cut that", or select "budget" and then cut that), Earwig picks each command when its turn comes, against the buffer as the commands before it left it, by these, in order:

1. Words to find must be in the buffer, numbers must make sense, and "replace" must have something to replace. So "select budget cut that" selects "budget" and cuts it, unless "budget cut that" is in the buffer.
2. Words that can't be checked, as "search" and "switch to" take, run to the end, or to "and then": "search budget go to top" searches for all of it, "search budget and then go to top" doesn't.
3. "and then" splits commands where it can. Only where nothing else reads is it words, as in "replace and then with so".
4. A pause, where Orukeet writes a period or comma, goes between commands: "Select budget. Cut that." is two commands even when "budget cut that" is in the buffer.
5. The fewest commands.
6. Your commands before Earwig's, so yours can take over a phrase of Earwig's.
7. The fewest words to find, so "select last two words" are the two words before the cursor, not those words wherever they are; and "replace one with two in this paragraph" replaces in the paragraph.
8. Words split as early as possible: "replace tea with milk with coffee" replaces "tea" if it's there.

If none of them works, the best of the rest runs, to say why: "No "budget" here".

### Commands while dictating

You never have to leave dictation to give a command, or a chain of them. While you dictate, pause, say "okay" and the command, pause again, and carry on:

> …and that's the plan. *(pause)* Okay, select last sentence and then format bold. *(pause)* Next, the budget…

- This works at every pause (`earwig-stream-pause`, 1.5 s by default), with any dictation key, tapped or held. It needs streaming; without it, only a recording that starts with "okay" is a command.
- As soon as Earwig hears "okay", the provisional text turns the color of CMD in the mode line (blue) instead of grey, so you can tell a command is coming, and the mode line shows ▶ CMD until the command has run and dictation carries on with ● REC. `earwig-provisional-command` gives the text a face of its own.
- Provisional text starts with the icon from the mode line, where it will go: the red ● of REC for dictation, the blue ▶ of CMD for a command. For a command, ▶ takes the place of "okay", and goes between the commands, in place of "and then" too: "okay, select last sentence and then cut that" and "okay, select last sentence cut that" both show as "▶ select last sentence ▶ cut that". `earwig-recording-icon`, `earwig-command-icon` and `earwig-provisional-chain-mark` change them, in the mode line too; `earwig-provisional-icons` turns the icons off in provisional text.
- To keep the buffer for dictation only, show commands in the echo area instead, as with a command key: `(setopt earwig-provisional-command-display 'echo-area)`.
- If no command matches, what you said is inserted as dictation, "okay" and all.
- What only writes forward, where you're dictating, needs no "okay": spoken punctuation, "new line", "new paragraph", and in Org and Markdown "new heading" and "new item" (see [Headings and lists](#headings-and-lists-org-and-markdown)). Everything that changes what's already there, moves, or runs something does.
- Dictation follows point. After "okay, go to top", or after you click somewhere else, what you say next goes there, even mid-sentence. What you'd already said before you moved still goes where you said it, where its provisional text showed. Leaving evil's insert state, which moves point back a character, doesn't count as moving.
- Each stretch of dictation between commands, or before you move, is one undo step, and it's what "scratch that" takes back.
- The wake words are in `earwig-wake-words` ("okay" and "ok"). To have a dictation key only ever dictate, turn it off: `(setopt earwig-wake-word-commands nil)`.

### Commands after a wake word (experimental)

With `earwig-listen-mode`, the microphone stays open and a wake word gives a command without a key:

> Hey Jarvis, delete last word.

The listening is done by [Pincer](https://github.com/thndrbrrr/earwig-pincer), a helper program that listens for the wake word with openWakeWord, using a few percent of one core. The speech server only transcribes once it hears the wake word. Install it as its README says, then:

```elisp
(setopt earwig-pincer-command '("earwig-pincer" "--model" "hey_jarvis"))
(earwig-listen-mode 1)
```

- The command is recorded from 1.5 s before the wake word was heard (`earwig-pincer-pre-roll`), so the wake word and what follows are all there however quickly you say them; what was said before the wake word is dropped. `earwig-pincer-wake-words` says how the wake word is transcribed ("hey jarvis" for the `hey_jarvis` model).
- It's then a command as one given with a command key: shown in the echo area as you say it, and run at the pause after it, once it's complete (`earwig-pincer-command-pause`, 1 s, or `earwig-command-auto-stop` if that's set). C-g cancels it.
- While Earwig records or transcribes, the wake word does nothing. While dictating, it works as "okay" does, after a pause.
- The microphone is open all the time, as the orange indicator on macOS shows. Turning `earwig-listen-mode` off closes it, unless Pincer is also the recorder (below); turning `earwig-mode` off always does, and turns listen mode off too. Turning listen mode on turns `earwig-mode` on. Audio stays on your computer. A Bluetooth headset switches to its low-quality call profile while the microphone is open.
- The pre-trained models are English phrases such as "hey Jarvis" and "alexa"; a wake word of your own needs a model trained for it (`--model path/to/model.onnx`).

#### Recording through Pincer (experimental)

Pincer can also record everything, in place of sox, wake word or not:

```elisp
(setopt earwig-recorder 'pincer)
```

- It runs while `earwig-mode` is on, keeping the microphone open, so recording starts the moment you press a key, where sox takes 0.2 to 0.5 s. It also keeps the audio from just before: a recording starts `earwig-pincer-key-pre-roll` seconds (0.25) before it was started, so a word begun as the key went down isn't cut.
- It streams, as sox does, and records commands and dictation that doesn't stream.
- It records `earwig-input-device`, as named in the system's sound settings; a change takes effect when Pincer next starts (turn `earwig-mode` off and on).
- sox and ffmpeg are untouched: set `earwig-recorder` back to use them. `M-x earwig-check-setup` checks whichever is chosen.

### Editing: a verb and a target

Every verb works on every target: "select last two words", "delete that", "capitalize deadline", "cut because through Friday".

| Verb       | Also said as                 | Does                                       |
|------------|------------------------------|--------------------------------------------|
| select     |                              | selects it (evil: a visual selection)      |
| delete     |                              | deletes it, tidying the spaces left behind; punctuation left at the start of a sentence goes too ("delete yeah" in "Yeah! Igor…" leaves "Igor…"), and if it started the sentence with a capital, the next word takes it |
| cut        |                              | the same, into the kill ring               |
| copy       | yank                         | copies it to the kill ring                 |
| capitalize | cap                          | first letter of each word upper case       |
| uppercase  | upper case, upcase, all caps |                                            |
| lowercase  | lower case, downcase         |                                            |
| title case |                              | title case, small words stay lower case    |

| Target                                                  | Example                                                                    | Means                                                                                                    |
|---------------------------------------------------------|----------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| nothing, region, selection                              | "uppercase", "cut the selection"                                           | the region or evil's visual selection; "select" alone needs one                                          |
| that, this, it                                          | "delete that"                                                              | the region, or else the text that went in last: your last dictation, or what a command put in after it  |
| [QUANTITY] UNIT [FILTER]                                | "select this sentence", "delete last three words", "the second paragraph with budget" | units of the buffer, see [Units, quantities and filters](#units-quantities-and-filters) below |
| PART in / of PART                                       | "the first word of the second sentence in the paragraph with moonbase"     | a part counted inside another, to any depth                                                              |
| the [whole] buffer or file, everything, all             | "copy everything"                                                          | the whole buffer                                                                                         |
| A through B, A until B, from A to / until / through B   | "cut because through Friday", "copy from however until shown"              | from the nearest A that has a B after it to the end of the first such B                                  |
| TARGET through TARGET, from TARGET to TARGET            | "select the second sentence through the end of this paragraph"             | from the start of the first to the end of the second, whichever comes first in the buffer               |
| any other words                                         | "capitalize emacs lisp"                                                    | the nearest place those words appear                                                                     |
| the word / the words WORDS                              | "wrap the word this in single quotes"                                      | the same, for words that mean something else here, like "this", "that", "next" or "everything"           |
| the next / following / previous / preceding WORDS       | "select the next budget"                                                   | the nearest after or before point                                                                        |
| WORDS in PART                                           | "delete very in this paragraph", "format italic meow in the last two sentences" | every place WORDS are inside PART; for a command that acts on one place ("select", "go", "rewrite"), the nearest. A through B or the next WORDS in PART is the nearest |
| every / each WORDS [in PART]                            | "format bold every deadline in this section"                               | all of them                                                                                              |
| the start / beginning / end of TARGET                   | "go to the end of the paragraph with budget"                               | the place right before or after it                                                                       |
| A and B                                                 | "delete very and really"                                                   | both, where "A and B" isn't in the buffer as words: "salt and pepper" stays one target if it's there     |
| both A and B, each of A B and C                         | "capitalize each of Monday Tuesday and Friday"                             | several, even where "A and B" is in the buffer; parts of them that overlap are one                       |

PART is any of these that names a part of the buffer, not words. In Org and Markdown, headings are parts too:

| Target                                                  | Example                                             | Means                                                                                                        |
|---------------------------------------------------------|-----------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| this heading, this headline                             | "title case this heading"                           | its title, without stars, TODO keyword, priority or tags                                                     |
| this section, this subtree                              | "move this section after the section with timeline" | the heading with everything under it                                                                         |
| the body of PART, the text under PART                   | "select the first sentence of the body of the heading with budget" | its own text: after the heading line and Org's planning line (SCHEDULED, DEADLINE) and drawers, up to its first subheading |
| everything under PART                                   | "delete everything under the heading with draft"    | its own text and its subheadings                                                                             |
| the subheadings [of PART]                               | "copy the subheadings of the heading with plans"    | its subheadings, with theirs                                                                                 |
| the parent heading, the parent headline                 | "uppercase the parent heading"                      | one level up                                                                                                 |

The PART of these names a heading or section: "this heading", "the section with budget", "the parent heading", "the second heading of this section".

#### Units, quantities and filters

A part of the buffer is a UNIT, with a QUANTITY before it and a FILTER after it, both optional: "the third through fifth words", "every item without a date", "the last sentence ending with Friday". Parts nest with "in" or "of" to any depth, each counted inside the next: "the first word of every item", "the sentence with moonbase in the second paragraph of the section with plans". After a filter only "in" joins, as "of" is often one of the words.

- **UNIT** is word, sentence, paragraph, line, heading (or headline), section (or subtree), item (or bullet), checkbox (an item with one) or link; singular or plural. Headings and sections are Org's and Markdown's; items (a list item with its sub-items) and links (an Org link, a Markdown link or a URL) are found in any buffer. Items and checkboxes move under each other either way, indented. A paragraph is lines of text between blank lines; a list is one, as is a heading's title. A deleted or cut line, item, section or paragraph of whole lines takes its newline with it.
- **QUANTITY**:

  | Quantity | Example | Means |
  |----------|---------|-------|
  | (none), this, the, current | "select this sentence" | the one around point |
  | (none), with a filter | "select the paragraph with budget" | the nearest one the filter lets through, in the window first, then in the whole buffer; for a plural, every one ("delete the paragraphs with budget") |
  | next / following, previous / preceding [N] | "copy next line", "select the next sentence with budget", "swap this section with the next section" | after or before point: headings and items at any level, sections at the level of the one you're in; inside a part, from point there |
  | last [N] | "delete last three words" | before point, the most common correction while dictating. With a filter or a part it counts from the end there instead: "the last sentence of this paragraph", "the last item with milk" |
  | first [N], second, third … twentieth, 21st, 42nd … | "capitalize the third word", "the first two items of this list" | counted from the start of where it counts, see below. "the first word" is the first of this sentence, not the next word |
  | second to last, next to last, penultimate, third from last, third from the end … | "select the second to last item of the section with tasks" | counted from the end |
  | ORDINAL through ORDINAL | "select the third through fifth words", "the second through the fourth paragraph" | from one to the other, either way round |
  | every, each, all [the] | "uppercase every heading in this section", "all paragraphs" | all of them; "all" alone is the whole buffer |

  N is a number in words or digits: "last three words", "the first 2 items".
- **FILTER** is with or containing, without, starting with, or ending with WORDS. The filter goes first, then the count: "the second paragraph with budget" is the second of the paragraphs with budget. Words match a word unit in part ("the word starting with moon" and "the word containing oon" find `moonbase`) and other units as whole words. A heading or section matches by its title; a link by its visible text or its URL ("the link ending with pdf").
- **Where they count.** Without a part, a unit counts in its natural container: a word in its sentence, a sentence or line in its paragraph (a list item's own text and a heading's title are paragraphs for this), an item or checkbox in its list, a heading or section in its parent's section (at the top, the buffer), a paragraph or link in the heading's own text, or the buffer where there are no headings. "Capitalize the third word" is the third word of this sentence. When a filter finds too few there, it looks further out, up to the buffer: from the paragraph to the heading's own text, its section, the sections around that, and the buffer. A part that's said is where it counts, without going further. Headings, sections, items and checkboxes are counted among their siblings: under "Plans" with A, B (B.1, B.2) and C, "the third heading" is C. With a filter, or "every", or "next" and "previous", they count at any level.
- **Several parts.** "the first sentence of every paragraph" is one sentence per paragraph, skipping paragraphs with too few. Units next to each other are one target ("the third through fifth words"); with a filter they're separate ones, which "delete" and the other verbs act on each of, and "select" can't take. An item counts its own text, not its sub-items: "the first word of every item" counts each item once.
- **"this" and "next" inside a part:** "this sentence in the second paragraph" works only if the cursor is in that paragraph, and "the next sentence in the second paragraph" is the first one after the cursor there.
- **Sentences** end where Emacs's sentence motion says they do. Emacs expects two spaces after a sentence unless `sentence-end-double-space` is nil, so for text with one space, set `(setopt sentence-end-double-space nil)`; otherwise a paragraph is one long sentence. A period inside emphasis, as in `*… wait.*`, ends a sentence too.
- **Last and next sentences.** The sentence the cursor is inside isn't the last or the next one: in `One. Two| three. Four.` "last sentence" (or "previous") is `One.` and "next sentence" is `Four.`. Right after a sentence, or just before its period, it's the last one. "last word" leaves the punctuation after the word alone. In evil's normal state the character under the cursor counts as before point.

More about targets:

- **Words are found** ignoring case and the punctuation between them, so "end of file" also finds "end-of-file". Markup doesn't get in the way: "heading" is found in `_Some underlined heading_`, and "last word" there is `heading` without the underscore. An underscore or apostrophe between letters joins them, so `foo_bar` and `don't` are one word each, but `'go'` is the word `go` in quotes. The nearest is looked for in the window first, then in the whole buffer: one around point wins, then the closest before point, then the closest after.
- **"in"** only scopes when what follows names a part of the buffer; otherwise it's one of the words: "select log in screen". Where both read, as in "the sentence with sign in the second paragraph", the reading with fewer words to find is tried first, and the buffer settles it.
- **Several places,** as "every" and "and" give, are acted on together, in one undo step; cut or copied, they go into the kill ring together. "select" takes only one.
- **"next one", "previous one"** (or "next match") move a word target on to the next or previous place it appears, after "select WORDS" or "go before/after WORDS".

### Formatting

"format STYLE TARGET" marks the target up, with any target from the table above: "format bold meow in the last two sentences", "format italic last word", "format underline from however until shown", "format code that". The style can go last too: "format that bold". Saying it again takes the style off again.

| Style                                              | Org                                             | Markdown           |
|----------------------------------------------------|-------------------------------------------------|--------------------|
| bold                                               | `*bold*`                                        | `**bold**`         |
| italic, italics                                    | `/italic/`                                      | `_italic_`         |
| underline, underlined                              | `_underline_`                                   | `<u>underline</u>` |
| code                                               | `~code~`                                        | `` `code` ``       |
| verbatim                                           | `=verbatim=`                                    | `` `verbatim` ``   |
| strike through, strikethrough, strike, crossed out | `+strike+`                                      | `~~strike~~`       |
| plain, normal, none                                | takes all markup off the target, also inside it |                    |

- Styles combine: "format bold" on italic text gives `/*text*/`.
- Markup goes around the text of each line, not its indentation, bullet, checkbox or heading stars, nor an Org heading's TODO keyword, priority and tags. A target over several list items or paragraphs is marked up item by item, as is one longer than the two lines Org's emphasis can span.
- Other modes have no formatting; `earwig-format-markup` says which markup each mode gets.

### Headings and lists (Org and Markdown)

| Say                         | Does                                                                                                                                            |
|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| new heading [TEXT]          | a heading at the level of the one you're under, in it or in its body, after its subtree                                                         |
| new subheading [TEXT]       | one level deeper, as the last child                                                                                                             |
| new item, new bullet [TEXT] | the next item of the list you're in, after its sub-items, without a checkbox even in a list of them; outside a list, starts a `- ` list on the next line (also "new list", "start a list") |
| new sub item [TEXT]         | an item one level deeper                                                                                                                        |
| new checkbox [TEXT]         | an item with `[ ] `                                                                                                                             |
| new sub checkbox [TEXT]     | a checkbox one level deeper, as "new sub item" is an item one level deeper                                                                      |

Numbered lists go on numbering. Only "new checkbox" and "new sub checkbox" make a checkbox; "new item" never does, also not "new item under/before/after TARGET". While dictating, "new sub item" and "new sub checkbox" make a child of the item you're in without "okay"; as a command, "okay, new item under this item" or "okay, new checkbox under this item" does the same. TEXT goes in with a capital: "new heading next steps". In Org these use Org's own commands, so blank lines and numbering follow Org's settings; in Markdown they work on `#` headings outside code blocks and on `-`, `+`, `*` and numbered lists.

Elsewhere, and in any buffer for paragraphs, as commands:

| Say                                                                 | Does                                                                                                                                   |
|---------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| new heading, item, checkbox, paragraph before / after / under DEST  | "new heading after the heading with budget", "new item before the item with eggs", "new checkbox under this item", "new paragraph before however"; then dictate it |
| add a heading, add an item, add a paragraph … (the same)            | "add an item under the item with eggs": a sub-item                                                                                     |
| new subheading under DEST                                           | a subheading, as the last one                                                                                                          |
| new item under HEADING                                              | an item at the end of the heading's own text: the list it ends with goes on, at its outer level; otherwise a `- ` list starts there     |
| go into DEST, add to DEST                                           | to the end of a heading's own text, before its first subheading, to add to it: "okay, go into the heading with budget", dictate, "go back" |

- DEST is one target, as in the tables above, not "every" or "and".
- A heading or item goes where "new heading" or "new item" would put one if you were at DEST, or right before it. "under" makes a subheading or sub-item, the last.
- "new heading after the heading with budget" makes the heading there when the buffer has a heading with "budget"; otherwise it's a new heading titled "After the heading with budget", as before.
- A new paragraph next to a paragraph, section or list item goes beside it; next to other words it splits their paragraph, with the new, empty one between. "under" a heading, it's at the end of the heading's own text.
- Going into a heading with no text of its own opens a line for it, after Org's planning line and drawers.
- The bare commands "next heading", "next item" and "next bullet" are gone: "the next heading" is a target, as in "select the next heading". Say "new heading" or "new item".

**In dictation** the same phrases work where they start a sentence, so pause before them: "That's all for now. New heading. Next steps. First we plan it. New item, buy milk. New item, call mum." gives

```org
That's all for now.
** Next steps
First we plan it.
- Buy milk
- Call mum
```

- The first sentence after "new heading" is the heading, without its period; the rest is its body. A single sentence after "new item" loses its period.
- It carries over pauses and dictations: "New heading.", then "Next steps.", then the body, each on its own, works the same.
- Like "new paragraph", these only write forward, where you're dictating, so they need no "okay". Commands that change what's already there, like "join last sentence", do.
- Mid-sentence, "we need a new heading here" stays words; so does "literal new heading". `(setq earwig-dictation-structure nil)` turns it off.

### Joining sentences

When a pause split a sentence in two, mend it without leaving dictation: say "okay, join last sentence". It works in any buffer.

| Say                                          | Gives                                                          |
|----------------------------------------------|----------------------------------------------------------------|
| join last sentence                           | "We went to the. Store today." → "We went to the store today." |
| join last sentence with comma                | "I think so. Then we go." → "I think so, then we go."          |
| join the last three sentences [with a comma] | three sentences become one                                     |

"join last two sentences" is the same as "join last sentence": the two become one. The sentence that follows loses its capital, unless it's "I", an acronym or a word your corrections put in. Sentences aren't joined across a blank line, or into a list item or heading.

### Replacing

| Say                         | Replaces                                                                     |
|-----------------------------|------------------------------------------------------------------------------|
| replace A with B            | the nearest A                                                                |
| replace the next / previous A with B | the nearest A after or before point (in PART, if one follows)       |
| replace every A with B      | every A in the buffer, or in PART: "replace every shark in this section with dolphin" |
| replace A with B in PART    | every A in PART: "in this paragraph", "in the last three lines", "in that"   |
| replace A in PART with B    | the same: "replace moonbase in the second paragraph with base"               |
| replace A with B everywhere | every A in the buffer                                                        |
| replace that with B         | the region itself, if there is one; otherwise the word "that"                |
| replace the word A with B   | the words A, even ones that mean something else in a target                  |
| replace PART with B         | the text of PART: "replace the second word with moon", "replace the last sentence with see you then" |

B takes A's capital ("Monday" → "Tuesday" at a sentence start), but the capital of "I", an acronym or a name only at a sentence start: "replace I with we" gives "we" mid-sentence. Replacing a part whose text ends in a period, question or exclamation mark keeps it, unless B has its own. PART is a part of the buffer from the tables above, not words. A and B may themselves contain "with": "replace the sentence with budget with we have no money" tries each way of splitting until one finds something to replace.

### Moving, copying and wrapping

| Say                                                                     | Does                                                                                                                       |
|-------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| move TARGET before / after / under DEST, move TARGET to the start / end of DEST | "move last sentence after budget", "move this section under the heading with plans", "move the item with sharks after the item with Igor" |
| move TARGET to / into DEST                                              | the same as "under": "select the first two items of the section with interns", then "move that to the section with open questions" |
| copy TARGET before / after / under DEST, or to the start / end of DEST  | the same, leaving it where it was; "copy TARGET" alone copies to the kill ring, as before                                  |
| swap A with B                                                           | "swap Monday with Tuesday", "swap this section with the next section"                                                      |
| duplicate TARGET                                                        | a copy right after it: "duplicate this line"                                                                               |
| rewrite TARGET                                                          | deletes it and leaves the cursor there, to dictate in its place: "okay, rewrite last sentence", keep talking, "go back"     |
| put PAIR around TARGET, wrap TARGET in / into PAIR                      | "wrap last three words in quotes", "put brackets around that", "wrap from which until context in parentheses"              |
| remove the PAIR around TARGET, unwrap TARGET                            | "unwrap that" takes off the nearest quotes or brackets around it                                                           |
| replace the PAIR around TARGET with PAIR, change the PAIR around TARGET to PAIR | "replace the parentheses around as noted with dashes"                                                              |

- **What moves goes as what it is.** A section goes with its subheadings, their levels set for where it goes: beside a heading "before" or "after" it, as its last subheading "under" it. Whole lines and list items go as lines, indented like the item they go next to, or as its last sub-item "under" it; a numbered Org list is renumbered. A paragraph goes as a paragraph, and other text is spaced from the words around it, as dictation is.
- **DEST** is one target, not "every" or "and". "under" can also be said "as a subheading of" or "as a sub-item of", or "to" or "into". A selection of whole lines moves as lines, and as list items if it starts at one; a numbered list they leave numbers on from 1.
- **"that"** is then what went in, so a chain can go on with it: "duplicate the item with call mum and then replace mum with dad in that", "move the sentence with however to the end of this paragraph and then replace however with still in that". What went in flashes, for `earwig-flash-duration` seconds (1.5); `(setopt earwig-flash nil)` turns that off.
- **Swapping sections** swaps their levels too. "swap A with B" may have "with" in A or B; the buffer settles which "with" splits them, as for "replace".
- **PAIR** is quotes, single quotes, parentheses (or parenthesis, parens, brackets), square brackets, dashes or commas; "quote", "bracket" and "square bracket" work too. Quotes are typographic (“ ”) where the buffer already has some. Dashes and commas take the place of the spaces around the text, and none goes at the end of a sentence: "wrap as noted earlier in commas" gives "x, as noted earlier, y". The dash is `earwig-dash`, a spaced em dash by default. "unwrap" takes off only quotes and brackets; name dashes and commas to remove them.
- Each is one undo step. "rewrite" keeps a list item's bullet or a heading's stars; "go back" returns to where you were.

### Moving and other editing

| Say                                         | Does                                                                                             |
|---------------------------------------------|--------------------------------------------------------------------------------------------------|
| go before TARGET, go after TARGET           | "go after budget", "go before budget in this paragraph", "go after this section"                 |
| go to the start / beginning / end of TARGET | "go to the end of the line", "go to the start of the paragraph with budget"                      |
| go back                                     | back to where point was before the last "go" (or "next one" after "go"); again, to where it went |
| paste                                       | the buffer's own paste, spaced from the words around it as dictation is; see below              |
| new line, new paragraph                     |                                                                                                  |
| scratch that                                | deletes the last dictation                                                                       |
| undo, redo                                  |                                                                                                  |

- **Cut and paste:** "cut last sentence and then go before mercy and then paste" puts the sentence there with a space on either side, as dictation would; "move last sentence before mercy" does the same in one. Lines cut or copied whole ("cut this line", "copy last two lines") go in as lines: before the line point is on, or after it when point is at the end of its text.
- **In evil,** paste goes after the cursor in normal state, but where "go before" or "go after" put it right after one of those. A visual selection is replaced. Lines cut or copied whole are line-wise for evil's own `p` and `P` too. Terminals get the paste as typed input, unspaced.

### Emacs and Org commands

| Say                                                           | Does                                                  |
|---------------------------------------------------------------|-------------------------------------------------------|
| save [file \| buffer]                                         | saves the buffer                                      |
| close [buffer]                                                | kills the current buffer                              |
| comment that                                                  | comments the region or line                           |
| go to line N                                                  | "forty two" or 42                                     |
| go to [the] top, go to [the] bottom                           |                                                       |
| go to heading [NAME]                                          |                                                       |
| scroll down, scroll up                                        |                                                       |
| other window                                                  |                                                       |
| search [for] [TEXT]                                           |                                                       |
| switch to [buffer] [NAME]                                     | "switch to init dot el"                               |
| run command NAME                                              | runs an Emacs command: "run command org agenda"       |
| what can I say                                                | lists all commands, your own too                      |
| mark [it] done, toggle todo                                   | Org: the TODO state of the entry at point             |
| schedule [it] [for] today \| tomorrow \| next week \| on DAY  | Org: schedules the entry at point                     |
| open agenda                                                   | Org's agenda dispatcher                               |
| open the link with WORDS, open that link, open the link in TARGET | follows an Org link, a Markdown link or a URL     |
| focus on TARGET, narrow to TARGET                             | shows only it: "focus on this section"                |
| show everything, widen                                        | shows the whole buffer again                          |
| where is TARGET, show me TARGET                               | flashes it, scrolling there if it's out of sight; "show me everything" flashes the whole buffer |

"search", "switch to buffer" and "go to heading" use consult when it's installed; without it, isearch, `switch-to-buffer` and `imenu`.

## Dictation

### Cleanup

Dictation drops "um" and "uh" (`earwig-filler-words`), applies your [corrections](#corrections), turns [spoken punctuation](#spoken-punctuation) into symbols, and fits the text to where it goes (capitals, spacing, punctuation). In a heading or list item it starts with a capital, and a heading or checkbox item gets no period unless you say "period" or it's more than one sentence. Words in `earwig-keep-capitalized` keep their capital mid-sentence.

It goes where point is, so click somewhere else and keep talking: the sentence you're saying ends where you moved.

### Spoken punctuation

Inside dictation these phrases become symbols; Orukeet's own punctuation around them goes ("tomorrow, period." becomes "tomorrow.").

| Say                                                             | Gives                        |
|-----------------------------------------------------------------|------------------------------|
| comma, period / full stop, colon, semicolon                     | `,` `.` `:` `;`              |
| question mark, exclamation mark / point                         | `?` `!`                      |
| ellipsis, dot dot dot                                           | `…`                          |
| open paren / close paren (also parenthesis)                     | `(` `)`                      |
| open bracket / close bracket (also square bracket)              | `[` `]`                      |
| open brace / close brace (also curly brace)                     | `{` `}`                      |
| open quote / close quote (also begin quote, end quote, unquote) | `"` `"`                      |
| open single quote / close single quote                          | `'` `'`                      |
| quote, single quote                                             | a quote that opens or closes |
| continue quote, continue single quote                           | `, "` with no capital after  |
| em dash                                                         | `—`                          |
| new line, new paragraph                                         | a line break, a blank line   |
| new sentence                                                    | a capital for the next word  |

- **Spacing:** punctuation and closing brackets attach to the word before; opening brackets to the word after; an em dash to both. The word after a sentence end or a break gets a capital.
- **Quotes:** an opening quote attaches to the word after, which gets a capital where the quote starts a sentence: at the start of one or after a comma or colon, as in `He said, “Go.”`. After a closing quote, the next word gets a capital only if a period ends the quote, so `“Go!” she said` stays lower case. "open double quote" is there too; for single quotes on "open quote", see `earwig-spoken-format`.
- **Dialogue:** "quote" closes the quote open in the paragraph, or opens one: "quote fiddlesticks exclamation mark quote he snapped" gives `“Fiddlesticks!” he snapped`. "new sentence" gives the next word a capital: `“Fiddlesticks!” He snapped`. "continue quote" opens a quote again with no capital after it, and a comma before it in place of a period: "he said continue quote to tell you" gives `he said, “to tell you`. A closing quote has the punctuation inside: what you said, or else Orukeet's on either side of "quote" (a question or exclamation mark, a period, or a comma), so "for her quote" gives `for her.”`. Orukeet's punctuation between the words of a phrase, as in "continue, quote", doesn't matter. As "quote" is a word too, say "literal quote" for it.
- **Curly quotes:** quotes and apostrophes are curly (`“Don’t”`) where `electric-quote-mode` would curl what you type, as `earwig-curly-quotes` says, with the characters of `electric-quote-chars`.
- **Across a pause:** said on its own after a pause, "comma" replaces the period Orukeet ended the previous part with.
- **As a word:** "literal" before a phrase keeps it: "a literal period of time".
- **In terminals** punctuation works, but "new line" stays words, so it can't press Enter.
- **Code symbols:** hyphen, dash, underscore, slash, backslash, dot and tilde are also ordinary words, so they're off. To dictate "foo dot el" as `foo.el`:

  ```elisp
  (setq earwig-spoken-format
        (append earwig-spoken-format earwig-spoken-format-code))
  ```

- `(setq earwig-format-dictation nil)` turns it all off.

### Corrections

Cmd-e fixes a misheard word and remembers "wrong => right" in `earwig-corrections-learned`, saved by Customize and applied to every transcription from then on; with C-u it also fixes the rest of the buffer. Corrections of your own go in `earwig-corrections`, and those only for commands in `earwig-corrections-commands`; all are matched as whole words, ignoring case:

```elisp
(setopt earwig-corrections
        '(("Maggot" . "Magit")
          ("in it yell" . "init.el")))
(setopt earwig-corrections-commands
        '(("kut" . "cut")))       ; "Kut" stays a name in dictation
```

Command corrections apply only when the command as said matches none, so "find note Kut" still finds Kut. Misheard punctuation goes in `earwig-spoken-format` instead, as more phrases: that's for dictation only, and "literal" keeps one as words:

```elisp
(setopt earwig-spoken-format
        (append earwig-spoken-format
                '((punct "," "coma")
                  (punct ":" "colonel" "Colin"))))
```

For a word misheard in a command of your own, an alternative in its pattern is better still, as Earwig's own "mark done" accepts "dunn": `("mark" (| "done" "dunn"))`.

To see which words are misheard again and again, set `(setq earwig-log-transcriptions t)`: each transcription is logged to *Messages*, as Orukeet wrote it and as Earwig made of it.

## The speech server

The speech server is a separate program that does the transcribing; Earwig doesn't include or install one. Earwig sends each recording to `earwig-speech-server-base-url` (`http://127.0.0.1:18178` by default), and needs a server there that:

- answers OpenAI's `POST /v1/audio/transcriptions`, with `file`, `model` (`earwig-speech-server-model`, `"orukeet"`) and `response_format=text`, with the transcription as plain text;
- only listens once it's ready to transcribe, as Earwig takes a listening server for a ready one.

Orukeet's `local_server.py` is such a server; the README's setup installs it. Orukeet's [local server guide](https://github.com/Oruk-AI/orukeet/blob/main/examples/local-server.md) has more on it. The server listens on port 8000 unless told otherwise, a common local port, so the README's configuration starts it with `--port 18178`, the port of `earwig-speech-server-base-url`.

**Started by Earwig.** With `earwig-speech-server-command` and `earwig-speech-server-directory` set, `M-x earwig-speech-server-start` runs the server as a subprocess of Emacs. `M-x earwig-speech-server-stop` stops it again, asking it to shut down and killing it after `earwig-speech-server-stop-timeout` seconds (10), and `M-x earwig-speech-server-toggle` does either; `M-x earwig-speech-server-log` shows its output. Turning on `earwig-mode` starts it, in the background, unless something already answers at `earwig-speech-server-base-url`; Orukeet takes up to about 20 seconds to load. With `earwig-speech-server-autostart` nil it doesn't, and dictating while no server answers offers to start it.

**Started by you.** Or leave `earwig-speech-server-command` unset and start the server yourself, at login with launchd for one; Earwig uses whatever listens at `earwig-speech-server-base-url`. From its directory, that's:

```sh
.venv/bin/python local_server.py --installation installation.json --port 18178
```

## Commands of your own

Voice commands, Earwig's and yours, are rules of a [phony.el](https://github.com/ErikPrantare/phony.el) grammar. Define yours with `phony-defun`: a name, a pattern of words, an optional docstring, and the body that runs.

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

A pattern is words in quotes, `(? …)` for what's optional, `(| …)` for one of several, `(seq …)` for several in a row, `(+ …)` and `(* …)` for repeats, and other rules, by name. `(name RULE)` passes what RULE matched to the body as `name`. Phony's README has the details, and its own rules, as `word` and `phrase`.

- Commands are found in what's said without "and then", as Earwig's are, and your commands win over Earwig's for the same words, so they can take over one of its phrases.
- "what can I say" lists yours after Earwig's, from their patterns, with the first line of the docstring.
- Phony matches words: no regexps. Case doesn't matter, and punctuation is gone before a command is read.
- Before 0.3.0 commands of your own were regexps in `earwig-extra-commands`. That's no longer used: rewrite each as a `phony-defun`, as the examples below do for the earlier examples. Earwig warns once if it's still set.

### Rules and helpers

Rules of Earwig's to use in your patterns:

- `earwig-text` – Any words, as for a search or a name. They can't be checked, so they run to the end of what's said, or to "and then".
- `earwig-words` – Words to find in the buffer. Earwig prefers a reading where they're there.
- `earwig-number` – A number, in digits or words, see `earwig-parse-number` below. Its value is the number; a reading where it isn't one is only chosen to say so.
- `earwig-part` – A part of the buffer, named as the editing commands' targets are: "last two sentences", "this paragraph", "that", "the whole buffer", "the second sentence of the paragraph with budget". `earwig-part-range` makes it `(BEG . END)`.
- `earwig-unit` – A unit, singular or plural, as "paragraphs"; its value is the singular, `"paragraph"`. `earwig-ordinal` is an ordinal, "second" or "21st" or "third to last", as `(N . FROM)`, FROM `start` or `end`.
- `earwig-target` – What an editing verb acts on: a part, or words to find, "A through B", "WORDS in PART", "every WORDS", "A and B", "the end of TARGET", "TARGET through TARGET". `earwig-target-ranges` makes it a list of `(BEG . END)`, and signals a `user-error` if it isn't there; `earwig-target-range` gives the one `(BEG . END)`, and signals one if it's several places too.
- `earwig-destination` – Where to put something: "before TARGET", "after TARGET", "under TARGET", "to the start of TARGET", "to the end of TARGET". Its value is `(KIND TARGET)`, KIND `before`, `after`, `under`, `start` or `end`.
- `earwig-when` – A spoken date ("today", "tomorrow", "next week", "next month", "on Friday"); its value is what was said, which `earwig-spoken-time` makes a time, as "schedule" does. They're in `earwig-org.el`, as `earwig-spoken-time` uses Org's date reading.

Helpers:

- `earwig-with-input` calls a command with text typed into its first prompt.
- `earwig-downcase-first-word` undoes the capital Orukeet gives the first word.
- `earwig-parse-number` returns the number a spoken text says, in digits or words: "42", "forty-two", "one hundred and five", "a thousand", "1,000", "2 million". Numbers said one after another make one of all their digits, so "one one" is 11, "nineteen eighty-four" 1984 and "five twenty" 520, and a decimal after "point" or "decimal" ("two point five", "2.5") gives a float. Anything else signals an error that says what it couldn't read, `Can't parse number "five hundred hundred": "hundred" after "hundred"`. With a second argument, a decimal fails too ("Not a whole number"); with a third, it returns nil instead of failing.
- `earwig-raw-command` is the command as transcribed while it runs, with its punctuation, for passing on what was said.
- `earwig-part-range` returns `(BEG . END)` of an `earwig-part`, or of a part named in words, as in `(earwig-part-range "last two sentences")` or `(earwig-part-range "the section with budget")`; nil for the selection. It returns nil for anything else, such as words to look for, and signals a `user-error` if the part isn't there.
- `earwig-defcommand` is how Earwig defines its own commands: a `phony-defun` that also takes `:help` for "what can I say", `:check`, a form that says whether the command can act on the buffer as it is, to choose between readings, and `:go t` for commands "go back" returns from.

### Examples

"git status" opens Magit; "good status" is how it's often heard:

```elisp
(with-eval-after-load 'earwig
  (phony-defun my/git-status ((| "magit" "magit status" (seq (| "git" "good") "status")))
    "Show Magit's status."
    (call-interactively #'magit-status)))
```

"open agenda" opens the agenda dispatcher. To go straight to a view of your own, here the one under the key "a", say "open my agenda", or take over Earwig's phrase with the same pattern, `("open" (? "the") "agenda")`:

```elisp
(with-eval-after-load 'earwig
  (phony-defun my/agenda ("open my agenda")
    "Open my agenda view."
    (org-agenda nil "a")))
```

"count words in last two paragraphs" shows how many words they have; the part can be named as the editing commands' targets are, as in "count words in this sentence" or "count words in the whole buffer", and plain "count words" counts the selection:

```elisp
(with-eval-after-load 'earwig
  (phony-defun my/count-words ("count words" (? "in" (part earwig-part)))
    "Count the words in PART, or the selection."
    (let ((range (earwig-part-range part)))
      (message "%d words" (count-words (car range) (cdr range))))))
```

"remind me tomorrow to call the bank" adds a TODO to inbox.org, scheduled for tomorrow; "remind me to …" leaves it unscheduled:

```elisp
(with-eval-after-load 'earwig
  (phony-defun my/remind ("remind me" (? (date earwig-when)) "to" (task earwig-text))
    "Add a TODO to the inbox, scheduled DATE."
    (let* ((time (earwig-spoken-time date))
           (org-capture-templates
            `(("v" "Voice reminder" entry
               (file ,(expand-file-name "inbox.org" org-directory))
               ;; TASK goes in as %i, so %-sequences in it aren't expanded
               ,(concat "* TODO %i"
                        (when time (format-time-string "\nSCHEDULED: <%Y-%m-%d %a>" time)))
               :immediate-finish t))))
      (org-capture-string (concat (upcase (substring task 0 1)) (substring task 1)) "v"))))
```

## Customization reference

All options live under `M-x customize-group RET earwig RET`, the speech server, streaming and hold timing in subgroups.

- **`earwig-input-device`** – The microphone to record from (`"default"`: the one chosen in the system's sound settings), named as the audio driver names it.
- **`earwig-recorder`** – `sox`, `ffmpeg`, or `auto` (sox if it's installed), for dictation and commands.
- **`earwig-recording-timeout`** – Seconds after which a recording that isn't streamed, a command or dictation without streaming, stops by itself (300; nil for no limit).
- **`earwig-audio-driver`**, **`earwig-pulse-latency`** – The driver sox records through (`auto`: coreaudio on macOS), and with PulseAudio, how much audio it hands sox at a time.
- **`earwig-toggle-keys`**, **`earwig-correct-keys`** – The keys of `earwig-mode` that toggle recording when tapped, and those that correct.
- **`earwig-push-to-talk`**, **`earwig-push-to-talk-keys`** – Whether there's push-to-talk (off by default), and the keys that record while held (the space bar).
- **`earwig-wake-word-commands`**, **`earwig-wake-words`** – Whether you can give commands while dictating by saying "okay" first (on by default), and the words for that.
- **`earwig-chain-words`** – Words that can go between commands (`"and then"`). Commands are found without them too; with them, words that can't be checked, as "search" takes, end there. See [Several commands in a row](#several-commands-in-a-row).
- **`earwig-cancel-words`** – Words that, said last, cancel a command (`"cancel"`, `"never mind"`).
- **`earwig-command-auto-stop`**, **`earwig-command-auto-stop-incomplete`** – Seconds of silence after a complete voice command started with a tap that stop its recording (1.5; nil: only the key stops it), and after what isn't a command yet (3; nil to wait for the key).
- **`earwig-command-preview`**, **`earwig-provisional-command-display`** – Whether a command said with a command key shows in the echo area as you say it (on), and whether a command given while dictating shows in the buffer (the default) or the echo area.
- **`earwig-flash`**, **`earwig-flash-duration`** – Whether the text a command put in, moved or wrapped flashes, so you see where it went (on), and for how long (1.5 s). "where is TARGET" flashes either way.
- **`earwig-dash`** – The dash "wrap TARGET in dashes" puts on either side, with its spaces (`" — "`).
- **`earwig-corrections`**, **`earwig-corrections-commands`**, **`earwig-corrections-learned`** – "Wrong => right" corrections: for every transcription, for commands only, and those made with Cmd-e.
- **`earwig-filler-words`**, **`earwig-keep-capitalized`** – Words dropped from dictation, and words that keep their capital mid-sentence.
- **`earwig-format-dictation`**, **`earwig-spoken-format`**, **`earwig-literal-word`** – Spoken punctuation in dictation.
- **`earwig-log-transcriptions`** – Log each transcription to *Messages*, as Orukeet wrote it and what Earwig made of it (off by default): to see which words are misheard again and again, for `earwig-corrections`, or where spoken punctuation goes wrong.
- **`earwig-log-commands`** – Log each voice command to *Messages* as it runs, said with a command key or after "okay" (off by default): as its provisional text shows, "▶ select last sentence ▶ cut that", with what isn't a command in grey and a cancelled one struck through.
- **`earwig-curly-quotes`** – Whether dictated quotes and apostrophes are curly: where `electric-quote-mode` is on (the default), everywhere, or nowhere.
- **`earwig-dictation-structure`** – Headings and list items said in dictation.
- **`earwig-format-markup`** – The markup "format STYLE" uses in each major mode.
- **`earwig-streaming`** and **`earwig-stream-*`** – Streaming (on by default; needs sox, and with ffmpeg dictation is transcribed when you stop, as *Messages* notes once): the pause that ends a segment (`earwig-stream-pause`), how loud and how long a sound must be to count as speech (`-speech-ratio`, `-speech-onset`, `-noise-floor`), provisional text and how much of the server's time it may take (`-provisional`, `-provisional-interval`, `-provisional-share`), the longest segment (`-max-segment`), and typing over provisional text (`-flush-on-key`, `-flush-punctuation`).
- **`earwig-hold-*`** – Telling a held key, push-to-talk, from a tap; `earwig-hold-debug` logs the key repeat intervals.
- **Faces and icons** – `earwig-mode-line-recording` (red), `earwig-mode-line-command` (blue) and `earwig-mode-line-transcribing` for REC, CMD and STT in the mode line, and their icons ● and ▶ (`earwig-recording-icon`, `earwig-command-icon`), also before provisional text (`earwig-provisional-icons`), with `earwig-provisional-chain-mark` between chained commands; `earwig-provisional` for provisional text, `earwig-provisional-command` for that of a command said while dictating (unset, it takes the color of CMD), and `earwig-flash` for text that flashes.
- **`earwig-speech-server-base-url`**, **`earwig-speech-server-model`** – The address of the speech server Earwig sends recordings to, and the model name it asks for.
- **`earwig-speech-server-command`**, **`earwig-speech-server-directory`** – How `M-x earwig-speech-server-start` runs the speech server as a subprocess of Emacs, and in which directory; unset, you start the server outside Emacs.
- **`earwig-speech-server-stop-timeout`** – Seconds `M-x earwig-speech-server-stop` waits for the server to shut down before killing it.
- **`earwig-check-app-id`** – The macOS bundle identifier of Emacs, whose press-and-hold setting `earwig-check-setup` reads.

Commands of your own aren't an option: they're `phony-defun` forms, see [Commands of your own](#commands-of-your-own). `earwig-extra-commands`, where they used to be, is no longer used.

## Troubleshooting

Run `M-x earwig-check-setup` first. Beyond what it finds:

| Symptom                                                              | Likely cause, and what to do                                                                                                                                                                                                       |
|----------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Recording shows, but no text ever comes                              | The server isn't running: `M-x earwig-speech-server-start`; `M-x earwig-speech-server-log` shows its output                                                                                                                        |
| The first words are cut off                                          | ffmpeg as the recorder: install sox, or with ffmpeg, wait a second before speaking                                                                                                                                                 |
| Holding the space bar only types spaces                              | `earwig-push-to-talk` is off, or the key doesn't repeat (press and hold, see [Microphone and keyboard timing](#microphone-and-keyboard-timing)), or repeats more slowly than `earwig-hold-*` expect: set `(setq earwig-hold-debug t)` to log the intervals to *Messages* |
| A spoken quote, punctuation or command is ignored or comes out wrong | Orukeet may have misheard it, or put punctuation in it: set `(setq earwig-log-transcriptions t)` to log what it wrote to *Messages*, and add a correction for a mishearing that recurs                                              |
| Dictation stops while the key is still held                          | Repeats arrive further apart than `earwig-hold-release-delay`                                                                                                                                                                      |
| A sentence is split at a pause to think                              | Raise `earwig-stream-pause`                                                                                                                                                                                                        |
| Streaming never ends a segment                                       | Background noise counts as speech: raise `earwig-stream-speech-ratio`, or `earwig-stream-noise-floor` for a microphone with noise suppression                                                                                       |
| Streaming cuts in the middle of quiet speech                         | Lower `earwig-stream-speech-ratio`                                                                                                                                                                                                 |
| The first syllable of a short word is lost                           | Lower `earwig-stream-speech-onset`                                                                                                                                                                                                 |
| The fan runs while you dictate                                       | Each transcription keeps the CPU busy: raise `earwig-stream-provisional-interval`, lower `earwig-stream-provisional-share`, or turn off `earwig-stream-provisional`                                                                 |
| The same word keeps coming out wrong                                 | Fix it once with Cmd-e; it's remembered in `earwig-corrections-learned`                                                                                                                                                            |
| A voice command does nothing                                         | It runs once you stop it: pause, or tap Cmd-f again. With `earwig-command-auto-stop` nil, only the key stops it                                                                                                                    |
| A command runs before you've finished                                | A pause of `earwig-command-auto-stop` after a complete command ends it: say it without pausing, or raise the option. Commands that take any words, like "select WORDS", are complete after the first word                       |
| A command isn't recognized                                           | "what can I say"; all of what you say has to read as commands, so a word too many makes it fail. Set `(setq earwig-log-commands t)` to see how it was read                                                                         |
| Two commands run where you meant one, or the other way round         | Pause between them, or say "and then"; see [Several commands in a row](#several-commands-in-a-row)                                                                                                                                 |
| A target picks the wrong place                                       | Name it more closely: "the next budget", "budget in this paragraph", "the second sentence with budget"; "where is TARGET" shows what it finds                                                                                     |
| `earwig-extra-commands` is no longer used                            | Commands of your own are `phony-defun` forms now: see [Commands of your own](#commands-of-your-own)                                                                                                                                |

## Source files

- `earwig.el`: `earwig-mode`, recording, what happens to a transcription
- `earwig-server.el`: sending recordings to the speech server, and starting and stopping it
- `earwig-platform.el`: what differs from one operating system to another
- `earwig-cleanup.el`: fillers, corrections, spoken punctuation, fitting text in
- `earwig-grammar.el`: voice commands as a phony.el grammar: finding them in what's said and choosing between readings
- `earwig-phony.el`: what Earwig needs from phony.el that its public API doesn't have yet
- `earwig-commands.el`, `earwig-edit.el`: spoken commands; `earwig-edit.el` also has the targets
- `earwig-move.el`: moving, copying and wrapping text, making room for new headings and items, links, focus
- `earwig-structure.el`: headings and lists, as commands and in dictation, and joining sentences
- `earwig-org.el`: Org TODOs, scheduling and the agenda, as commands
- `earwig-stream.el`: streaming dictation and provisional text
- `earwig-hold.el`: tap versus hold, and push-to-talk
- `earwig-check.el`: `M-x earwig-check-setup`
- `earwig-pincer.el`: commands after a wake word, and recording, with Pincer, the helper that listens for it (experimental)
- `docs/roadmap/`: what's planned
- `test/earwig-test.el`: the tests
