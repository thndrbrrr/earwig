"""The listener, with a stand-in detector."""

import json
import wave

from earwig_listener.listener import BLOCK_BYTES, Listener, seconds_to_bytes


class FakeDetector:
    """Gives the scores queued for the coming blocks, then 0."""

    def __init__(self):
        self.scores = []
        self.resets = 0

    def score(self, block):
        return {"zelda": self.scores.pop(0) if self.scores else 0.0}

    def reset(self):
        self.resets += 1


def block(n):
    """Return a block whose bytes say which block it is."""
    return bytes([n % 256]) * BLOCK_BYTES


def make(**kwargs):
    events = []
    detector = FakeDetector()
    return Listener(detector, events.append, **kwargs), detector, events


def kinds(events):
    return [event["event"] for event in events]


def test_flowing_once_and_positions():
    listener, _, events = make()
    for n in range(3):
        listener.audio(block(n))
    assert events == [{"event": "flowing", "position": 0}]
    assert listener.position == 3 * BLOCK_BYTES


def test_buffer_keeps_the_last_seconds():
    listener, _, _ = make(buffer_seconds=0.2)  # 6400 bytes: 2.5 blocks
    for n in range(10):
        listener.audio(block(n))
    assert len(listener.ring) == seconds_to_bytes(0.2)
    assert listener.buffer_start == 10 * BLOCK_BYTES - 6400
    assert bytes(listener.ring[-BLOCK_BYTES:]) == block(9)


def test_recording_from_the_past(tmp_path):
    listener, _, events = make()
    for n in range(5):
        listener.audio(block(n))
    path = str(tmp_path / "rec.raw")
    listener.start(path, 2 * BLOCK_BYTES)
    for n in range(5, 7):
        listener.audio(block(n))
    listener.stop()
    with open(path, "rb") as f:
        assert f.read() == b"".join(block(n) for n in range(2, 7))
    started, stopped = events[1], events[2]
    assert started == {"event": "started", "path": path, "from": 2 * BLOCK_BYTES,
                       "position": 5 * BLOCK_BYTES}
    assert stopped == {"event": "stopped", "path": path, "from": 2 * BLOCK_BYTES,
                       "bytes": 5 * BLOCK_BYTES}


def test_recording_from_now_and_clamped(tmp_path):
    listener, _, events = make(buffer_seconds=0.16)  # 2 blocks
    for n in range(5):
        listener.audio(block(n))
    path = str(tmp_path / "rec.raw")
    # From now
    listener.start(path)
    assert events[-1]["from"] == 5 * BLOCK_BYTES
    # Too far back: from the oldest audio kept; odd: a whole sample
    listener.start(path, 1)
    assert events[-2]["event"] == "stopped"
    assert events[-1]["from"] == 3 * BLOCK_BYTES
    listener.start(path, 4 * BLOCK_BYTES + 3)
    assert events[-1]["from"] == 4 * BLOCK_BYTES + 2
    # In the future: from now
    listener.start(path, 99 * BLOCK_BYTES)
    assert events[-1]["from"] == 5 * BLOCK_BYTES
    listener.close()
    assert events[-1]["event"] == "stopped"


def test_wake_word_and_refractory():
    listener, detector, events = make(threshold=0.5, refractory_seconds=0.3)
    detector.scores = [0.1, 0.9, 0.95, 0.9, 0.9, 0.9, 0.9]
    for n in range(7):
        listener.audio(block(n))
    wakes = [event for event in events if event["event"] == "wake"]
    # Once, at the end of the block that scored; then quiet for 0.3 s (3.75 blocks)
    assert wakes[0] == {"event": "wake", "model": "zelda", "score": 0.9,
                        "position": 2 * BLOCK_BYTES}
    assert [wake["position"] for wake in wakes] == [2 * BLOCK_BYTES, 6 * BLOCK_BYTES]
    assert detector.resets == 2


def test_wake_word_while_recording(tmp_path):
    listener, detector, events = make()
    path = str(tmp_path / "rec.raw")
    listener.audio(block(0))
    listener.start(path)
    detector.scores = [0.0, 0.0, 0.8]
    for n in range(1, 4):
        listener.audio(block(n))
    wake = events[-1]
    assert wake["event"] == "wake"
    # Where it is in the file
    assert wake["position"] - events[1]["from"] == 3 * BLOCK_BYTES


def test_commands(tmp_path):
    listener, _, events = make()
    listener.audio(block(0))
    path = str(tmp_path / "rec.raw")
    assert listener.command(json.dumps({"command": "start", "path": path, "from": 0}))
    assert events[-1]["event"] == "started"
    assert listener.command('{"command": "stop"}')
    assert events[-1]["event"] == "stopped"
    for bad in ["not json", "[1]", '{"command": "fly"}', '{"command": "start"}',
                '{"command": "start", "path": "x", "from": "now"}',
                json.dumps({"command": "start", "path": str(tmp_path / "no" / "such.raw")})]:
        assert listener.command(bad)
        assert events[-1]["event"] == "error", bad
    assert not listener.command('{"command": "quit"}')
    assert "started" not in kinds(events[3:])


def test_recording_wav(tmp_path):
    listener, _, events = make()
    for n in range(3):
        listener.audio(block(n))
    path = str(tmp_path / "rec.wav")
    assert listener.command(json.dumps({"command": "start", "path": path, "from": BLOCK_BYTES,
                                        "format": "wav"}))
    # Readable while recording, from the data chunk on, as Earwig reads it
    with open(path, "rb") as f:
        data = f.read()
    assert data.index(b"data") == 36
    assert data[44:] == block(1) + block(2)
    listener.audio(block(3))
    listener.stop()
    with wave.open(path, "rb") as f:
        assert (f.getframerate(), f.getnchannels(), f.getsampwidth()) == (16000, 1, 2)
        assert f.readframes(f.getnframes()) == block(1) + block(2) + block(3)
    assert listener.command('{"command": "start", "path": "x", "format": "mp3"}')
    assert events[-1]["event"] == "error"
