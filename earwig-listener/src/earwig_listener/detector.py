"""The wake-word detector, openWakeWord."""

import os

import numpy as np


class SetupError(Exception):
    """Something to install or set up before listening."""


def _model_path(spec: str) -> str:
    """Return the ONNX file of the model SPEC: a path, or a pre-trained model's name."""
    import openwakeword

    if os.path.exists(spec):
        return spec
    if spec not in openwakeword.MODELS:
        raise SetupError(f"no model file {spec!r}, nor a pre-trained model of that name "
                         f"(they are: {', '.join(sorted(openwakeword.MODELS))})")
    path = openwakeword.MODELS[spec]["model_path"].replace(".tflite", ".onnx")
    if not os.path.exists(path):
        raise SetupError(f"the pre-trained model {spec!r} isn't downloaded; "
                         f"run: earwig-listener --download-models {spec}")
    return path


def download(names: list) -> None:
    """Download the pre-trained models NAMES, and the feature models all need."""
    from openwakeword.utils import download_models

    download_models(model_names=names)


class OpenWakeWord:
    """Scores audio for the wake-word models SPECS (paths or pre-trained names)."""

    def __init__(self, specs: list):
        import openwakeword
        from openwakeword.model import Model

        paths = [_model_path(spec) for spec in specs]
        models = os.path.join(os.path.dirname(openwakeword.__file__), "resources", "models")
        for feature in ("melspectrogram.onnx", "embedding_model.onnx"):
            if not os.path.exists(os.path.join(models, feature)):
                raise SetupError("openWakeWord's feature models aren't downloaded; "
                                 "run: earwig-listener --download-models")
        self.model = Model(wakeword_models=paths, inference_framework="onnx")
        self.names = list(self.model.models)

    def score(self, block: bytes) -> dict:
        return self.model.predict(np.frombuffer(block, dtype=np.int16))

    def reset(self) -> None:
        self.model.reset()
