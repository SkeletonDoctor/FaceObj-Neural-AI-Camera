"""Face recognition with per-person adaptive thresholds."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .database import FaceDatabase
from .utils import batch_cosine_similarity

# Cosine similarity thresholds (higher = stricter)
BASE_THRESHOLD   = 0.62   # minimum to claim a match
AUTO_LEARN_THRESH = 0.72  # above this, auto-add the sample (confident match)
MAX_THRESHOLD    = 0.82   # ceiling — never go above this

MIN_SAMPLES_FOR_ADAPT = 8  # need at least this many samples to trust variance


@dataclass
class RecognitionResult:
    name: str | None         # None  → unknown face
    confidence: float        # cosine similarity of best match (0–1)
    second_best: str | None  # runner-up name (for debugging)
    second_conf: float
    auto_learned: bool
    sample_count: int        # samples we have for matched person (0 if unknown)


class FaceRecognizer:
    """Stateless recogniser that reads from (and writes to) a FaceDatabase."""

    def __init__(self, db: FaceDatabase):
        self.db = db

    # ------------------------------------------------------------------
    # Per-person adaptive threshold
    # ------------------------------------------------------------------

    def _threshold_for(self, name: str) -> float:
        rec = self.db.get(name)
        if rec is None or rec.sample_count < MIN_SAMPLES_FOR_ADAPT:
            return BASE_THRESHOLD

        var = rec.intra_variance
        t = BASE_THRESHOLD + 0.05 * (1.0 - min(var / 0.3, 1.0))
        t -= 0.04 * min(var / 0.3, 1.0)

        return float(np.clip(t, BASE_THRESHOLD, MAX_THRESHOLD))

    # ------------------------------------------------------------------
    # Core recognition
    # ------------------------------------------------------------------

    def recognize(
        self,
        embedding: np.ndarray,
        quality: float = 1.0,
        auto_learn: bool = True,
    ) -> RecognitionResult:
        protos = self.db.prototypes()

        if not protos:
            return RecognitionResult(
                name=None, confidence=0.0,
                second_best=None, second_conf=0.0,
                auto_learned=False, sample_count=0,
            )

        names   = list(protos.keys())
        proto_m = np.stack(list(protos.values()), axis=0)    # (N, 512)
        sims    = batch_cosine_similarity(embedding, proto_m)  # (N,)

        order  = np.argsort(sims)[::-1]
        best_i = order[0]
        best_name = names[best_i]
        best_sim  = float(sims[best_i])

        second_name = names[order[1]] if len(order) > 1 else None
        second_sim  = float(sims[order[1]]) if len(order) > 1 else 0.0

        threshold = self._threshold_for(best_name)

        if best_sim < threshold:
            return RecognitionResult(
                name=None, confidence=best_sim,
                second_best=second_name, second_conf=second_sim,
                auto_learned=False, sample_count=0,
            )

        # Match found
        auto_learned = False
        if auto_learn and best_sim >= AUTO_LEARN_THRESH:
            added = self.db.add_sample(best_name, embedding, quality)
            auto_learned = added

        rec = self.db.get(best_name)
        return RecognitionResult(
            name=best_name,
            confidence=best_sim,
            second_best=second_name,
            second_conf=second_sim,
            auto_learned=auto_learned,
            sample_count=rec.sample_count if rec else 0,
        )

    # ------------------------------------------------------------------
    # Manual labelling
    # ------------------------------------------------------------------

    def label(self, name: str, embedding: np.ndarray, quality: float) -> bool:
        """Explicitly assign a name to an embedding (e.g., from user input)."""
        return self.db.add_sample(name, embedding, quality)
