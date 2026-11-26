# Always-listening wake word (partly built)

The helper and a first version of Earwig's side exist (see the two "Built so far" sections). The microphone would stay open all the time, and saying a
wake word such as "Zelda" would give a command at any moment, without a key, or add a command
during dictation. A dedicated wake-word detector, openWakeWord, would listen instead of the
speech server, in one helper process that records the microphone and hands the audio over to
Earwig at a byte offset when it hears the wake word.

## Built so far: the helper

The helper is built and tested on its own, in [earwig-listener/](../../earwig-listener/README.md),
a self-contained Python project in this repository until it moves to a repository of its own
(agreed). It starts with openWakeWord's pre-trained `hey_jarvis`
model while a "Zelda" model is trained; a custom model goes in with `--model zelda.onnx`.

These were chosen while building it, and settle open questions 1 and 2 below for now; they can
still change when Earwig's side is built:

- **Earwig runs it as a subprocess and they talk in JSON lines**: events on stdout (`ready`,
  `flowing`, `wake`, `started`, `stopped`, `end`, `error`), commands on stdin (`start`, `stop`,
  `quit`). Closing stdin quits it, so it doesn't outlive Emacs.
- **Positions are bytes of audio since the helper started.** A `wake` event gives the position
  where the wake word was heard; Earwig answers with `start` and a `from` position in the past,
  up to `--buffer` (3 s) back, and the recording file holds the audio from there on. Earwig, not
  the helper, decides whether and from where to record.
- **It writes only while recording**, so the file doesn't grow while nobody dictates; the ring
  buffer covers the time before.
- **Wake words are reported while recording too**, for
  [commands-without-pause.md](commands-without-pause.md).
- `--device` takes the names `earwig-input-device` does; `--input file.wav --realtime` stands in
  for the microphone in tests, as `earwig--stream-input` does for sox.

Measured on the i7-8700B (Python 3.12, openWakeWord 0.6.0, onnxruntime 1.23.2, the last with
Intel Mac wheels):

- **CPU:** 66 s of real-time listening took 5.7 s of CPU, start-up included: under 9% of one
  core. Scoring alone was 2.4–3.7% of one core. About 200 MB of memory.
- **Detection:** "hey Jarvis" said by `say` (Samantha, Daniel) scored 0.96–1.00, first crossing
  0.5 within 0.06 s of the end of the words. No detection in a minute of pink noise.
- **Handover:** "This is a sentence before. Hey Jarvis, delete that line.": a recording started
  1.5 s before the detection came back from Orukeet as "Hey Jarvis, delete that line." So
  1–1.5 s of audio from before the detection holds the whole wake word.

## Built so far: commands after the wake word

`earwig-listen.el` has a first version of Earwig's side, for commands only (see the manual,
"Commands after a wake word"). `earwig-listen-mode` starts the helper with
`earwig-listener-command`; on a `wake` event, unless Earwig is recording or transcribing, it
records a voice command from `earwig-listener-pre-roll` (1.5 s) before the detection, as a WAV
file the helper writes (`"format": "wav"`). From there it is a command as one started with a
command key (`earwig--record` with its WAKE argument): previewed, stopped at the pause after a
complete command (`earwig-listener-command-pause`, 1 s, or `earwig-command-auto-stop`), and run.

- **The recording is still a process.** Earwig's recording code is built around a recorder
  process (live while recording, its sentinel acting on the recording). A pipe process stands
  for the helper's recording: `earwig--stop-recorder` calls its `earwig-stop` property, which
  sends `stop`; on `stopped` it's deleted, and `earwig--recorder-stopped-p` counts that as
  stopped, not failed.
- **What's transcribed up to the wake word is dropped** (`earwig-listen--after-wake-word`,
  `earwig-listener-wake-words`, "hey jarvis" for now), as the recording starts before it.
- **The listener's wake words also work while dictating**, after a pause, as "okay" does
  (`earwig--wake-words`).
- Keys still record with sox; so question 4 below is still open.

