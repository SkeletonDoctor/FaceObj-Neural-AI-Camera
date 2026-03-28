"""Face database — stores per-person embeddings and computes quality-weighted prototypes."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np


MAX_SAMPLES = 64       # max stored embeddings per person
MIN_QUALITY = 0.20     # below this, a sample is silently rejected


@dataclass
class PersonRecord:
    name: str
    embeddings: list[np.ndarray] = field(default_factory=list)   # each (512,)
    qualities:  list[float]      = field(default_factory=list)
    timestamps: list[float]      = field(default_factory=list)
    _prototype: np.ndarray | None = field(default=None, repr=False)

    # ------------------------------------------------------------------
    # Prototype management
    # ------------------------------------------------------------------

    @property
    def prototype(self) -> np.ndarray | None:
        if not self.embeddings:
            return None
        if self._prototype is None:
            self._recompute_prototype()
        return self._prototype

    def _recompute_prototype(self):
        weights = np.array(self.qualities, dtype=np.float32)
        weights = weights / (weights.sum() + 1e-8)
        stacked = np.stack(self.embeddings, axis=0)          # (N, 512)
        proto = (stacked * weights[:, None]).sum(axis=0)
        norm = np.linalg.norm(proto)
        self._prototype = proto / (norm + 1e-8)

    def invalidate_prototype(self):
        self._prototype = None

    # ------------------------------------------------------------------
    # Adding samples
    # ------------------------------------------------------------------

    def add_sample(self, embedding: np.ndarray, quality: float) -> bool:
        """
        Add a new embedding.  Returns True if added, False if rejected.
        Keeps the MAX_SAMPLES highest-quality samples.
        """
        if quality < MIN_QUALITY:
            return False

        self.embeddings.append(embedding.copy())
        self.qualities.append(float(quality))
        self.timestamps.append(time.time())

        # Prune to MAX_SAMPLES by dropping the lowest-quality entry
        if len(self.embeddings) > MAX_SAMPLES:
            worst = int(np.argmin(self.qualities))
            del self.embeddings[worst]
            del self.qualities[worst]
            del self.timestamps[worst]

        self.invalidate_prototype()
        return True

    # ------------------------------------------------------------------
    # Stats
    # ------------------------------------------------------------------

    @property
    def sample_count(self) -> int:
        return len(self.embeddings)

    @property
    def mean_quality(self) -> float:
        return float(np.mean(self.qualities)) if self.qualities else 0.0

    @property
    def intra_variance(self) -> float:
        """Average squared distance from prototype — lower = tighter cluster."""
        if len(self.embeddings) < 2 or self.prototype is None:
            return 1.0
        sims = np.array([
            float(np.dot(e / (np.linalg.norm(e) + 1e-8), self.prototype))
            for e in self.embeddings
        ])
        return float(1.0 - sims.mean())

    # ------------------------------------------------------------------
    # Serialisation
    # ------------------------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "embeddings": [e.tolist() for e in self.embeddings],
            "qualities": self.qualities,
            "timestamps": self.timestamps,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "PersonRecord":
        rec = cls(name=d["name"])
        rec.embeddings  = [np.array(e, dtype=np.float32) for e in d["embeddings"]]
        rec.qualities   = d["qualities"]
        rec.timestamps  = d.get("timestamps", [time.time()] * len(rec.embeddings))
        return rec


# ============================================================

class FaceDatabase:
    """Thread-safe (single-process) face database with JSON persistence."""

    def __init__(self, db_path: str | Path = "data/faces.json"):
        self._path = Path(db_path)
        self._people: dict[str, PersonRecord] = {}
        if self._path.exists():
            self.load()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def names(self) -> list[str]:
        return sorted(self._people.keys())

    def has(self, name: str) -> bool:
        return name in self._people

    def get(self, name: str) -> PersonRecord | None:
        return self._people.get(name)

    def add_sample(self, name: str, embedding: np.ndarray, quality: float) -> bool:
        """Add or update a person's face sample. Creates the person if new."""
        if name not in self._people:
            self._people[name] = PersonRecord(name=name)
        return self._people[name].add_sample(embedding, quality)

    def rename(self, old_name: str, new_name: str):
        if old_name not in self._people:
            raise KeyError(old_name)
        rec = self._people.pop(old_name)
        rec.name = new_name
        self._people[new_name] = rec

    def delete(self, name: str):
        self._people.pop(name, None)

    def prototypes(self) -> dict[str, np.ndarray]:
        """Return {name: prototype_embedding} for all people with ≥1 sample."""
        return {
            name: rec.prototype
            for name, rec in self._people.items()
            if rec.prototype is not None
        }

    def stats(self) -> list[dict]:
        rows = []
        for rec in self._people.values():
            rows.append({
                "name": rec.name,
                "samples": rec.sample_count,
                "mean_quality": round(rec.mean_quality, 3),
                "intra_variance": round(rec.intra_variance, 4),
            })
        return sorted(rows, key=lambda r: r["name"])

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def save(self):
        self._path.parent.mkdir(parents=True, exist_ok=True)
        data = {name: rec.to_dict() for name, rec in self._people.items()}
        tmp = self._path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, separators=(",", ":")))
        tmp.replace(self._path)

    def load(self):
        raw = json.loads(self._path.read_text())
        self._people = {name: PersonRecord.from_dict(d) for name, d in raw.items()}
