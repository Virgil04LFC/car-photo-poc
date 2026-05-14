import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'services/compositor_service.dart';
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
        ResolutionPreset.high,
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
              Text(_errorMessage!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center),
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
                  Text('Segmenting…',
                      style: TextStyle(color: Colors.white, fontSize: 18)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Result Screen ───────────────────────────────────────────────────────────

enum _ViewMode { original, cutout, composite }

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
  _ViewMode _mode = _ViewMode.composite;
  ShowroomBackground _selectedBg = ShowroomBackground.light;

  Uint8List? _compositeBytes;
  bool _compositing = false;
  bool _saving = false;

  final TransformationController _xController = TransformationController();

  // Small preview thumbnails for the background picker — generated once.
  late final Map<ShowroomBackground, Uint8List> _thumbs;

  @override
  void initState() {
    super.initState();
    _thumbs = {
      for (final bg in ShowroomBackground.values)
        bg: CompositorService.thumbnail(bg),
    };
    _buildComposite();
  }

  @override
  void dispose() {
    _xController.dispose();
    super.dispose();
  }

  // ── Compositing ─────────────────────────────────────────────────────────────

  Future<void> _buildComposite() async {
    setState(() {
      _compositing = true;
      _compositeBytes = null;
    });
    try {
      final bytes = await compute(
        runComposite,
        CompositeArgs(widget.segmentedBytes, _selectedBg),
      );
      if (mounted) setState(() => _compositeBytes = bytes);
    } catch (e) {
      if (mounted) _snack('Composite failed: $e');
    } finally {
      if (mounted) setState(() => _compositing = false);
    }
  }

  Future<void> _switchBackground(ShowroomBackground bg) async {
    if (bg == _selectedBg && _compositeBytes != null) return;
    _resetZoom();
    setState(() => _selectedBg = bg);
    await _buildComposite();
  }

  // ── Save ─────────────────────────────────────────────────────────────────────

  Future<void> _saveToGallery() async {
    if (_compositeBytes == null) return;
    setState(() => _saving = true);
    try {
      final name = 'car_${DateTime.now().millisecondsSinceEpoch}.png';
      await Gal.putImageBytes(_compositeBytes!, name: name);
      if (mounted) _snack('Saved to gallery ✓');
    } catch (e) {
      if (mounted) _snack('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  void _resetZoom() => _xController.value = Matrix4.identity();

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  String get _title => switch (_mode) {
        _ViewMode.original => 'Original',
        _ViewMode.cutout => 'Cutout',
        _ViewMode.composite => 'Composite',
      };

  Widget get _activeImage {
    switch (_mode) {
      case _ViewMode.original:
        return Image.file(widget.originalFile, fit: BoxFit.contain);
      case _ViewMode.cutout:
        return _CheckeredBackground(
          child: Image.memory(
            widget.segmentedBytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      case _ViewMode.composite:
        if (_compositing) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Building composite…',
                    style: TextStyle(color: Colors.white54)),
              ],
            ),
          );
        }
        if (_compositeBytes == null) {
          return const Center(
            child: Text('No composite',
                style: TextStyle(color: Colors.white38)),
          );
        }
        return Image.memory(
          _compositeBytes!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _mode == _ViewMode.composite && _compositeBytes != null && !_compositing;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(_title),
        centerTitle: true,
        actions: [
          // Save button — only when composite is ready
          if (canSave)
            _saving
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.save_alt),
                    tooltip: 'Save to gallery',
                    onPressed: _saveToGallery,
                  ),
          // Reset zoom
          IconButton(
            icon: const Icon(Icons.fit_screen),
            tooltip: 'Reset zoom',
            onPressed: _resetZoom,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Full-screen zoomable image ──────────────────────────────────
          Expanded(
            child: GestureDetector(
              onDoubleTap: _resetZoom,
              child: InteractiveViewer(
                transformationController: _xController,
                minScale: 0.5,
                maxScale: 8.0,
                child: Center(child: _activeImage),
              ),
            ),
          ),

          // ── Hint ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(
              'Pinch to zoom · Double-tap to reset',
              style: TextStyle(color: Colors.white30, fontSize: 11),
            ),
          ),

          // ── 3-way mode toggle ───────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                for (final mode in _ViewMode.values) ...[
                  if (mode.index > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _ModeButton(
                      label: switch (mode) {
                        _ViewMode.original => 'Original',
                        _ViewMode.cutout => 'Cutout',
                        _ViewMode.composite => 'Composite',
                      },
                      icon: switch (mode) {
                        _ViewMode.original => Icons.photo_camera,
                        _ViewMode.cutout => Icons.auto_fix_high,
                        _ViewMode.composite => Icons.layers,
                      },
                      selected: _mode == mode,
                      onTap: () {
                        _resetZoom();
                        setState(() => _mode = mode);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Background picker (composite mode only) ─────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: _mode == _ViewMode.composite
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Row(
                      children: [
                        for (final bg in ShowroomBackground.values) ...[
                          if (bg.index > 0) const SizedBox(width: 10),
                          Expanded(
                            child: _BgCard(
                              label: CompositorService.labels[bg]!,
                              thumbnail: _thumbs[bg]!,
                              selected: _selectedBg == bg,
                              onTap: () => _switchBackground(bg),
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // Safe area bottom
          SizedBox(height: 12 + MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

// ─── Mode Toggle Button ───────────────────────────────────────────────────────

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
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
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? Colors.blue.withOpacity(0.15)
              : Colors.white.withOpacity(0.05),
          border: Border.all(color: color, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Background Picker Card ───────────────────────────────────────────────────

class _BgCard extends StatelessWidget {
  final String label;
  final Uint8List thumbnail;
  final bool selected;
  final VoidCallback onTap;

  const _BgCard({
    required this.label,
    required this.thumbnail,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? Colors.blue : Colors.white24,
            width: selected ? 2.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            children: [
              // Background thumbnail
              Image.memory(
                thumbnail,
                width: double.infinity,
                height: 64,
                fit: BoxFit.cover,
              ),
              // Selected tick
              if (selected)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(Icons.check, color: Colors.white, size: 12),
                  ),
                ),
              // Label
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  color: Colors.black54,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Checkerboard Background (cutout view) ────────────────────────────────────

class _CheckeredBackground extends StatelessWidget {
  final Widget child;
  const _CheckeredBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _CheckerPainter(), child: child);
  }
}

class _CheckerPainter extends CustomPainter {
  static const _cell = 16.0;
  static const _light = Color(0xFFAAAAAA);
  static const _dark = Color(0xFF777777);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    for (var row = 0; row * _cell < size.height; row++) {
      for (var col = 0; col * _cell < size.width; col++) {
        p.color = (row + col).isEven ? _light : _dark;
        canvas.drawRect(
          Rect.fromLTWH(col * _cell, row * _cell, _cell, _cell),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter _) => false;
}
