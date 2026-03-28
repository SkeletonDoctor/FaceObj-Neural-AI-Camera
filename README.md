# FaceRec

Real-time face recognition optimised for Apple Silicon. Assigns names to faces and improves accuracy the more it sees each person.

Built with MTCNN detection, FaceNet (VGGFace2) embeddings, Kalman tracking, and optional YOLOv8 object detection. All inference runs on-device via MPS.
<img width="2292" height="1281" alt="Screenshot 2026-03-28 at 12 49 59 PM" src="https://github.com/user-attachments/assets/5fab499f-d079-42f1-b9af-27a00ccd11de" />

## Requirements

- macOS with Apple Silicon (M1 or later)
- Python 3.12 (installed via Homebrew)
- Logitech Brio or any 1080p+ webcam

## Setup

```bash
git clone <repo>
cd FaceRec
./setup.sh
source .venv/bin/activate
```

`setup.sh` creates a Python 3.12 virtual environment and downloads all model weights (~150 MB total, one time).

## Usage

**Live camera**
```bash
python main.py camera
```

**Enrol someone from photos** (more angles = better accuracy)
```bash
python main.py add "Alice" photo1.jpg photo2.jpg photo3.jpg
```

**Other commands**
```bash
python main.py list                        # show known people and sample counts
python main.py test photo.jpg              # identify faces in a still image
python main.py rename "Alice" "Alice S."
python main.py delete "Alice"
```

## Camera controls

| Key | Action |
|-----|--------|

| `A` | Label the largest face in frame |
| `O` | Toggle object detection (YOLOv8) |
| `S` | Save database |
| `L` | List known people |
| `Q` / `ESC` | Quit |

## How it works

**Detection** — MTCNN runs on CPU (ARM NEON). Tries the frame upright first; if no face is found, retries at ±45° and ±90° to handle tilted heads.

**Embedding** — InceptionResnetV1 pretrained on VGGFace2 produces 512-dim embeddings. Runs on MPS.

**Recognition** — cosine similarity against per-person prototype embeddings. Threshold adapts per person based on how consistent their embeddings are.

**Learning** — every confident match above 72% similarity is added to that person's sample pool (up to 64 samples, quality-weighted). Samples from harder angles are also added when the Kalman tracker has an established identity but recognition drops below threshold.

**Tracking** — Kalman filter (constant-velocity) per face. Boxes are smooth and predict forward between detection frames. Confirmed after 2 matches, dropped after 8 missed frames.

**Object detection** — YOLOv8n on MPS, 80 COCO classes. Runs in a separate thread so it doesn't affect face detection throughput.

## Data

Face embeddings are stored in `data/faces.json`. This file is excluded from the repo — it contains biometric data and should never be committed.

Model weights (`data/yolov8n.pt`, and the facenet-pytorch cached weights) are also excluded and re-downloaded by `setup.sh`.
