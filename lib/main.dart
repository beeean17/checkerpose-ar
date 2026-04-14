import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'ar_painter.dart';

// ---------------------------------------------------------------------------
// Top-level constants & shared utilities
// ---------------------------------------------------------------------------

const MethodChannel _pythonChannel = MethodChannel('checkerpose/python');
const int _requiredCalibrationSamples = 20;
const String _calibrationFolderName = 'checkerboard_calibration';

Future<Directory> _ensureCalibrationDirectory() async {
  final directories =
      await getExternalStorageDirectories(type: StorageDirectory.pictures);
  final baseDirectory = directories != null && directories.isNotEmpty
      ? directories.first
      : await getApplicationDocumentsDirectory();
  final calibrationDirectory = Directory(
    '${baseDirectory.path}${Platform.pathSeparator}$_calibrationFolderName',
  );
  if (!calibrationDirectory.existsSync()) {
    await calibrationDirectory.create(recursive: true);
  }
  return calibrationDirectory;
}

Future<void> _disposeCameraController(CameraController? controller) async {
  if (controller == null) {
    return;
  }
  try {
    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  } catch (_) {}
  try {
    await controller.dispose();
  } catch (_) {}
}

img.Image _framePacketToPngImage(_FramePacket packet) {
  var image = img.Image(width: packet.width, height: packet.height);
  for (var y = 0; y < packet.height; y++) {
    final rowOffset = y * packet.bytesPerRow;
    for (var x = 0; x < packet.width; x++) {
      final value = packet.bytes[rowOffset + x];
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  final rotation = packet.rotationDegrees % 360;
  if (rotation == 90) {
    image = img.copyRotate(image, angle: 90);
  } else if (rotation == 180) {
    image = img.copyRotate(image, angle: 180);
  } else if (rotation == 270) {
    image = img.copyRotate(image, angle: 270);
  }
  return image;
}

Uint8List _framePacketToPreviewBytes(_FramePacket packet) {
  var image = _framePacketToPngImage(packet);
  const maxDimension = 320;
  if (image.width > maxDimension || image.height > maxDimension) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxDimension : null,
      height: image.height > image.width ? maxDimension : null,
      interpolation: img.Interpolation.linear,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 78));
}

Uint8List? _encodedImageToPreviewBytes(Uint8List fileBytes) {
  final decoded = img.decodeImage(fileBytes);
  if (decoded == null) {
    return null;
  }

  var preview = decoded;
  const maxDimension = 320;
  if (preview.width > maxDimension || preview.height > maxDimension) {
    preview = img.copyResize(
      preview,
      width: preview.width >= preview.height ? maxDimension : null,
      height: preview.height > preview.width ? maxDimension : null,
      interpolation: img.Interpolation.linear,
    );
  }

  return Uint8List.fromList(img.encodeJpg(preview, quality: 78));
}

class _DecodeResult {
  const _DecodeResult({
    required this.grayBytes,
    required this.width,
    required this.height,
  });

  final Uint8List grayBytes;
  final int width;
  final int height;
}

_DecodeResult? _decodeAndGrayscaleImage(Uint8List fileBytes) {
  final decoded = img.decodeImage(fileBytes);
  if (decoded == null) {
    return null;
  }
  final width = decoded.width;
  final height = decoded.height;
  final grayBytes = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final pixel = decoded.getPixel(x, y);
      grayBytes[y * width + x] = img.getLuminanceRgb(
        pixel.r.toInt(),
        pixel.g.toInt(),
        pixel.b.toInt(),
      ).toInt();
    }
  }
  return _DecodeResult(
    grayBytes: grayBytes,
    width: width,
    height: height,
  );
}

Map<String, dynamic> _normalizeMap(Object? value) {
  final map = Map<dynamic, dynamic>.from(value as Map);
  return map.map(
    (key, nestedValue) => MapEntry(
      key.toString(),
      _normalizeValue(nestedValue),
    ),
  );
}

dynamic _normalizeValue(dynamic value) {
  if (value is Map) {
    return Map<dynamic, dynamic>.from(value).map(
      (key, nestedValue) => MapEntry(
        key.toString(),
        _normalizeValue(nestedValue),
      ),
    );
  }
  if (value is List) {
    return value.map(_normalizeValue).toList(growable: false);
  }
  return value;
}

Future<_CalibrationResult?> _loadCalibrationFromDisk(
  CameraDescription camera,
) async {
  try {
    final directory = await _ensureCalibrationDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}calibration.json',
    );
    if (!file.existsSync()) {
      return null;
    }
    final payload =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final calibration = _CalibrationResult.fromJson(payload);
    final cameraMatches =
        calibration.cameraName == null || calibration.cameraName == camera.name;
    final lensMatches = calibration.lensDirection == null ||
        calibration.lensDirection == camera.lensDirection.name;
    final orientationMatches = calibration.sensorOrientation == null ||
        calibration.sensorOrientation == camera.sensorOrientation;
    if (!cameraMatches || !lensMatches || !orientationMatches) {
      return null;
    }
    return calibration;
  } catch (_) {
    return null;
  }
}

List<double> _toDoubleList(dynamic value) {
  if (value is! List) {
    return const <double>[];
  }
  return value
      .map((entry) => (entry as num).toDouble())
      .toList(growable: false);
}

// ---------------------------------------------------------------------------
// App entry point
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(CheckerPoseApp(cameras: cameras));
}

class CheckerPoseApp extends StatelessWidget {
  const CheckerPoseApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CheckerPose AR',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF17C964),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF071014),
      ),
      home: CheckerPoseHomePage(cameras: cameras),
    );
  }
}

// ---------------------------------------------------------------------------
// Main Screen – camera preview + AR overlay + image picker
// ---------------------------------------------------------------------------

