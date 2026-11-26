"""The listener: a ring buffer of recent audio, a recording, and the wake word.

Everything is counted in bytes of 16 kHz, signed 16-bit mono audio since
the listener started (its *position*), as Earwig counts its recordings.
A recording started at position FROM holds the audio from FROM on, so a
position P is at byte P - FROM of its file.
"""

import json
import struct
from typing import Protocol
from collections.abc import Callable

RATE = 16000
SAMPLE_BYTES = 2
BLOCK_SAMPLES = 1280  # 80 ms, what openWakeWord takes at a time
BLOCK_BYTES = BLOCK_SAMPLES * SAMPLE_BYTES


def wav_header(length: int) -> bytes:
    """Return the WAV header for LENGTH bytes of the audio, at most 4 GB."""
    length = min(length, 0xFFFFFFFF - 36)
    return (b"RIFF" + struct.pack("<I", 36 + length) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * SAMPLE_BYTES, SAMPLE_BYTES, 16)
            + b"data" + struct.pack("<I", length))


def seconds_to_bytes(seconds: float) -> int:
    """Return SECONDS of audio in bytes, whole samples."""
    return int(seconds * RATE) * SAMPLE_BYTES


class Detector(Protocol):
    def score(self, block: bytes) -> dict:
        """Return {model name: score from 0 to 1} for the next block of audio."""

    def reset(self) -> None:
        """Forget the audio scored so far."""


class Listener:
    """Takes audio blocks and commands, and emits events.

    EMIT is called with each event, a dict with an "event" key.
    """

    def __init__(self, detector: Detector, emit: Callable[[dict], None], *,
                 buffer_seconds: float = 3.0, threshold: float = 0.5,
                 refractory_seconds: float = 1.0):
        self.detector = detector
        self.emit = emit
        self.threshold = threshold
        self.refractory = seconds_to_bytes(refractory_seconds)
        self.ring = bytearray()
        self.ring_max = seconds_to_bytes(buffer_seconds)
        self.position = 0
        self.flowing = False
        self.quiet_until = 0
        self.file = None
        self.path: str | None = None
        self.wav = False
        self.start_position = 0

    # Audio

    def audio(self, block: bytes) -> None:
        """Take the next BLOCK of audio: keep it, record it, and listen to it."""
        if not self.flowing:
            self.flowing = True
            self.emit({"event": "flowing", "position": self.position})
        self.ring += block
        if len(self.ring) > self.ring_max:
            del self.ring[:len(self.ring) - self.ring_max]
        self.position += len(block)
        # Recorded before the detector runs, so Earwig never waits on it
        if self.file:
            self.file.write(block)
            self.file.flush()
        self._listen(block)

    def _listen(self, block: bytes) -> None:
        scores = self.detector.score(block)
        if self.position < self.quiet_until:
            return
        for name, score in scores.items():
            if score >= self.threshold:
                self.emit({"event": "wake", "model": name, "score": round(float(score), 3),
                           "position": self.position})
                # Scores stay high for a while after a detection
                self.quiet_until = self.position + self.refractory
                self.detector.reset()
                return

    # Recording

    @property
    def buffer_start(self) -> int:
        """The position of the oldest audio kept."""
        return self.position - len(self.ring)

    def start(self, path: str, from_position: int | None = None, wav: bool = False) -> None:
        """Record to PATH, from FROM_POSITION on, or from now.

        FROM_POSITION may be in the past, as far back as the audio kept;
        further back is taken as the oldest audio kept.  A recording going
        on is stopped first.  With WAV, the file is a WAV file, whose
        header has the largest length until recording stops, as sox's.
        """
        if self.file:
            self.stop()
        if from_position is None:
            from_position = self.position
        from_position = min(max(from_position, self.buffer_start), self.position)
        from_position -= from_position % SAMPLE_BYTES
        self.file = open(path, "wb")
        self.path = path
        self.wav = wav
        self.start_position = from_position
        if wav:
            self.file.write(wav_header(0xFFFFFFFF))
        self.file.write(self.ring[from_position - self.buffer_start:])
        self.file.flush()
        self.emit({"event": "started", "path": path, "from": from_position,
                   "position": self.position})

    def stop(self) -> None:
        """Stop recording, if recording."""
        if not self.file:
            return
        if self.wav:
            self.file.seek(0)
            self.file.write(wav_header(self.position - self.start_position))
        self.file.close()
        self.emit({"event": "stopped", "path": self.path, "from": self.start_position,
                   "bytes": self.position - self.start_position})
        self.file = None
        self.path = None

    # Commands

    def command(self, line: str) -> bool:
        """Carry out the command LINE, a JSON object; return False to quit."""
        try:
            command = json.loads(line)
            if not isinstance(command, dict):
                raise ValueError("a command is a JSON object")
            name = command.get("command")
            if name == "start":
                path = command.get("path")
                if not isinstance(path, str) or not path:
                    raise ValueError("start needs a path")
                from_position = command.get("from")
                if from_position is not None and not isinstance(from_position, int):
                    raise ValueError("from must be a position, a whole number of bytes")
                back = command.get("back")
                if back is not None:
                    if from_position is not None:
                        raise ValueError("start takes from or back, not both")
                    if not isinstance(back, int) or back < 0:
                        raise ValueError("back must be a whole number of bytes, 0 or more")
                    from_position = self.position - back
                audio_format = command.get("format", "raw")
                if audio_format not in ("raw", "wav"):
                    raise ValueError("format must be raw or wav")
                self.start(path, from_position, wav=audio_format == "wav")
            elif name == "stop":
                self.stop()
            elif name == "quit":
                return False
            else:
                raise ValueError(f"unknown command: {name!r}")
        except (ValueError, OSError) as err:
            self.emit({"event": "error", "message": str(err)})
        return True

    def close(self) -> None:
        """Stop recording, as the listener exits."""
        self.stop()
