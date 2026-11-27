# Roadmap

Work that is planned but not built. Using this directory: each item is a row in a table below,
grouped by section. A bigger item has its own design document here, which says what was found,
what was agreed, what was only suggested and what is still open, so the work can be picked up from
the document alone. A small item is just a row. When an item is built, its row and document go,
and the user's guide (`README.md` at the top of the repository) and the commentary of the files
describe it instead.

## Platforms

| Item | Status | Document |
|------|--------|----------|
| Run Earwig on Linux for the first time: setup check, recording and streaming through PulseAudio and ALSA, key repeat under Wayland and X11, the function keys, the server | built, not tested on Linux; the README documents macOS only until then | [linux-testing.md](linux-testing.md) |
| Windows support: fill in and test the Windows branches of earwig-platform.el (waveaudio recording, stopping without SIGINT, microphones, key repeat) | designed, deferred until there's a Windows machine to test on | [windows.md](windows.md) |

Windows comes after Linux: its test plan would follow linux-testing.md.

## Voice commands

| Item | Status | Document |
|------|--------|----------|
| Define all voice commands, Earwig's and the user's, as a phony.el grammar in Earwig's own English words, with commands taken from cursorfree.el (move, swap, change, wrap…), heading and section targets, and command boundaries found without "and then" | phases 1 and 2 built: all commands on Phony, boundaries without "and then", ranking over readings; the new targets and the commands taken from cursorfree. What Phony 4.0.0 lacks is worked around in earwig-phony.el, standing for a public API proposed upstream. Phase 3 (hatty) not built | [phony-grammar.md](phony-grammar.md) |
| An always-open microphone with a wake word ("Zelda"): one helper process records and runs openWakeWord, and on the wake word hands the audio over to Earwig at a byte offset, for a command at any time or during dictation | helper built: [Pincer](https://github.com/thndrbrrr/earwig-pincer), with a pre-trained model; Earwig's side built for commands outside dictation (`earwig-pincer.el`); not tried with the live microphone | [wake-word.md](wake-word.md) |
| Give commands during dictation without pausing first: cut the segment being spoken where the wake-word helper heard the wake word, and end the command's segment sooner once it's a complete command | designed, not built; the wake-word helper it needs is built. Agreed: Pincer's wake word starts the command, and the audio stays in files | [commands-without-pause.md](commands-without-pause.md) |

Commands without a pause follow the wake-word helper: they cut the audio at the offset it reports, so only with the `pincer` recorder.

