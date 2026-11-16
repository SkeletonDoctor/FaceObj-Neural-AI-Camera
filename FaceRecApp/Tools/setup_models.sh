#!/usr/bin/env bash
# Builds a throwaway Python environment and converts both models to Core ML.
# Needs uv (brew install uv). Output: FaceRec/Models/*.mlpackage
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK_DIR:-$HERE/.convert}"
mkdir -p "$WORK"
cd "$WORK"
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python \
    "torch==2.5.1" "torchvision==0.20.1" "numpy<2" coremltools ultralytics pillow requests tqdm
uv pip install --python .venv/bin/python --no-deps facenet-pytorch
.venv/bin/python "$HERE/convert_models.py" "$HERE/../FaceRec/Models"
