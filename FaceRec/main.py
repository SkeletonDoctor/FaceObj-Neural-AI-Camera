#!/usr/bin/env python3
"""
Neural Face Recognition for Apple Silicon
==========================================
Commands:
  python main.py camera              — live webcam mode
  python main.py add NAME file.jpg   — enrol a person from photo(s)
  python main.py list                — list known people
  python main.py delete NAME         — remove a person
  python main.py rename OLD NEW      — rename a person
  python main.py test file.jpg       — run recognition on an image file
"""

from __future__ import annotations

import argparse
import queue
import sys
import threading
import time
from pathlib import Path

import cv2
import numpy as np
from rich.console import Console
from rich.table import Table

from facerec import FaceDetector, FaceEmbedder, FaceDatabase, FaceRecognizer
from facerec.object_detector import ObjectDetector, draw_objects
from facerec.tracker import FaceTracker
from facerec.utils import configure_threads, face_quality, draw_face_box

configure_threads()

def _make_detector():
    return FaceDetector()

console = Console()

DB_PATH = "data/faces.json"
AUTO_SAVE_INTERVAL = 30   # seconds between auto-saves in camera mode
DETECT_SCALE       = 0.5   # run MTCNN at half resolution


# ============================================================
# Background detection worker
# ============================================================

class _DetectionWorker:
    """
    Runs face detection + embedding + recognition in a daemon thread.

    The main loop submits frames via put(); completed results are read
    back via get_latest(). Both queues hold at most 1 item — stale
    frames and results are dropped so the worker always processes the
    freshest available frame.
    """

    def __init__(self, detector, embedder, recognizer, scale: float = DETECT_SCALE):
        self._detector   = detector
        self._embedder   = embedder
        self._recognizer = recognizer
        self._scale      = scale
        self._in_q:  queue.Queue = queue.Queue(maxsize=1)
        self._out_q: queue.Queue = queue.Queue(maxsize=1)
        t = threading.Thread(target=self._loop, daemon=True)
        t.start()

    def put(self, frame: np.ndarray):
        """Submit a frame; drops the pending one if the worker is busy."""
        try:
            self._in_q.put_nowait(frame)
        except queue.Full:
            pass

    def get_latest(self):
        """Return the most recent result list, or None if nothing new."""
        result = None
        while True:
            try:
                result = self._out_q.get_nowait()
            except queue.Empty:
                break
        return result

    def _loop(self):
        while True:
            frame = self._in_q.get()           # blocks until a frame arrives

            h, w = frame.shape[:2]
            small = cv2.resize(frame, (int(w * self._scale), int(h * self._scale)))
            dets  = self._detector.detect(small)

            # Scale bounding boxes back to full resolution
            inv = 1.0 / self._scale
            for d in dets:
                x1, y1, x2, y2 = d.box
                d.box = (int(x1*inv), int(y1*inv), int(x2*inv), int(y2*inv))
                # Replace small crop with full-res crop for quality scoring
                fx1, fy1, fx2, fy2 = d.box
                fx1, fy1 = max(0, fx1), max(0, fy1)
                fx2, fy2 = min(w, fx2), min(h, fy2)
                if fx2 > fx1 and fy2 > fy1:
                    d.face_crop_bgr = frame[fy1:fy2, fx1:fx2]

            results = []
            if dets:
                tensors    = [d.aligned for d in dets]
                embeddings = self._embedder.embed(tensors)
                for det, emb in zip(dets, embeddings):
                    qual = (
                        face_quality(det.face_crop_bgr, det.prob)
                        if det.face_crop_bgr is not None else 0.3
                    )
                    res = self._recognizer.recognize(emb, quality=qual, auto_learn=True)
                    results.append((det, emb, qual, res))

            # Publish; drop stale result if not yet consumed
            try:
                self._out_q.put_nowait(results)
            except queue.Full:
                try:
                    self._out_q.get_nowait()
                except queue.Empty:
                    pass
                self._out_q.put_nowait(results)


# ============================================================
# Camera mode
# ============================================================

def _colour_for_track(track) -> tuple[int, int, int]:
    if track.name is None:
        return (0, 60, 220)
    if track.confidence >= 0.80:
        return (0, 200, 0)
    if track.confidence >= 0.70:
        return (0, 200, 160)
    return (0, 180, 220)


WINDOW = "FaceRec — Apple Silicon"