Tested end to end (`earwig-test-listen-command`, with `--input` and `say`): "This is a sentence
before. Hey Jarvis, delete last word." in a buffer with "One two three" leaves "One two". The
recording stopped about 2 s after the speech ended (a preview must cover all the speech, then
the pause), and the command ran about 2.4 s later, after a final transcription queued behind
the last preview. Since then, a command whose preview covered all of it and stopped the
recording runs as that preview heard it, without a final transcription
(`earwig--record-final`): the command now runs within 0.1 s of the recording stopping, about
1.7–2 s after the speech ends. What's left is the preview that was in flight as the speech
ended, which the server finishes even when Earwig drops it, then a fresh one of all of it.

Not tested yet: the live microphone, and false detections in everyday speech and media.

## Background: why not the speech server

Orukeet can't listen all the time. The worker (`python -m orukeet.worker`, started by
`local_server.py`) runs the model on the CPU through ggml (`installation.json`: `"device": "cpu"`,
`orukeet-v0.1.0-q8.gguf`). On the i7-8700B (6 cores, 12 threads) it was measured at up to 600%
CPU while a request is in flight. It has no setting for fewer threads: neither the C API
(`nemo_speech_asr_backend_config` has only `gpu`) nor `local_server.py` offers one.

Requests timed against the running server (`/v1/audio/transcriptions`, speech made by `say`):

| Audio | Time |
|-------|------|
| 2 s of pink noise | 0.64 s |
| 1 s of speech | 0.78 s |
| 5 s | 1.32 s |
| 10 s | 1.84 s |
| 15 s | 2.52 s |

So every request costs about 0.6 s of all cores plus about 0.13 s per second of audio, even for
noise. An always-open microphone feeding the server, even only with what sounds like speech,
would keep the fan going with every conversation or TV in the room.

The same measurements explained the fan during dictation: provisional passes re-transcribed the
segment from its start back to back, and clicks and typing counted as speech. That was fixed in
earwig-stream.el, and the design below relies on it (see "Things to get right"):

- `earwig-stream-speech-onset` (0.15 s): a sound must stay loud that long to be speech.
- `earwig-stream-noise-floor` (10): the least noise level assumed, for microphones with noise
  suppression.
- `earwig-stream-provisional-share` (0.5): provisional passes back off while the server is slow,
  and only run if there was speech since the last one.
- A segment that reaches `earwig-stream-max-segment` without speech is dropped, not sent.

## Sharing the microphone isn't the problem; the switch is

On macOS several processes can record the same input at once (CoreAudio shares it; so do
PipeWire and PulseAudio on Linux). openWakeWord listening in one process wouldn't stop Earwig's
sox from starting in another.

But with two processes the words right after the wake word are lost. Saying "Zelda, delete that
line" in one breath:

1. openWakeWord fires about 100–300 ms after "Zelda" ends.
2. Emacs is told and Earwig starts sox: another 100–300 ms.
3. sox records from then on, so "delete" is partly or wholly gone.

The user would have to pause after "Zelda", which is what a wake word should avoid. This
two-process arrangement was rejected for that reason.

## Design

Agreed in outline: **one process records, and Earwig is handed the audio from a byte offset.**

```
mic ──► helper (e.g. Python: sounddevice + openWakeWord)
          ├─ records 16 kHz, 16-bit mono, all the time
          ├─ keeps the last few seconds (a ring buffer, ~3 s suggested)
          ├─ runs openWakeWord on each 80 ms frame        (a few % of one core)
          └─ on "Zelda" ──► tells Earwig: wake word at byte N
                         └─ writes the audio from just before N on to Earwig's raw file
```

- **No gap.** The ring buffer still holds the audio from before the detection, so nothing said
  after the wake word is lost.
