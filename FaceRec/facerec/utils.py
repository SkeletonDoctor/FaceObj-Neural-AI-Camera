"""Utility helpers: quality scoring, image preprocessing, distance math."""

import cv2
import numpy as np
import torch
from PIL import Image


def get_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def configure_threads():
    """
    On Apple Silicon, pin PyTorch CPU ops to the performance core count only.
    Using all cores (P+E) hurts latency for small sequential workloads like MTCNN
    because efficiency cores are slower and inter-thread synchronisation dominates.
    """
    import subprocess, os
    p_cores = 4  # M4 default fallback
    try:
        out = subprocess.check_output(
            ["sysctl", "-n", "hw.perflevel0.physicalcpu"], text=True
        ).strip()
        p_cores = int(out)
    except Exception:
        pass

    torch.set_num_threads(p_cores)
    torch.set_num_interop_threads(max(1, p_cores // 2))


# ---------------------------------------------------------------------------
# Distance / similarity
# ---------------------------------------------------------------------------

def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Cosine similarity in [-1, 1].  Higher = more similar."""
    a = a / (np.linalg.norm(a) + 1e-8)
    b = b / (np.linalg.norm(b) + 1e-8)
    return float(np.dot(a, b))


def batch_cosine_similarity(query: np.ndarray, protos: np.ndarray) -> np.ndarray:
    """
    query : (D,)
    protos: (N, D)
    returns: (N,) similarities
    """
    q = query / (np.linalg.norm(query) + 1e-8)
    p = protos / (np.linalg.norm(protos, axis=1, keepdims=True) + 1e-8)
    return p @ q


# ---------------------------------------------------------------------------
# Face quality scoring  (0 = worst, 1 = best)
# ---------------------------------------------------------------------------

def blur_score(gray: np.ndarray) -> float:
    """Laplacian variance — higher = sharper."""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def face_quality(face_bgr: np.ndarray, detection_prob: float) -> float:
    """
    Combine sharpness, face area, and detector confidence into [0, 1].
    face_bgr: BGR crop from camera (any size)
    """
    h, w = face_bgr.shape[:2]
    area = h * w

    gray = cv2.cvtColor(face_bgr, cv2.COLOR_BGR2GRAY)
    lap = blur_score(gray)

    # Normalise each factor to [0,1] with soft caps
    area_score = min(area / (200 * 200), 1.0)                 # 200×200 is "good"
    sharp_score = min(lap / 500.0, 1.0)                       # 500 Laplacian = very sharp
    conf_score = float(detection_prob)

    return 0.3 * area_score + 0.4 * sharp_score + 0.3 * conf_score


# ---------------------------------------------------------------------------
# Image helpers
# ---------------------------------------------------------------------------

def bgr_to_pil(frame: np.ndarray) -> Image.Image:
    return Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))


def box_to_int(box) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = box
    return int(x1), int(y1), int(x2), int(y2)


def draw_face_box(
    frame: np.ndarray,
    box: tuple[int, int, int, int],
    label: str,
    color: tuple[int, int, int],
    confidence: float | None = None,
    samples: int | None = None,
):
    x1, y1, x2, y2 = box
    thickness = 2
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)

    parts = [label]
    if confidence is not None:
        parts.append(f"{confidence * 100:.0f}%")
    if samples is not None:
        parts.append(f"#{samples}")
    text = "  ".join(parts)

    font = cv2.FONT_HERSHEY_SIMPLEX
    scale = 0.55
    (tw, th), baseline = cv2.getTextSize(text, font, scale, 1)
    bg_y1 = max(y1 - th - baseline - 6, 0)
    cv2.rectangle(frame, (x1, bg_y1), (x1 + tw + 8, y1), color, cv2.FILLED)
    cv2.putText(frame, text, (x1 + 4, y1 - baseline - 2), font, scale, (0, 0, 0), 1, cv2.LINE_AA)
