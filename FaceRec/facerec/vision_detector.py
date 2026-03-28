"""
Face detection via Apple's Vision framework.

Uses VNDetectFaceLandmarksRequest which runs on the Neural Engine / GPU
through Core ML — the fastest face detection available on Apple Silicon.

Landmarks are used to compute a similarity transform so the aligned
160×160 crop matches what MTCNN would produce, keeping embedding quality
identical to the MTCNN-trained InceptionResnetV1 model.
"""

from __future__ import annotations

import io

import cv2
import numpy as np
import torch

try:
    import Vision
    import Foundation
    VISION_AVAILABLE = True
except ImportError:
    VISION_AVAILABLE = False

from .detector import Detection


# Reference 5-point landmarks for a 160×160 aligned face.
# These match the alignment target used when training VGGFace2 / FaceNet.
_REF_LANDMARKS = np.array([
    [38.2946, 51.6963],   # left eye centre
    [73.5318, 51.5014],   # right eye centre
    [56.0252, 71.7366],   # nose tip
    [41.5493, 92.3655],   # left mouth corner
    [70.7299, 92.2041],   # right mouth corner
], dtype=np.float32)


def _estimate_transform(src_pts: np.ndarray) -> np.ndarray:
    """
    Estimate a similarity transform (scale + rotation + translation) that
    maps src_pts → _REF_LANDMARKS.  Returns a 2×3 affine matrix.
    """
    mat, _ = cv2.estimateAffinePartial2D(
        src_pts, _REF_LANDMARKS,
        method=cv2.LMEDS,
    )
    return mat


def _align_face(frame_bgr: np.ndarray, landmarks_5: np.ndarray) -> torch.Tensor:
    """
    Warp frame so the 5 face landmarks align to the reference positions,
    then return a (3, 160, 160) float tensor in [-1, 1].
    """
    mat = _estimate_transform(landmarks_5)
    if mat is None:
        return None

    warped = cv2.warpAffine(frame_bgr, mat, (160, 160), flags=cv2.INTER_LINEAR)
    rgb    = cv2.cvtColor(warped, cv2.COLOR_BGR2RGB)
    t      = torch.from_numpy(rgb).float().permute(2, 0, 1)   # CHW
    return (t - 127.5) / 128.0                                 # [-1, 1]


def _pil_to_nsdata(frame_bgr: np.ndarray):
    """Convert a BGR numpy frame to NSData (PNG) for Vision."""
    from PIL import Image
    rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
    buf = io.BytesIO()
    Image.fromarray(rgb).save(buf, format="PNG")
    raw = buf.getvalue()
    return Foundation.NSData.dataWithBytes_length_(raw, len(raw))


class AppleVisionDetector:
    """
    Detects faces and 5 facial landmarks using Apple's Vision framework.
    Falls back to None if Vision / pyobjc is not available.
    """

    def __init__(self, min_confidence: float = 0.5):
        if not VISION_AVAILABLE:
            raise RuntimeError(
                "pyobjc-framework-Vision not installed. "
                "Run: pip install pyobjc-framework-Vision pyobjc-framework-Quartz"
            )
        self._min_conf = min_confidence

    def detect(self, frame_bgr: np.ndarray) -> list[Detection]:
        h, w = frame_bgr.shape[:2]
        ns_data = _pil_to_nsdata(frame_bgr)

        handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(
            ns_data, {}
        )
        # VNDetectFaceLandmarksRequest also returns bounding boxes
        request = Vision.VNDetectFaceLandmarksRequest.alloc().init()
        handler.performRequests_error_([request], None)

        results: list[Detection] = []
        for obs in (request.results() or []):
            conf = float(obs.confidence())
            if conf < self._min_conf:
                continue

            # Vision bbox: normalised, origin = bottom-left
            bbox = obs.boundingBox()
            bx, by   = bbox.origin.x,    bbox.origin.y
            bw, bh_n = bbox.size.width,  bbox.size.height

            x1 = int(bx * w)
            y1 = int((1.0 - by - bh_n) * h)
            x2 = int((bx + bw) * w)
            y2 = int((1.0 - by) * h)
            x1, y1 = max(0, x1), max(0, y1)
            x2, y2 = min(w, x2), min(h, y2)

            crop_bgr = frame_bgr[y1:y2, x1:x2] if (y2 > y1 and x2 > x1) else None

            # --- facial landmarks ---
            aligned = None
            lm = obs.landmarks()
            if lm is not None:
                pts = _extract_5_points(lm, x1, y1, x2 - x1, y2 - y1)
                if pts is not None:
                    aligned = _align_face(frame_bgr, pts)

            # Fallback: plain crop + resize (no alignment)
            if aligned is None and crop_bgr is not None:
                face   = cv2.resize(crop_bgr, (160, 160))
                rgb    = cv2.cvtColor(face, cv2.COLOR_BGR2RGB)
                t      = torch.from_numpy(rgb).float().permute(2, 0, 1)
                aligned = (t - 127.5) / 128.0

            if aligned is None:
                continue

            results.append(Detection(
                box=(x1, y1, x2, y2),
                prob=conf,
                aligned=aligned,
                face_crop_bgr=crop_bgr,
            ))

        return results


def _extract_5_points(
    landmarks,
    box_x: int, box_y: int, box_w: int, box_h: int,
) -> np.ndarray | None:
    """
    Pull the 5-point set (left eye, right eye, nose, left mouth, right mouth)
    from a VNFaceLandmarks2D object and convert to pixel coordinates.
    """
    def _region_centre(region):
        if region is None:
            return None
        pts = region.normalizedPoints()
        if not pts:
            return None
        xs = [p.x for p in pts]
        ys = [p.y for p in pts]
        # Vision landmark coords are normalised relative to the bounding box,
        # with y=0 at bottom.
        cx = float(np.mean(xs)) * box_w + box_x
        cy = (1.0 - float(np.mean(ys))) * box_h + box_y
        return [cx, cy]

    left_eye   = _region_centre(landmarks.leftEye())
    right_eye  = _region_centre(landmarks.rightEye())
    nose       = _region_centre(landmarks.nose())
    left_mouth = _region_centre(landmarks.outerLips())   # approximate
    right_mouth = left_mouth                              # fallback

    # Try to get individual mouth corners
    outer = landmarks.outerLips()
    if outer is not None:
        pts = outer.normalizedPoints()
        if pts and len(pts) >= 6:
            # Outer lips: first point ≈ left corner, middle ≈ right corner
            n = len(pts)
            lp = pts[0]
            rp = pts[n // 2]
            left_mouth  = [lp.x * box_w + box_x, (1.0 - lp.y) * box_h + box_y]
            right_mouth = [rp.x * box_w + box_x, (1.0 - rp.y) * box_h + box_y]

    if any(p is None for p in [left_eye, right_eye, nose, left_mouth, right_mouth]):
        return None

    return np.array([left_eye, right_eye, nose, left_mouth, right_mouth], dtype=np.float32)
