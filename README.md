[한국어 README 보기](./README_kr.md)

# CheckerPose AR

CheckerPose AR is an Android app that estimates camera pose from a chessboard pattern and places a custom AR poster on top of the live camera view.  
The app combines Flutter for the UI, Chaquopy for the Android-Python bridge, and OpenCV for calibration, pose estimation, and tracking.

## Demo

### Screenshot

> TODO: Add a screenshot of the AR result here.

### Video

> TODO: Add a demo video link or GIF here.

## Overview

This project performs two main tasks:

1. Camera calibration using multiple chessboard images
2. Real-time camera pose estimation and AR object rendering

Instead of drawing the default example object, this app renders a vertical image billboard/poster in perspective.  
The user can switch between built-in poster images and also load a custom image from the gallery.

## Main Features

- Camera calibration from chessboard samples
- Persistent calibration loading from saved `calibration.json`
- Sample image saving under the app's pictures directory
- Preview and replacement of calibration samples one by one
- Real-time pose estimation using `solvePnP`
- AR billboard rendering with perspective transform
- Custom poster image / animated image support
- Hybrid runtime tracking:
  full detection, optical-flow corner tracking, ROI-based re-detection

## How It Works

### 1. Calibration

The app collects chessboard images and runs OpenCV camera calibration to estimate:

- intrinsic camera matrix `K`
- distortion coefficients `dist`

The result is saved to `calibration.json` and loaded automatically on the next launch if it matches the current camera.

### 2. Pose Estimation

For each incoming camera frame, the app estimates the camera pose relative to the chessboard.

The runtime pipeline is:

1. Detect the chessboard corners
2. Track the corners between frames using optical flow
3. Re-detect inside a local ROI when tracking quality drops
4. Compute pose with `cv.solvePnP`
5. Project a vertical AR plane with `cv.projectPoints`

This hybrid approach improves tracking responsiveness compared with performing full chessboard detection from scratch on every frame.

### 3. AR Object Rendering

The AR object in this project is a vertical poster-like plane standing on the chessboard.  
Flutter receives the projected 2D quad from Python and renders the image using a perspective transform in a `CustomPainter`.

## Tech Stack

- Flutter
- Dart
- Android
- Chaquopy
- Python 3.10
- OpenCV
- NumPy

## Project Structure

- `lib/main.dart`
  main Flutter UI, camera preview, calibration screen, sample management, and AR flow
- `lib/ar_painter.dart`
  perspective rendering of the poster image onto the projected quad
- `android/app/src/main/kotlin/com/example/checkerpose_ar/PythonBridge.kt`
  Android bridge between Flutter and Python
- `android/app/src/main/python/open_cv_bridge.py`
  calibration, pose estimation, corner tracking, and ROI re-detection logic
- `reference/camera_calibration.py`
  reference calibration workflow
- `reference/pose_estimation_chessboard.py`
  reference pose estimation workflow

## Running the App

### Requirements

- Flutter SDK installed
- Android device or emulator
- Local Python 3.10 installed for Chaquopy build

### Run

```bash
flutter pub get
flutter run
```

## Calibration Workflow

1. Open the calibration screen
2. Capture chessboard samples from different distances and angles
3. Review the saved samples
4. Replace bad samples individually if needed
5. Run calibration
6. Return to the main screen and start AR pose tracking

## Notes

- The calibration result is stored locally as `calibration.json`.
- Calibration sample images are stored in the app's pictures directory under `checkerboard_calibration`.
- The app is currently designed for Android because the Python/OpenCV pipeline is connected through Chaquopy.
