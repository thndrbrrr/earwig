# Changelog

## Unreleased

### Changes to check

- **The pause settings are renamed**, after what you do rather than how Earwig works, with no aliases. If you set any, set the new one instead:
  - `earwig-stream-pause` is now `earwig-dictation-pause`.
  - `earwig-command-auto-stop` is now `earwig-command-pause`. Set to nil, it stopped commands only with their key: that's `(setopt earwig-command-key-stops-at-pause nil)` now.
  - `earwig-command-auto-stop-incomplete` is now `earwig-unfinished-command-pause`.
- **One log:** `earwig-log-transcriptions` and `earwig-log-commands` are gone; set `earwig-log` instead, and `M-x earwig-show-log` shows it. Transcriptions and commands are logged to *earwig-log* now, not *Messages*.

### New

- **Commands while dictating run once complete.** After "okay", a complete command runs after `earwig-command-pause` of silence, as its provisional text has it, without being transcribed again. `earwig-wake-word-commands-end-at-pause` turns it off.
- **No pause before a command while dictating, with Pincer (experimental).** With `earwig-listen-mode` and `pincer` as `earwig-recorder`, the wake word cuts the dictation where you said it and starts a command, even in the same breath. The wake words are `earwig-wake-words` then, and must be the words of Pincer's model. See [Commands after a wake word](docs/manual.md#commands-after-a-wake-word-experimental), with `earwig-wake-word-keeps-provisional-text` and `earwig-repeated-wake-word`.

- **A log of what Earwig hears and does** (`earwig-log`, `M-x earwig-show-log`): each transcription with how long it took for how much audio, where dictation was cut and why, each step of the cleanup that changed a transcription (filler words, corrections, spoken punctuation, fitting it to where it goes), the wake word and how a command was told from the dictation, Pincer's events, and the commands run, each with the time. See [The log](docs/manual.md#the-log).

### Fixed

- **"undo" said twice** undid and then redid, as each voice command starts a new undo sequence. It now goes further back each time; "redo" redoes.

## 0.3.0

Voice commands are now rules of a [phony.el](https://github.com/ErikPrantare/phony.el) grammar instead of regexps. That makes commands combine more freely, but changes how you write commands of your own.

### Changes to check

- **Commands of your own** are defined with `phony-defun` now. `earwig-extra-commands` is no longer used: Earwig warns once if it's still set. Rewrite each command as in [Commands of your own](docs/manual.md#commands-of-your-own); the helpers (`earwig-with-input`, `earwig-parse-number`, `earwig-part-range` and the others) are still there.
- **phony.el 4.0.0** is required. It comes from MELPA, and is installed with Earwig when MELPA is in `package-archives`.
- **"next heading", "next item" and "next bullet"** are gone as commands of their own. "the next heading" is a target now; to start a new one, say "new heading" or "new item".
- **Voice commands stop at a pause.** `earwig-command-auto-stop` is 1.5 now instead of nil: a command started with a tap runs after 1.5 s of silence, once it's complete, without tapping the key again. Set it to nil for the old behaviour.
- **"first N UNIT"**, such as "first two words", counts from the start of its container (the sentence, the paragraph, …) instead of meaning "next".

### New

- **Targets that compose:** units with a quantity and a filter, chained with "in" or "of" to any depth: "the first word of the second sentence in the paragraph with moonbase", "every item without done", "the third through fifth words". Headings, sections, items, checkboxes and links are units too. See [Editing: a verb and a target](docs/manual.md#editing-a-verb-and-a-target).
- **Several commands in a row** without "and then": "select last sentence format bold".
- **Rearranging:** move, copy, swap, duplicate, rewrite, wrap and unwrap, and changing the quotes or brackets around text. See [Moving, copying and wrapping](docs/manual.md#moving-copying-and-wrapping).
- **More commands with a target:** "go before / after / to the end of TARGET", "replace TARGET with B", "new heading after TARGET", "new item under TARGET", "go into TARGET", "focus on TARGET", "where is TARGET", "open the link with WORDS".
- **"that"** also means the text a command put in last, which flashes so you see where it went (`earwig-flash`, `earwig-flash-duration`).

### Fixed and improved

- Streaming dictation keeps the speech server, and your fan, quieter: clicks and typing no longer count as speech, and provisional text is asked for less often while the server is slow (`earwig-stream-speech-onset`, `earwig-stream-noise-floor`, `earwig-stream-provisional-share`).
- "last / next N sentences" stay within the current section, and no longer run into an Org planning line or across headings.
- Cutting or deleting no longer leaves stray punctuation ("loud,.") or empty emphasis, brackets or quotes behind.
- Numbered lists are renumbered after moving items, and sub-items keep their indentation.
- Transcriptions with no letters or digits are dropped.
