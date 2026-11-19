# Testing Earwig on Linux (test plan, not run)

The Linux code is written, but nobody has run it on Linux yet. earwig-platform.el has a Linux
branch for everything that differs from macOS. Its tests pass on macOS, which binds
`system-type` to `gnu/linux` and feeds them what the Linux programs would print. Nothing has
recorded a microphone, read a real key repeat or started a server on Linux. This plan is for
doing that, on a real machine or a VM that passes the microphone through. When it has been run
and what it finds is fixed, the README says Linux is supported without reservation, and this
document goes. Windows is a separate item: [windows.md](windows.md).

## Background: what's built

Decided while this was built:

- **Linux and macOS are supported; Windows is a roadmap item.** Everything that differs by OS
  is in earwig-platform.el, decided by `system-type`. Windows branches are untested guesses or
  return nil.
- **sox stays the recorder**, because streaming needs it. On Linux it records through
  `pulseaudio` (which PipeWire serves too) or `alsa`.
- **Function keys are the Linux defaults**, because the desktop keeps Super (Cmd on a Mac) for
  itself. The user asked for function keys; F7, F8 and F9 were picked during the build and
  weren't discussed. F7 dictates, F8 gives a command, F9 corrects. The keypad keys are the same
  as on macOS (`earwig--default-keys`).
- **Orukeet is installed separately.** `orukeet/install.sh` and the launchd plist were taken
  out. Earwig needs only these:
  - `earwig-server-base-url`, the address of the server.
  - `earwig-server-model`, the model name it sends.
  - Optionally `earwig-server-command` and `earwig-server-directory`, to start the server
    from Emacs.
  - The server must answer OpenAI's POST /v1/audio/transcriptions, take language "auto", and
    listen only once it's ready.
- **Linux tests that don't need audio or Linux tools run on macOS**, in test/earwig-test.el
  under ";;;; Platforms" and ";;;; The server":
  - `earwig-test-sox-drivers`, `earwig-test-audio-driver`, `earwig-test-pulse-server`
  - `earwig-test-record-commands` (the sox commands for PulseAudio and ALSA)
  - `earwig-test-record-runs`: the Linux streaming command, run through env with this sox and a
    file as input
  - `earwig-test-recorder-stopped`, `earwig-test-default-keys`, `earwig-test-input-devices`
    (sample pactl and arecord output)
  - `earwig-test-key-repeat-linux` (sample xset, gsettings and kreadconfig output)
  - `earwig-test-check-keyboard-linux`, `earwig-test-install-hints`,
    `earwig-test-check-tools-linux`, `earwig-test-server-settings`

  The streaming test `earwig-test-stream` makes its speech with macOS's `say`. It stays
  macOS-only and is skipped elsewhere; that was the user's decision.

What the Linux branch does, and so what to check:

