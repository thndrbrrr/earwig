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
| Define all voice commands, Earwig's and the user's, as a phony.el grammar in Earwig's own English words, with commands taken from cursorfree.el (move, swap, change, wrap…), heading and section targets, and command boundaries found without "and then" | phases 1 and 2 built: all commands on Phony, boundaries without "and then", ranking over readings; the new targets and the commands taken from cursorfree. Phase 3 (hatty) not built | [phony-grammar.md](phony-grammar.md) |

