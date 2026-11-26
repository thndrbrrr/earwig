# earwig-listener

Records the microphone all the time, listens for a wake word with
[openWakeWord](https://github.com/dscripka/openWakeWord), and hands the audio over to
[Earwig](../README.md) from any point in the last few seconds. Earwig runs it as a subprocess
and talks to it in JSON lines.

Experimental: it lives in Earwig's repository until it's tested, then moves to its own. The
design, and what's still open, is in [docs/roadmap/wake-word.md](../docs/roadmap/wake-word.md).
Earwig uses it in `earwig-listen-mode` (earwig-listen.el), for commands after the wake word.

## Why one process

Started when the wake word is heard, a recorder would miss the words right after it: the
detection comes at the end of the wake word, and a recorder takes a moment to start. This one
keeps recording, keeps the last few seconds, and starts a recording *in the past*, from just
before the wake word, so nothing is lost and no pause is needed after it.

## Installing

With [uv](https://docs.astral.sh/uv/), in this directory:

```sh
uv sync
uv run earwig-listener --download-models          # hey_jarvis, and the feature models
uv run earwig-listener --download-models alexa    # others: hey_mycroft, hey_rhasspy, …
```

On Intel Macs, onnxruntime is held below 1.24, the last version built for them.

## Trying it

```sh
uv run earwig-listener --list-devices
uv run earwig-listener                            # say "hey Jarvis"
```

Each line it prints is an event; type a command as a line to give it one, e.g.

```json
{"command": "start", "path": "/tmp/test.raw", "from": 96000}
{"command": "stop"}
```

and play the recording with `play -t raw -r 16000 -b 16 -e signed -c 1 /tmp/test.raw`.

A model of your own goes in with `--model path/to/zelda.onnx`.

## Options

| Option | Default | |
|--------|---------|-|
| `--model NAME_OR_PATH` | `hey_jarvis` | A pre-trained model's name or an `.onnx` file; repeatable |
| `--threshold SCORE` | 0.5 | Score from 0 to 1 that counts as the wake word |
| `--refractory SECONDS` | 1.0 | After a wake word, none is reported for this long |
| `--buffer SECONDS` | 3.0 | Audio kept: how far back a recording can start |
| `--device NAME` | `default` | Input device, as in the system's sound settings, as `earwig-input-device`; a unique part of the name will do |
| `--input WAV` | | Read a 16 kHz, 16-bit mono WAV file instead of the microphone, for testing |
| `--realtime` | | With `--input`, read it at the pace it would be recorded |
| `--list-devices` | | List the input devices and exit |
| `--download-models [NAME…]` | | Download models and exit |

## Protocol

Audio is 16 kHz, signed 16-bit, mono, little-endian, as Earwig records it. A **position** is a
count of bytes of audio since the listener started. A recording started at position FROM holds
the audio from FROM on: position P is at byte P − FROM of its file.

Events, on stdout, one JSON object a line:

| Event | Fields | When |
|-------|--------|------|
| `ready` | `device`, `models`, `rate`, `buffer` (bytes kept) | The model is loaded and the input opened |
| `flowing` | `position` | The first audio has come in (Earwig shows REC from here) |
| `wake` | `model`, `score`, `position` | A wake word was heard, ending about at `position` |
| `started` | `path`, `from`, `position` | Recording to `path` from position `from`, written up to `position` already |
| `stopped` | `path`, `from`, `bytes` | Recording stopped; `bytes` written in all |
| `end` | `position` | The `--input` file is all read; the listener exits |
| `error` | `message` | A command failed; at startup, the listener then exits with status 1 |

Commands, on stdin, one JSON object a line:

| Command | Fields | |
|---------|--------|-|
| `start` | `path`, optionally `from` and `format` | Record to `path` (overwritten) from position `from`, or from now. `from` may be as far back as the audio kept; further back is taken as the oldest kept. `format` is `raw` (the default) or `wav`: a WAV file's header has the largest length until recording stops, as sox's. A recording going on is stopped first |
| `stop` | | Stop recording; listening goes on |
| `quit` | | Exit; so does closing stdin, SIGINT or SIGTERM |

Recording writes each 80 ms block as it comes in, before the wake word is listened for. Wake
words are reported while recording too, so one said during dictation can cut it there.

Everything else the program or its libraries print goes to stderr.

## Development

```sh
uv run pytest
```

`tests/test_cli.py` runs the program on speech made by macOS's `say` and needs `say`, `sox` and
the `hey_jarvis` model; it's skipped without them.