| Part | Linux behaviour | Where |
|------|-----------------|-------|
| Audio driver | `earwig-audio-driver` `auto`: pulseaudio if sox has it (from `sox -h`, "AUDIO DEVICE DRIVERS:") and `$PULSE_SERVER` or `$XDG_RUNTIME_DIR/pulse/native` exists; alsa otherwise | `earwig--audio-driver`, `earwig--pulse-server-p` |
| PulseAudio latency | sox runs as `env PULSE_LATENCY_MSEC=30 sox …` (`earwig-pulse-latency`, nil for libpulse's default). 30 ms is a guess, not measured | `earwig--sox-program` |
| ffmpeg | `-f pulse` if a sound server runs, else `-f alsa`; the device is `earwig-input-device` as it is | `earwig--ffmpeg-input-format`, `earwig--ffmpeg-input-device` |
| Stopping a recorder | SIGINT (`interrupt-process`), as on macOS; env replaces itself with sox, so sox gets it | `earwig--stop-recorder` |
| Stopping the server | SIGINT, then `delete-process` after `earwig-server-stop-timeout` | `earwig--interrupt-server`, `earwig-server-stop` |
| Microphones | `pactl list short sources`, without `.monitor` sources, with pulseaudio; `arecord -L`, without `null`, with alsa | `earwig--input-devices` |
| Key repeat | Wayland (`$WAYLAND_DISPLAY`): GNOME's gsettings (`org.gnome.desktop.peripherals.keyboard` `repeat`, `delay`, `repeat-interval`) or KDE's `kreadconfig6`/`kreadconfig5` (`kcminputrc` Keyboard `RepeatDelay`, `RepeatRate`); other Wayland desktops: unknown. X11 (`$DISPLAY`): `xset q`. `off` if repeat is off | `earwig--linux-key-repeat` |
| Install hints | apt, dnf, pacman or zypper, whichever is installed. On apt, sox is `sox libsox-fmt-pulse libsox-fmt-alsa`; a missing driver suggests `libsox-fmt-pulse` or `libsox-fmt-alsa` | `earwig--install-hint`, `earwig--sox-driver-hint` |
| Microphone access | "check that the input isn't muted or turned down, e.g. with pavucontrol; an Emacs from Flatpak or Snap also needs to be allowed the microphone" | `earwig--microphone-access-hint` |

## Test environments

Each environment covers something the others don't. The first one is the minimum.

1. **Ubuntu 24.04, GNOME on Wayland, PipeWire, pgtk Emacs 29 or 30.** This is the most common
   setup. It also covers Debian's split sox packages.
2. **The same machine, logged in to "GNOME on Xorg", with an X11 (GTK or Lucid) Emacs.** This is
   the `xset q` path.
3. **KDE Plasma on Wayland** (Fedora KDE or Kubuntu). This is the `kreadconfig` path and dnf.
4. **Optional:** a plain ALSA system without a sound server, a Wayland desktop other than GNOME
   or KDE (sway), and Emacs in a terminal (`emacs -nw`).

On each one: the Emacs version and build (`M-x emacs-version`, `system-configuration-features`),
the sox version, and `sox -h | grep DRIVERS`.

## Steps

### 1. Setting up

1. Install sox and curl following the README. On Ubuntu, first try `sudo apt install
   sox` alone and run step 3. That shows whether `sox` pulls in the driver packages through
   Recommends, which nobody checked. Then add `libsox-fmt-pulse libsox-fmt-alsa`.
2. Install Orukeet following its own instructions. Set `earwig-server-command` and
   `earwig-server-directory` as the README shows, with `.venv/bin/python`.
3. Run the test suite (README, Development). Everything but `earwig-test-stream` should pass,
   which skips without `say`.

### 2. earwig-check-setup

1. `M-x earwig-check-setup` with the server stopped. Server should fail with "M-x
   earwig-server-start", and Transcription shouldn't appear.
2. `M-x earwig-server-start`. "Speech server ready at …" should come once the model is loaded.
   `M-x earwig-server-log` shows its output. Press `g` in the report: everything should be ✓.
3. Note what each line says:
   - Audio driver: pulseaudio is expected on environments 1–3.
   - Microphone level.
   - Key repeat: does it match the desktop's keyboard settings?
4. Change the delay and rate in the desktop's keyboard settings and press `g`. Key repeat should
   follow without restarting Emacs.
5. Turn key repeat off in the settings. Key repeat should fail with "off".
6. Mute the microphone. Microphone should fail with "records only silence" and the hint.
7. Set `earwig-input-device` to a name that doesn't exist. The fix should list the sources pactl
   gives, or the arecord devices with `(setq earwig-audio-driver 'alsa)`.
8. With sox lacking the driver (step 1.1, or `(setq earwig-audio-driver 'coreaudio)`), Audio
   driver should fail with the apt hint or the list of drivers this sox has. Microphone should
   say "see Audio driver above".

### 3. Recording and streaming

1. Tap F7 and dictate three sentences with pauses. Then tap F7 again.
   - Text should appear at each pause.
   - The rest should go in on the stop.
   - No "Recording failed" message should appear: the sentinel has to see "interrupt" or
     "finished", through env (`earwig--recorder-stopped-p`).
2. **How soon audio flows.** *Messages* logs "Microphone live after N ms" on each recording;
   on macOS sox takes about 100 ms. Compare, and watch whether provisional text comes in evenly
   or in bursts:
   - pulseaudio with `earwig-pulse-latency` 30;
   - pulseaudio with nil (libpulse's default);
   - with `(setq earwig-audio-driver 'alsa)`.
   This settles whether `PULSE_LATENCY_MSEC` is needed, and whether 30 is right.
3. A command with F8 ("what can I say"). This records in one piece (`earwig--record`), with sox
   writing a WAV it stops with SIGINT. Check the transcription is complete.
4. `(setq earwig-streaming nil)`, then dictate. Same path as 3.
5. `(setq earwig-recorder 'ffmpeg)`, then dictate. ffmpeg records with `-f pulse -i default`
   (`earwig--record-command`), and its exit status 255 on SIGINT counts as stopped, not failed.
   Note how much of the start is lost; on macOS it's about a second.
6. Set `earwig-input-device` to a PulseAudio source name from the check, then to an ALSA name
   (`hw:CARD=…,DEV=0`) with the alsa driver. Both should record.

### 4. Keys and push-to-talk

1. F7, F8, F9 and the keypad keys. Check whether the desktop, GTK or the terminal takes any of
   them. On laptops whose F-keys are media keys, check what Fn needs.
2. `(setopt earwig-push-to-talk t)`, then hold the space bar: it should dictate, and a tap
   should type a space. With `(setq earwig-hold-debug t)`, compare the intervals logged with the
   Key repeat line of the check.
3. pgtk Emacs on Wayland, and an X11 Emacs on Wayland (XWayland): does a held key repeat
   evenly, and does the release come within `earwig-hold-release-delay`? Under XWayland the
   repeat is read from the desktop's settings, as `$WAYLAND_DISPLAY` is set. Check it matches
   what Emacs sees.
4. With an input method on (IBus, Fcitx), check held keys still repeat.

### 5. The server

1. `earwig-server-stop`. The server should exit on SIGINT well within
   `earwig-server-stop-timeout`, and the log should say it shut down cleanly.
2. Start the server outside Emacs, from a shell or a `systemd --user` unit. Recording should use
   it, and `earwig-server-start` should refuse ("Something already listens at …").
3. Without `earwig-server-command`, dictating with no server should say "No speech server
   answers at …: start it, or set `earwig-server-command'".

## Open questions

- **Does Orukeet run on Linux** (x86_64, aarch64)? Its installer offered `cpu`, `metal`, `cuda`
  and `vulkan` devices, which suggests it does, but nobody checked. If it doesn't, any server
  that meets the contract above can stand in for the test.
- **Whether PulseAudio needs `PULSE_LATENCY_MSEC` at all, and at what value** (step 3.2).
- **Whether XWayland reflects the desktop's repeat settings** (step 4.3).
- **Key repeat on other Wayland desktops** (sway, Hyprland, Cinnamon, …) can't be read. The
  check warns and suggests `earwig-hold-debug`. Decide whether that's enough.
- **An Emacs from Flatpak or Snap** has no way to run the system's sox, so it may not work at
  all. Not looked at.
- **The Linux branch is chosen for any system that isn't darwin or windows-nt**, so the BSDs get
  it too. Untested, and not a goal.
