# Commands during dictation without a pause (design, not built)

Nothing in this document exists yet. While dictating, a command can only be given after a pause:
"okay" must start a segment, and segments only end at `earwig-stream-pause` (1.5 s) of silence.
This item removes that pause, and shortens the one after the command. It is a follow-up to the
wake-word helper in [wake-word.md](wake-word.md), on which the preferred design depends, and is
kept apart from it on purpose (agreed).

## Background: why the pause is needed

- A command given while dictating (`earwig-wake-word-commands`) is recognised only when a
  segment's text starts with one of `earwig-wake-words` (`'("okay" "ok")`):
  `earwig--strip-wake-word` (earwig-commands.el) matches at the start of the text only.
- Streaming dictation cuts segments at pauses after speech (`earwig--stream-measure`,
  earwig-stream.el), or at `earwig-stream-max-segment`, or where point moves.
- So "…end of the sentence okay delete last word", said in one breath, is one segment, and goes
  in as dictation, "okay" and all.

The final transcription of the segment before doesn't have to have arrived: "okay" can be said
as soon as the pause has cut the segment, and Earwig keeps the order (segments are inserted in
order; what's said while a command runs goes where it leaves point,
`earwig--stream-after-command`). It's the pause itself that's in the way.

The command's own segment also needs 1.5 s of silence to end, so a command runs that long after
it's said.

## Design

### Cut the audio where the helper heard the wake word (preferred)

Once the helper from [wake-word.md](wake-word.md) records and listens, it reports when in the
audio it heard the wake word, as a byte offset into the recording Earwig reads. Earwig cuts the
segment being spoken just before it, as it does when point moves (`earwig--stream-cut-at-move`:
cut at the quietest moment nearby with `earwig--stream-quietest`, queue what's before with
`earwig--stream-cut`, start the next segment there with `earwig--stream-restart-segment`).

- What was said before goes in as dictation; the wake word and the command are a segment of
  their own, which the existing wake-word handling runs.
- No pause before the wake word, and no text to split: false triggers depend only on the
  detector, not on the word turning up in dictation.
- It works in the middle of dictation too ("…zelda new paragraph", then more dictation).

### End the command's segment sooner

Once a segment starts with the wake word, Earwig could end it the way `earwig-command-auto-stop`
ends a command recorded with a command key (earwig.el): after a short pause once the provisional
text is a complete command (`earwig-commands-complete-p`, earwig-grammar.el; see
`earwig--command-heard-complete-p`), and after a longer one if it isn't yet
(`earwig-command-auto-stop-incomplete`, 3 s by default). Suggested, not agreed; it doesn't need
the helper and could come first.

## Options considered

| Option | Verdict |
|--------|---------|
| Cut the audio at the helper's offset (above) | preferred; needs the wake-word helper |
| Split the final text: when a segment contains the wake word in the middle and everything after it is a complete command (`earwig-commands-complete-p`), insert the part before as dictation and run the rest | **not now** (agreed). With "okay" as the wake word it would introduce new problems: "okay" is common in dictation ("that's okay, go to the store"), and requiring a complete command after it limits false splits but doesn't rule them out. It would only be safe with an unusual wake word. It also only handles a command at the end of a segment, not one followed by more dictation, which would need the grammar to find where the command ends |
| Word timestamps from the server: Orukeet's engine has a start and end time for each word (`_result` in `orukeet/nvidia.py`), but `local_server.py` returns only the text. Returning them (as OpenAI's `verbose_json` with word timestamps does) would let Earwig cut the audio at "okay" without the helper | not discussed beyond noting it; needs a change to a server that isn't Earwig's, and has the same "okay is common" problem as splitting the text |

"okay" stays the wake word for now (agreed); a more unusual one comes with the helper.

## Things to get right when building it

- **Latency of the detection.** openWakeWord fires about 100–300 ms after the wake word ends, so
  the cut has to be looked for before the offset it reports, far enough back to keep the whole
  wake word in the command's segment, but not into the dictation before it.
- **Provisional text.** The segment being spoken shows as provisional text; after the cut, the
  part before is that segment's, and the command's segment shows with
  `earwig-provisional-command` and `earwig-command-icon`.
- **Undo.** A command given while dictating ends the dictation so far (`earwig--stream-break`):
  one undo step and what "scratch that" takes back. That must still hold when the cut comes
  from the helper.

## Decide first

1. Whether ending the command's segment sooner is built on its own first, before the helper.
2. How far before the reported offset to look for the cut, and what the command's segment
   starts with (the wake word, so `earwig--strip-wake-word` handles it, or the audio after it);
   this follows open question 3 of [wake-word.md](wake-word.md).

## When to build it

After the wake-word helper in [wake-word.md](wake-word.md), for the audio cut. Splitting the
text is to be reconsidered only if the wake word becomes an unusual word.
