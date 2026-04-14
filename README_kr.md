# CheckerPose AR

[English README](./README.md)

CheckerPose AR는 체커보드 패턴을 기준으로 카메라의 자세를 추정하고, 실시간 카메라 화면 위에 AR 포스터를 표시하는 Android 앱입니다.  
이 프로젝트는 Flutter UI, Android-Python 연동을 위한 Chaquopy, 그리고 캘리브레이션/자세 추정/트래킹을 위한 OpenCV를 함께 사용합니다.

## 데모

### 스크린샷

<img src="example/example_picture.jpg" alt="예시 스크린샷" width="320" />

### 영상

데모 영상 파일: [example_video.mp4](example/example_video.mp4)

## 예시 자료

- 데모 스크린샷: [example/example_picture.jpg](example/example_picture.jpg)
- 데모 영상: [example/example_video.mp4](example/example_video.mp4)
- 캘리브레이션 결과 예시 JSON: [example/calibration_example.json](example/calibration_example.json)

참고로 `example/` 아래의 JSON 파일은 저장 예시를 보여주기 위한 레포지토리용 파일입니다.  
실제 Android 기기에서는 캘리브레이션 결과가 아래 경로에 저장됩니다.

`/storage/emulated/0/Android/data/com.example.checkerpose_ar/files/Pictures/checkerboard_calibration/calibration.json`

## 프로젝트 개요

이 프로젝트는 크게 두 가지를 수행합니다.

1. 체커보드 이미지를 이용한 카메라 캘리브레이션
2. 실시간 카메라 자세 추정 및 AR 물체 렌더링

기본 예제처럼 단순한 물체를 그리는 대신, 이 프로젝트에서는 체커보드 위에 수직으로 서 있는 포스터 형태의 AR 이미지를 표시합니다.  
사용자는 기본 제공 포스터를 선택할 수 있고, 갤러리에서 커스텀 이미지를 불러와 AR 물체로 사용할 수도 있습니다.

## 주요 기능

- 체커보드 샘플 기반 카메라 캘리브레이션
- 저장된 `calibration.json` 자동 로드
- 앱의 pictures 디렉터리에 캘리브레이션 샘플 이미지 저장
- 캘리브레이션 샘플 미리보기 및 개별 교체
- `solvePnP` 기반 실시간 자세 추정
- 원근 변환을 이용한 AR 포스터 렌더링
- 커스텀 이미지 / 애니메이션 이미지 지원
- 하이브리드 실시간 추적
  - 전체 검출
  - optical flow 기반 코너 추적
  - ROI 기반 재검출

## 동작 방식

### 1. 캘리브레이션

앱은 여러 장의 체커보드 이미지를 수집한 뒤 OpenCV 카메라 캘리브레이션을 수행하여 아래 값을 추정합니다.

- 내부 파라미터 행렬 `K`
- 왜곡 계수 `dist`

결과는 `calibration.json`으로 저장되며, 다음 실행 시 현재 카메라와 일치하면 자동으로 다시 불러옵니다.

### 2. 자세 추정

각 카메라 프레임에 대해 체커보드를 기준으로 카메라 자세를 추정합니다.

런타임 파이프라인은 다음과 같습니다.

1. 체커보드 코너 검출
2. 프레임 간 optical flow로 코너 추적
3. 추적 품질이 떨어지면 지역 ROI에서 재검출
4. `cv.solvePnP`로 자세 계산
5. `cv.projectPoints`로 수직 AR 평면 투영

이 구조는 매 프레임마다 전체 체커보드를 처음부터 다시 찾는 방식보다 더 나은 실시간 추종성을 제공합니다.

### 3. AR 물체 렌더링

이 프로젝트의 AR 물체는 체커보드 위에 세워진 포스터 형태의 수직 평면입니다.  
Flutter는 Python이 반환한 2D 사각형 좌표를 받아 `CustomPainter`에서 원근 변환을 적용해 이미지를 렌더링합니다.

