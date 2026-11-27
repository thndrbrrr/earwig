# Changelog

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