def run_camera(db: FaceDatabase, camera_index: int = 0):
    detector   = _make_detector()
    embedder   = FaceEmbedder()
    recognizer = FaceRecognizer(db)
    worker     = _DetectionWorker(detector, embedder, recognizer)

    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        console.print("[red]Cannot open camera.[/red]")
        sys.exit(1)

    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    cap.set(cv2.CAP_PROP_FPS, 60)

    console.print("\n[bold green]Camera running[/bold green]")
    console.print("  [cyan]A[/cyan]  — label the largest face in frame")
    console.print("  [cyan]O[/cyan]  — toggle object detection (YOLOv8)")
    console.print("  [cyan]S[/cyan]  — save database now")
    console.print("  [cyan]L[/cyan]  — list known people")
    console.print("  [cyan]Q / ESC[/cyan] — quit\n")

    obj_detector = ObjectDetector()
    last_save    = time.time()
    tracker      = FaceTracker()
    cached_objs: list = []
    frame_count  = 0
    fps_t        = time.time()

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame = cv2.flip(frame, 1)
        frame_count += 1
        worker.put(frame)
        obj_detector.submit(frame)

        # Collect object detections
        new_objs = obj_detector.get_latest()
        if new_objs is not None:
            cached_objs = new_objs

        # Feed new detections into tracker when available
        new = worker.get_latest()
        if new is not None:
            tracker.update(new, recognizer=recognizer)

        # Predict (smooth + extrapolate) every display frame
        active_tracks = tracker.predict()

        display = frame.copy()

        if obj_detector.enabled and cached_objs:
            draw_objects(display, cached_objs)

        for track in active_tracks:
            if track.confidence < 0.25:
                continue
            box    = track.get_box()
            label  = track.name if track.name else "?"
            colour = _colour_for_track(track)
            draw_face_box(
                display, box, label, colour,
                confidence=track.confidence,
                samples=track.sample_count if track.name else None,
            )
            if track.auto_learned:
                cx = (box[0] + box[2]) // 2
                cv2.circle(display, (cx, box[3] + 8), 4, (0, 255, 255), cv2.FILLED)

        # --- HUD ---
        now = time.time()
        elapsed = now - fps_t
        fps = frame_count / elapsed if elapsed > 0 else 0.0
        if elapsed > 2.0:
            frame_count = 0
            fps_t = now

        people_n = len(db.names())
        obj_tag  = f"  OBJ:{len(cached_objs)}" if obj_detector.enabled else "  OBJ:off"
        hud = f"FPS:{fps:.0f}  People:{people_n}  Faces:{len(active_tracks)}{obj_tag}"
        cv2.putText(display, hud, (10, 24),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (200, 200, 200), 1, cv2.LINE_AA)

        # --- auto-save ---
        if now - last_save > AUTO_SAVE_INTERVAL:
            db.save()
            last_save = now

        cv2.imshow(WINDOW, display)
        key = cv2.waitKey(1) & 0xFF

        if key in (ord('q'), 27):    # Q or ESC
            break

        elif key == ord('a'):        # Label largest face
            t = tracker.largest_confirmed()
            if t is None or t.emb is None:
                console.print("[yellow]No confirmed face in frame.[/yellow]")
            else:
                if t.name:
                    console.print(f"  Currently identified as [bold]{t.name}[/bold].")
                name = console.input("  Enter name (blank = keep current): ").strip()
                if name:
                    recognizer.label(name, t.emb, t.qual or 0.5)
                    db.save()
                    console.print(f"  [green]Saved[/green] as '{name}'.")

        elif key == ord('o'):
            obj_detector.enabled = not obj_detector.enabled
            if not obj_detector.enabled:
                cached_objs = []
            console.print(f"  Object detection: {'ON' if obj_detector.enabled else 'OFF'}")

        elif key == ord('s'):
            db.save()
            console.print("[green]Database saved.[/green]")

        elif key == ord('l'):
            _print_list(db)

    cap.release()
    cv2.destroyAllWindows()
    db.save()
    console.print("[green]Saved on exit.[/green]")


# ============================================================
# CLI sub-commands
# ============================================================

def cmd_add(db: FaceDatabase, name: str, paths: list[str]):
    detector = _make_detector()
    embedder = FaceEmbedder()

    added = 0
    for p in paths:
        img = cv2.imread(p)
        if img is None:
            console.print(f"[red]Cannot read {p}[/red]")
            continue

        dets = detector.detect(img)
        if not dets:
            console.print(f"[yellow]No face found in {p}[/yellow]")
            continue

        # Pick highest-confidence detection
        best = max(dets, key=lambda d: d.prob)
        emb  = embedder.embed_one(best.aligned)
        qual = face_quality(best.face_crop_bgr, best.prob) if best.face_crop_bgr is not None else 0.5

        if db.add_sample(name, emb, qual):
            added += 1
            console.print(f"  [green]+[/green] {p}  (quality {qual:.2f})")
        else:
            console.print(f"  [yellow]~[/yellow] {p}  quality too low ({qual:.2f}), skipped")

    db.save()
    console.print(f"\nAdded [bold]{added}[/bold] sample(s) for '{name}'. "
                  f"Total: {db.get(name).sample_count if db.has(name) else 0}")