## 사용 기술

- Flutter
- Dart
- Android
- Chaquopy
- Python 3.10
- OpenCV
- NumPy

## 프로젝트 구조

- `lib/main.dart`
  - Flutter 메인 UI, 카메라 프리뷰, 캘리브레이션 화면, 샘플 관리, AR 동작
- `lib/ar_painter.dart`
  - 투영된 사각형 위에 포스터 이미지를 원근감 있게 렌더링
- `android/app/src/main/kotlin/com/example/checkerpose_ar/PythonBridge.kt`
  - Flutter와 Python 사이의 Android 브리지
- `android/app/src/main/python/open_cv_bridge.py`
  - 캘리브레이션, 자세 추정, 코너 추적, ROI 재검출 로직
- `reference/camera_calibration.py`
  - 캘리브레이션 참고 코드
- `reference/pose_estimation_chessboard.py`
  - 자세 추정 참고 코드

## 핵심 코드 설명

- `reference/camera_calibration.py`
  - OpenCV 체커보드 캘리브레이션의 기본 흐름을 참고했습니다.
  - 코너 검출, `cornerSubPix` 보정, `calibrateCamera`를 통한 `K`와 `dist` 계산이 핵심입니다.
- `reference/pose_estimation_chessboard.py`
  - 체커보드 기반 자세 추정의 기본 흐름을 참고했습니다.
  - 코너 검출 후 `solvePnP`로 자세를 구하고, `projectPoints`로 3D 점을 2D 화면으로 다시 투영합니다.
- `android/app/src/main/python/open_cv_bridge.py`
  - 실제 핵심 로직이 들어 있는 파일입니다.
  - 위 reference들의 캘리브레이션/자세 추정 구조를 앱용으로 옮긴 뒤, optical flow 추적과 ROI 재검출을 추가해 실시간성을 높였습니다.
- `android/app/src/main/kotlin/com/example/checkerpose_ar/PythonBridge.kt`
  - Flutter와 Python 사이를 연결하는 Android 브리지입니다.
  - 카메라 프레임과 calibration 데이터를 Python으로 보내고, 결과를 다시 Flutter로 돌려줍니다.
- `lib/main.dart`
  - 앱 동작의 중심입니다.
  - 캘리브레이션 샘플 수집, Python 캘리브레이션 실행, 프레임별 자세 추정 요청, 렌더링 데이터 전달을 담당합니다.
- `lib/ar_painter.dart`
  - 렌더링 핵심입니다.
  - Python이 반환한 2D 사각형 위에 포스터 이미지를 원근 변환으로 입혀 AR 결과를 그립니다.

## 실행 방법

### 요구 사항

- Flutter SDK 설치
- Android 기기 또는 에뮬레이터
- Chaquopy 빌드를 위한 로컬 Python 3.10 설치

### 실행

```bash
flutter pub get
flutter run
```

## 캘리브레이션 절차

1. 캘리브레이션 화면으로 이동
2. 거리와 각도를 바꿔가며 체커보드 샘플 수집
3. 저장된 샘플 미리보기 확인
4. 품질이 좋지 않은 샘플은 개별 교체
5. 캘리브레이션 실행
6. 메인 화면으로 돌아와 AR 자세 추적 시작

## 참고 사항

- 캘리브레이션 결과는 로컬 `calibration.json`으로 저장됩니다.
- 캘리브레이션 샘플 이미지는 앱의 pictures 디렉터리 아래 `checkerboard_calibration` 폴더에 저장됩니다.
- 실제 기기 저장 경로 예시:
  `/storage/emulated/0/Android/data/com.example.checkerpose_ar/files/Pictures/checkerboard_calibration/calibration.json`
- Python/OpenCV 파이프라인이 Chaquopy를 통해 연결되어 있으므로 현재 구현은 Android 중심으로 구성되어 있습니다.
