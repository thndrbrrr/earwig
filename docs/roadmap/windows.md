# Windows support (design, not built)

Nothing in this document exists yet, beyond the placeholders listed below. Earwig runs on macOS
and Linux. It was agreed that Windows comes later, as a roadmap item. The work that made Earwig
work on more than one OS took Windows into account, so that what's left is filling in and testing
the Windows branches of earwig-platform.el. Linux is tested by
[linux-testing.md](linux-testing.md).

## Background: what's there

Everything that differs by OS is in earwig-platform.el, decided by `system-type`. Its
`windows-nt` branches are either untested guesses, marked "Windows: untested", or return nil
where nothing is known. When `earwig-mode` is turned on on a system other than macOS or Linux,
it warns once that Earwig hasn't been tested there (`earwig--platform-warn`).

| Part | Windows branch now | Status |
|------|--------------------|--------|
| sox driver (`earwig--default-audio-driver`) | `waveaudio`, `-t waveaudio DEVICE` | guess |
| ffmpeg (`earwig--ffmpeg-input-format`, `earwig--ffmpeg-input-device`) | `-f dshow -i audio=NAME`. DirectShow has no "default" device, so `earwig-input-device` "default" won't work | guess |
| Stopping a recorder (`earwig--stop-recorder`) | after 0.3 s, `delete-process` (no SIGINT on Windows). Recording a little longer keeps the last word, which killing would lose | guess |
| Recorder sentinel (`earwig--recorder-stopped-p`) | also takes "killed" and "deleted" as a stop, not a failure | guess |
| Stopping the server (`earwig--interrupt-server`) | `delete-process` straight away | guess |
| Default keys (`earwig--default-keys`) | the Linux function keys, F7, F8, F9, and the keypad. The Windows key, Emacs's Super, is taken: Win+D shows the desktop, Win+E opens Explorer | chosen, as for any system but macOS |
| Microphones (`earwig--input-devices`) | nil: the check can't list them | not done |
| Key repeat (`earwig--key-repeat`) | nil: the check warns it can't read it | not done |
| Install hints (`earwig--package-manager`) | `winget`, but `earwig--install-command` has no winget case, so the hint is "install sox" | not done |
| Microphone access (`earwig--microphone-access-hint`) | "turn on Settings > Privacy & security > Microphone > Let desktop apps access your microphone" | guess |

What doesn't need doing:

- **Orukeet's install is no longer Earwig's** (agreed). Earwig talks to whatever server answers
  at `earwig-speech-server-base-url` and starts one only with `earwig-speech-server-command`. So the
  `.venv/bin` versus `.venv\Scripts\python.exe` question, and a PowerShell port of the old
  `install.sh`, are gone. A user on Windows gives `earwig-speech-server-command` with their own path.
- `null-device` already replaces `/dev/null` in earwig-check.el.
- The text processing, commands, editing, curl requests and WAV writing are plain Emacs Lisp.
- Telling a tap from a hold relies on key repeat, which Emacs on Windows gets too. Windows'
  default of about 500 ms, then about 33 ms, is within the `earwig-hold-*` defaults.

## Streaming on Windows

sox is the recorder, as it is what streams (the user's preference; ffmpeg is thought not to
stream well). The streaming design should carry over:

- sox writes raw PCM to a file with `--buffer 1920`.
- Emacs reads what's new every 0.2 s (`earwig--stream-measure`).
- sox's `-S` progress, "Out:…", says when audio flows.

What may not carry over:

- **Stopping.** Emacs on Windows only fakes SIGINT, by sending Ctrl-C to a console. It isn't
  expected to reach a piped sox; that's a belief, not tested. Since the file is raw PCM, killing
  sox loses only what it hasn't written, hence the delayed kill above. The path that records in
  one piece (commands, and dictation without streaming) stops with `interrupt-process` too. There sox
  writes a WAV, whose header lengths may never be filled in if sox is killed. Many decoders
  cope; the server has to be tried.
- **Reading a file while sox writes it.** Windows' C runtime opens files shared, so it should
  work. Its own write buffer, about 4 KB or 130 ms of audio, may delay what Emacs sees, which is
  still under the 0.2 s it reads at.
- **sox itself.** The last sox release, 14.4.2 from 2015, has a 32-bit Windows build with
  `waveaudio`. How it names devices, by name, prefix or number, and whether "default" works,
  is unknown. So is how device names outside ASCII survive Emacs passing arguments in the
  system's code page.

## Things to do

1. Try sox's `waveaudio` recording into a growing raw file from Emacs, and stopping it (above).
   Fix `earwig--stop-recorder` and `earwig--recorder-stopped-p` to what's found.
2. Fill in `earwig--input-devices`, from `ffmpeg -list_devices true -f dshow -i dummy` or
   PowerShell, and in the form sox's waveaudio takes the name.
3. Fill in `earwig--key-repeat` from `HKCU\Control Panel\Keyboard`:
   - `KeyboardDelay` 0–3 means 250–1000 ms.
   - `KeyboardSpeed` 0–31 means about 2.5–30 repeats a second, or about 400–33 ms.
4. Give `earwig--install-command` a winget case. Check the package IDs for sox and curl (curl
   comes with Windows 10 and later).
5. Check ffmpeg's Windows recording (`-f dshow`, from `earwig--record-command`), as the
   fallback recorder.
6. Check that F7, F8 and F9 reach Emacs. Check that the speech server can be started and stopped
   from Emacs with `earwig-speech-server-command`.
7. A test plan like [linux-testing.md](linux-testing.md), then the README's setup for Windows.

## Options considered

- **ffmpeg instead of sox on Windows**, recording `-f s16le` to the growing file: suggested as a
  fallback in case sox's waveaudio doesn't work. It would mean teaching streaming to record with
  ffmpeg, which it can't today (`earwig--stream-p`). The user prefers sox; not agreed.
- **Only WSL.** Not discussed beyond noting that the old install script would have needed WSL or
  Git Bash. With the install gone, it doesn't matter for Earwig.

## Decide first

1. Whether a Windows machine (or VM with microphone) is available to build and test on. Nothing
   above can be settled without one.
2. If sox's `waveaudio` turns out not to work or not to stop cleanly: try ffmpeg for streaming,
   or leave Windows out.

## When to build it

When there's a Windows machine to test on, and a speech server that runs on Windows: Orukeet, if
its runtime has a Windows build (not checked), or another server with the same API.
