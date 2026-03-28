#!/usr/bin/env bash
set -e

VENV_DIR="$(dirname "$0")/.venv"

echo "==> Creating virtual environment (Python 3.12)..."
python3.12 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "==> Upgrading pip, setuptools, wheel..."
pip install --upgrade pip setuptools wheel --quiet

echo "==> Installing Pillow (build tools must be current first)..."
pip install --upgrade "Pillow>=11.0.0" --quiet

echo "==> Installing PyTorch (Apple Silicon optimised)..."
pip install torch torchvision --quiet

echo "==> Installing face recognition dependencies..."
pip install facenet-pytorch opencv-python numpy scipy rich ultralytics --quiet

echo ""
echo "==> Verifying MPS availability..."
python3 - <<'PYEOF'
import torch
print(f"  PyTorch  : {torch.__version__}")
print(f"  MPS avail: {torch.backends.mps.is_available()}")
if torch.backends.mps.is_available():
    x = torch.ones(1, device='mps')
    print(f"  MPS test : OK  ({x.device})")
PYEOF

echo ""
echo "==> Downloading model weights (first run)..."
python3 - <<'PYEOF'
import torch
from pathlib import Path

device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')

from facenet_pytorch import MTCNN, InceptionResnetV1
print(f"  MTCNN on {device}...")
MTCNN(device=device)
print(f"  InceptionResnetV1 (vggface2) on {device}...")
InceptionResnetV1(pretrained='vggface2').eval().to(device)

yolo_path = Path("data/yolov8n.pt")
if not yolo_path.exists():
    print("  YOLOv8n...")
    from ultralytics import YOLO
    m = YOLO("yolov8n.pt")
    yolo_path.parent.mkdir(exist_ok=True)
    Path("yolov8n.pt").rename(yolo_path)

print("  All models ready.")
PYEOF

echo ""
echo "=============================="
echo " Setup complete!"
echo " Run:  source .venv/bin/activate"
echo " Then: python main.py camera"
echo "=============================="
