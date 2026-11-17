<img src="FaceRecApp/FaceRec/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="FaceRec icon">

# FaceRec

Real-time face recognition for Apple Silicon Macs. Name a face once and the app keeps learning that person from every new angle. Everything runs on-device: video is drawn with Metal and both neural networks run on the Apple Neural Engine through Core ML.

## Download

**[Download FaceRec for Mac (.dmg)](https://github.com/SkeletonDoctor/FaceObj-Neural-AI-Camera/releases/latest)**

Requires macOS 15 or later on Apple Silicon.

1. Open the `.dmg` and drag FaceRec to Applications.
2. The app is not notarised by Apple, so the first launch is blocked. Open **System Settings › Privacy & Security**, scroll to the message about FaceRec and click **Open Anyway**.
3. Allow camera access when asked.

### Updates

FaceRec updates itself. It checks this repository's releases shortly after launch and once a day, downloads a newer version in the background, and installs it when you quit (or straight away with **Restart to Update**). Improved neural networks are delivered the same way. Every download is checked against a signature before it is installed. **More › Check for Updates…** checks on demand, and **More › Update Automatically** turns the background checks off.

Because the app is not notarised, macOS asks for camera access again after each update.

## Using it

| Key | Toolbar | Action |
|---|---|---|
| `A` | Name Face | Name the largest face in frame (shows its picture; pick an existing person to add to them) |
| | Camera and quality menus | Choose the camera, its resolution and its frame rate (remembered per camera) |
| `G` | Grid | With network cameras added: show every camera, or only the selected one |
| `O` | Objects | Toggle object detection (80 everyday object classes) |
| `L` | People | Show known people with their picture and learned angles; hover a row for rename and delete |
| `S` | More › Save Database | Save the database now |
| | More › Enrol from Photos | Add a person from image files |
| | More › Identify a Photo | Recognise the faces in an image file |
| `⌘,` | More › Network Cameras and Settings | Add network cameras and change settings |

On the video, a white bracket is an unknown face and a green one a recognised face (shading to orange for weaker matches). A spark next to a name means that frame was just learned. The capsules at the top-left show camera frame rate, frames analysed per second, faces in view, samples learned since launch and, when on, objects in view.

## Network cameras

Add IP cameras in **Settings › Network Cameras** by address. They appear in a grid beside this Mac's camera; click a tile to select it and double-click to show it alone. Faces seen on any camera are recognised and learned the same way.

| Address | What it is |
|---|---|
| `rtsp://user:password@192.168.1.20:554/stream1` | RTSP camera, H.264 or H.265, decoded in hardware. `rtsps://` (TLS) also works |
| `http://192.168.1.21/video.mjpg` | Motion-JPEG stream over HTTP |
| `http://192.168.1.22/snapshot.jpg` | Still-picture address, fetched about twice a second |

If the camera needs signing in, put the user name and password in the address. **Test Connection** in the editor tries the address and reports the picture size or what went wrong.

Network cameras do not have to be analysed fully live. This Mac's camera always has priority and is analysed at its full frame rate. Network cameras are analysed in the gaps: often when the Mac is keeping up, less often as load rises, and never less often than the limit in **Settings › General** (1 second by default). Their video keeps playing at full speed either way, and each tile shows its video rate and how many frames per second are being analysed.

RTSP is read over TCP only, so cameras that offer video only over UDP will not connect. Using a camera's lower-resolution stream keeps decoding cheap.

## Continuous learning

After a person is named once, the app keeps learning them:

- **Angles are filed separately.** Samples are sorted into 9 head-angle bins (left/centre/right turn by up/level/down tilt), 16 per bin. A new angle is never crowded out by more frontal frames. The grid next to each name in the People panel shows which angles are covered.
- **Confident matches refresh the samples.** A match of 72% or more that clearly beats every other person is stored if it shows something new, or replaces a stored near-duplicate if it is sharper or the stored one is over a week old.
- **New angles are learned through tracking.** When a tracked, confirmed face turns far enough that it is no longer recognised, the frame is stored if it is still close to something already known about that person and does not look like anyone else.
- **Naming enrols every angle seen so far.** While a face is unnamed, the tracker collects its varied views; pressing `A` stores all of them.
- **Safeguards.** A track must agree on a name 5 times before it can teach new angles, a different name has to win twice in a row before a track switches to it, and a track drops its name after 6 frames that look nothing like that person.

## Privacy

Video never leaves the Mac. Everything is stored only in `~/Library/Application Support/FaceRec/`: `faces.json` holds the face embeddings, `avatars/` one small picture per person, and `cameras.json` the network camera addresses (including any passwords in them; the file is readable only by your user account). Delete that folder to erase everything the app has learned.

## How it works

| Stage | How it runs |
|---|---|
| Camera | AVFoundation, mirrored, at the resolution and frame rate you pick |
| Network cameras | Native RTSP client with VideoToolbox hardware decoding; Motion-JPEG and stills over HTTP |
| Video display | Metal, each frame drawn as it arrives, camera buffers wrapped as textures without copying |
| Face detection + landmarks | Vision |
| Face embedding | FaceNet (InceptionResnetV1, VGGFace2) on Core ML |
| Object detection | YOLOv8n on Core ML |
| Tracking | Kalman filter per face with Hungarian assignment |

Core ML decides where each layer runs. On an M5, the self-test reports 99% of FaceNet's and 98% of YOLOv8n's layers on the Neural Engine.

## Accuracy and speed

Measured with `FaceRec --benchmark` on the LFW face-pairs benchmark, through the app's own detector, alignment and embedding (M5):

| | Held-out test pairs (1000) |
|---|---|
| Best verification accuracy | 99.2% |
| Same-person pairs accepted at the app's 0.55 threshold | 97.0% |
| Different-person pairs accepted at 0.55 | 0 of 500 (0.09% on the 2200 tuning pairs) |
| Time per image, one face | 6.5 ms |

A 1280×720 frame with two faces takes about 10 ms to analyse, so analysis keeps up with a 60 fps camera.

## Building from source

Needs Xcode.

```bash
cd FaceRecApp
```

```bash
Tools/build.sh
```

```bash
open build/Build/Products/Release/FaceRec.app
```

`Tools/build.sh` signs with an Apple Development certificate if the keychain has one, so macOS remembers the camera permission between builds. You can also open `FaceRecApp/FaceRec.xcodeproj` in Xcode and press Run.

The neural networks are not in the repository. A build without them downloads the published set on first launch. To convert them yourself from the original PyTorch weights instead (needs [`uv`](https://docs.astral.sh/uv/), about 150 MB of downloads), run `Tools/setup_models.sh` before building.

### Releasing

| Script | What it does |
|---|---|
| `Tools/make_dmg.sh` | Builds the distributable disk image |
| `Tools/release.sh` | Builds, signs and publishes a GitHub release: the disk image, `FaceRec.zip` for self-update and `Models-<n>.zip` |
| `Tools/sign_update.swift` | Creates the update signing key and signs files. The private key stays in `~/.config/facerec/`, outside the repository |
| `Tools/make_icon.swift` | Draws the app icon |

To publish a new version, raise `MARKETING_VERSION` in the Xcode project (and `ModelStore.bundledVersion` if the models changed), commit, and run `Tools/release.sh`. Forks need their own key: change `repository` and `publicKey` in `FaceRec/ReleaseFeed.swift`.

### Checks without a camera

The built binary is at `build/Build/Products/Release/FaceRec.app/Contents/MacOS/FaceRec`:

| Command | What it does |
|---|---|
| `FaceRec --selftest photo.jpg …` | Loads the models, reports where they run, analyses the photos and exercises the learning and tracking logic |
| `FaceRec --benchmark pairs.tsv` | Measures accuracy on labelled pairs, one per line: `imageA<TAB>imageB<TAB>1` (same person) or `0` |
| `FaceRec --render <dir> photo.jpg` | Draws the interface over a photo into `video.png` and `people.png` |
| `FaceRec --stream-test <address> [seconds]` | Connects to a network camera, then reports frames received, picture size and faces found |
| `FaceRec --update-test` | Runs one update check, download and install without the window. `FACEREC_UPDATE_FEED` can point it at a test release description; signatures are still checked |

## Licences

The app's code is under the Apache 2.0 licence in this repository. The downloadable app bundles two converted models with their own licences: FaceNet weights from [facenet-pytorch](https://github.com/timesler/facenet-pytorch) (MIT) and YOLOv8n from [Ultralytics](https://github.com/ultralytics/ultralytics) (AGPL-3.0).
