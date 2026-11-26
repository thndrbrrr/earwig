"""The program, on speech made by macOS's say, with the hey_jarvis model."""

import json
import shutil
import subprocess
import sys
import wave

import pytest


def _have_model():
    try:
        from earwig_listener.detector import _model_path

        _model_path("hey_jarvis")
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not (shutil.which("say") and shutil.which("sox") and _have_model()),
    reason="needs say, sox and the hey_jarvis model")


@pytest.fixture
def speech(tmp_path):
    """Return a WAV file: a sentence, then "hey Jarvis, delete that line"."""
    aiff = tmp_path / "speech.aiff"
    wav = tmp_path / "speech.wav"
    subprocess.run(["say", "-v", "Samantha", "-o", str(aiff),
                    "This is a sentence before. [[slnc 600]] Hey Jarvis, delete that line. [[slnc 1500]]"],
                   check=True)
    subprocess.run(["sox", str(aiff), "-r", "16000", "-c", "1", "-b", "16", str(wav)], check=True)
    return wav


def listen(*args):
    return subprocess.Popen([sys.executable, "-m", "earwig_listener", *args],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1)


def events_until(proc, kind):
    seen = []
    for line in proc.stdout:
        seen.append(json.loads(line))
        if seen[-1]["event"] == kind:
            return seen
    raise AssertionError(f"no {kind} event in {seen}; stderr: {proc.stderr.read()}")


def test_hands_over_from_before_the_wake_word(speech, tmp_path):
    """On the wake word, a recording started 1.5 s back holds it and what follows."""
    proc = listen("--input", str(speech), "--realtime")
    try:
        events = events_until(proc, "wake")
        assert [e["event"] for e in events[:2]] == ["ready", "flowing"]
        assert events[0]["models"] == ["hey_jarvis_v0.1"]
        wake = events[-1]
        path = tmp_path / "rec.raw"
        proc.stdin.write(json.dumps({"command": "start", "path": str(path),
                                     "from": wake["position"] - 48000}) + "\n")
        events = events_until(proc, "end")
        started = next(e for e in events if e["event"] == "started")
        assert started["from"] == wake["position"] - 48000
        proc.stdin.close()
        assert proc.wait(timeout=10) == 0
    finally:
        proc.kill()
    with wave.open(str(speech), "rb") as f:
        audio = f.readframes(f.getnframes())
    recorded = path.read_bytes()
    # The recording is the audio from 1.5 s before the wake word on, to the end
    assert recorded == audio[started["from"]:started["from"] + len(recorded)]
    assert len(recorded) >= len(audio) - started["from"] - 2560
    # The wake word was heard about where it ends in the sentence: after "before."
    assert 2.5 < wake["position"] / 32000 < 4.5


def test_unknown_device():
    proc = listen("--device", "No such microphone, surely")
    out, _ = proc.communicate(timeout=60)
    assert proc.returncode == 1
    assert json.loads(out.splitlines()[-1])["event"] == "error"


def test_stdin_closing_quits(speech):
    proc = listen("--input", str(speech), "--realtime")
    events_until(proc, "flowing")
    proc.stdin.close()
    assert proc.wait(timeout=10) == 0
