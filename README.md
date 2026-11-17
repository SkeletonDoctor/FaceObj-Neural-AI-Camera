<img src="FaceRecApp/FaceRec/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="FaceRec icon">

# FaceRec

Real-time face recognition for Apple Silicon Macs. Name a face once and the app keeps learning that person from every new angle. Everything runs on-device: video is drawn with Metal and both neural networks run on the Apple Neural Engine through Core ML.

![FaceRec in Security mode watching three public street cameras, with tracked objects](docs/images/camera-grid.jpg)

*Security mode watching three public street cameras at once (Nashville, Akron and Lake Tahoe), with object tracking on.*

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

The switch at the top of the window picks the mode, and FaceRec asks which you want the first time it opens.

| Mode | What it does |
|---|---|
| **This Mac** | Recognises people in front of this Mac's camera. Network cameras are not connected. |
| **Security** | Watches your network cameras in a grid, logs who appears and can alert you. This Mac's camera is off unless you turn it on in Settings › Security. |

| Key | Toolbar | Action |
|---|---|---|
| `A` | Name Face | Name the largest face in view (shows its picture; pick an existing person to add to them) |
| | Camera and quality menus | This Mac mode: choose the camera, its resolution and its frame rate |
| | Add Camera | Security mode: add a network camera |
| `G` | Grid | With several cameras: show every camera, or only the selected one |
| `O` | Objects | Turn object detection on or off; the button opens the object filter |
| `L` | People and History | Known people, with their picture and learned angles |
| `H` | People and History | The history of faces seen |
| `S` | More › Save Database | Save the database now |
| | More › Enrol from Photos | Add a person from image files |
| | More › Identify a Photo | Recognise the faces in an image file |
| `⌘,` | More › Settings | Network cameras, security and general settings |

On the video, a white bracket is an unknown face and a green one a recognised face (shading to orange for weaker matches). A spark next to a name means that frame was just learned.

### Face history

Faces the app does not know are kept in the History tab with a picture, the camera and the time, so you can add someone to People after the fact: click **Add…**, type a name, and the person is enrolled from the views that were captured. Other history entries of the same person are named too. Network cameras log everyone who appears, known or not; this Mac's camera logs unknown faces only. The latest 300 entries are kept.

### Object filter

The Objects button opens a panel to turn detection on, set how sure the detector must be before a box is shown, and choose which of the 80 kinds of object to show. **Security** keeps people, vehicles, pets and bags only.

### Object tracking

Objects are followed from frame to frame, so a box does not flicker or vanish while the object is still in view:

- An object must be detected confidently to appear, but once it is tracked much weaker detections keep it.
- If the detector misses a tracked object entirely, its box is held in place and drawn dashed. The longer the object has been seen, the longer it is held, up to 8 seconds.
- An object at the edge of the picture and moving out is dropped within half a second; a moving object lost mid-picture is followed along its path briefly and let go after 1.5 seconds, so no empty box is left behind.
- The label is the one the detector has given the object most, so it does not flip between similar kinds.

On two live street cameras over 40 seconds, boxes that vanished and came back within 2 seconds went from 172 to 2 and from 54 to 0.

![One camera shown alone, with cars, a truck and people tracked](docs/images/object-tracking.jpg)

*One camera shown alone. Each box is a tracked object with its label and the detector's confidence.*

![The object filter panel open over the video](docs/images/object-filter.jpg)

*The object filter: turn detection on, set how sure it must be, and choose which kinds of object to show.*

## Network cameras

In Security mode, add IP cameras with **Add Camera** (in the toolbar, or the dashed tile in the grid). Pick the camera's make, type its address, user name and password, and FaceRec builds the stream address for Hikvision, Dahua, Amcrest, Reolink, TP-Link Tapo, Axis and Foscam cameras; or paste a full address. **Test Connection** shows the camera's picture before you add it. Cameras appear in a grid: click a tile to select it, double-click to show it alone, and hover for edit, switch-off and remove. Faces seen on any camera are recognised and learned the same way.

| Address | What it is |
|---|---|
| `rtsp://user:password@192.168.1.20:554/stream1` | RTSP camera, H.264 or H.265, decoded in hardware. `rtsps://` (TLS) also works |
| `https://example.com/live/stream.m3u8` | HLS stream, as used by most public webcam sites and cloud cameras. Runs several seconds behind live |
| `http://192.168.1.21/video.mjpg` | Motion-JPEG stream over HTTP |
| `http://192.168.1.22/snapshot.jpg` | Still-picture address, fetched about twice a second |

The make presets are the usual addresses for those brands; some models differ.

Network cameras do not have to be analysed fully live. When this Mac's camera is also being watched it has priority and is analysed at its full frame rate. Network cameras are analysed in the gaps: often when the Mac is keeping up, less often as load rises, and never less often than the limit in **Settings › General** (1 second by default). Their video keeps playing at full speed either way, and each tile shows its video rate and how many frames per second are being analysed.

### Trying it without a camera of your own

Public webcams work as test cameras. This one is a street in South Lake Tahoe, offered both ways:

```
rtsp://live6.brownrice.com:1935/communityinktahoesouth/communityinktahoesouth.stream
```

```
https://live6.brownrice.com:444/communityinktahoesouth/communityinktahoesouth.stream/main_playlist.m3u8
```