class CheckerPoseHomePage extends StatefulWidget {
  const CheckerPoseHomePage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<CheckerPoseHomePage> createState() => _CheckerPoseHomePageState();
}

class _CheckerPoseHomePageState extends State<CheckerPoseHomePage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  _FramePacket? _pendingPoseFrame;
  _CalibrationResult? _calibration;
  _PoseResult? _poseResult;
  final Map<String, ui.Image> _posterImages = <String, ui.Image>{};

  bool _cameraReady = false;
  bool _initializingCamera = false;
  Future<void>? _pendingCameraDisposal;
  bool _processingPose = false;
  String _statusMessage = '카메라를 준비하는 중입니다.';
  String _selectedPoster = 'sunrise';
  ui.Image? _customPosterImage;
  ui.Codec? _customPosterCodec;
  Timer? _gifTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_preparePosters());
    unawaited(_initializeCamera());
  }

  @override
  void dispose() {
    _gifTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeCameraController(_cameraController));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      if (state == AppLifecycleState.resumed) {
        unawaited(_initializeCamera());
      }
      return;
    }
    if (state == AppLifecycleState.inactive) {
      _cameraController = null;
      _cameraReady = false;
      _pendingPoseFrame = null;
      if (mounted) {
        setState(() {});
      }
      _pendingCameraDisposal = _disposeCameraController(controller);
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_initializeCamera());
    }
  }

  // --- Poster generation ---------------------------------------------------

  Future<void> _preparePosters() async {
    final posters = <String, ui.Image>{
      'sunrise': await _buildPoster(
        title: 'AR Poster',
        subtitle: 'CheckerPose',
        topColor: const Color(0xFFF97316),
        bottomColor: const Color(0xFF7C3AED),
      ),
      'mint': await _buildPoster(
        title: 'Pose Lab',
        subtitle: 'Real-time',
        topColor: const Color(0xFF00C2A8),
        bottomColor: const Color(0xFF064E3B),
      ),
      'mono': await _buildPoster(
        title: 'CV Homework',
        subtitle: 'solvePnP',
        topColor: const Color(0xFFF5F5F4),
        bottomColor: const Color(0xFF1C1917),
        darkText: true,
      ),
    };
    if (!mounted) {
      return;
    }
    setState(() {
      _posterImages
        ..clear()
        ..addAll(posters);
    });
  }

  // --- Camera & calibration loading ----------------------------------------

  Future<void> _initializeCamera() async {
    if (_initializingCamera) {
      return;
    }
    if (widget.cameras.isEmpty) {
      setState(() {
        _statusMessage = '사용 가능한 카메라가 없습니다.';
      });
      return;
    }
    _initializingCamera = true;
    try {
      final backCamera = widget.cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .isNotEmpty
          ? widget.cameras
              .firstWhere((c) => c.lensDirection == CameraLensDirection.back)
          : widget.cameras.first;

      final previousController = _cameraController;
      _cameraController = null;
      _cameraReady = false;
      
      if (_pendingCameraDisposal != null) {
        await _pendingCameraDisposal;
        _pendingCameraDisposal = null;
      }
      await _disposeCameraController(previousController);

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await controller.startImageStream(_onFrameAvailable);

      final calibration = await _loadCalibrationFromDisk(backCamera);

      if (!mounted) {
        await _disposeCameraController(controller);
        return;
      }

      setState(() {
        _cameraController = controller;
        _cameraReady = true;
        if (calibration != null) {
          _calibration = calibration;
        }
        _statusMessage = _calibration == null
            ? '저장된 Calibration이 없습니다. 메뉴에서 Calibration을 진행하세요.'
            : '저장된 Calibration을 불러왔습니다. AR을 시작합니다.';
      });
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraReady = false;
        _statusMessage = '카메라 초기화 실패: ${error.description ?? error.code}';
      });
    } finally {
      _initializingCamera = false;
    }
  }

  // --- Pose estimation (runs on every camera frame) ------------------------

  Future<void> _onFrameAvailable(CameraImage image) async {
    if (image.planes.isEmpty) {
      return;
    }
    final controller = _cameraController;
    if (controller == null) {
      return;
    }

    final packet = _FramePacket(
      bytes: Uint8List.fromList(image.planes.first.bytes),
      width: image.width,
      height: image.height,
      bytesPerRow: image.planes.first.bytesPerRow,
      rotationDegrees: controller.description.sensorOrientation,
    );
    _pendingPoseFrame = packet;

    final calibration = _calibration;
    if (calibration == null || _processingPose) {
      return;
    }

    unawaited(_processLatestPoseLoop());
  }

  Future<void> _processLatestPoseLoop() async {
    if (_processingPose) {
      return;
    }

    _processingPose = true;
    try {
      while (mounted) {
        final calibration = _calibration;
        final packet = _pendingPoseFrame;
        _pendingPoseFrame = null;

        if (calibration == null || packet == null) {
          break;
        }

        try {
          final result = await _pythonChannel.invokeMethod<Object?>(
            'getArPose',
            <String, Object?>{
              'frame': packet.toMap(),
              'calibration': calibration.toMap(),
              'boardCols': calibration.boardCols,
              'boardRows': calibration.boardRows,
              'squareSizeMm': calibration.squareSizeMm,
            },
          );

          if (!mounted) {
            return;
          }

          final map = _normalizeMap(result);
          setState(() {
            final nextPose = _PoseResult.fromMap(map);
            _poseResult = _poseResult == null
                ? nextPose
                : _poseResult!.stabilizedWith(nextPose);
            _statusMessage = _poseResult?.message ??
                '체커보드를 찾지 못했습니다. 프레임 안에 전체 패턴이 보이도록 맞춰주세요.';
          });
        } on PlatformException catch (error) {
          if (!mounted) {
            return;
          }
          setState(() {
            _statusMessage = error.message ?? error.code;
          });
          break;
        }

        if (_pendingPoseFrame == null) {
          break;
        }
      }
    } finally {
      _processingPose = false;
    }
  }

  // --- Navigation -----------------------------------------------------------

  Future<void> _navigateToCalibration() async {
    // Release the camera so CalibrationScreen can use it.
    final controller = _cameraController;
    _cameraController = null;
    _cameraReady = false;
    _pendingPoseFrame = null;
    setState(() {});
    await _disposeCameraController(controller);

    if (!mounted) {
      return;
    }

    final result = await Navigator.push<_CalibrationResult>(
      context,
      MaterialPageRoute<_CalibrationResult>(
        builder: (_) => _CalibrationScreen(cameras: widget.cameras),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        _calibration = result;
        _poseResult = null;
        _statusMessage = 'Calibration 완료. AR을 시작합니다.';
      });
    }

    // Re-initialise the camera on this screen.
    unawaited(_initializeCamera());
  }

  // --- Custom poster picking -----------------------------------------------

  Future<void> _pickCustomPoster() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) {
      return;
    }

    final bytes = await pickedFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    
    _gifTimer?.cancel();
    _gifTimer = null;

    if (codec.frameCount > 1) {
      _customPosterCodec = codec;
      _playNextGifFrame();
      setState(() {
        _statusMessage = '애니메이션 이미지를 AR 포스터로 설정했습니다.';
      });
    } else {
      final frame = await codec.getNextFrame();
      if (!mounted) {
        return;
      }
      setState(() {
        _customPosterImage = frame.image;
        _customPosterCodec = null;
        _statusMessage = '커스텀 이미지를 AR 포스터로 설정했습니다.';
      });
    }
  }

  void _playNextGifFrame() async {
    final codec = _customPosterCodec;
    if (codec == null || !mounted) {
      return;
    }

    final frame = await codec.getNextFrame();
    if (!mounted || _customPosterCodec != codec) {
      return;
    }

    setState(() {
      _customPosterImage = frame.image;
    });

    _gifTimer = Timer(frame.duration, _playNextGifFrame);
  }

  // --- Calibration reset (from menu) ---------------------------------------

  Future<void> _resetCalibration() async {
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Calibration 다시 하기'),
          content: const Text(
            '기존 calibration.json과 저장된 샘플 이미지를 지우고 다시 설정합니다.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('다시 하기'),
            ),
          ],
        );
      },
    );

    if (shouldReset != true) {
      return;
    }

    final directory = await _ensureCalibrationDirectory();
    if (directory.existsSync()) {
      for (final entity in directory.listSync()) {
        if (entity is File) {
          await entity.delete();
        }
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _calibration = null;
      _poseResult = null;
      _statusMessage =
          '기존 Calibration 데이터를 삭제했습니다. 메뉴에서 Calibration을 다시 진행하세요.';
    });
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final pose = _poseResult;
    final poster = _customPosterImage ?? _posterImages[_selectedPoster];

    return Scaffold(
      appBar: AppBar(
        title: const Text('CheckerPose AR'),
        actions: <Widget>[
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'calibration') {
                unawaited(_navigateToCalibration());
              } else if (value == 'recalibrate') {
                unawaited(_resetCalibration());
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'calibration',
                child: Text('Calibration 설정'),
              ),
              PopupMenuItem<String>(
                value: 'recalibrate',
                child: Text('Calibration 다시 하기'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // Camera preview fills most of the screen.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _PreviewPane(
                controller: controller,
                cameraReady: _cameraReady,
                poseResult: pose,
                poster: poster,
                statusMessage: _statusMessage,
              ),
            ),
          ),
          // Bottom bar: poster selector + image picker.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _customPosterImage != null
                          ? null
                          : _selectedPoster,
                      decoration: const InputDecoration(
                        labelText: 'Poster',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem(
                          value: 'sunrise',
                          child: Text('Sunrise'),
                        ),
                        DropdownMenuItem(
                          value: 'mint',
                          child: Text('Mint'),
                        ),
                        DropdownMenuItem(
                          value: 'mono',
                          child: Text('Mono'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _selectedPoster = value;
                          _customPosterImage = null;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _pickCustomPoster,
                    icon: const Icon(Icons.image),
                    label: const Text('이미지 선택'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Poster generator (unchanged) ----------------------------------------

  Future<ui.Image> _buildPoster({
    required String title,
    required String subtitle,
    required Color topColor,
    required Color bottomColor,
    bool darkText = false,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(640, 960);
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          <Color>[topColor, bottomColor],
        ),
    );

    canvas.drawCircle(
      const Offset(120, 140),
      90,
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );
    canvas.drawCircle(
      const Offset(540, 780),
      140,
      Paint()..color = Colors.black.withValues(alpha: 0.12),
    );

    final titlePainter = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color: darkText ? const Color(0xFF111827) : Colors.white,
          fontSize: 56,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 520);
    titlePainter.paint(canvas, const Offset(52, 80));

    final subtitlePainter = TextPainter(
      text: TextSpan(
        text: subtitle,
        style: TextStyle(
          color: darkText
              ? const Color(0xFF1F2937).withValues(alpha: 0.85)
              : Colors.white.withValues(alpha: 0.92),
          fontSize: 28,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 520);
    subtitlePainter.paint(canvas, const Offset(56, 168));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(54, 286, 530, 520),
        const Radius.circular(40),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.14),
    );

    final badgePainter = TextPainter(
      text: TextSpan(
        text: 'LIVE AR',
        style: TextStyle(
          color: darkText ? const Color(0xFF0F172A) : Colors.white,
          fontSize: 34,
          fontWeight: FontWeight.bold,
          letterSpacing: 3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    badgePainter.paint(canvas, const Offset(192, 508));

    final footerPainter = TextPainter(
      text: TextSpan(
        text: 'flutter + python + opencv',
        style: TextStyle(
          color: darkText
              ? const Color(0xFF0F172A).withValues(alpha: 0.7)
              : Colors.white.withValues(alpha: 0.85),
          fontSize: 24,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    footerPainter.paint(canvas, const Offset(144, 860));

    return recorder.endRecording().toImage(640, 960);
  }

}

// ---------------------------------------------------------------------------
// Calibration Screen – dedicated page for camera calibration
// ---------------------------------------------------------------------------

class _CalibrationScreen extends StatefulWidget {
  const _CalibrationScreen({required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<_CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<_CalibrationScreen>
    with WidgetsBindingObserver {
  final TextEditingController _boardColsController = TextEditingController(
    text: '10',
  );
  final TextEditingController _boardRowsController = TextEditingController(
    text: '7',
  );
  final TextEditingController _squareSizeController = TextEditingController(
    text: '25.0',
  );

  CameraController? _cameraController;
  _CalibrationResult? _calibration;
  final List<_CalibrationSample> _calibrationFrames = <_CalibrationSample>[];

  bool _cameraReady = false;
  bool _initializingCamera = false;
  Future<void>? _pendingCameraDisposal;
  bool _runningCalibration = false;
  bool _capturingSample = false;
  int? _selectedCalibrationSampleIndex;
  String _statusMessage = '카메라를 준비하는 중입니다.';
  String? _calibrationDirectoryPath;

  int get _boardCols => int.tryParse(_boardColsController.text.trim()) ?? 10;
  int get _boardRows => int.tryParse(_boardRowsController.text.trim()) ?? 7;
  double get _squareSizeMm =>
      double.tryParse(_squareSizeController.text.trim()) ?? 25.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeCameraController(_cameraController));
    _boardColsController.dispose();
    _boardRowsController.dispose();
    _squareSizeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      if (state == AppLifecycleState.resumed) {
        unawaited(_initializeCamera());
      }
      return;
    }
    if (state == AppLifecycleState.inactive) {
      _cameraController = null;
      _cameraReady = false;
      if (mounted) {
        setState(() {});
      }
      _pendingCameraDisposal = _disposeCameraController(controller);
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_initializeCamera());
    }
  }

  // --- Camera --------------------------------------------------------------

  Future<void> _initializeCamera() async {
    if (_initializingCamera) {
      return;
    }
    if (widget.cameras.isEmpty) {
      setState(() {
        _statusMessage = '사용 가능한 카메라가 없습니다.';
      });
      return;
    }
    _initializingCamera = true;
    try {
      final backCamera = widget.cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .isNotEmpty
          ? widget.cameras
              .firstWhere((c) => c.lensDirection == CameraLensDirection.back)
          : widget.cameras.first;

      final previousController = _cameraController;
      _cameraController = null;
      _cameraReady = false;
      
      if (_pendingCameraDisposal != null) {
        await _pendingCameraDisposal;
        _pendingCameraDisposal = null;
      }
      await _disposeCameraController(previousController);

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      final calibration = await _loadCalibrationFromDisk(backCamera);
      final savedSamples = await _loadSavedCalibrationSamples();

      if (!mounted) {
        await _disposeCameraController(controller);
        return;
      }

      setState(() {
        _cameraController = controller;
        _cameraReady = true;
        if (calibration != null) {
          _calibration = calibration;
          _boardColsController.text = calibration.boardCols.toString();
          _boardRowsController.text = calibration.boardRows.toString();
          _squareSizeController.text = calibration.squareSizeMm.toString();
        }
        if (savedSamples.isNotEmpty) {
          _calibrationFrames
            ..clear()
            ..addAll(savedSamples);
          _selectedCalibrationSampleIndex = 0;
        }
        _updateStatusMessage();
      });
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cameraReady = false;
        _statusMessage = '카메라 초기화 실패: ${error.description ?? error.code}';
      });
    } finally {
      _initializingCamera = false;
    }
  }

  void _updateStatusMessage() {
    if (_calibration != null) {
      _statusMessage =
          '저장된 calibration.json을 불러왔습니다. 바로 프리뷰와 AR을 시작합니다.';
    } else if (_calibrationFrames.isNotEmpty) {
      _statusMessage =
          '저장된 샘플 이미지 ${_calibrationFrames.length}장을 불러왔습니다. '
          '${_calibrationFrames.length < _requiredCalibrationSamples ? '나머지 ${_requiredCalibrationSamples - _calibrationFrames.length}장을 추가로 수집하세요.' : '샘플을 확인한 뒤 Run Calibration을 누르세요.'}';
    } else {
      _statusMessage =
          '저장된 calibration.json이 없습니다. 20장의 체커보드 이미지를 수집하세요.';
    }
  }

  // --- Board validation ----------------------------------------------------

  String? _validateBoardInputs() {
    if (_boardCols < 2) {
      return 'Board columns는 2 이상이어야 합니다.';
    }
    if (_boardRows < 2) {
      return 'Board rows는 2 이상이어야 합니다.';
    }
    if (_squareSizeMm <= 0) {
      return 'Square size는 0보다 커야 합니다.';
    }
    return null;
  }

  // --- Capture / gallery ---------------------------------------------------

  Future<void> _captureCalibrationFrame() async {
    final validationError = _validateBoardInputs();
    if (validationError != null) {
      _showSnackBar(validationError);
      return;
    }

    if (_runningCalibration || _capturingSample) {
      return;
    }

    if (_calibrationFrames.length >= _requiredCalibrationSamples) {
      _showSnackBar('이미 $_requiredCalibrationSamples장을 모두 수집했습니다.');
      return;
    }

    final nextIndex = _calibrationFrames.length + 1;
    setState(() {
      _capturingSample = true;
      _statusMessage = '고해상도 샘플을 촬영하는 중입니다.';
    });

    try {
      final stillBytes = await _captureStillImageBytes();
      if (stillBytes == null) {
        _showSnackBar('고해상도 샘플 촬영에 실패했습니다.');
        return;
      }

      final sample =
          await _buildCalibrationSampleFromEncodedImage(stillBytes, nextIndex);
      await _deleteCalibrationFileIfExists();

      if (!mounted) {
        return;
      }

      setState(() {
        _calibration = null;
        _calibrationFrames.add(sample);
        _selectedCalibrationSampleIndex = _calibrationFrames.length - 1;
        _statusMessage = _calibrationFrames.length == _requiredCalibrationSamples
            ? '20장 수집 완료. 샘플을 미리보고 수정한 뒤 Run Calibration을 누르세요.'
            : '캘리브레이션 샘플 $nextIndex/$_requiredCalibrationSamples 저장 완료: ${sample.filePath}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _capturingSample = false;
        });
      }
    }
  }

  Future<void> _pickImagesFromGallery() async {
    if (_runningCalibration) {
      return;
    }

    final remaining = _requiredCalibrationSamples - _calibrationFrames.length;
    if (remaining <= 0) {
      _showSnackBar('이미 $_requiredCalibrationSamples장을 모두 수집했습니다.');
      return;
    }

    final picker = ImagePicker();
    final pickedFiles = await picker.pickMultiImage();

    if (pickedFiles.isEmpty) {
      return;
    }

    final filesToProcess = pickedFiles.length > remaining
        ? pickedFiles.sublist(0, remaining)
        : pickedFiles;

    int addedCount = 0;
    await _deleteCalibrationFileIfExists();

    setState(() {
      _statusMessage = '선택한 이미지(${filesToProcess.length}장)를 변환하는 중입니다...';
    });

    for (final pickedFile in filesToProcess) {
      if (_calibrationFrames.length >= _requiredCalibrationSamples) {
        break;
      }

      try {
        final fileBytes = await pickedFile.readAsBytes();
        final nextIndex = _calibrationFrames.length + 1;
        final sample =
            await _buildCalibrationSampleFromEncodedImage(fileBytes, nextIndex);

        setState(() {
          _calibration = null;
          _calibrationFrames.add(sample);
          _selectedCalibrationSampleIndex = _calibrationFrames.length - 1;
        });

        addedCount++;
      } catch (_) {
        // Skip unreadable files.
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      if (addedCount > 0) {
        _statusMessage = _calibrationFrames.length == _requiredCalibrationSamples
            ? '20장 수집 완료. 샘플을 확인한 뒤 Run Calibration을 누르세요.'
            : '갤러리에서 $addedCount장 추가 완료. '
                '${_calibrationFrames.length}/$_requiredCalibrationSamples장 수집됨.';
      } else {
        _statusMessage = '선택한 이미지를 디코딩할 수 없습니다. jpg, png, gif 파일을 선택하세요.';
      }
    });
  }

  // --- Run calibration -----------------------------------------------------

  Future<void> _runCalibration() async {
    final validationError = _validateBoardInputs();
    if (validationError != null) {
      _showSnackBar(validationError);
      return;
    }

    if (_calibrationFrames.length < _requiredCalibrationSamples) {
      _showSnackBar(
        '캘리브레이션에는 $_requiredCalibrationSamples장의 체커보드 프레임이 필요합니다.',
      );
      return;
    }

    setState(() {
      _runningCalibration = true;
      _statusMessage = 'Python에서 카메라 캘리브레이션을 계산하는 중입니다.';
    });

    try {
      final result = await _pythonChannel.invokeMethod<Object?>(
        'calibrateCamera',
        <String, Object?>{
          'images': _calibrationFrames
              .map((sample) => sample.packet.toMap())
              .toList(growable: false),
          'boardCols': _boardCols,
          'boardRows': _boardRows,
          'squareSizeMm': _squareSizeMm,
        },
      );

      if (!mounted) {
        return;
      }

      final map = _normalizeMap(result);
      final calibration = _CalibrationResult.fromMap(
        map,
        cameraDescription: _cameraController?.description,
      );
      await _persistCalibration(calibration);
      setState(() {
        _calibration = calibration;
        _boardColsController.text = calibration.boardCols.toString();
        _boardRowsController.text = calibration.boardRows.toString();
        _squareSizeController.text = calibration.squareSizeMm.toString();
        _statusMessage =
            '캘리브레이션 완료. calibration.json 저장됨. '
            'RMS=${calibration.rms.toStringAsFixed(4)}, '
            '유효 이미지=${calibration.usedImages}장';
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = error.message ?? error.code;
      });
    } finally {
      if (mounted) {
        setState(() {
          _runningCalibration = false;
        });
      }
    }
  }

  // --- Sample management ---------------------------------------------------

  Future<void> _replaceSelectedCalibrationSample() async {
    final selectedIndex = _selectedCalibrationSampleIndex;
    if (selectedIndex == null ||
        selectedIndex < 0 ||
        selectedIndex >= _calibrationFrames.length) {
      _showSnackBar('먼저 수정할 샘플을 선택하세요.');
      return;
    }

    final validationError = _validateBoardInputs();
    if (validationError != null) {
      _showSnackBar(validationError);
      return;
    }

    if (_runningCalibration || _capturingSample) {
      return;
    }

    setState(() {
      _capturingSample = true;
      _statusMessage = '선택한 샘플을 고해상도 사진으로 교체하는 중입니다.';
    });

    try {
      final stillBytes = await _captureStillImageBytes();
      if (stillBytes == null) {
        _showSnackBar('고해상도 샘플 촬영에 실패했습니다.');
        return;
      }

      final sample = await _buildCalibrationSampleFromEncodedImage(
        stillBytes,
        selectedIndex + 1,
      );
      await _deleteCalibrationFileIfExists();

      if (!mounted) {
        return;
      }

      setState(() {
        _calibrationFrames[selectedIndex] = sample;
        _calibration = null;
        _statusMessage = '샘플 ${selectedIndex + 1}번을 고해상도 사진으로 교체했습니다.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _capturingSample = false;
        });
      }
    }
  }

  Future<void> _clearCalibrationSamples() async {
    final directory = await _ensureCalibrationDirectory();
    if (directory.existsSync()) {
      for (final entity in directory.listSync()) {
        if (entity is File && entity.path.endsWith('.png')) {
          await entity.delete();
        }
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _calibrationFrames.clear();
      _selectedCalibrationSampleIndex = null;
      _statusMessage = '샘플 이미지를 비웠습니다. 다시 프레임을 수집하세요.';
    });
  }

  Future<void> _startCalibrationFromScratch() async {
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('처음부터 새로 시작'),
          content: const Text(
            '기존 calibration.json과 지금까지 저장한 샘플을 모두 지우고 처음부터 다시 시작합니다.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('새로 시작'),
            ),
          ],
        );
      },
    );

    if (shouldReset != true) {
      return;
    }

    final directory = await _ensureCalibrationDirectory();
    if (directory.existsSync()) {
      for (final entity in directory.listSync()) {
        if (entity is File) {
          await entity.delete();
        }
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _calibrationFrames.clear();
      _selectedCalibrationSampleIndex = null;
      _calibration = null;
      _statusMessage =
          '기존 calibration 데이터를 삭제했습니다. 다시 20장의 샘플을 수집하세요.';
    });
  }

  // --- File helpers --------------------------------------------------------

  Future<File> _saveCalibrationSample(_FramePacket packet, int index) async {
    final directory = await _ensureCalibrationDirectory();
    _calibrationDirectoryPath = directory.path;
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'sample_${index.toString().padLeft(2, '0')}.png',
    );
    final image = _framePacketToPngImage(packet);
    await file.writeAsBytes(img.encodePng(image), flush: true);
    return file;
  }

  Future<_CalibrationSample> _buildCalibrationSampleFromEncodedImage(
    Uint8List encodedBytes,
    int index,
  ) async {
    final result = await compute(_decodeAndGrayscaleImage, encodedBytes);
    if (result == null) {
      throw StateError('이미지를 디코딩할 수 없습니다.');
    }

    final packet = _FramePacket(
      bytes: result.grayBytes,
      width: result.width,
      height: result.height,
      bytesPerRow: result.width,
      rotationDegrees: 0,
    );
    final savedFile = await _saveCalibrationSample(packet.clone(), index);

    return _CalibrationSample(
      packet: packet,
      previewBytes:
          _encodedImageToPreviewBytes(encodedBytes) ??
          _framePacketToPreviewBytes(packet),
      filePath: savedFile.path,
    );
  }

  Future<Uint8List?> _captureStillImageBytes() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return null;
    }

    XFile? capturedFile;
    try {
      capturedFile = await controller.takePicture();
      final bytes = await capturedFile.readAsBytes();
      return bytes;
    } on CameraException {
      return null;
    } finally {
      if (capturedFile != null) {
        try {
          final tempFile = File(capturedFile.path);
          if (tempFile.existsSync()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _deleteCalibrationFileIfExists() async {
    final directory = await _ensureCalibrationDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}calibration.json',
    );
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<void> _persistCalibration(_CalibrationResult calibration) async {
    final directory = await _ensureCalibrationDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}calibration.json',
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(calibration.toJson()),
      flush: true,
    );
  }

  Future<List<_CalibrationSample>> _loadSavedCalibrationSamples() async {
    try {
      final directory = await _ensureCalibrationDirectory();
      _calibrationDirectoryPath = directory.path;
      if (!directory.existsSync()) {
        return const <_CalibrationSample>[];
      }

      final samples = <_CalibrationSample>[];
      for (var i = 1; i <= _requiredCalibrationSamples; i++) {
        final fileName = 'sample_${i.toString().padLeft(2, '0')}.png';
        final file = File(
          '${directory.path}${Platform.pathSeparator}$fileName',
        );
        if (!file.existsSync()) {
          continue;
        }

        final pngBytes = await file.readAsBytes();
        final decoded = img.decodePng(pngBytes);
        if (decoded == null) {
          continue;
        }

        final width = decoded.width;
        final height = decoded.height;
        final grayBytes = Uint8List(width * height);
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final pixel = decoded.getPixel(x, y);
            grayBytes[y * width + x] = pixel.r.toInt();
          }
        }

        final packet = _FramePacket(
          bytes: grayBytes,
          width: width,
          height: height,
          bytesPerRow: width,
          rotationDegrees: 0,
        );

        var preview = decoded;
        const maxDimension = 320;
        if (preview.width > maxDimension || preview.height > maxDimension) {
          preview = img.copyResize(
            preview,
            width: preview.width >= preview.height ? maxDimension : null,
            height: preview.height > preview.width ? maxDimension : null,
            interpolation: img.Interpolation.linear,
          );
        }
        final previewBytes =
            Uint8List.fromList(img.encodeJpg(preview, quality: 78));

        samples.add(_CalibrationSample(
          packet: packet,
          previewBytes: previewBytes,
          filePath: file.path,
        ));
      }
      return samples;
    } catch (_) {
      return const <_CalibrationSample>[];
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final calibrationReady = _calibration != null;
    final samplesRemaining = (_requiredCalibrationSamples -
            _calibrationFrames.length)
        .clamp(0, _requiredCalibrationSamples);
    final selectedSample = _selectedCalibrationSampleIndex != null &&
            _selectedCalibrationSampleIndex! >= 0 &&
            _selectedCalibrationSampleIndex! < _calibrationFrames.length
        ? _calibrationFrames[_selectedCalibrationSampleIndex!]
        : null;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final previewHeight = (screenHeight * 0.34).clamp(220.0, 320.0).toDouble();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pop(_calibration);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Calibration'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_calibration),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            // Camera preview for live capture.
            if (_cameraReady &&
                _cameraController != null &&
                _cameraController!.value.isInitialized)
              Builder(
                builder: (context) {
                  final previewSize = _cameraController!.value.previewSize;
                  final previewWidth = previewSize?.height ?? 720.0;
                  final previewInnerHeight = previewSize?.width ??
                      previewWidth * _cameraController!.value.aspectRatio;

                  return ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: previewHeight,
                      width: double.infinity,
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: previewWidth,
                          height: previewInnerHeight,
                          child: CameraPreview(_cameraController!),
                        ),
                      ),
                    ),
                  );
                },
              )
            else
              Container(
                height: previewHeight,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Center(child: CircularProgressIndicator()),
              ),
            const SizedBox(height: 12),

            // Status message.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_statusMessage),
              ),
            ),
            const SizedBox(height: 12),

            // Board parameters.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Board 설정',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _boardColsController,
                      decoration: const InputDecoration(
                        labelText: 'Board columns (default 10)',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _boardRowsController,
                      decoration: const InputDecoration(
                        labelText: 'Board rows (default 7)',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _squareSizeController,
                      decoration: const InputDecoration(
                        labelText: 'Square size in mm',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Sample controls.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Samples: ${_calibrationFrames.length}/$_requiredCalibrationSamples',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (_calibrationDirectoryPath != null) ...<Widget>[
                      const SizedBox(height: 8),
                      SelectableText(
                        'Storage: $_calibrationDirectoryPath',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text('Remaining captures: $samplesRemaining'),
                    const SizedBox(height: 16),

                    // Action buttons row 1: Add Sample + Gallery + Run
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: FilledButton(
                            onPressed: _cameraReady &&
                                    !_runningCalibration &&
                                    !_capturingSample &&
                                    (!calibrationReady ||
                                        _calibrationFrames.isNotEmpty) &&
                                    _calibrationFrames.length <
                                        _requiredCalibrationSamples
                                ? _captureCalibrationFrame
                                : null,
                            child: const Text('Add Sample'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: !_runningCalibration &&
                                    !_capturingSample &&
                                    _calibrationFrames.length <
                                        _requiredCalibrationSamples
                                ? () => unawaited(_pickImagesFromGallery())
                                : null,
                            child: const Text('갤러리에서 추가'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: _runningCalibration ||
                                    _capturingSample ||
                                    _calibrationFrames.length <
                                        _requiredCalibrationSamples
                                ? null
                                : _runCalibration,
                            child: _runningCalibration
                                ? const Text('Calibrating...')
                                : const Text('Run'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Action buttons row 2: Replace + Clear
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            onPressed: !_runningCalibration &&
                                    !_capturingSample &&
                                    selectedSample != null &&
                                    _cameraReady
                                ? () => unawaited(
                                    _replaceSelectedCalibrationSample())
                                : null,
                            child: const Text('선택 샘플 교체'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: !_runningCalibration &&
                                    !_capturingSample &&
                                    _calibrationFrames.isNotEmpty
                                ? () => unawaited(_clearCalibrationSamples())
                                : null,
                            child: const Text('샘플만 비우기'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: !_runningCalibration
                              && !_capturingSample
                          ? () => unawaited(_startCalibrationFromScratch())
                          : null,
                      child: const Text('처음부터 새로 시작'),
                    ),
                  ],
                ),
              ),
            ),

            // Selected sample preview.
            if (selectedSample != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                '선택된 샘플: ${_selectedCalibrationSampleIndex! + 1}/$_requiredCalibrationSamples',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.memory(
                    selectedSample.previewBytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ],

            // Sample grid.
            if (_calibrationFrames.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                '샘플 미리보기',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _calibrationFrames.length,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemBuilder: (context, index) {
                  final sample = _calibrationFrames[index];
                  final selected =
                      index == _selectedCalibrationSampleIndex;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedCalibrationSampleIndex = index;
                      });
                    },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white.withValues(alpha: 0.18),
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        children: <Widget>[
                          Expanded(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(11),
                              ),
                              child: Image.memory(
                                sample.previewBytes,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            child: Text(
                              '${index + 1}',
                              style:
                                  Theme.of(context).textTheme.labelLarge,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],

            // Calibration result info.
            if (_calibration != null) ...<Widget>[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'RMS: ${_calibration!.rms.toStringAsFixed(4)}\n'
                    'K: ${_calibration!.k.map((v) => v.toStringAsFixed(2)).join(', ')}\n'
                    'dist: ${_calibration!.dist.map((v) => v.toStringAsFixed(4)).join(', ')}\n'
                    'savedAt: ${_calibration!.savedAt ?? '-'}',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preview Pane – camera preview with AR overlay
// ---------------------------------------------------------------------------

class _PreviewPane extends StatelessWidget {
  const _PreviewPane({
    required this.controller,
    required this.cameraReady,
    required this.poseResult,
    required this.poster,
    required this.statusMessage,
  });

  final CameraController? controller;
  final bool cameraReady;
  final _PoseResult? poseResult;
  final ui.Image? poster;
  final String statusMessage;

  @override
  Widget build(BuildContext context) {
    if (!cameraReady || controller == null || !controller!.value.isInitialized) {
      return const Card(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final previewSize = controller!.value.previewSize;
    final previewAspectRatio = previewSize == null
        ? 1 / controller!.value.aspectRatio
        : previewSize.height / previewSize.width;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: previewAspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CameraPreview(controller!),
            CustomPaint(
              painter: ArPainter(
                posterImage: poster,
                normalizedQuad: poseResult?.quad ?? const <Offset>[],
                showPoster: poseResult?.found == true,
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              right: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    statusMessage,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
            if (poseResult?.found == true)
              Positioned(
                left: 12,
                bottom: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text(
                      'tvec: ${poseResult!.tvec.map((v) => v.toStringAsFixed(2)).join(', ')}',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

class _FramePacket {
  const _FramePacket({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.rotationDegrees,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final int rotationDegrees;

  _FramePacket clone() {
    return _FramePacket(
      bytes: Uint8List.fromList(bytes),
      width: width,
      height: height,
      bytesPerRow: bytesPerRow,
      rotationDegrees: rotationDegrees,
    );
  }

  Map<String, Object> toMap() {
    return <String, Object>{
      'bytes': bytes,
      'width': width,
      'height': height,
      'bytesPerRow': bytesPerRow,
      'rotationDegrees': rotationDegrees,
    };
  }
}

class _CalibrationSample {
  const _CalibrationSample({
    required this.packet,
    required this.previewBytes,
    required this.filePath,
  });

  final _FramePacket packet;
  final Uint8List previewBytes;
  final String filePath;
}

class _CalibrationResult {
  const _CalibrationResult({
    required this.k,
    required this.dist,
    required this.rms,
    required this.usedImages,
    required this.boardCols,
    required this.boardRows,
    required this.squareSizeMm,
    this.cameraName,
    this.lensDirection,
    this.sensorOrientation,
    this.savedAt,
  });

  final List<double> k;
  final List<double> dist;
  final double rms;
  final int usedImages;
  final int boardCols;
  final int boardRows;
  final double squareSizeMm;
  final String? cameraName;
  final String? lensDirection;
  final int? sensorOrientation;
  final String? savedAt;

  factory _CalibrationResult.fromMap(
    Map<String, dynamic> map, {
    CameraDescription? cameraDescription,
  }) {
    return _CalibrationResult(
      k: _toDoubleList(map['K']),
      dist: _toDoubleList(map['dist']),
      rms: (map['rms'] as num).toDouble(),
      usedImages: (map['usedImages'] as num).toInt(),
      boardCols: (map['boardCols'] as num?)?.toInt() ?? 10,
      boardRows: (map['boardRows'] as num?)?.toInt() ?? 7,
      squareSizeMm: (map['squareSizeMm'] as num?)?.toDouble() ?? 25.0,
      cameraName: cameraDescription?.name,
      lensDirection: cameraDescription?.lensDirection.name,
      sensorOrientation: cameraDescription?.sensorOrientation,
      savedAt: DateTime.now().toIso8601String(),
    );
  }

  Map<String, Object> toMap() {
    return <String, Object>{
      'K': k,
      'dist': dist,
    };
  }

  factory _CalibrationResult.fromJson(Map<String, dynamic> json) {
    return _CalibrationResult(
      k: _toDoubleList(json['K']),
      dist: _toDoubleList(json['dist']),
      rms: (json['rms'] as num?)?.toDouble() ?? 0,
      usedImages: (json['usedImages'] as num?)?.toInt() ?? 0,
      boardCols: (json['boardCols'] as num?)?.toInt() ?? 10,
      boardRows: (json['boardRows'] as num?)?.toInt() ?? 7,
      squareSizeMm: (json['squareSizeMm'] as num?)?.toDouble() ?? 25.0,
      cameraName: json['cameraName'] as String?,
      lensDirection: json['lensDirection'] as String?,
      sensorOrientation: (json['sensorOrientation'] as num?)?.toInt(),
      savedAt: json['savedAt'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'K': k,
      'dist': dist,
      'rms': rms,
      'usedImages': usedImages,
      'boardCols': boardCols,
      'boardRows': boardRows,
      'squareSizeMm': squareSizeMm,
      'cameraName': cameraName,
      'lensDirection': lensDirection,
      'sensorOrientation': sensorOrientation,
      'savedAt': savedAt,
    };
  }
}

class _PoseResult {
  const _PoseResult({
    required this.found,
    required this.message,
    required this.quad,
    required this.rvec,
    required this.tvec,
    required this.cameraPosition,
  });

  final bool found;
  final String message;
  final List<Offset> quad;
  final List<double> rvec;
  final List<double> tvec;
  final List<double> cameraPosition;

  static const double _vectorSmoothingAlpha = 0.22;

  factory _PoseResult.fromMap(Map<String, dynamic> map) {
    final quad = <Offset>[];
    final quadPayload = map['quad'];
    if (quadPayload is List) {
      for (final point in quadPayload) {
        if (point is Map<String, dynamic>) {
          quad.add(
            Offset(
              (point['x'] as num).toDouble(),
              (point['y'] as num).toDouble(),
            ),
          );
        }
      }
    }

    return _PoseResult(
      found: map['found'] as bool? ?? false,
      message: map['message'] as String? ?? '',
      quad: quad,
      rvec: _toDoubleList(map['rvec']),
      tvec: _toDoubleList(map['tvec']),
      cameraPosition: _toDoubleList(map['cameraPosition']),
    );
  }

  _PoseResult stabilizedWith(_PoseResult next) {
    if (!found || !next.found) {
      return next;
    }
    if (quad.length != 4 || next.quad.length != 4) {
      return next;
    }

    return _PoseResult(
      found: true,
      message: next.message,
      quad: next.quad,
      rvec: _lerpDoubleList(rvec, next.rvec, _vectorSmoothingAlpha),
      tvec: _lerpDoubleList(tvec, next.tvec, _vectorSmoothingAlpha),
      cameraPosition: _lerpDoubleList(
        cameraPosition,
        next.cameraPosition,
        _vectorSmoothingAlpha,
      ),
    );
  }

  static List<double> _lerpDoubleList(
    List<double> previous,
    List<double> next,
    double alpha,
  ) {
    if (previous.length != next.length) {
      return next;
    }
    return List<double>.generate(previous.length, (index) {
      return previous[index] + (next[index] - previous[index]) * alpha;
    }, growable: false);
  }
}
