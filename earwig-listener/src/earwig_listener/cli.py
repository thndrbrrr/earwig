"""The program: listens until stdin closes, talking JSON lines with Earwig.

Events go to stdout, one JSON object a line; commands come on stdin,
likewise.  Anything else the program or its libraries print goes to
stderr, so stdout carries the protocol only.  See README.md.
"""

import argparse
import json
import os
import queue
import signal
import sys
import threading

from . import __version__
from .detector import SetupError
from .listener import Listener


def _protocol_stream():
    """Return stdout for the protocol, and send what else is printed there to stderr."""
    stream = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr
    return stream


def _read_commands(events: queue.Queue) -> None:
    for line in sys.stdin:
        if line.strip():
            events.put(("command", line))
    events.put(("quit", None))


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="earwig-listener",
        description="Record the microphone, listen for a wake word, and hand the audio over to Earwig.")
    parser.add_argument("--model", action="append", dest="models", metavar="NAME_OR_PATH",
                        help="wake-word model: a pre-trained one's name or an .onnx file; "
                             "repeatable (default: hey_jarvis)")
    parser.add_argument("--threshold", type=float, default=0.5,
                        help="score from 0 to 1 that counts as the wake word (default: 0.5)")
    parser.add_argument("--refractory", type=float, default=1.0, metavar="SECONDS",
                        help="seconds after a wake word in which none is reported (default: 1.0)")
    parser.add_argument("--buffer", type=float, default=3.0, metavar="SECONDS",
                        help="seconds of audio kept, how far back a recording can start (default: 3.0)")
    parser.add_argument("--device", default="default",
                        help="input device, as named in the system's sound settings (default: default)")
    parser.add_argument("--input", metavar="WAV",
                        help="read a 16 kHz, 16-bit mono WAV file instead of the microphone")
    parser.add_argument("--realtime", action="store_true",
                        help="with --input, read it at the pace it would be recorded")
    parser.add_argument("--list-devices", action="store_true", help="list the input devices and exit")
    parser.add_argument("--download-models", nargs="*", metavar="NAME",
                        help="download pre-trained models (and the feature models all need) and exit")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.list_devices:
        from .sources import input_devices

        for name in input_devices():
            print(name)
        return 0
    if args.download_models is not None:
        from .detector import download

        download(args.download_models or ["hey_jarvis"])
        return 0

    protocol = _protocol_stream()

    def emit(event: dict) -> None:
        protocol.write(json.dumps(event) + "\n")

    events: queue.Queue = queue.Queue()
    source = None
    listener = None
    try:
        from .detector import OpenWakeWord

        detector = OpenWakeWord(args.models or ["hey_jarvis"])
        if args.input:
            from .sources import WavFile

            source = WavFile(args.input, events, realtime=args.realtime)
        else:
            from .sources import Microphone

            source = Microphone(args.device, events)
        listener = Listener(detector, emit, buffer_seconds=args.buffer,
                            threshold=args.threshold, refractory_seconds=args.refractory)
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, lambda *_: events.put(("quit", None)))
        threading.Thread(target=_read_commands, args=(events,), daemon=True).start()
        emit({"event": "ready", "device": source.name, "models": detector.names,
              "rate": 16000, "buffer": listener.ring_max})
        source.start()
        while True:
            try:
                kind, value = events.get(timeout=0.5)
            except queue.Empty:
                continue
            if kind == "audio":
                listener.audio(value)
            elif kind == "command":
                if not listener.command(value):
                    break
            elif kind == "end":
                emit({"event": "end", "position": listener.position})
                break
            elif kind == "quit":
                break
        return 0
    except SetupError as err:
        emit({"event": "error", "message": str(err)})
        print(f"earwig-listener: {err}", file=sys.stderr)
        return 1
    except Exception as err:  # e.g. PortAudio refusing the device
        emit({"event": "error", "message": f"{type(err).__name__}: {err}"})
        raise
    finally:
        if listener:
            listener.close()
        if source:
            source.close()
