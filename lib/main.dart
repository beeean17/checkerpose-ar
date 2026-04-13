import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'ar_painter.dart';

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

class CheckerPoseHomePage extends StatefulWidget {
  const CheckerPoseHomePage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<CheckerPoseHomePage> createState() => _CheckerPoseHomePageState();
}

class _CheckerPoseHomePageState extends State<CheckerPoseHomePage>
    with WidgetsBindingObserver {
  static const MethodChannel _pythonChannel = MethodChannel('checkerpose/python');
  static const int _requiredCalibrationSamples = 20;
  static const String _calibrationFolderName = 'checkerboard_calibration';

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
  _FramePacket? _latestFrame;
  _CalibrationResult? _calibration;
  _PoseResult? _poseResult;
  final List<_CalibrationSample> _calibrationFrames = <_CalibrationSample>[];
  final Map<String, ui.Image> _posterImages = <String, ui.Image>{};

  bool _cameraReady = false;
  bool _initializingCamera = false;
  bool _processingPose = false;
  bool _runningCalibration = false;
  bool _loadingSavedCalibration = false;
  int? _selectedCalibrationSampleIndex;
  String _statusMessage = '카메라를 준비하는 중입니다.';
  String _selectedPoster = 'sunrise';
  String? _calibrationDirectoryPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_preparePosters());
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
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _cameraController = null;
      _cameraReady = false;
      if (mounted) {
        setState(() {});
      }
      unawaited(_disposeCameraController(controller));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_initializeCamera());
    }
  }

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
      final backCamera =
          widget.cameras.where((camera) => camera.lensDirection == CameraLensDirection.back).isNotEmpty
          ? widget.cameras.firstWhere(
              (camera) => camera.lensDirection == CameraLensDirection.back,
            )
          : widget.cameras.first;

      final previousController = _cameraController;
      _cameraController = null;
      _cameraReady = false;
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

      final calibration = await _loadSavedCalibrationIfAvailable(backCamera);
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
        if (_calibration != null) {
          _statusMessage =
              '저장된 calibration.json을 불러왔습니다. 바로 프리뷰와 AR을 시작합니다.';
        } else if (_calibrationFrames.isNotEmpty) {
          _statusMessage =
              '저장된 샘플 이미지 ${_calibrationFrames.length}장을 불러왔습니다. '
              '${_calibrationFrames.length < _requiredCalibrationSamples
                  ? '나머지 ${_requiredCalibrationSamples - _calibrationFrames.length}장을 추가로 수집하세요.'
                  : '샘플을 확인한 뒤 Run Calibration을 누르세요.'}';
        } else {
          _statusMessage =
              '저장된 calibration.json이 없습니다. 20장의 체커보드 이미지를 수집하세요.';
        }
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
    _latestFrame = packet;

    final calibration = _calibration;
    if (calibration == null || _processingPose) {
      return;
    }

    final validationError = _validateBoardInputs();
    if (validationError != null) {
      if (mounted && _statusMessage != validationError) {
        setState(() {
          _statusMessage = validationError;
        });
      }
      return;
    }

    _processingPose = true;
    try {
      final result = await _pythonChannel.invokeMethod<Object?>(
        'getArPose',
        <String, Object?>{
          'frame': packet.toMap(),
          'calibration': calibration.toMap(),
          'boardCols': _boardCols,
          'boardRows': _boardRows,
          'squareSizeMm': _squareSizeMm,
        },
      );

      if (!mounted) {
        return;
      }

      final map = _normalizeMap(result);
      setState(() {
        _poseResult = _PoseResult.fromMap(map);
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
    } finally {
      _processingPose = false;
    }
  }

  Future<void> _captureCalibrationFrame() async {
    final latestFrame = _latestFrame;
    if (latestFrame == null) {
      _showSnackBar('아직 카메라 프레임이 준비되지 않았습니다.');
      return;
    }

    final validationError = _validateBoardInputs();
    if (validationError != null) {
      _showSnackBar(validationError);
      return;
    }

    if (_runningCalibration) {
      return;
    }

    if (_calibrationFrames.length >= _requiredCalibrationSamples) {
      _showSnackBar('이미 $_requiredCalibrationSamples장을 모두 수집했습니다.');
      return;
    }

    final nextIndex = _calibrationFrames.length + 1;
    final sample = await _buildCalibrationSample(latestFrame, nextIndex);
    await _deleteCalibrationFileIfExists();

    setState(() {
      _calibration = null;
      _poseResult = null;
      _calibrationFrames.add(sample);
      _selectedCalibrationSampleIndex = _calibrationFrames.length - 1;
      _statusMessage = _calibrationFrames.length == _requiredCalibrationSamples
          ? '20장 수집 완료. 샘플을 미리보고 수정한 뒤 Run Calibration을 누르세요.'
          : '캘리브레이션 샘플 $nextIndex/$_requiredCalibrationSamples 저장 완료: ${sample.filePath}';
    });
  }

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

  Future<void> _replaceSelectedCalibrationSample() async {
    final selectedIndex = _selectedCalibrationSampleIndex;
    final latestFrame = _latestFrame;
    if (selectedIndex == null ||
        selectedIndex < 0 ||
        selectedIndex >= _calibrationFrames.length) {
      _showSnackBar('먼저 수정할 샘플을 선택하세요.');
      return;
    }
    if (latestFrame == null) {
      _showSnackBar('아직 카메라 프레임이 준비되지 않았습니다.');
      return;
    }

    final validationError = _validateBoardInputs();
    if (validationError != null) {
      _showSnackBar(validationError);
      return;
    }

    final sample = await _buildCalibrationSample(latestFrame, selectedIndex + 1);
    await _deleteCalibrationFileIfExists();

    if (!mounted) {
      return;
    }

    setState(() {
      _calibrationFrames[selectedIndex] = sample;
      _calibration = null;
      _poseResult = null;
      _statusMessage = '샘플 ${selectedIndex + 1}번을 현재 프레임으로 교체했습니다.';
    });
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
      _poseResult = null;
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
            '기존 calibration.json과 지금까지 저장한 샘플 20장을 모두 지우고 처음부터 다시 시작합니다.',
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

    await _performCalibrationReset();
  }

  Future<void> _resetCalibration() async {
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Calibration 다시 하기'),
          content: const Text(
            '기존 calibration.json과 저장된 샘플 이미지를 지우고 다시 20장을 수집합니다.',
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

    await _performCalibrationReset();
  }

  Future<void> _performCalibrationReset() async {

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
      _poseResult = null;
      _statusMessage =
          '기존 calibration 데이터를 삭제했습니다. 다시 20장의 샘플을 수집하세요.';
    });
  }

  int get _boardCols => int.tryParse(_boardColsController.text.trim()) ?? 10;
  int get _boardRows => int.tryParse(_boardRowsController.text.trim()) ?? 7;
  double get _squareSizeMm =>
      double.tryParse(_squareSizeController.text.trim()) ?? 25.0;

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

  Future<void> _disposeCameraController(CameraController? controller) async {
    if (controller == null) {
      return;
    }

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // Ignore lifecycle races while the app is backgrounding or resuming.
    }

    try {
      await controller.dispose();
    } catch (_) {
      // Ignore lifecycle races while the app is backgrounding or resuming.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    final pose = _poseResult;
    final poster = _posterImages[_selectedPoster];

    return Scaffold(
      appBar: AppBar(
        title: const Text('CheckerPose AR'),
        actions: <Widget>[
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'recalibrate') {
                unawaited(_resetCalibration());
              }
            },
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'recalibrate',
                child: Text('Calibration 다시 하기'),
              ),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1080;

            final previewPane = _PreviewPane(
              controller: controller,
              cameraReady: _cameraReady,
              poseResult: pose,
              poster: poster,
              statusMessage: _statusMessage,
            );

            final controlPane = _buildControlPane(context);

            if (wide) {
              return Row(
                children: <Widget>[
                  Expanded(flex: 7, child: previewPane),
                  const SizedBox(width: 16),
                  SizedBox(width: 360, child: controlPane),
                ],
              );
            }

            return Column(
              children: <Widget>[
                Expanded(flex: 6, child: previewPane),
                const SizedBox(height: 16),
                Expanded(flex: 5, child: controlPane),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildControlPane(BuildContext context) {
    final calibration = _calibration;
    final pose = _poseResult;
    final calibrationReady = calibration != null;
    final samplesRemaining =
        (_requiredCalibrationSamples - _calibrationFrames.length).clamp(0, _requiredCalibrationSamples);
    final selectedSample = _selectedCalibrationSampleIndex != null &&
            _selectedCalibrationSampleIndex! >= 0 &&
            _selectedCalibrationSampleIndex! < _calibrationFrames.length
        ? _calibrationFrames[_selectedCalibrationSampleIndex!]
        : null;

    return ListView(
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Calibration',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  calibrationReady
                      ? '저장된 calibration.json이 로드되어 있습니다. 새 샘플로 다시 맞추려면 아래에서 처음부터 새로 시작하세요.'
                      : '저장된 calibration.json이 없어서 캘리브레이션 모드입니다. 20장을 모은 뒤 미리보고 개별 수정할 수 있습니다.',
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
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 12),
                Text(
                  'Saved samples: ${_calibrationFrames.length}/$_requiredCalibrationSamples',
                  style: Theme.of(context).textTheme.bodyLarge,
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
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton(
                        onPressed: _cameraReady &&
                                !_runningCalibration &&
                                (!calibrationReady || _calibrationFrames.isNotEmpty) &&
                                _calibrationFrames.length < _requiredCalibrationSamples
                            ? _captureCalibrationFrame
                            : null,
                        child: const Text('Add Sample'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _runningCalibration ||
                                _calibrationFrames.length < _requiredCalibrationSamples
                            ? null
                            : _runCalibration,
                        child: _runningCalibration
                            ? const Text('Calibrating...')
                            : const Text('Run Calibration'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: !_runningCalibration &&
                                selectedSample != null &&
                                _cameraReady
                            ? () => unawaited(_replaceSelectedCalibrationSample())
                            : null,
                        child: const Text('선택 샘플 교체'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: !_runningCalibration &&
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
                      ? () => unawaited(_startCalibrationFromScratch())
                      : null,
                  child: const Text('처음부터 새로 시작'),
                ),
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
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.8,
                    ),
                    itemBuilder: (context, index) {
                      final sample = _calibrationFrames[index];
                      final selected = index == _selectedCalibrationSampleIndex;
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
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
                if (calibration != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    'RMS: ${calibration.rms.toStringAsFixed(4)}\n'
                    'K: ${calibration.k.map((value) => value.toStringAsFixed(2)).join(', ')}\n'
                    'dist: ${calibration.dist.map((value) => value.toStringAsFixed(4)).join(', ')}\n'
                    'savedAt: ${calibration.savedAt ?? '-'}',
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'AR Overlay',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedPoster,
                  decoration: const InputDecoration(labelText: 'Poster image'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'sunrise', child: Text('Sunrise Poster')),
                    DropdownMenuItem(value: 'mint', child: Text('Mint Poster')),
                    DropdownMenuItem(value: 'mono', child: Text('Mono Poster')),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _selectedPoster = value;
                    });
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  pose == null || !pose.found
                      ? calibrationReady
                          ? '체커보드를 찾으면 여기에서 tvec와 카메라 위치가 갱신됩니다.'
                          : '캘리브레이션이 끝나면 여기에서 실시간 tvec와 카메라 위치가 갱신됩니다.'
                      : 'tvec: ${pose.tvec.map((value) => value.toStringAsFixed(2)).join(', ')}\n'
                          'camera XYZ: ${pose.cameraPosition.map((value) => value.toStringAsFixed(2)).join(', ')}',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

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
    _calibrationDirectoryPath = calibrationDirectory.path;
    return calibrationDirectory;
  }

  Future<File> _saveCalibrationSample(_FramePacket packet, int index) async {
    final directory = await _ensureCalibrationDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'sample_${index.toString().padLeft(2, '0')}.png',
    );
    final image = _framePacketToPngImage(packet);
    await file.writeAsBytes(img.encodePng(image), flush: true);
    return file;
  }

  Future<_CalibrationSample> _buildCalibrationSample(
    _FramePacket packet,
    int index,
  ) async {
    final clonedPacket = packet.clone();
    final savedFile = await _saveCalibrationSample(clonedPacket, index);
    return _CalibrationSample(
      packet: clonedPacket,
      previewBytes: _framePacketToPreviewBytes(clonedPacket),
      filePath: savedFile.path,
    );
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

  /// Scans the calibration directory for existing sample PNG images
  /// (sample_01.png ~ sample_20.png) and returns them as [_CalibrationSample]
  /// objects so the user can review or modify them without re-capturing.
  Future<List<_CalibrationSample>> _loadSavedCalibrationSamples() async {
    try {
      final directory = await _ensureCalibrationDirectory();
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

        // Reconstruct a grayscale _FramePacket from the decoded image.
        // The saved PNG was already rotated, so rotationDegrees is 0.
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

        // Build a small JPEG preview from the loaded image.
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

  Future<_CalibrationResult?> _loadSavedCalibrationIfAvailable(
    CameraDescription camera,
  ) async {
    if (_loadingSavedCalibration) {
      return null;
    }

    _loadingSavedCalibration = true;
    try {
      final directory = await _ensureCalibrationDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}calibration.json',
      );
      if (!file.existsSync()) {
        return null;
      }

      final payload = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final calibration = _CalibrationResult.fromJson(payload);
      final cameraMatches =
          calibration.cameraName == null || calibration.cameraName == camera.name;
      final lensMatches =
          calibration.lensDirection == null ||
          calibration.lensDirection == camera.lensDirection.name;
      final orientationMatches =
          calibration.sensorOrientation == null ||
          calibration.sensorOrientation == camera.sensorOrientation;
      if (!cameraMatches || !lensMatches || !orientationMatches) {
        return null;
      }
      return calibration;
    } catch (_) {
      return null;
    } finally {
      _loadingSavedCalibration = false;
    }
  }

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

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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
}

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
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text(
                      'tvec: ${poseResult!.tvec.map((value) => value.toStringAsFixed(2)).join(', ')}',
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
}

List<double> _toDoubleList(dynamic value) {
  if (value is! List) {
    return const <double>[];
  }
  return value.map((entry) => (entry as num).toDouble()).toList(growable: false);
}
