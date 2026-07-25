"""Reusable faster-whisper wrapper for the Peregrine services.

`assistant.py` still owns its own module-level whisper_model (unchanged, to
avoid disrupting the running voice loop). This module gives `web_chat.py`
and any future consumer a matching engine without importing all of
assistant.py's global state.

Each importing process loads its own WhisperModel — ~150 MB resident on the
Q6A per instance, which is fine on 8 GB.
"""

from __future__ import annotations

import os
import tempfile
import time
import wave
from typing import Optional

from faster_whisper import WhisperModel


class STTEngine:
    """Persistent faster-whisper transcription engine."""

    def __init__(
        self,
        model_size: Optional[str] = None,
        cpu_threads: Optional[int] = None,
        sample_rate: int = 16000,
    ):
        self.model_size = model_size or os.getenv("WHISPER_SIZE", "base.en")
        self.cpu_threads = cpu_threads or int(os.getenv("CPU_THREADS", "8"))
        self.sample_rate = sample_rate
        self._model: Optional[WhisperModel] = None

    @property
    def available(self) -> bool:
        return self._model is not None

    def load(self) -> bool:
        if self._model is not None:
            return True
        try:
            t0 = time.monotonic()
            self._model = WhisperModel(
                self.model_size,
                device="cpu",
                compute_type="int8",
                cpu_threads=self.cpu_threads,
            )
            print(
                f"  [stt] loaded {self.model_size} in "
                f"{time.monotonic() - t0:.2f}s (threads={self.cpu_threads})"
            )
            return True
        except Exception as e:
            print(f"  [stt] WhisperModel load failed: {e}")
            self._model = None
            return False

    def transcribe_pcm(self, pcm_bytes: bytes, initial_prompt: Optional[str] = None) -> str:
        """Transcribe raw S16LE mono PCM at `self.sample_rate`."""
        if not self.load():
            return ""
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as f:
            with wave.open(f.name, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(self.sample_rate)
                wf.writeframes(pcm_bytes)
            return self._transcribe_path(f.name, initial_prompt)

    def transcribe_wav(self, wav_bytes: bytes, initial_prompt: Optional[str] = None,
                       language: str = "en") -> str:
        """Transcribe a complete WAV file provided as bytes.

        Used by the /api/voice endpoint — the ESP32 uploads a header + PCM
        payload, so we drop it straight into a tempfile and hand the path
        to faster-whisper without re-encoding.
        """
        if not self.load():
            return ""
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(wav_bytes)
            path = f.name
        try:
            return self._transcribe_path(path, initial_prompt)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def _transcribe_path(self, path: str, initial_prompt: Optional[str]) -> str:
        kwargs = {"beam_size": 1}
        if initial_prompt:
            kwargs["initial_prompt"] = initial_prompt
        segments, _ = self._model.transcribe(path, **kwargs)
        return " ".join(seg.text for seg in segments).strip()
