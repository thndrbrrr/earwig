# Commands during dictation without a pause (design, not built)

Nothing in this document exists yet. While dictating, a command can only be given after a pause:
the wake word must start a segment, and segments only end at `earwig-stream-pause` (1.5 s) of
silence. This item removes that pause, and shortens the one after the command, by having Pincer's
wake word start the command: Earwig cuts the dictation where Pincer heard it. It follows the
wake-word helper in [wake-word.md](wake-word.md), which is now built
([Pincer](https://github.com/thndrbrrr/earwig-pincer), and `earwig-pincer.el` for commands outside
dictation), and is kept apart from it on purpose (agreed).

## Background: why the pause is needed

- A command given while dictating (`earwig-wake-word-commands`) is recognised only when a
  segment's text starts with a wake word (`earwig--wake-words`: `earwig-wake-words`, `'("okay"
  "ok")`, plus `earwig-pincer-wake-words` with `earwig-listen-mode`).
  `earwig--strip-wake-word` (earwig-commands.el) matches at the start of the text only. So while
  dictating, the wake word is found by Orukeet, in the transcription, not by Pincer.
- Streaming dictation cuts segments at pauses after speech (`earwig--stream-measure`,
  earwig-stream.el), or at `earwig-stream-max-segment`, or where point moves.
- So "…end of the sentence okay delete last word", said in one breath, is one segment, and goes
  in as dictation, "okay" and all.
- Pincer reports `wake` events while it records too (`Listener._listen` in Pincer's
  `listener.py`), but `earwig-pincer--wake` ignores them while Earwig records or transcribes.

The final transcription of the segment before doesn't have to have arrived: the wake word can be
said as soon as the pause has cut the segment, and Earwig keeps the order (segments are inserted
in order; what's said while a command runs goes where it leaves point,
`earwig--stream-after-command`). It's the pause itself that's in the way.

The command's own segment also needs 1.5 s of silence to end, and is then transcribed once more
as a final segment, so a command runs about 1.5 s + up to 0.2 s (the next measurement) + about
0.8 s (the transcription) ≈ 2.5 s after it's said (estimated, not measured).

## Design

**Agreed: Pincer's wake word starts the command.** During dictation, Earwig acts on Pincer's
`wake` event by cutting the segment being spoken just before the wake word, instead of waiting
for a pause and finding the wake word in the transcription.

Also agreed, from "Decide first":

- The command is a segment of the dictation (below), not a recording of its own.
- The dictation before the cut may go in as its provisional text, under the rule below, from
  the first version on, behind a setting.
- Commands whose wake word is found in the transcription (`earwig-wake-words`, "okay" by
  default, any word) end sooner too, with the shorter pause only (step 0), behind a setting.
- **All the pauses, and when each applies, are configurable**, with setting names and
  descriptions a user easily understands (see "Pause settings").
- **No wake word gets special treatment.** "okay" is only the default of `earwig-wake-words`;
  what differs is how the wake word is found: in the transcription, where it may be plain
  dictation, or by Pincer in the audio, where it's known to start a command.
- **The wake word is declared once,** in `earwig-wake-words` (one or several), see "One
  wake-word setting".

The steps and details are suggested, worked out in discussion.

### Only with the `pincer` recorder

With `earwig-recorder` set to `pincer`, the raw file streaming dictation reads is Pincer's
recording, so Pincer's positions map onto it: position P is at byte `P - from` of
`earwig--stream-raw`, where `from` comes in Pincer's `started` event. Earwig doesn't keep `from`
yet (`earwig-pincer--event` only sets `earwig-pincer--started` on `started`); a one-line change.

When sox records, Pincer's positions mean nothing for Earwig's file; `earwig-listen-mode` keeps
today's behaviour then (a command after a pause).

### The command is a segment of the dictation, not a recording of its own

The command isn't a new recording or a separate transcription session; it's a stretch of the same
raw file, marked as a command, sent through the same request queue:

```
audio.raw  ──────────────────────────────────────────────────►
           [ dictation segment ][ hey jarvis delete that ][ more dictation …
                                ^cut                     ^command ends
                                (from the wake position)  (pause after a complete command)
```

Why not a recording of its own, as `earwig--record` makes for a command after the wake word
outside dictation:

- **Pincer records one file at a time.** `Listener` has one `file`; `Listener.start` stops a
  recording going on first. Earwig's side has one `earwig-pincer--recording`, and on `stopped`
  `earwig-pincer--stopped` deletes it. A `start` for the command would end the dictation:
  `earwig--stream-recorder-sentinel` sends the rest and `earwig--stream-finish` ends the undo
  step, drops the markers and removes the hooks.
- **The audio is there already.** What's said after the wake word goes on into the dictation's
  file; a second copy adds nothing. Earwig already sends byte ranges of it as WAV files
  (`earwig--stream-write-wav`).
- **Order.** The dictation said before the wake word must be in before the command runs, as the
  command may refer to it ("delete last word"). One queue (`earwig--stream-curl`, the next
  segment sent once the last one has gone in) keeps that without coordination.
- **Server load.** Orukeet takes one request at a time, using all cores (up to 600% CPU measured,
  [wake-word.md](wake-word.md)). `earwig--record`'s previews go straight to the server
  (`earwig--preview-tick` → `earwig-server-transcribe`), outside the stream's queue; next to a
  dictation they would compete with its requests and slow both.

Going back to dictation needs nothing new: recording never stopped, so what's said after the
command is the next segment, and `earwig--stream-after-command` / `earwig--stream-break` already
handle point and undo.

### Steps

0. **First, without Pincer: end a command found by its wake word in the transcription sooner.**
   Whatever the word (`earwig-wake-words`). Once a segment's provisional
   text starts with a wake word (as `earwig--provisional-face` tells now), it ends at the pause
   after a complete command and runs as its last provisional pass heard it, without a final
   transcription. Only the shorter pause: while it isn't a complete command, it keeps
   `earwig-stream-pause`, not the longer wait for an incomplete command, as a wake word found in
   the text may begin plain dictation ("Okay, so the plan is…" with the default). Agreed. It works with any recorder and can be
   tested with `earwig--stream-input` and `say`; steps 1–5 reuse its command state.
1. **On a `wake` event at position P while streaming with the `pincer` recorder:** measure the new
   audio (`earwig--stream-measure`), then look for the quietest frame (`earwig--stream-quietest`
   over `earwig--stream-levels`) in roughly P − 1.5 s to P − 0.7 s: "hey jarvis" takes about
   0.6–0.8 s (estimated), and is heard as it ends (measured: within 0.06 s with `say`; 0.1–0.3 s
   expected in general). If the stream's own pause detection has cut later than that already,
   cut at the current segment's start. Cut there as `earwig--stream-cut-at-move` does
   (`earwig--stream-cut`, `earwig--stream-restart-segment`), and mark the segment from the cut on
   as a command.
2. **The part before the cut** is an ordinary dictation segment, in the queue in order, so it goes
   in before the command runs.
3. **The command segment** shows with `earwig-provisional-command` and `earwig-command-icon`. It
   ends at the pause after a complete command, or after a longer one when it isn't one yet, as
   a command after the wake word outside dictation does (now `earwig-command-auto-stop`, 1.5 s,
   or `earwig-pincer-command-pause`, 1 s, only when that is nil; and
   `earwig-command-auto-stop-incomplete`, 3 s), rather than at `earwig-stream-pause`. The logic is in `earwig--auto-stop-tick` and
   `earwig--command-heard-complete-p`, for `earwig--record`. It runs as its last provisional pass
   heard it, without a final transcription, as `earwig--record-final` does.
4. **What the command segment heard before the wake word goes in as dictation**, rather than being
   dropped as `earwig-pincer-after-wake-word` does now. The cut can then lean early, so no part of
   the wake word is left in the dictation. Splitting the text at the wake word is safe here,
   unlike the text split rejected below: Pincer has already confirmed the wake word from the
   audio.
5. **A command segment that isn't a command** (no match in `earwig-find-commands`) gives a message
   rather than going in as dictation with "hey jarvis" in it, as `earwig--process-text-1` would
   do now.

Estimated size: 150–250 lines in earwig-stream.el and earwig-pincer.el, plus a test like
`earwig-test-listen-command` (Pincer's `--input` with `--realtime`, speech made by `say`). Pincer
needs no change.

### The dictation before the cut: final transcription, or the provisional text as it is

Agreed: accept the provisional text of the segment being dictated as its final text when the
wake word comes, as `earwig--stream-flush` does for a key, sparing the server its final
transcription; under the rule below, from the first version on, with a setting to turn it off.

The catch is that provisional text lags: passes start at least
`earwig-stream-provisional-interval` (1 s) apart and take 0.8–1.8 s, so the last one usually
reaches 1–3 s before the wake word is heard (`earwig--stream-provisional-end`,
`earwig--stream-provisional-raw`). What's said in between would be lost. So:

- Accept the provisional text only if there was no speech between where it ends and the cut
  (`earwig--stream-speech-end`); otherwise send the segment up to the cut for its final
  transcription. Then nothing is lost: the final transcription would be of the same speech plus
  silence. (Not checked: whether Orukeet gives the same text for the same audio every time.)
- It applies only after a short pause before the wake word, long enough for a provisional pass
  to cover what came before; the wake word said in the same breath as the dictation nearly
  always leaves speech after the last pass.
- It mostly saves load, not time: the final transcription runs while the command is being said
  (about 0.8–1.5 s against 1.5 s or more of speech), so it's rarely waited on. It does let the
  command's first provisional pass start sooner.

### Expected gains (estimated)

- **Before the command:** no pause at all.
- **After the command:** the pause after a complete command (1.5 s by default now, the same as
  `earwig-stream-pause`) + up to 0.2 s + whatever provisional pass is in flight, against about
  2.5 s now: the saving is the final transcription, and whatever the pause is shortened to. A
  command after the wake word outside dictation was measured at 1.7–2 s after the speech ends.
- **Server load:** one or two fewer requests per command: no final transcription of the command,
  and none of the dictation before it when its provisional text is accepted. Fewer provisional
  passes, as the command ends sooner.

## Options considered

| Option | Verdict |
|--------|---------|
| Cut the audio where Pincer heard the wake word (above) | **preferred (agreed)** |
| The command as a recording of its own (`earwig--record` with Pincer, as outside dictation) | rejected (agreed): Pincer records one file at a time, so it would end the dictation; its requests would bypass the stream's queue (order, server load) |
| Pincer writing several files at once, so the command can have its own | rejected (agreed): a small change in Pincer, but two transcription pipelines in Earwig to keep in order and off each other's toes |
| Stop the dictation, record the command, start dictating again | rejected (agreed): no audio lost (Pincer's ring buffer), but stopping ends the undo step and "scratch that" range, the noise levels and where the dictation goes, and REC flickers |
| Split the final text: when a segment contains the wake word in the middle and everything after it is a complete command (`earwig-commands-complete-p`), insert the part before as dictation and run the rest | **not now** (agreed). With "okay" as the wake word it would introduce new problems: "okay" is common in dictation ("that's okay, go to the store"), and requiring a complete command after it limits false splits but doesn't rule them out. It also only handles a command at the end of a segment, not one followed by more dictation, which would need the grammar to find where the command ends. (Step 4 splits text too, but only where Pincer heard the wake word) |
| Word timestamps from the server: Orukeet's engine has a start and end time for each word (`_result` in `orukeet/nvidia.py`), but `local_server.py` returns only the text. Returning them (as OpenAI's `verbose_json` with word timestamps does) would let Earwig cut the audio at "okay" without the helper | not discussed beyond noting it; needs a change to a server that isn't Earwig's, and has the same "okay is common" problem as splitting the text |

### Audio in files, or not

Asked: does the audio need to be in files at all? Orukeet takes the audio as an HTTP upload, not
a file. **Agreed: files stay for now.**

| Hop | Now | Without a file |
|-----|-----|----------------|
| Pincer → Earwig | Pincer appends to `audio.raw`; `earwig--stream-measure` reads what's new every 0.2 s | a pipe or socket, Earwig keeping the audio in a buffer |
| Earwig → server | `earwig--stream-write-wav`, then `curl -F file=@…` (`earwig-server-transcribe`) | `curl -F 'file=@-;filename=a.wav'`, the WAV on curl's stdin |
| Inside Orukeet | the upload written to a temp file, converted to another (`normalize_audio` in `local_server.py`), the model given its path | not Earwig's; the native API takes a path |

Why the files stay:

- The cost is in the model (about 0.6 s of all cores a request, plus 0.13 s per second of audio),
  not in writing and reading a few hundred KB through the page cache.
- The only gain would be finding a pause or cut up to 0.2 s sooner, without polling.
- The file keeps Pincer independent of Emacs. Emacs reads a pipe only when it's free; while it
  runs a command or collects garbage the pipe fills (64 KB on macOS, about 2 s of this audio),
  Pincer's writes block, and its listening stalls with them. A pipe would need a writer thread
  and a queue in Pincer.
- Cuts and provisional passes read back into the past; a file gives that for free.
- Tests feed audio through files (`--input`, `earwig--stream-input`).

What would really cut the load is streaming to the server: Orukeet's `NvidiaRecognizer.stream()`
transcribes each chunk once, where provisional passes now re-send the segment from its start.
`local_server.py` doesn't expose it (it would need an endpoint, e.g. a WebSocket). Noted in
[wake-word.md](wake-word.md) ("Options considered") as worth a look separately; not part of this
item.

## Things to get right when building it

- **Saying the wake word straight after dictation, with no gap.** The quietest frame may fall
  inside a word. Step 4 covers dictation caught in the command segment; a cut too late leaves
  "hey" in the dictation.
- **Detection latency.** The cut has to be looked for before the reported position, far enough
  back to keep the whole wake word in the command's segment.
- **Audio not measured yet.** The wake event can come before `earwig--stream-measure` has read
  that far (it runs every 0.2 s); measure first, and the cut must not be past
  `earwig--stream-read`.
- **A wake word near the start of the dictation.** The cut window can reach before `from`, the
  start of the file (`earwig-pincer-key-pre-roll`, 0.25 s, of pre-roll); clamp it.
- **Wake words close together.** Pincer ignores a second within `--refractory` (1 s). After
  that, Pincer's wake word inside a command segment cuts again (agreed, see "A wake word said
  again").
- **The wake word missing from the transcription** (e.g. "hey Travis"). Fall back to taking the
  whole command segment as the command, as now.
- **The stream's other limits** must not end the command segment early: `earwig-stream-pause`
  (1.5 s) is shorter than `earwig-command-auto-stop-incomplete` (3 s); `earwig-stream-max-segment`.
- **Provisional text.** After the cut, the part before keeps its provisional text until its final
  text comes; the command's segment shows with `earwig-provisional-command` and
  `earwig-command-icon` (`earwig-provisional-command-display`).
- **Undo.** A command given while dictating ends the dictation so far (`earwig--stream-break`, in
  `earwig--run-command-in`): one undo step and what "scratch that" takes back. That must still
  hold when the cut comes from Pincer.
- **Not tested yet:** the live microphone's latency and false detections in everyday speech and
  media (open in [wake-word.md](wake-word.md) too).

## One wake-word setting

Agreed: the wake words are declared once, in `earwig-wake-words`, which may hold several.
`earwig-pincer-wake-words` goes (never released, so no changelog entry). It's the user's
responsibility to give Pincer a model trained on the same words (`--model` in
`earwig-pincer-command`); Earwig doesn't check.

Now there are two: `earwig-wake-words` (`'("okay" "ok")`), found in the transcription, and
`earwig-pincer-wake-words` (`'("hey jarvis")`), how Pincer's word comes out transcribed. With
`earwig-listen-mode` both give a command while dictating, as `earwig--wake-words`
(earwig-commands.el) joins them. What changes (suggested, from reading the code):

- `earwig--wake-words` is just `earwig-wake-words`.
- `earwig-pincer-after-wake-word` drops what's transcribed up to the first of
  `earwig-wake-words`, keeping its tolerance for punctuation between the words of one.
- The "Listening for …" messages in earwig-pincer.el name `earwig-wake-words`, and say whether
  listen mode is on or off (agreed; wording suggested):

  | When | Now | Suggested |
  |------|-----|-----------|
  | On, Pincer ready | "Listening for hey jarvis" | `Earwig listen mode on: listening for "hey jarvis" or "zelda"` |
  | On, Pincer starting | nothing until the `ready` event, then the above | `Earwig listen mode on: starting Pincer…`, then the above |
  | Off | Emacs's "Earwig-Listen mode disabled" | `Earwig listen mode off` |
  | Off, Pincer is the recorder | "Pincer keeps the microphone open, as `earwig-recorder'" | `Earwig listen mode off; Pincer still records (earwig-recorder)` |
  | Off as Pincer exited (`earwig-pincer--sentinel`) | "Pincer stopped: …" | `Earwig listen mode off: Pincer stopped: …` |
- The commentary of earwig-pincer.el, the docstring of `earwig-listen-mode`, the manual
  ("Commands after a wake word") and the tests that bind `earwig-pincer-wake-words`
  (test/earwig-test.el) follow.
- The default `'("okay" "ok")` suits only dictation without Pincer; with the pre-trained
  `hey_jarvis` model, the user sets `'("hey jarvis")`. The manual says so.

This doesn't need the rest of the item and can be done first.

## A wake word said again

Agreed: when Pincer hears its wake word again inside a command segment, Earwig cuts there and
starts a new command segment, and a setting says what happens to the one before:

- **Next command:** it runs if it's a complete command, and is dropped with a message if it
  isn't. Saying the wake word again chains another command, or, after a slip, starts over.
- **Start over:** it's always dropped.

The setting (agreed): `earwig-repeated-wake-word`, with `next-command` (the default) and
`start-over`. The same holds when Pincer hears its wake word during a command found by its wake
word in the transcription: Pincer's cut wins. Without a cut, the grammar would get "delete that
hey jarvis new paragraph" and fail, as `earwig-pincer-after-wake-word` drops only what's up to the
first wake word.

## Pause settings

Agreed: every pause, and when each applies, is a setting whose name and description a user
easily understands. The settings there are now, which already confuse (by default
`earwig-pincer-command-pause` is never used, as `earwig-command-auto-stop` is set):

| Setting | Default | Ends |
|---------|---------|------|
| `earwig-stream-pause` | 1.5 s | a segment of streaming dictation |
| `earwig-command-auto-stop` | 1.5 s | a command recorded with a command key or after Pincer's wake word, once it's complete; nil: only its key stops it |
| `earwig-command-auto-stop-incomplete` | 3 s | the same, while it isn't (yet) a complete command |
| `earwig-pincer-command-pause` | 1 s | a command after Pincer's wake word, only when `earwig-command-auto-stop` is nil |

New with this item: a command during dictation after Pincer's wake word (complete, and not yet
complete), and one found by its wake word in the transcription (complete only); and the setting
for accepting the dictation's provisional text at the cut.

Agreed (decide-first 4): one setting per kind of pause, named after what the user does rather
than Earwig's workings, one command pause for however the command was started, and switches for
the conditions. Names and defaults as agreed; descriptions to be written when building, for the user:

| Setting | Default | What it is | Replaces |
|---------|---------|------------|----------|
| `earwig-dictation-pause` | 1.5 s | Silence that ends a stretch of dictation, which is then transcribed and inserted | `earwig-stream-pause` |
| `earwig-command-pause` | 1.5 s | Silence after a complete voice command before it runs, however it was started: a command key, Pincer's wake word, or a wake word while dictating | `earwig-command-auto-stop`, `earwig-pincer-command-pause` |
| `earwig-unfinished-command-pause` | 3 s | Silence that ends a command that isn't complete yet ("go to line" before its number). Not for a command found by its wake word in the transcription, which may be plain dictation | `earwig-command-auto-stop-incomplete` |
| `earwig-command-key-stops-at-pause` | t | Whether a command started with a key stops at the pause after it; nil: only with the key | `earwig-command-auto-stop` set to nil |
| `earwig-wake-word-commands-end-at-pause` | t | Whether a command given while dictating, found by its wake word in the transcription (`earwig-wake-words`), ends at `earwig-command-pause` once complete; nil: it ends like dictation | new |
| `earwig-wake-word-keeps-provisional-text` | t | When Pincer's wake word cuts the dictation, the dictation goes in as its provisional text shows it, if that covers all that was said | new |

Agreed: **a clean break** for the old names. `earwig-stream-pause`,
`earwig-command-auto-stop` and `earwig-command-auto-stop-incomplete` (released in 0.3.0) are
removed, without obsolete aliases or warnings; the changelog says what to set instead, under
"Changes to check". `earwig-pincer-command-pause` was never released and just goes. Considered
and not chosen: aliases where the meaning is the same, and for `earwig-command-auto-stop`
(whose nil now belongs to `earwig-command-key-stops-at-pause`) a one-time warning while still
honouring it, as for `earwig-extra-commands`.

## Decide first

1. ~~Whether the command is a segment of the dictation.~~ Yes (agreed).
2. ~~Whether the dictation before the cut may go in as its provisional text.~~ Yes, under the
   rule, from the first version on, behind a setting (agreed).
3. ~~Whether a command found by its wake word in the transcription ends sooner too.~~ Yes,
   the shorter pause only, behind a setting (agreed).
4. ~~The pause settings.~~ As in "Pause settings" (agreed).

## Decide when building

- **The cut window's numbers.** Agreed method: the quietest frame in a fixed window before the
  wake position P, leaning early (step 4 makes too early harmless; too late leaves part of the
  wake word in the dictation). P − 1.5 s to P − 0.7 s suggested, fitting "hey jarvis" (about
  0.6–0.8 s, estimated); "Zelda" is shorter (about 0.4 s, estimated). The numbers come from
  measuring with the live microphone and the "Zelda" model, with a debug option in Pincer
  (agreed) that logs every block's score.

  Only if cuts land too late, two refinements (raised and discussed, kept for then):
  - **The score's timing (the user's idea).** Its size says how sure the model is, not where the
    wake word started; but the start of the run of blocks above a low level (e.g. 0.1) that
    ended in the detection marks roughly where the word ended, better than the threshold
    crossing. Pincer would report that position in the `wake` event; Earwig looks for the quiet
    before it, less the wake word's length. A run begun on a similar-sounding word points too
    early, which is harmless.
  - **Earwig's own levels** (`earwig--stream-levels`): the last quiet stretch before the wake
    word. Fails when it follows the dictation without a gap, so only on top of the above.
