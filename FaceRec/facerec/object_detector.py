"""YOLOv8n object detection on MPS, running in a background worker thread."""

from __future__ import annotations

import queue
import threading
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

MODEL_PATH = Path(__file__).parent.parent / "data" / "yolov8n.pt"
CONF_THRESHOLD = 0.45   # minimum confidence to show a box

# Per-category colour palette (BGR).  Cycles through hues.
_PALETTE: list[tuple[int, int, int]] = [
    (235,  64,  52), (235, 149,  52), (222, 235,  52), ( 52, 235,  67),
    ( 52, 235, 229), ( 52, 131, 235), (131,  52, 235), (235,  52, 174),
    (255, 165,   0), (  0, 200, 200), (200, 200,   0), (100, 200, 100),
]


def _class_colour(class_id: int) -> tuple[int, int, int]:
    return _PALETTE[class_id % len(_PALETTE)]


@dataclass
class ObjDetection:
    box:        tuple[int, int, int, int]
    label:      str
    confidence: float
    class_id:   int


class ObjectDetector:
    """
    YOLOv8n running on MPS in a daemon thread.

    submit(frame)      — non-blocking, drops stale frames
    get_latest()       — returns most recent ObjDetection list, or None
    enabled            — set True/False to start/stop processing
    """

    def __init__(self):
        from ultralytics import YOLO
        import torch
        self._device  = "mps" if torch.backends.mps.is_available() else "cpu"
        self._model   = YOLO(str(MODEL_PATH))
        # Warm up
        dummy = np.zeros((64, 64, 3), dtype=np.uint8)
        self._model(dummy, device=self._device, verbose=False)

        self.enabled: bool = False
        self._in_q:  queue.Queue = queue.Queue(maxsize=1)
        self._out_q: queue.Queue = queue.Queue(maxsize=1)
        t = threading.Thread(target=self._loop, daemon=True)
        t.start()

    # ------------------------------------------------------------------

    def submit(self, frame: np.ndarray):
        if not self.enabled:
            return
        try:
            self._in_q.put_nowait(frame)
        except queue.Full:
            pass

    def get_latest(self) -> list[ObjDetection] | None:
        result = None
        while True:
            try:
                result = self._out_q.get_nowait()
            except queue.Empty:
                break
        return result

    # ------------------------------------------------------------------

    def _loop(self):
        while True:
            frame = self._in_q.get()          # blocks until a frame arrives
            if not self.enabled:
                continue

            rgb     = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = self._model(
                rgb,
                device=self._device,
                conf=CONF_THRESHOLD,
                verbose=False,
            )

            detections: list[ObjDetection] = []
            for r in results:
                for box in r.boxes:
                    x1, y1, x2, y2 = (int(v) for v in box.xyxy[0].tolist())
                    cls_id  = int(box.cls[0])
                    conf    = float(box.conf[0])
                    label   = r.names[cls_id]
                    detections.append(ObjDetection(
                        box=(x1, y1, x2, y2),
                        label=label,
                        confidence=conf,
                        class_id=cls_id,
                    ))

            try:
                self._out_q.put_nowait(detections)
            except queue.Full:
                try:
                    self._out_q.get_nowait()
                except queue.Empty:
                    pass
                self._out_q.put_nowait(detections)


# ------------------------------------------------------------------
# Drawing helper
# ------------------------------------------------------------------

def draw_objects(img: np.ndarray, detections: list[ObjDetection]):
    font      = cv2.FONT_HERSHEY_SIMPLEX
    scale     = 0.50
    thickness = 1

    for det in detections:
        x1, y1, x2, y2 = det.box
        colour = _class_colour(det.class_id)

        # Dashed-style box: draw as a normal rect with thinner line
        cv2.rectangle(img, (x1, y1), (x2, y2), colour, 1)

        label = f"{det.label} {det.confidence:.0%}"
        (tw, th), baseline = cv2.getTextSize(label, font, scale, thickness)
        bg_y1 = max(y1 - th - baseline - 4, 0)
        cv2.rectangle(img, (x1, bg_y1), (x1 + tw + 6, y1), colour, cv2.FILLED)
        cv2.putText(img, label, (x1 + 3, y1 - baseline - 1),
                    font, scale, (0, 0, 0), thickness, cv2.LINE_AA)
