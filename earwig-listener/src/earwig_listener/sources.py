"""Where the audio comes from: the microphone, or a WAV file for testing.

A source puts ("audio", BLOCK) on a queue for each 80 ms block, and
("end", None) when there is no more, or ("error", MESSAGE) if it fails.
"""

import queue
import sys
import threading
import time
import wave

from .detector import SetupError
from .listener import BLOCK_BYTES, BLOCK_SAMPLES, RATE


def input_devices() -> list:
    """Return the names of the input devices."""
    import sounddevice

    return [device["name"] for device in sounddevice.query_devices()
            if device["max_input_channels"] > 0]


def find_device(name: str):
    """Return the input device NAME as sounddevice takes it: None for "default".

    NAME is as in the system's sound settings, as `earwig-input-device';
    if no device is called that, one whose name contains it, ignoring case.
    """
    if name in ("", "default"):
        return None
    names = input_devices()
    if name in names:
        return name
    matches = [device for device in names if name.lower() in device.lower()]
    if len(matches) == 1:
        return matches[0]
    raise SetupError(f"{'no' if not matches else 'more than one'} input device "
                     f"matches {name!r} (there are: {', '.join(names) or 'none'})")


class Microphone:
    """Records the input device NAME."""

    def __init__(self, name: str, blocks: queue.Queue):
        import sounddevice

        self.blocks = blocks
        device = find_device(name)
        self.stream = sounddevice.RawInputStream(
            samplerate=RATE, channels=1, dtype="int16", blocksize=BLOCK_SAMPLES,
            device=device, callback=self._callback)
        self.name = sounddevice.query_devices(self.stream.device)["name"]

    def _callback(self, data, _frames, _time, status) -> None:
        if status:
            print(f"earwig-listener: {status}", file=sys.stderr)
        self.blocks.put(("audio", bytes(data)))

    def start(self) -> None:
        self.stream.start()

    def close(self) -> None:
        self.stream.stop()
        self.stream.close()


class WavFile:
    """Reads PATH, a 16 kHz, 16-bit mono WAV file; at real time with REALTIME."""

    def __init__(self, path: str, blocks: queue.Queue, realtime: bool = False):
        self.blocks = blocks
        self.realtime = realtime
        self.name = path
        try:
            self.wav = wave.open(path, "rb")
        except (OSError, wave.Error) as err:
            raise SetupError(f"can't read {path}: {err}") from err
        if (self.wav.getframerate(), self.wav.getnchannels(), self.wav.getsampwidth()) != (RATE, 1, 2):
            raise SetupError(f"{path} isn't 16 kHz, 16-bit mono")
        self.thread = threading.Thread(target=self._read, daemon=True)

    def _read(self) -> None:
        start = time.monotonic()
        count = 0
        while True:
            block = self.wav.readframes(BLOCK_SAMPLES)
            if len(block) < BLOCK_BYTES:
                break
            if self.realtime:
                time.sleep(max(0.0, start + count * BLOCK_SAMPLES / RATE - time.monotonic()))
            self.blocks.put(("audio", block))
            count += 1
        self.blocks.put(("end", None))

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.wav.close()