def _print_list(db: FaceDatabase):
    stats = db.stats()
    if not stats:
        console.print("[yellow]No people in database.[/yellow]")
        return
    t = Table(title="Known People")
    t.add_column("Name",          style="bold cyan")
    t.add_column("Samples",       justify="right")
    t.add_column("Mean Quality",  justify="right")
    t.add_column("Intra-Variance",justify="right")
    for row in stats:
        t.add_row(
            row["name"],
            str(row["samples"]),
            f"{row['mean_quality']:.3f}",
            f"{row['intra_variance']:.4f}",
        )
    console.print(t)


def cmd_test(db: FaceDatabase, path: str):
    img = cv2.imread(path)
    if img is None:
        console.print(f"[red]Cannot read {path}[/red]")
        sys.exit(1)

    detector   = _make_detector()
    embedder   = FaceEmbedder()
    recognizer = FaceRecognizer(db)

    dets = detector.detect(img)
    if not dets:
        console.print("[yellow]No faces detected.[/yellow]")
        return

    tensors    = [d.aligned for d in dets]
    embeddings = embedder.embed(tensors)

    for i, (det, emb) in enumerate(zip(dets, embeddings)):
        qual = face_quality(det.face_crop_bgr, det.prob) if det.face_crop_bgr is not None else 0.5
        res  = recognizer.recognize(emb, quality=qual, auto_learn=False)
        name = res.name or "Unknown"
        console.print(
            f"Face {i+1}: [bold]{name}[/bold]  "
            f"conf={res.confidence:.3f}  "
            f"2nd={res.second_best or '-'}({res.second_conf:.3f})  "
            f"box={det.box}"
        )


# ============================================================
# Entry point
# ============================================================

def main():
    ap = argparse.ArgumentParser(
        description="High-performance face recognition — Apple Silicon",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = ap.add_subparsers(dest="cmd")

    # camera
    p_cam = sub.add_parser("camera", help="Live webcam mode")
    p_cam.add_argument("--camera", type=int, default=0, help="Camera index (default 0)")
    p_cam.add_argument("--db", default=DB_PATH)

    # add
    p_add = sub.add_parser("add", help="Enrol a person from image file(s)")
    p_add.add_argument("name", help="Person's name")
    p_add.add_argument("files", nargs="+", help="Image file paths")
    p_add.add_argument("--db", default=DB_PATH)

    # list
    p_ls = sub.add_parser("list", help="List known people")
    p_ls.add_argument("--db", default=DB_PATH)

    # delete
    p_del = sub.add_parser("delete", help="Remove a person")
    p_del.add_argument("name")
    p_del.add_argument("--db", default=DB_PATH)

    # rename
    p_ren = sub.add_parser("rename", help="Rename a person")
    p_ren.add_argument("old")
    p_ren.add_argument("new")
    p_ren.add_argument("--db", default=DB_PATH)

    # test
    p_tst = sub.add_parser("test", help="Test recognition on an image")
    p_tst.add_argument("file")
    p_tst.add_argument("--db", default=DB_PATH)

    args = ap.parse_args()

    if args.cmd is None:
        ap.print_help()
        sys.exit(0)

    db = FaceDatabase(args.db)

    if args.cmd == "camera":
        run_camera(db, camera_index=args.camera)

    elif args.cmd == "add":
        cmd_add(db, args.name, args.files)

    elif args.cmd == "list":
        _print_list(db)

    elif args.cmd == "delete":
        if db.has(args.name):
            db.delete(args.name)
            db.save()
            console.print(f"[green]Deleted '{args.name}'.[/green]")
        else:
            console.print(f"[yellow]'{args.name}' not found.[/yellow]")

    elif args.cmd == "rename":
        try:
            db.rename(args.old, args.new)
            db.save()
            console.print(f"[green]Renamed '{args.old}' → '{args.new}'.[/green]")
        except KeyError:
            console.print(f"[red]'{args.old}' not found.[/red]")

    elif args.cmd == "test":
        cmd_test(db, args.file)


if __name__ == "__main__":
    main()
