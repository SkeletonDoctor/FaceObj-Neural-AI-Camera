"""Face detection via MTCNN with multi-angle rotation support."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np
import torch
from facenet_pytorch import MTCNN
from PIL import Image

from .utils import get_device


# Candidate rotation angles (degrees).  0° is always tried first.
# Extra angles only run when 0° misses one or more faces.
_EXTRA_ANGLES = [-45, 45, -90, 90]

# IoU threshold for suppressing duplicate boxes across rotations
_NMS_IOU = 0.35


@dataclass
class Detection:
    box: tuple[int, int, int, int]   # x1, y1, x2, y2  (original image coords)
    prob: float
    aligned: torch.Tensor             # (3, 160, 160) normalised, ready for embedder
    face_crop_bgr: np.ndarray | None  # raw crop for quality scoring


# ------------------------------------------------------------------ geometry helpers

def _rot_matrix(angle_deg: float, cx: float, cy: float) -> np.ndarray:
    return cv2.getRotationMatrix2D((cx, cy), angle_deg, 1.0)


def _rotate_frame(frame: np.ndarray, angle_deg: float) -> tuple[np.ndarray, np.ndarray]:
    """Rotate frame by angle_deg; return (rotated_frame, 2×3 forward matrix)."""
    h, w = frame.shape[:2]
    M = _rot_matrix(angle_deg, w / 2, h / 2)
    rotated = cv2.warpAffine(frame, M, (w, h), flags=cv2.INTER_LINEAR)
    return rotated, M


def _unrotate_box(
    box: tuple, M: np.ndarray, frame_w: int, frame_h: int
) -> tuple[int, int, int, int]:
    """Map a box from rotated space back to original space."""
    x1, y1, x2, y2 = box
    corners = np.array([[x1, y1], [x2, y1], [x2, y2], [x1, y2]], dtype=np.float32)
    # Invert the rotation matrix
    M_inv = cv2.invertAffineTransform(M)
    ones = np.ones((4, 1), dtype=np.float32)
    unrot = (M_inv @ np.hstack([corners, ones]).T).T
    rx1, ry1 = unrot.min(axis=0)
    rx2, ry2 = unrot.max(axis=0)
    rx1 = int(np.clip(rx1, 0, frame_w))
    ry1 = int(np.clip(ry1, 0, frame_h))
    rx2 = int(np.clip(rx2, 0, frame_w))
    ry2 = int(np.clip(ry2, 0, frame_h))
    return (rx1, ry1, rx2, ry2)


def _iou(a: tuple, b: tuple) -> float:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    inter = max(0, ix2 - ix1) * max(0, iy2 - iy1)
    if inter == 0:
        return 0.0
    union = (ax2-ax1)*(ay2-ay1) + (bx2-bx1)*(by2-by1) - inter
    return inter / union if union > 0 else 0.0


def _nms(detections: list[Detection]) -> list[Detection]:
    """Suppress duplicate detections across rotation passes by IoU."""
    if not detections:
        return []
    detections = sorted(detections, key=lambda d: d.prob, reverse=True)
    kept: list[Detection] = []
    for det in detections:
        if all(_iou(det.box, k.box) < _NMS_IOU for k in kept):
            kept.append(det)
    return kept


# ------------------------------------------------------------------ detector

class FaceDetector:

    def __init__(self, device: torch.device | None = None, min_face_px: int = 40):
        self.device = device or get_device()
        self._mtcnn = MTCNN(
            image_size=160,
            margin=20,
            min_face_size=min_face_px,
            thresholds=[0.6, 0.7, 0.8],
            factor=0.709,
            post_process=True,
            keep_all=True,
            device=torch.device("cpu"),
        )

    # ------------------------------------------------------------------

    def detect(self, frame_bgr: np.ndarray) -> list[Detection]:
        h, w = frame_bgr.shape[:2]

        # Always run at 0° first
        results = self._detect_at_angle(frame_bgr, 0.0, w, h)

        # Only try extra angles when 0° found nothing
        if not results:
            for angle in _EXTRA_ANGLES:
                extra = self._detect_at_angle(frame_bgr, angle, w, h)
                results.extend(extra)
                if results:          # stop as soon as we find something
                    break

        return _nms(results)

    # ------------------------------------------------------------------

    def _detect_at_angle(
        self, frame_bgr: np.ndarray, angle: float, orig_w: int, orig_h: int
    ) -> list[Detection]:
        if angle == 0.0:
            rotated, M = frame_bgr, None
        else:
            rotated, M = _rotate_frame(frame_bgr, angle)

        pil_img = Image.fromarray(rotated[:, :, ::-1])   # BGR→RGB

        boxes_, probs_ = self._mtcnn.detect(pil_img)
        if boxes_ is None:
            return []

        aligned_batch = self._mtcnn(pil_img)
        if aligned_batch is None:
            return []

        if aligned_batch.dim() == 3:
            aligned_batch = aligned_batch.unsqueeze(0)

        out: list[Detection] = []
        for i, (box, prob) in enumerate(zip(boxes_, probs_)):
            if prob < 0.85:
                continue

            # Map box back to original frame coordinates
            rx1, ry1, rx2, ry2 = (max(0, int(v)) for v in box)
            if M is not None:
                rx1, ry1, rx2, ry2 = _unrotate_box(
                    (rx1, ry1, rx2, ry2), M, orig_w, orig_h
                )

            rx2 = min(rx2, orig_w)
            ry2 = min(ry2, orig_h)
            crop = frame_bgr[ry1:ry2, rx1:rx2] if (ry2 > ry1 and rx2 > rx1) else None

            out.append(Detection(
                box=(rx1, ry1, rx2, ry2),
                prob=float(prob),
                aligned=aligned_batch[i],
                face_crop_bgr=crop,
            ))

        return out
