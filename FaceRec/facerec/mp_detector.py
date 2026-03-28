"""
Face detection via MediaPipe — ARM-optimised TFLite with XNNPACK.

Significantly faster than MTCNN on Apple Silicon CPU because MediaPipe
uses a single-shot BlazeFace model (not a 3-stage cascade), and TFLite's
XNNPACK backend is hand-tuned for ARM NEON.

Returns the same Detection dataclass as the MTCNN detector, with proper
5-point landmark alignment so FaceNet embedding quality is preserved.
"""

from __future__ import annotations

import cv2
import mediapipe as mp
import numpy as np
import torch

from .detector import Detection

# Reference 5-point landmarks for a 160×160 aligned face (FaceNet/VGGFace2 target)
_REF_PTS = np.array([
    [38.2946, 51.6963],   # left eye
    [73.5318, 51.5014],   # right eye
    [56.0252, 71.7366],   # nose tip
    [41.5493, 92.3655],   # left mouth corner
    [70.7299, 92.2041],   # right mouth corner
], dtype=np.float32)

# MediaPipe landmark indices that correspond to the 5 reference points
# 0=right_eye 1=left_eye 2=nose_tip 3=mouth_center 4=right_ear 5=left_ear
_MP_TO_REF = [1, 0, 2, 3, 3]   # left_eye, right_eye, nose, mouth(×2 as fallback)


def _align(frame_bgr: np.ndarray, src_pts: np.ndarray) -> torch.Tensor:
    mat, _ = cv2.estimateAffinePartial2D(src_pts, _REF_PTS, method=cv2.LMEDS)
    if mat is None:
        return None
    warped = cv2.warpAffine(frame_bgr, mat, (160, 160), flags=cv2.INTER_LINEAR)
    rgb = cv2.cvtColor(warped, cv2.COLOR_BGR2RGB)
    t = torch.from_numpy(rgb).float().permute(2, 0, 1)
    return (t - 127.5) / 128.0


class MediaPipeDetector:
    """
    BlazeFace detector via MediaPipe.  Uses the short-range model by default
    (fastest, good up to ~2 m).  Switch to model_selection=1 for long-range.
    """

    def __init__(self, min_confidence: float = 0.6, model_selection: int = 1):
        self._mp_fd = mp.solutions.face_detection.FaceDetection(
            model_selection=model_selection,
            min_detection_confidence=min_confidence,
        )

    def detect(self, frame_bgr: np.ndarray) -> list[Detection]:
        h, w = frame_bgr.shape[:2]
        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)

        out = self._mp_fd.process(rgb)
        if not out.detections:
            return []

        results: list[Detection] = []
        for det in out.detections:
            score = det.score[0] if det.score else 0.0

            # Bounding box (normalised)
            bb = det.location_data.relative_bounding_box
            x1 = max(0, int(bb.xmin * w))
            y1 = max(0, int(bb.ymin * h))
            x2 = min(w, int((bb.xmin + bb.width)  * w))
            y2 = min(h, int((bb.ymin + bb.height) * h))
            if x2 <= x1 or y2 <= y1:
                continue

            crop_bgr = frame_bgr[y1:y2, x1:x2]

            # Key points → 5-point alignment
            kps = det.location_data.relative_keypoints
            aligned = None
            if len(kps) >= 4:
                # MediaPipe gives 6 keypoints; map to our 5-point reference
                src = np.array([
                    [kps[1].x * w, kps[1].y * h],   # left eye
                    [kps[0].x * w, kps[0].y * h],   # right eye
                    [kps[2].x * w, kps[2].y * h],   # nose tip
                    [kps[3].x * w, kps[3].y * h],   # mouth left  (approx)
                    [kps[3].x * w, kps[3].y * h],   # mouth right (approx)
                ], dtype=np.float32)

                # Better mouth corners if ear keypoints are available
                if len(kps) >= 6:
                    # Estimate mouth corners from mouth centre + face width
                    face_w = (kps[0].x - kps[1].x) * w   # rough face width
                    mx, my = kps[3].x * w, kps[3].y * h
                    src[3] = [mx - face_w * 0.25, my]
                    src[4] = [mx + face_w * 0.25, my]

                aligned = _align(frame_bgr, src)

            if aligned is None:
                # Fallback: plain crop + resize
                face = cv2.resize(crop_bgr, (160, 160))
                rgb2 = cv2.cvtColor(face, cv2.COLOR_BGR2RGB)
                t = torch.from_numpy(rgb2).float().permute(2, 0, 1)
                aligned = (t - 127.5) / 128.0

            results.append(Detection(
                box=(x1, y1, x2, y2),
                prob=float(score),
                aligned=aligned,
                face_crop_bgr=crop_bgr,
            ))

        return results