Many webcam sites embed an HLS stream; the `.m3u8` address in the page's player is what to paste. Cameras shown through YouTube cannot be used. These are other people's cameras, so use them for a quick test rather than leaving them connected.

RTSP is read over TCP only, so cameras that offer video only over UDP will not connect. Using a camera's lower-resolution stream keeps decoding cheap.

## Security mode

Choose **Security** at the top of the window to use FaceRec as a camera monitor. This Mac's own camera is switched off (no camera permission is needed) and the network cameras get the Mac's full attention.

- **History.** Everyone who appears on a network camera is logged in the History tab (`H`) with the time, the camera, a face picture and a snapshot of the scene. Click an entry to see the snapshot. The same person on the same camera is logged at most once every 2 minutes (unknown people: every 30 seconds).
- **Alerts.** Settings › Alerts can alert you when an unknown person appears, and optionally for people you have named: as a macOS notification, on your phone, or to your own automation (see below).
- **Stay awake.** The Mac is kept from sleeping while network cameras are being watched (can be turned off).
- **This Mac's camera too.** Settings › Security can add this Mac's own camera to the grid.

Closing the window quits the app and stops watching. Check the rules on camera recording and face recognition where you live, and tell people they are on camera.

## Alerts on your phone

Settings › Alerts chooses when to alert and where to send it. Each outside service is off until you turn it on, and has a **Send Test** button.

| Where | What you need | Notes |
|---|---|---|
| macOS notification | Nothing | Stays on this Mac |
| **ntfy** (phone push) | The free ntfy app on iPhone or Android | Press **Suggest** for a topic name, scan the code shown in Settings with the phone, then Send Test. Works with ntfy.sh or your own ntfy server |
| **Telegram** | A bot token from @BotFather and your chat ID | Send your bot a message first so it may write to you |
| **Webhook** | An address that accepts a POST | JSON with `app`, `event`, `known`, `name`, `camera`, `time`, `title`, `message`, `test`, and `image_jpeg_base64` when a picture is included. For Home Assistant, n8n, Zapier, IFTTT and similar |

Alerts sent through ntfy, Telegram or a webhook leave this Mac and go through that service, with a snapshot of the scene unless you turn pictures off. An ntfy topic works like a password: anyone who knows it can read the alerts. Tokens and addresses are kept in `alerts.json` in the app's data folder, readable only by your user account.

## Continuous learning

After a person is named once, the app keeps learning them:

- **Angles are filed separately.** Samples are sorted into 9 head-angle bins (left/centre/right turn by up/level/down tilt), 16 per bin. A new angle is never crowded out by more frontal frames. The grid next to each name in the People panel shows which angles are covered.
- **Confident matches refresh the samples.** A match of 72% or more that clearly beats every other person is stored if it shows something new, or replaces a stored near-duplicate if it is sharper or the stored one is over a week old.
- **New angles are learned through tracking.** When a tracked, confirmed face turns far enough that it is no longer recognised, the frame is stored if it is still close to something already known about that person and does not look like anyone else.
- **Naming enrols every angle seen so far.** While a face is unnamed, the tracker collects its varied views; pressing `A` stores all of them.
- **Safeguards.** A track must agree on a name 5 times before it can teach new angles, a different name has to win twice in a row before a track switches to it, and a track drops its name after 6 frames that look nothing like that person.

## Privacy

Video never leaves the Mac. The one exception is opt-in: if you turn on ntfy, Telegram or a webhook in Settings › Alerts, each alert (and its snapshot, unless you turn pictures off) is sent through that service. Everything is stored only in `~/Library/Application Support/FaceRec/`: `faces.json` holds the face embeddings, `avatars/` one small picture per person, and `cameras.json` the network camera addresses (including any passwords in them; the file is readable only by your user account), and `events/` the face history with its pictures and, for unknown faces, the captured views. Delete that folder to erase everything the app has learned.

## How it works

| Stage | How it runs |
|---|---|
| Camera | AVFoundation, mirrored, at the resolution and frame rate you pick |
| Network cameras | Native RTSP client with VideoToolbox hardware decoding; HLS through AVPlayer; Motion-JPEG and stills over HTTP |
| Video display | Metal, each frame drawn as it arrives, camera buffers wrapped as textures without copying |
| Face detection + landmarks | Vision |
| Face embedding | FaceNet (InceptionResnetV1, VGGFace2) on Core ML |
| Object detection | YOLOv8n on Core ML, followed by a Kalman tracker with two confidence thresholds |
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
| `FaceRec --stream-test <address> [seconds]` | Connects to a network camera, then reports frames received, picture size and faces found. Set `FACEREC_RTSP_DEBUG=1` to print the RTSP conversation |
| `FaceRec --object-test [address] [seconds]` | Runs the object tracker's simulated cases and, given a camera, counts box flicker with and without tracking |
| `FaceRec --alert-test [picture.jpg]` | Sends a sample alert through every outside service switched on in Settings › Alerts and prints each result |
| `FaceRec --update-test` | Runs one update check, download and install without the window. `FACEREC_UPDATE_FEED` can point it at a test release description; signatures are still checked |

## Licences

The app's code is under the Apache 2.0 licence in this repository. The downloadable app bundles two converted models with their own licences: FaceNet weights from [facenet-pytorch](https://github.com/timesler/facenet-pytorch) (MIT) and YOLOv8n from [Ultralytics](https://github.com/ultralytics/ultralytics) (AGPL-3.0).
