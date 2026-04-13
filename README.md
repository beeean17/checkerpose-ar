# CheckerPose AR

`CheckerPose AR`는 Flutter 카메라 프리뷰 위에 Python/OpenCV로 계산한 체커보드 자세를 올려서, 이미지가 보드 위에 수직으로 서 있는 것처럼 보이게 만드는 Android 앱이다.

## 구현 설명
- 프론트엔드는 Flutter `camera` 패키지로 카메라 프리뷰와 실시간 프레임 스트림을 받는다.
- 안드로이드 네이티브 레이어는 Chaquopy를 통해 Python 모듈 `open_cv_bridge.py`를 호출한다.
- `calibrate_camera`는 `reference/camera_calibration.py`의 흐름을 그대로 따라가며, 선택된 체커보드 프레임들에서 `cv.calibrateCamera`를 수행해 `K`와 `dist`를 계산한다.
- `get_ar_pose`는 `reference/pose_estimation_chessboard.py`의 흐름을 따라 `cv.findChessboardCorners`와 `cv.solvePnP`를 수행하고, 큐브 대신 세워진 직사각형 평면의 네 꼭짓점을 `cv.projectPoints`로 투영한다.
- Flutter `CustomPainter`는 Python이 반환한 4개 정규화 좌표에 원근 변환을 적용해 포스터 이미지를 그린다.
- 화면 좌측 상단과 하단에는 실시간 상태 메시지와 `tvec`가 표시되어 자세 획득을 확인할 수 있다.

## 데모 영상 촬영 팁
- 캘리브레이션용 프레임은 최소 8장 이상 확보하고, 거리와 각도를 계속 바꿔가며 수집한다.
- 체커보드가 프레임 가장자리까지 치우치지 않게 하고, 내부 코너가 모두 선명하게 보이도록 유지한다.
- AR 데모 구간에서는 보드가 화면의 절반 이상 차지하도록 유지하면 포즈가 더 안정적이다.
- 제출 영상에는 `tvec`가 보이도록 함께 녹화해서 단순 렌더링이 아니라 실시간 자세 추정임을 보여주는 것이 좋다.

## Android 설정
- Flutter: `camera`
- Python backend: Chaquopy
- Python packages: `numpy`, `opencv-python-headless`
- Build machine requirement: `python3.10` installed locally, because the currently available Chaquopy Android OpenCV wheels are `cp310`.

## 실행 순서
1. 앱 실행 후 체커보드를 카메라에 비춘다.
2. `Add Sample` 버튼으로 캘리브레이션 프레임을 여러 장 저장한다.
3. `Run Calibration` 버튼을 눌러 내부 파라미터를 계산한다.
4. 캘리브레이션이 완료되면 동일한 체커보드를 비췄을 때 AR 포스터가 서 있는 것처럼 표시된다.

## 참고 파일
- `reference/camera_calibration.py`
- `reference/pose_estimation_chessboard.py`
- `android/app/src/main/python/open_cv_bridge.py`
- `lib/main.dart`
- `lib/ar_painter.dart`