- **Fits Earwig as it is.** Streaming dictation already reads raw 16 kHz, signed 16-bit mono PCM
  from a file (`earwig--stream-raw`, written by sox per `earwig--stream-command`) and works in
  byte offsets: `earwig--stream-read`, `earwig--stream-segment-start`, the segment queue,
  `earwig--stream-moves`. The helper would take sox's place as the writer of that file.
  openWakeWord takes the same format, so there's nothing to convert.
- **Between commands the speech server does nothing.** The only standing cost is openWakeWord.

### Suggested, not agreed

- **Let "Zelda" go through the existing wake-word path.** If the audio handed over starts just
  before the wake word, Orukeet transcribes "Zelda delete that line", and adding "zelda" to
  `earwig-wake-words` (now `'("okay" "ok")`, earwig-commands.el) lets `earwig--strip-wake-word`
  and the command handling do the rest. The alternative is to start the audio after the wake
  word and run what follows as a command directly.
- **During dictation, cut at the wake word.** The helper keeps listening on the same audio. On
  "Zelda" it tells Earwig the offset, and Earwig cuts the segment being spoken there (as
  `earwig--stream-cut` does at a pause) instead of waiting for `earwig-stream-pause` of
  silence. The command goes through at once, and more reliably than finding "okay" in the
  transcription.
- **The helper also records ordinary dictation**, so there's one recorder whether dictation
  starts by a key or by the wake word.

### What sox does for Earwig, and what the helper would take over

While the helper runs, Earwig doesn't need sox to record: the helper reads the microphone itself
(through PortAudio, with sounddevice) and writes the same raw PCM. sox has three jobs now, and
each could move to the helper:

| Where | What sox does | With the helper |
|-------|---------------|-----------------|
| Streaming dictation (`earwig--stream-command`, earwig-stream.el) | Writes raw 16 kHz, 16-bit mono PCM to `earwig--stream-raw` | The helper writes the file |
| Commands, and dictation without streaming (`earwig--record-command`, earwig.el) | Writes a WAV file in one piece; ffmpeg can do this instead (`earwig-recorder`) | The helper writes raw PCM and Earwig adds the header, as `earwig--wav-header` already does for segments |
| The setup check (earwig-check.el) | Is checked for, and test-recorded from the microphone with `earwig--sox-input-args` | Checks the helper instead |

Besides recording, sox does these things for Earwig, all of which the helper would have to do:

