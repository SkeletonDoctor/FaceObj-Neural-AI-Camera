"""Multi-face Kalman tracker with IoU-based Hungarian assignment."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from scipy.optimize import linear_sum_assignment


MIN_HITS      = 2    # detections before a track is shown
MAX_MISSES    = 8    # missed frames before a track is dropped
IOU_THRESHOLD = 0.25 # minimum IoU to match a detection to a track
_NEXT_ID      = 0


def _new_id() -> int:
    global _NEXT_ID
    _NEXT_ID += 1
    return _NEXT_ID


# ------------------------------------------------------------------ helpers

def _to_cxcywh(box: tuple) -> np.ndarray:
    x1, y1, x2, y2 = box
    return np.array([(x1+x2)/2, (y1+y2)/2, x2-x1, y2-y1], dtype=np.float64)


def _to_xyxy(cx, cy, w, h) -> tuple[int,int,int,int]:
    return (int(cx - w/2), int(cy - h/2), int(cx + w/2), int(cy + h/2))


def _iou(a: tuple, b: tuple) -> float:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    inter = max(0, ix2-ix1) * max(0, iy2-iy1)
    if inter == 0:
        return 0.0
    ua = (ax2-ax1)*(ay2-ay1) + (bx2-bx1)*(by2-by1) - inter
    return inter / ua if ua > 0 else 0.0


# ------------------------------------------------------------------ single track

class KalmanTrack:
    """One tracked face with an 8-dim Kalman state."""

    # Constant-velocity transition: pos += vel each frame
    _F = np.eye(8)
    _F[0, 4] = _F[1, 5] = _F[2, 6] = _F[3, 7] = 1.0

    # Observation picks out the first 4 state dims
    _H = np.zeros((4, 8))
    _H[:4, :4] = np.eye(4)

    # Process noise — position uncertainty grows with velocity uncertainty
    _Q = np.diag([1., 1., 1., 1., 0.5, 0.5, 0.2, 0.2])

    # Measurement noise — trust detections reasonably but not blindly
    _R = np.diag([4., 4., 9., 9.])

    def __init__(self, box: tuple, det_info: dict):
        cx, cy, w, h = _to_cxcywh(box)
        self.x = np.array([cx, cy, w, h, 0., 0., 0., 0.])
        self.P = np.diag([10., 10., 20., 20., 50., 50., 20., 20.])
        self.track_id   = _new_id()
        self.hits       = 1
        self.misses     = 0
        self.age        = 0
        # Recognition metadata (updated whenever a match arrives)
        self.name:         str | None = det_info.get("name")
        self.confidence:   float      = det_info.get("confidence", 0.0)
        self.sample_count: int        = det_info.get("sample_count", 0)
        self.auto_learned: bool       = det_info.get("auto_learned", False)
        self.emb:          object     = det_info.get("emb")
        self.qual:         float      = det_info.get("qual", 0.0)

    @property
    def confirmed(self) -> bool:
        return self.hits >= MIN_HITS

    def predict(self):
        self.x = self._F @ self.x
        self.P = self._F @ self.P @ self._F.T + self._Q
        self.age += 1
        # Prevent negative width/height from drifting
        self.x[2] = max(self.x[2], 1.)
        self.x[3] = max(self.x[3], 1.)

    def update(self, box: tuple, det_info: dict):
        z = _to_cxcywh(box)
        S = self._H @ self.P @ self._H.T + self._R
        K = self.P @ self._H.T @ np.linalg.inv(S)
        self.x = self.x + K @ (z - self._H @ self.x)
        self.P = (np.eye(8) - K @ self._H) @ self.P
        self.hits   += 1
        self.misses  = 0
        # Update recognition info
        if det_info.get("name") is not None:
            self.name          = det_info["name"]
            self.confidence    = det_info.get("confidence", self.confidence)
            self.sample_count  = det_info.get("sample_count", self.sample_count)
        self.auto_learned = det_info.get("auto_learned", False)
        if det_info.get("emb") is not None:
            self.emb  = det_info["emb"]
            self.qual = det_info.get("qual", self.qual)

    def get_box(self) -> tuple[int,int,int,int]:
        return _to_xyxy(*self.x[:4])


# ------------------------------------------------------------------ multi tracker

class FaceTracker:
    """
    Manages a pool of KalmanTrack objects.

    Call predict()  every display frame  → returns current (smooth) track list.
    Call update()   when new detections arrive → matches & updates tracks.
    """

    def __init__(self):
        self._tracks: list[KalmanTrack] = []

    # ------------------------------------------------------------------

    def predict(self) -> list[KalmanTrack]:
        """Advance all tracks one step. Call every display frame."""
        for t in self._tracks:
            t.predict()
        return [t for t in self._tracks if t.confirmed]

    def update(self, detection_results: list[tuple], recognizer=None):
        if not detection_results:
            for t in self._tracks:
                t.misses += 1
            self._prune()
            return

        det_boxes = [dr[0].box for dr in detection_results]

        if not self._tracks:
            for dr in detection_results:
                self._tracks.append(KalmanTrack(dr[0].box, _det_info(dr)))
            return

        # Build IoU cost matrix  (tracks × detections)
        track_boxes = [t.get_box() for t in self._tracks]
        cost = np.zeros((len(self._tracks), len(det_boxes)))
        for i, tb in enumerate(track_boxes):
            for j, db in enumerate(det_boxes):
                cost[i, j] = 1.0 - _iou(tb, db)

        row_ind, col_ind = linear_sum_assignment(cost)

        matched_tracks = set()
        matched_dets   = set()

        for r, c in zip(row_ind, col_ind):
            if cost[r, c] <= (1.0 - IOU_THRESHOLD):
                track = self._tracks[r]
                det, emb, qual, res = detection_results[c]

                # Track has an identity but recognition dropped — learn from it
                if (
                    recognizer is not None
                    and track.name is not None
                    and track.hits >= MIN_HITS
                    and res.name is None
                    and emb is not None
                    and qual > 0.15
                ):
                    recognizer.label(track.name, emb, qual * 0.6)

                track.update(det.box, _det_info(detection_results[c]))
                matched_tracks.add(r)
                matched_dets.add(c)

        for i, t in enumerate(self._tracks):
            if i not in matched_tracks:
                t.misses += 1

        for j, dr in enumerate(detection_results):
            if j not in matched_dets:
                self._tracks.append(KalmanTrack(dr[0].box, _det_info(dr)))

        self._prune()

    def _prune(self):
        self._tracks = [t for t in self._tracks if t.misses <= MAX_MISSES]

    def largest_confirmed(self) -> KalmanTrack | None:
        confirmed = [t for t in self._tracks if t.confirmed]
        if not confirmed:
            return None
        return max(confirmed, key=lambda t: (t.x[2] * t.x[3]))


def _det_info(dr: tuple) -> dict:
    det, emb, qual, res = dr
    return {
        "name":         res.name,
        "confidence":   res.confidence,
        "sample_count": res.sample_count,
        "auto_learned": res.auto_learned,
        "emb":          emb,
        "qual":         qual,
    }
