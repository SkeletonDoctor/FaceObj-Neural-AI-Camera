"""Face embedding via InceptionResnetV1 (VGGFace2) — runs on MPS."""

from __future__ import annotations

import numpy as np
import torch
from facenet_pytorch import InceptionResnetV1

from .utils import get_device


class FaceEmbedder:
    """
    Wraps InceptionResnetV1 pre-trained on VGGFace2.

    Input : (N, 3, 160, 160) float tensor in [-1, 1]  (MTCNN output)
    Output: (N, 512) L2-normalised embeddings as numpy float32
    """

    EMBEDDING_DIM = 512

    def __init__(self, device: torch.device | None = None):
        self.device = device or get_device()
        self._model = (
            InceptionResnetV1(pretrained="vggface2")
            .eval()
            .to(self.device)
        )
        # Warm up
        with torch.inference_mode():
            dummy = torch.zeros(1, 3, 160, 160, device=self.device)
            self._model(dummy)

    # ------------------------------------------------------------------

    @torch.inference_mode()
    def embed(self, aligned_tensors: list[torch.Tensor] | torch.Tensor) -> np.ndarray:
        """
        aligned_tensors: list of (3,160,160) or single (N,3,160,160) tensor.
        Returns: float32 numpy array of shape (N, 512), L2-normalised.
        """
        if isinstance(aligned_tensors, (list, tuple)):
            batch = torch.stack(aligned_tensors, dim=0)
        else:
            batch = aligned_tensors
            if batch.dim() == 3:
                batch = batch.unsqueeze(0)

        batch = batch.to(self.device)
        embs = self._model(batch)          # (N, 512), model normalises internally
        return embs.cpu().numpy().astype(np.float32)

    def embed_one(self, aligned_tensor: torch.Tensor) -> np.ndarray:
        """Convenience wrapper for a single face. Returns (512,)."""
        return self.embed(aligned_tensor)[0]
