# Earwig manual

The [README](../README.md) covers installing Earwig, setting it up and everyday use. This manual is the full reference: every command and its details, how dictation is cleaned up, the speech server, all options, and writing commands of your own.

## Contents

- [Recording](#recording)
  - [Keys](#keys)
  - [Push-to-talk](#push-to-talk)
  - [Streaming and provisional text](#streaming-and-provisional-text)
  - [Microphone and keyboard timing](#microphone-and-keyboard-timing)
  - [Checking the setup](#checking-the-setup)
- [Voice commands](#voice-commands)
  - [How a command is recognized](#how-a-command-is-recognized)
  - [Commands while dictating](#commands-while-dictating)
  - [Editing: a verb and a target](#editing-a-verb-and-a-target)
  - [Formatting](#formatting)
  - [Headings and lists (Org and Markdown)](#headings-and-lists-org-and-markdown)
  - [Joining sentences](#joining-sentences)
  - [Replacing](#replacing)
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
| Cmd-f, keypad Enter         | start a voice command; tap again to stop                           |                          |
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

- **Streaming** (`earwig-streaming`, on by default): text appears while you talk, provisional (grey, or blue for a command after "okay") until a pause, then final. It needs sox; when ffmpeg records, dictation is transcribed when you stop instead, and *Messages* says so once.
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

;; Streaming: pauses depend on the microphone, the rest on the CPU
(setq earwig-stream-pause                1.5
      earwig-stream-speech-ratio         3.0
      earwig-stream-provisional-interval 1.0
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

- Tap Cmd-f (or keypad Enter), or use another key with the mode `command`, and say the command. Tap it again when you're done, or have a pause end it: with `(setopt earwig-command-auto-stop 1.5)`, recording stops after 1.5 s of silence once what you've said is a complete command (or ends with "cancel"). Earwig transcribes it as you speak to tell. After "go to line" without its number, or a chain ending in "and then", it waits longer, `earwig-command-auto-stop-incomplete` (3 s), before giving up. Commands that take any words, like "select WORDS", are complete after the first word, so don't pause inside those. The whole phrase has to match one; case and punctuation don't matter, and your corrections apply first, and `earwig-corrections-commands` only here. "what can I say" lists them all.
- While dictating, say "okay" and the command: see [Commands while dictating](#commands-while-dictating).
- Each change a command makes is one undo step.
- Commands joined by "and then" run one after another: "format bold results and then select the last sentence and then cut that, and then go to bottom, and then paste". Each is its own undo step, and the chain stops at one that fails. A phrase is only split where every part is a command, so "replace and then with so" is still one. A command that prompts, like "search", waits for you to answer before the next one runs. The words are in `earwig-chain-words`.
- While you say a command with a command key, the echo area shows what Earwig has heard so far, about every second: "▶ select last sentence ▶ cut that", the commands it chains in blue, and what isn't (yet) a command in grey. It runs when you stop, as before. An "okay" said out of habit is dropped, here and when it runs. `earwig-command-preview` turns this off.
- Changed your mind, or misheard? End with "cancel" or "never mind" ("select last sentence and then cut that, never mind") and nothing runs; the preview strikes the commands through. This works after "okay" while dictating too, and nothing is dictated then either. The words are in `earwig-cancel-words`. With a tapped command key, C-g while recording cancels too.

### Commands while dictating

You never have to leave dictation to give a command, or a chain of them. While you dictate, pause, say "okay" and the command, pause again, and carry on:

> …and that's the plan. *(pause)* Okay, select last sentence and then format bold. *(pause)* Next, the budget…

- This works at every pause (`earwig-stream-pause`, 1.5 s by default), with any dictation key, tapped or held. It needs streaming; without it, only a recording that starts with "okay" is a command.
- As soon as Earwig hears "okay", the provisional text turns the color of CMD in the mode line (blue) instead of grey, so you can tell a command is coming, and the mode line shows ▶ CMD until the command has run and dictation carries on with ● REC. `earwig-provisional-command` gives the text a face of its own.
- Provisional text starts with the icon from the mode line, where it will go: the red ● of REC for dictation, the blue ▶ of CMD for a command. For a command, ▶ takes the place of "okay", and of each "and then" after a command: "okay, select last sentence and then cut that" shows as "▶ select last sentence ▶ cut that". `earwig-recording-icon`, `earwig-command-icon` and `earwig-provisional-chain-mark` change them, in the mode line too; `earwig-provisional-icons` turns the icons off in provisional text.
- To keep the buffer for dictation only, show commands in the echo area instead, as with a command key: `(setopt earwig-provisional-command-display 'echo-area)`.
- If no command matches, what you said is inserted as dictation, "okay" and all.
- What only writes forward, where you're dictating, needs no "okay": spoken punctuation, "new line", "new paragraph", and in Org and Markdown "new heading" and "new item" (see [Headings and lists](#headings-and-lists-org-and-markdown)). Everything that changes what's already there, moves, or runs something does.
- Dictation follows point. After "okay, go to top", or after you click somewhere else, what you say next goes there, even mid-sentence. What you'd already said before you moved still goes where you said it, where its provisional text showed. Leaving evil's insert state, which moves point back a character, doesn't count as moving.
- Each stretch of dictation between commands, or before you move, is one undo step, and it's what "scratch that" takes back.
- The wake words are in `earwig-wake-words` ("okay" and "ok"). To have a dictation key only ever dictate, turn it off: `(setopt earwig-wake-word-commands nil)`.

### Editing: a verb and a target

Every verb works on every target: "select last two words", "delete that", "capitalize deadline", "cut because through Friday".

| Verb       | Also said as                 | Does                                       |
|------------|------------------------------|--------------------------------------------|
| select     |                              | selects it (evil: a visual selection)      |
| delete     |                              | deletes it, tidying the spaces left behind |
| cut        |                              | the same, into the kill ring               |
| copy       | yank                         | copies it to the kill ring                 |
| capitalize | cap                          | first letter of each word upper case       |
| uppercase  | upper case, upcase, all caps |                                            |
| lowercase  | lower case, downcase         |                                            |
| title case |                              | title case, small words stay lower case    |

| Target                                                | Example                                                                  | Means                                                                                  |
|-------------------------------------------------------|--------------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| nothing, region, selection                            | "uppercase", "cut the selection"                                         | the region or evil's visual selection; "select" alone needs one                        |
| that, this, it                                        | "delete that"                                                            | the region, or else the last dictation in this buffer                                  |
| [this, the, current] UNIT                             | "select this sentence", "title case line"                                | the unit around point                                                                  |
| last, previous, next [N] UNITs                        | "delete last three words", "copy next line"                              | before or after point; N as a word or digits                                           |
| the [whole] buffer or file, everything, all           | "copy everything"                                                        | the whole buffer                                                                       |
| A through B, A until B, from A to / until / through B | "cut because through Friday", "copy from however until shown"            | from the nearest A that has a B after it to the end of the first such B                |
| any other words                                       | "capitalize emacs lisp"                                                  | the nearest place those words appear                                                   |
| WORDS in TARGET                                       | "delete very in this paragraph", "select meow in the last two sentences" | the nearest WORDS (or A through B) inside TARGET, one of the parts of the buffer above |

- **UNIT** is word, sentence, paragraph or line. A deleted or cut line takes its newline with it. "last word" leaves the punctuation after the word alone. In evil's normal state the character under the cursor counts as before point.
- **Words are found** ignoring case and the punctuation between them, so "end of file" also finds "end-of-file". Markup doesn't get in the way: "heading" is found in `_Some underlined heading_`, and "last word" there is `heading` without the underscore. An underscore between letters joins them, so `foo_bar` is one word. The nearest is looked for in the window first, then in the whole buffer: one around point wins, then the closest before point, then the closest after.
- **"in"** only scopes when what follows names a part of the buffer; otherwise it's one of the words: "select log in screen".
- **"next one", "previous one"** (or "next match") move a word target on to the next or previous place it appears, after "select WORDS" or "go before/after WORDS".

### Formatting

"format STYLE TARGET" marks the target up, with any target from the table above: "format bold meow in the last two sentences", "format italic last word", "format underline from however until shown", "format code that". Saying it again takes the style off again.

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
| new item, new bullet [TEXT] | the next item of the list you're in, after its sub-items; outside a list, starts a `- ` list on the next line (also "new list", "start a list") |
| new sub item [TEXT]         | an item one level deeper                                                                                                                        |
| new checkbox [TEXT]         | an item with `[ ] `                                                                                                                             |

As commands, "next heading" and "next item" work too. Numbered lists go on numbering, and an item gets a checkbox when the one before has one. TEXT goes in with a capital: "new heading next steps". In Org these use Org's own commands, so blank lines and numbering follow Org's settings; in Markdown they work on `#` headings outside code blocks and on `-`, `+`, `*` and numbered lists.

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
| replace A with B in TARGET  | every A in TARGET: "in this paragraph", "in the last three lines", "in that" |
| replace A with B everywhere | every A in the buffer                                                        |
| replace that with B         | the region itself, if there is one                                           |

B takes A's capital ("Monday" → "Tuesday" at a sentence start), but the capital of "I", an acronym or a name only at a sentence start: "replace I with we" gives "we" mid-sentence. TARGET is a part of the buffer from the table above, not words. A and B may themselves contain "with".

### Moving and other editing

| Say                                                                    | Does                                                                                             |
|------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| go before WORDS, go after WORDS [in TARGET]                            | moves to the nearest place those words appear                                                    |
| go to [the] start of / beginning of / end of line, sentence, paragraph |                                                                                                  |
| go back                                                                | back to where point was before the last "go" (or "next one" after "go"); again, to where it went |
| paste                                                                  | the buffer's own paste, spaced from the words around it as dictation is; see below              |
| new line, new paragraph                                                |                                                                                                  |
| scratch that                                                           | deletes the last dictation                                                                       |
| undo, redo                                                             |                                                                                                  |

- **Moving text:** "cut last sentence and then go before mercy and then paste" puts the sentence there with a space on either side, as dictation would. Lines cut or copied whole ("cut this line", "copy last two lines") go in as lines: before the line point is on, or after it when point is at the end of its text. "go after sharks and then cut this line and then go before Igor and then paste" swaps two list items.
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

For a word misheard in a command of your own, an alternative in its pattern is better still, as Earwig's own "mark done" accepts "dunn": `"mark \\(?:done\\|dunn\\)"`.

To see which words are misheard again and again, set `(setq earwig-log-transcriptions t)`: each transcription is logged to *Messages*, as Orukeet wrote it and as Earwig made of it.

## The speech server

The speech server is a separate program that does the transcribing; Earwig doesn't include or install one. Earwig sends each recording to `earwig-speech-server-base-url` (`http://127.0.0.1:18178` by default), and needs a server there that:

- answers OpenAI's `POST /v1/audio/transcriptions`, with `file`, `model` (`earwig-speech-server-model`, `"orukeet"`) and `response_format=text`, with the transcription as plain text;
- only listens once it's ready to transcribe, as Earwig takes a listening server for a ready one.

Orukeet's `local_server.py` is such a server; the README's setup installs it. Orukeet's [local server guide](https://github.com/Oruk-AI/orukeet/blob/main/examples/local-server.md) has more on it. The server listens on port 8000 unless told otherwise, a common local port, so the README's configuration starts it with `--port 18178`, the port of `earwig-speech-server-base-url`.

**Started by Earwig.** With `earwig-speech-server-command` and `earwig-speech-server-directory` set, `M-x earwig-speech-server-start` runs the server as a subprocess of Emacs. `M-x earwig-speech-server-stop` stops it again, asking it to shut down and killing it after `earwig-speech-server-stop-timeout` seconds (10), and `M-x earwig-speech-server-toggle` does either; `M-x earwig-speech-server-log` shows its output. Dictating while no server answers offers to start it.

**Started by you.** Or leave `earwig-speech-server-command` unset and start the server yourself, at login with launchd for one; Earwig uses whatever listens at `earwig-speech-server-base-url`. From its directory, that's:

```sh
.venv/bin/python local_server.py --installation installation.json --port 18178
```

## Commands of your own

`earwig-extra-commands` holds commands of your own, as `(PATTERN FUNCTION HELP)`. They're tried before Earwig's, so they can also take over one of its phrases. PATTERN is a regexp matched against the whole command, ignoring case and punctuation; FUNCTION gets the groups of PATTERN as arguments, or is called interactively if PATTERN has none. HELP is what "what can I say" shows.

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

### Helpers

- `earwig-with-input` calls a command with text typed into its first prompt.
- `earwig-downcase-first-word` undoes the capital Orukeet gives the first word.
- `earwig-parse-number` returns the number a spoken group says, in digits or words: "42", "forty-two", "one hundred and five", "a thousand", "1,000", "2 million". Numbers said one after another make one of all their digits, so "one one" is 11, "nineteen eighty-four" 1984 and "five twenty" 520, and a decimal after "point" or "decimal" ("two point five", "2.5") gives a float. Anything else signals an error that says what it couldn't read, `Can't parse number "five hundred hundred": "hundred" after "hundred"`, and the command fails with it. With a second argument, a decimal fails too ("Not a whole number"); with a third, it returns nil instead of failing. Match the group with `\\(.+\\)` rather than digits, as Orukeet may write the number either way.
- `earwig-raw-command` is the command as transcribed while it runs, with its punctuation, for passing on what was said.
- `earwig-part-range` returns `(BEG . END)` of a part of the buffer, named as the editing commands' targets are: "last two sentences", "this paragraph", "that", "the whole buffer", or nil for the selection. It returns nil for anything else, such as words to look for, and signals a `user-error` if the part isn't there.
- `earwig-when-regexp` matches a spoken date ("today", "tomorrow", "next week", "next month", "on Friday"), and `earwig-spoken-time` makes it a time, as "schedule" does. They're in `earwig-org.el`, as `earwig-spoken-time` uses Org's date reading.

### Examples

"git status" opens Magit; "good status" is how it's often heard:

```elisp
(with-eval-after-load 'earwig
  (add-to-list 'earwig-extra-commands
               '("\\(?:git\\|good\\) status\\|magit\\(?: status\\)?" magit-status
                 "git status")))
```

"open agenda" opens the agenda dispatcher. To go straight to a view of your own, here the one under the key "a":

```elisp
(with-eval-after-load 'earwig
  (add-to-list 'earwig-extra-commands
               '("open \\(?:the \\)?agenda"
                 (lambda () (interactive) (org-agenda nil "a"))
                 "open agenda")))
```

"count words in last two paragraphs" shows how many words they have; the part can be named as the editing commands' targets are, as in "count words in this sentence" or "count words in the whole buffer", and plain "count words" counts the selection:

```elisp
(with-eval-after-load 'earwig
  (add-to-list 'earwig-extra-commands
               '("count words\\(?: in \\(.+\\)\\)?" my/count-words
                 "count words [in TARGET]")))

(defun my/count-words (target)
  (let ((range (or (earwig-part-range target)
                   (user-error "Not a part of the buffer: %s" target))))
    (message "%d words" (count-words (car range) (cdr range)))))
```

"remind me tomorrow to call the bank" adds a TODO to inbox.org, scheduled for tomorrow; "remind me to …" leaves it unscheduled:

```elisp
(with-eval-after-load 'earwig
  (add-to-list 'earwig-extra-commands
               `(,(concat "remind me\\(?: \\(" earwig-when-regexp "\\)\\)? to \\(.+\\)")
                 my/remind
                 "remind me [today | tomorrow | next week | on DAY] to TASK")))

(defun my/remind (when task)
  (let* ((time (earwig-spoken-time when))
         (org-capture-templates
          `(("v" "Voice reminder" entry
             (file ,(expand-file-name "inbox.org" org-directory))
             ;; TASK goes in as %i, so %-sequences in it aren't expanded
             ,(concat "* TODO %i"
                      (when time (format-time-string "\nSCHEDULED: <%Y-%m-%d %a>" time)))
             :immediate-finish t))))
    (org-capture-string (concat (upcase (substring task 0 1)) (substring task 1)) "v")))
```

## Customization reference

All options live under `M-x customize-group RET earwig RET`, the speech server, streaming and hold timing in subgroups.

- **`earwig-input-device`** – The microphone to record from (`"default"`: the one chosen in the system's sound settings), named as the audio driver names it.
- **`earwig-recorder`** – `sox`, `ffmpeg`, or `auto` (sox if it's installed), for dictation and commands.
- **`earwig-recording-timeout`** – Seconds after which a recording that isn't streamed, a command or dictation without streaming, stops by itself (300; nil for no limit).
- **`earwig-audio-driver`** – The driver sox records through (`auto`: coreaudio on macOS).
- **`earwig-toggle-keys`**, **`earwig-correct-keys`** – The keys of `earwig-mode` that toggle recording when tapped, and those that correct.
- **`earwig-push-to-talk`**, **`earwig-push-to-talk-keys`** – Whether there's push-to-talk (off by default), and the keys that record while held (the space bar).
- **`earwig-wake-word-commands`**, **`earwig-wake-words`** – Whether you can give commands while dictating by saying "okay" first (on by default), and the words for that.
- **`earwig-chain-words`** – The words between commands that run them one after another (`"and then"`).
- **`earwig-cancel-words`** – Words that, said last, cancel a command (`"cancel"`, `"never mind"`).
- **`earwig-command-auto-stop`**, **`earwig-command-auto-stop-incomplete`** – Seconds of silence after a complete voice command started with a tap that stop its recording (nil, off: only the key stops it), and after what isn't a command yet (3; nil to wait for the key).
- **`earwig-command-preview`**, **`earwig-provisional-command-display`** – Whether a command said with a command key shows in the echo area as you say it (on), and whether a command given while dictating shows in the buffer (the default) or the echo area.
- **`earwig-corrections`**, **`earwig-corrections-commands`**, **`earwig-corrections-learned`** – "Wrong => right" corrections: for every transcription, for commands only, and those made with Cmd-e.
- **`earwig-filler-words`**, **`earwig-keep-capitalized`** – Words dropped from dictation, and words that keep their capital mid-sentence.
- **`earwig-format-dictation`**, **`earwig-spoken-format`**, **`earwig-literal-word`** – Spoken punctuation in dictation.
- **`earwig-log-transcriptions`** – Log each transcription to *Messages*, as Orukeet wrote it and what Earwig made of it (off by default): to see which words are misheard again and again, for `earwig-corrections`, or where spoken punctuation goes wrong.
- **`earwig-log-commands`** – Log each voice command to *Messages* as it runs, said with a command key or after "okay" (off by default): as its provisional text shows, "▶ select last sentence ▶ cut that", with what isn't a command in grey and a cancelled one struck through.
- **`earwig-curly-quotes`** – Whether dictated quotes and apostrophes are curly: where `electric-quote-mode` is on (the default), everywhere, or nowhere.
- **`earwig-dictation-structure`** – Headings and list items said in dictation.
- **`earwig-format-markup`** – The markup "format STYLE" uses in each major mode.
- **`earwig-extra-commands`** – Commands of your own, see [Commands of your own](#commands-of-your-own).
- **`earwig-streaming`** and **`earwig-stream-*`** – Streaming (on by default; needs sox, and with ffmpeg dictation is transcribed when you stop, as *Messages* notes once), the pause that ends a segment, how loud speech is against the noise, provisional text.
- **`earwig-hold-*`** – Telling a held key, push-to-talk, from a tap.
- **Faces** – `earwig-mode-line-recording` (red), `earwig-mode-line-command` (blue) and `earwig-mode-line-transcribing` for REC, CMD and STT in the mode line, and their icons ● and ▶ (`earwig-recording-icon`, `earwig-command-icon`), also before provisional text; `earwig-provisional` for provisional text, and `earwig-provisional-command` for that of a command said while dictating (unset, it takes the color of CMD).
- **`earwig-speech-server-base-url`**, **`earwig-speech-server-model`** – The address of the speech server Earwig sends recordings to, and the model name it asks for.
- **`earwig-speech-server-command`**, **`earwig-speech-server-directory`** – How `M-x earwig-speech-server-start` runs the speech server as a subprocess of Emacs, and in which directory; unset, you start the server outside Emacs.
- **`earwig-speech-server-stop-timeout`** – Seconds `M-x earwig-speech-server-stop` waits for the server to shut down before killing it.
- **`earwig-check-app-id`** – The macOS bundle identifier of Emacs, whose press-and-hold setting `earwig-check-setup` reads.

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
| Streaming never ends a segment                                       | Background noise counts as speech: raise `earwig-stream-speech-ratio`                                                                                                                                                              |
| Streaming cuts in the middle of quiet speech                         | Lower `earwig-stream-speech-ratio`                                                                                                                                                                                                 |
| The same word keeps coming out wrong                                 | Fix it once with Cmd-e; it's remembered in `earwig-corrections-learned`                                                                                                                                                            |
| A voice command does nothing                                         | It runs only once you stop it: tap Cmd-f again, or set `earwig-command-auto-stop` to have a pause stop it                                                                                                                          |
| A command isn't recognized                                           | "what can I say"; commands are matched on the whole phrase                                                                                                                                                                         |

## Source files

- `earwig.el`: `earwig-mode`, recording, what happens to a transcription
- `earwig-server.el`: sending recordings to the speech server, and starting and stopping it
- `earwig-platform.el`: what differs from one operating system to another
- `earwig-cleanup.el`: fillers, corrections, spoken punctuation, fitting text in
- `earwig-commands.el`, `earwig-edit.el`: spoken commands
- `earwig-structure.el`: headings and lists, as commands and in dictation, and joining sentences
- `earwig-org.el`: Org TODOs, scheduling and the agenda, as commands
- `earwig-stream.el`: streaming dictation and provisional text
- `earwig-hold.el`: tap versus hold, and push-to-talk
- `earwig-check.el`: `M-x earwig-check-setup`
- `docs/roadmap/`: what's planned
- `test/earwig-test.el`: the tests