- The settings' descriptions; suggested below, not agreed. The wake word is named once in
  them: Pincer comes up only where whether it listens changes what happens.

```elisp
(defcustom earwig-dictation-pause 1.5
  "Seconds of silence that end a stretch of dictation.
What you said up to the pause is transcribed and goes in while you
keep talking.  Shorter puts text in sooner, but more of your pauses
in the middle of a sentence end up as a full stop."
  :type 'number)

(defcustom earwig-command-pause 1.5
  "Seconds of silence after a complete voice command before it runs.
However you started it: with a command key or with the wake word.
Shorter runs commands sooner, but commands said one after another
must then follow each other without a pause this long.  While what
you said isn't a complete command yet, `earwig-unfinished-command-pause'
applies instead."
  :type 'number)

(defcustom earwig-unfinished-command-pause 3.0
  "Seconds of silence that end a voice command that isn't complete yet.
As \"go to line\" before its number: somewhat longer than
`earwig-command-pause', so there's time to finish it.  While
dictating without Pincer listening (`earwig-listen-mode'), Earwig
only knows you gave a command from what's transcribed, and the wake
word may just be part of a sentence; so there it doesn't wait this
long, and the command ends like dictation until it's complete.  nil
to wait for the command key, or without one, until
`earwig-recording-timeout'."
  :type '(choice (const :tag "Wait" nil) number))

(defcustom earwig-command-key-stops-at-pause t
  "Non-nil for a command started with a command key to stop by itself.
At the pause after it, see `earwig-command-pause'.  nil to stop it
only with the key.  Pushed to talk, it always stops when the key is
let go."
  :type 'boolean)

(defcustom earwig-wake-word-commands-end-at-pause t
  "Non-nil for a command given while dictating to run as soon as it's complete.
After `earwig-command-pause', as heard while you said it.  nil to
have it end like dictation, after `earwig-dictation-pause', and be
transcribed once more before it runs: a little slower, but heard
more carefully.  Only without Pincer listening (`earwig-listen-mode');
with it, a command given while dictating always runs as soon as it's
complete."
  :type 'boolean)

(defcustom earwig-wake-word-keeps-provisional-text t
  "Non-nil to keep the dictation as shown when the wake word interrupts it.
With Pincer listening (`earwig-listen-mode'), saying the wake word
while dictating ends the dictation there.  What you said before it
goes in as its provisional text shows it, as long as that covers all
of it, instead of being transcribed again.  That spares the speech
server some work.  nil to always have it transcribed again."
  :type 'boolean)

(defcustom earwig-repeated-wake-word 'next-command
  "What saying the wake word again during a voice command does.
With Pincer listening (`earwig-listen-mode').
`next-command': the command said so far runs if it's complete, and
what you say after the wake word is the next command.  If it isn't
complete, it's dropped, so you start over.
`start-over': the command said so far is always dropped."
  :type '(choice (const :tag "Run it if complete, then the next command" next-command)
                 (const :tag "Drop it and start over" start-over)))
```

  Agreed with them: `earwig-wake-word-commands-end-at-pause` applies only without Pincer
  listening, and says so. Covering Pincer too was considered: off, it would only make commands
  after Pincer's wake word slower and drop the wait for an unfinished one ("go to line" cut
  after 1.5 s), protecting against nothing, as Pincer's false detections come from the
  detector. Without Pincer it doesn't prevent false commands either (a segment starting with a
  wake word runs as a command either way, if it is one): it trades speed (the final
  transcription, about 0.8 s, with both pauses at 1.5 s) for a command heard more carefully.
