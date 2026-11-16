#!/usr/bin/env python3
"""
One-time conversion of the two neural networks to Core ML.

  FaceNet  (InceptionResnetV1, VGGFace2)  ->  FaceNet.mlpackage
  YOLOv8n  (COCO, with built-in NMS)      ->  YOLOv8n.mlpackage

Usage:  python convert_models.py <output-dir>
Run it through Tools/setup_models.sh, which builds the Python environment.
"""
import pathlib
import shutil
import sys

import coremltools as ct
import numpy as np
import torch
from PIL import Image

out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------- FaceNet
from facenet_pytorch import InceptionResnetV1

net = InceptionResnetV1(pretrained="vggface2").eval()
traced = torch.jit.trace(net, torch.rand(1, 3, 160, 160) * 2 - 1)

# The image input bakes in FaceNet's (x - 127.5) / 128 normalisation, so the
# app hands Core ML a plain 160x160 pixel buffer.
facenet = ct.convert(
    traced,
    inputs=[ct.ImageType(
        name="image", shape=(1, 3, 160, 160),
        scale=1 / 128.0, bias=[-127.5 / 128.0] * 3,
        color_layout=ct.colorlayout.RGB,
    )],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS14,
)
facenet.short_description = "FaceNet InceptionResnetV1 (VGGFace2), 512-d L2-normalised face embedding"
dst = out / "FaceNet.mlpackage"
shutil.rmtree(dst, ignore_errors=True)
facenet.save(str(dst))

# Check the converted model against PyTorch on a random image.
rgb = (np.random.rand(160, 160, 3) * 255).astype(np.uint8)
ref = net(((torch.from_numpy(rgb).float().permute(2, 0, 1) - 127.5) / 128.0)[None]).detach().numpy()[0]
got = np.asarray(facenet.predict({"image": Image.fromarray(rgb)})["embedding"]).reshape(-1)
cos = float(ref @ got / (np.linalg.norm(ref) * np.linalg.norm(got)))
print(f"FaceNet Core ML vs PyTorch cosine similarity: {cos:.5f}")
assert cos > 0.99, "converted FaceNet does not match PyTorch"

# ---------------------------------------------------------------- YOLOv8n
from ultralytics import YOLO

exported = YOLO("yolov8n.pt").export(format="coreml", nms=True, half=True, imgsz=640)
dst = out / "YOLOv8n.mlpackage"
shutil.rmtree(dst, ignore_errors=True)
shutil.move(str(exported), str(dst))
print("Saved", [p.name for p in out.glob("*.mlpackage")])