- **Picking the microphone.** `earwig-input-device` names it, as in the system's sound settings
  ("default" for the system's choice). `earwig--sox-input-args` turns it into sox arguments,
  through the driver `earwig-audio-driver` (coreaudio on macOS; pulseaudio or alsa on Linux,
  where `earwig--sox-drivers` checks which ones this sox has). The helper needs the same names
  to mean the same microphones.
- **PulseAudio latency.** `earwig-pulse-latency` sets `PULSE_LATENCY_MSEC` for sox alone
  (`earwig--sox-program`, run through env), or PulseAudio hands audio over in large chunks, so
  streamed text comes in bursts and REC shows late.
- **Saying when audio flows.** Earwig shows REC once sox's `-S` progress ("Out:…") says audio is
  coming in (`earwig--recorder-filter`, `earwig--audio-flowing`), not when the process starts.
  The helper needs to say so too, or REC shows before anything is recorded.
- **Small, prompt writes.** sox runs with `--buffer 1920` (60 ms), so each 0.2 s
  `earwig--stream-measure` finds the new audio already in the file.
- **Stopping.** `earwig--stop-recorder` sends SIGINT, and sox finishes its last write (and, for
  a WAV file, its header) before exiting. The recorder sentinels tell a stop from a failure with
  `earwig--recorder-stopped-p`. With the helper, stopping a dictation must end the audio Earwig
  reads, but not the listening.
- **Reporting failures.** When sox fails, its output is what *Messages* shows ("Recording
  failed …"), e.g. a missing driver or microphone access refused
  (`earwig--microphone-access-hint`).
- **Recording from a file, for tests.** `earwig--stream-input` gives sox a WAV file instead of the
  microphone; `earwig-test-stream` uses it to stream speech made by `say` through the server.
  The helper needs a file mode for that, or the tests keep using sox.
- **Starting quickly.** The README says only sox starts quickly enough not to lose the first
  words. An always-running helper doesn't start at all, and its ring buffer holds the audio from
  just before a key press too, so key-started dictation would gain a pre-roll it doesn't have now.

The cost is that every user who wants the helper needs Python and the helper installed, not just
sox from a package manager. The helper shouldn't live in Orukeet's virtualenv: Earwig talks to
whatever server answers at `earwig-speech-server-base-url`, and Orukeet's install isn't
Earwig's.

## Options considered

| Option | Standing cost | Verdict |
|--------|---------------|---------|
| openWakeWord (Apache 2.0, ONNX, 80 ms frames) | a few % of one core | preferred; "Zelda" needs a custom model |
| Porcupine (Picovoice) | small | an alternative; proprietary, free tier, custom words made in their console |
| Speech server on everything that sounds like speech (energy or Silero VAD gate) | ≥0.6 s of all cores per utterance | rejected: background talk keeps it busy |
| Orukeet's native streaming (`NvidiaRecognizer.stream()` in `orukeet/nvidia.py`; `local_server.py` doesn't expose it) | a 0.6B model running all the time on the CPU | rejected for always-on. Worth a look separately for cheaper provisional text, as it transcribes each chunk once instead of re-sending the segment |
| Two processes sharing the microphone, sox started on detection | small | rejected: loses the words after the wake word (above) |

The runtime also ships Silero VAD support (`--vad-model`, `nemo_speech_asr_vad_config`), but no
VAD model is installed in `~/.local/share/orukeet/orukeet-cache/models`.

## Things to get right when building it

- **The noise fixes matter.** After "Zelda …", Earwig's pause detection decides when the
  command ends; clicks and typing mustn't keep it open (`earwig-stream-speech-onset`,
  `earwig-stream-noise-floor`, `earwig--stream-frame`).
- **Offsets.** The raw file Earwig reads must start where the handed-over audio starts, or
  Earwig must be told the offset of its first byte, so its byte offsets stay consistent.
  The file must not grow without bound while nobody is dictating.
- **Everything sox does besides recording** (above): microphone names, PulseAudio latency, REC
  when audio flows, prompt writes, stopping, failures, file input for tests.
- **Bluetooth headsets** switch to their low-quality call profile while any app has the
  microphone open, so an always-open microphone degrades music for as long as it's open. A
  wired or built-in microphone avoids it.
- **The orange microphone indicator** on macOS stays on. Audio stays local.
- **False triggers.** A custom "Zelda" model needs its threshold tuned against everyday speech
  and media.

## Decide first

1. How the helper tells Emacs about a detection, and which byte offset it means: a line on
   stdout or stderr, a socket, or something else.
2. Whether the helper writes all audio to the raw file and Earwig keeps track of where
   dictation starts, or writes only from a detection or a key press on (with the ring buffer as
   pre-roll).
3. Whether the audio handed over includes the wake word (existing `earwig-wake-words` path) or
   starts after it.
4. Whether the helper replaces sox for all recording, or only while it runs. Suggested: keep sox
   as the recorder when the wake word is off, and have the helper take over all three of sox's
   jobs only while it runs. Those who don't want an always-open microphone keep the simple
   setup (sox only, no Python), at the cost of two recorders to maintain, which must agree on
   microphone names and the audio format.
5. Training the "Zelda" model: openWakeWord's synthetic-speech training takes a few hours on a
   GPU (or Colab). Whether to do that, pick a word with a ready-made model, or use Porcupine.

## Decide when building

- The ring buffer's length and the pre-roll before the detection.
- What the wake word does outside dictation: run one command, or start dictation too.
- Language and packaging of the helper (Python with sounddevice was suggested), and how Earwig
  starts it, like `earwig-speech-server-command`.
- Linux: whether the same helper works through PipeWire/PulseAudio (see
  [linux-testing.md](linux-testing.md)).
