import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'services/segmentation_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.camera.request();
  await Permission.storage.request();
  runApp(const CarPhotoPOC());
}

class CarPhotoPOC extends StatelessWidget {
  const CarPhotoPOC({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Car Photo POC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const CameraScreen(),
    );
  }
}

// ─── Camera Screen ───────────────────────────────────────────────────────────

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraReady = false;
  bool _isProcessing = false;
  String? _errorMessage;
  final SegmentationService _segmentationService = SegmentationService();
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() => _errorMessage = 'No camera found');
        return;
      }
      final backCamera = _cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );
      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high, // Higher res for edge quality assessment
        enableAudio: false,
      );
      await _cameraController!.initialize();
      setState(() => _isCameraReady = true);
    } catch (e) {
      setState(() => _errorMessage = 'Camera error: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 100,
    );
    if (picked == null || !mounted) return;
    await _runSegmentation(File(picked.path));
  }

  Future<void> _captureAndSegment() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    final XFile imageFile = await _cameraController!.takePicture();
    await _runSegmentation(File(imageFile.path));
  }

  Future<void> _runSegmentation(File file) async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });
    try {
      final segmentedBytes = await _segmentationService.segmentCarImage(file);
      if (segmentedBytes != null && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ResultScreen(
              originalFile: file,
              segmentedBytes: segmentedBytes,
            ),
          ),
        );
      } else {
        setState(() => _errorMessage = 'Segmentation returned no result');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Processing failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _segmentationService.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Car Photo POC'),
        centerTitle: true,
        backgroundColor: Colors.black,
      ),
      body: _buildBody(),
      floatingActionButton: _isCameraReady && !_isProcessing
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  FloatingActionButton.extended(
                    heroTag: 'gallery',
                    onPressed: _pickFromGallery,
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Gallery'),
                    backgroundColor: Colors.white12,
                    foregroundColor: Colors.white,
                  ),
                  FloatingActionButton.large(
                    heroTag: 'camera',
                    onPressed: _captureAndSegment,
                    child: const Icon(Icons.camera_alt),
                  ),
                ],
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => setState(() => _errorMessage = null),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (!_isCameraReady) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Positioned.fill(child: CameraPreview(_cameraController!)),
        if (_isProcessing)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    'Segmenting…',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Result Screen ───────────────────────────────────────────────────────────

class ResultScreen extends StatefulWidget {
  final File originalFile;
  final Uint8List segmentedBytes;

  const ResultScreen({
    super.key,
    required this.originalFile,
    required this.segmentedBytes,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  bool _showSegmented = true;
  final TransformationController _transformController = TransformationController();

  void _resetZoom() => _transformController.value = Matrix4.identity();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(_showSegmented ? 'Segmented Result' : 'Original Photo'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.fit_screen),
            tooltip: 'Reset zoom',
            onPressed: _resetZoom,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Full-screen zoomable image ──
          Expanded(
            child: GestureDetector(
              onDoubleTap: _resetZoom,
              child: InteractiveViewer(
                transformationController: _transformController,
                minScale: 0.5,
                maxScale: 8.0,
                child: Center(
                  child: _showSegmented
                      ? _CheckeredBackground(
                          child: Image.memory(
                            widget.segmentedBytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        )
                      : Image.file(
                          widget.originalFile,
                          fit: BoxFit.contain,
                        ),
                ),
              ),
            ),
          ),

          // ── Hint text ──
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Pinch to zoom · Double-tap to reset',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),

          // ── Toggle bar ──
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _ToggleButton(
                      label: 'Original',
                      icon: Icons.photo_camera,
                      selected: !_showSegmented,
                      onTap: () {
                        _resetZoom();
                        setState(() => _showSegmented = false);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ToggleButton(
                      label: 'Segmented',
                      icon: Icons.auto_fix_high,
                      selected: _showSegmented,
                      onTap: () {
                        _resetZoom();
                        setState(() => _showSegmented = true);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Toggle Button ───────────────────────────────────────────────────────────

class _ToggleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ToggleButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.blue : Colors.white38;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: selected ? Colors.blue.withOpacity(0.15) : Colors.white.withOpacity(0.05),
          border: Border.all(color: color, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Checkerboard Background ─────────────────────────────────────────────────
// Shows transparent areas clearly instead of rendering them black.

class _CheckeredBackground extends StatelessWidget {
  final Widget child;
  const _CheckeredBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CheckerPainter(),
      child: child,
    );
  }
}

class _CheckerPainter extends CustomPainter {
  static const _cellSize = 16.0;
  static const _light = Color(0xFFAAAAAA);
  static const _dark = Color(0xFF777777);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var row = 0; row * _cellSize < size.height; row++) {
      for (var col = 0; col * _cellSize < size.width; col++) {
        paint.color = (row + col).isEven ? _light : _dark;
        canvas.drawRect(
          Rect.fromLTWH(col * _cellSize, row * _cellSize, _cellSize, _cellSize),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => false;
}
