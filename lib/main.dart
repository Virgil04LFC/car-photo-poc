// dart:developer log() goes to DevTools stream, not terminal — use debugPrint instead
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';

// ─── Perf timing ──────────────────────────────────────────────────────────────

class _PerfLog {
  final _sw = Stopwatch()..start();
  final _marks = <String, int>{};

  void mark(String label) => _marks[label] = _sw.elapsedMilliseconds;

  void dump() {
    final entries = _marks.entries.toList();
    final parts = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final prev = i == 0 ? 0 : entries[i - 1].value;
      final delta = entries[i].value - prev;
      parts.add('${entries[i].key}=+${delta}ms');
    }
    debugPrint('[PERF] ${parts.join(' ')} | total=${_sw.elapsedMilliseconds}ms');
  }

  int get totalMs => _sw.elapsedMilliseconds;
}

// ─── Resize helper (top-level — required for compute()) ──────────────────────

class _ResizeArgs {
  final Uint8List bytes;
  final int maxLongEdge;
  final int quality;
  const _ResizeArgs(this.bytes, this.maxLongEdge, this.quality);
}

Uint8List _resizeForUpload(_ResizeArgs args) {
  final decoded = img.decodeImage(args.bytes);
  if (decoded == null) return args.bytes;

  final w = decoded.width;
  final h = decoded.height;
  final longEdge = w > h ? w : h;

  img.Image source = decoded;
  if (longEdge > args.maxLongEdge) {
    final scale = args.maxLongEdge / longEdge;
    source = img.copyResize(
      decoded,
      width: (w * scale).round(),
      height: (h * scale).round(),
      interpolation: img.Interpolation.linear,
    );
  }

  return Uint8List.fromList(img.encodeJpg(source, quality: args.quality));
}

// ─── App ─────────────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.camera.request();
  runApp(const CarPhotoPOC());
}

class CarPhotoPOC extends StatelessWidget {
  const CarPhotoPOC({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Car Photo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const CameraScreen(),
    );
  }
}

// ─── Camera Screen ────────────────────────────────────────────────────────────

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
  String _statusMessage = '';
  String? _errorMessage;
  String _selectedBackgroundId = kDefaultBackgroundId;
  final ImagePicker _imagePicker = ImagePicker();

  // Retry support — remember last input so error screen can re-process
  File? _lastFile;
  bool _lastFromCamera = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() => _errorMessage = 'No camera found');
        return;
      }
      final back = _cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );
      _cameraController = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      setState(() => _isCameraReady = true);
    } catch (e) {
      setState(() => _errorMessage = 'Camera error: $e');
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  // ── Input sources ──────────────────────────────────────────────────────────

  Future<void> _pickFromGallery() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 100,
    );
    if (picked == null || !mounted) return;
    await _processWithBackend(File(picked.path), fromCamera: false);
  }

  Future<void> _capture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    final xfile = await _cameraController!.takePicture();
    await _processWithBackend(File(xfile.path), fromCamera: true);
  }

  // ── Backend processing ─────────────────────────────────────────────────────

  Future<void> _processWithBackend(File file, {required bool fromCamera}) async {
    // Remember for retry
    _lastFile = file;
    _lastFromCamera = fromCamera;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Resizing…';
      _errorMessage = null;
    });

    final perf = _PerfLog();

    try {
      // 1. Read source file
      final originalBytes = await file.readAsBytes();
      perf.mark('read');

      // 2. Resize on background isolate (pure-Dart image pkg — may be slow)
      final uploadBytes = await compute(
        _resizeForUpload,
        _ResizeArgs(originalBytes, kMaxLongEdgePx, kUploadJpegQuality),
      );
      perf.mark('resize');

      if (!mounted) return;
      setState(() => _statusMessage = 'Uploading…');

      // 3. POST multipart to backend
      final uri = Uri.parse('$kBackendBaseUrl/process');
      final request = http.MultipartRequest('POST', uri);
      request.fields['background_id'] = _selectedBackgroundId;
      request.files.add(
        http.MultipartFile.fromBytes(
          'image',
          uploadBytes,
          filename: 'car.jpg',
        ),
      );

      setState(() => _statusMessage = 'Processing…');

      final streamed = await request.send().timeout(const Duration(seconds: 90));
      perf.mark('upload_headers');

      final response = await http.Response.fromStream(streamed);
      perf.mark('response_body');

      if (!mounted) return;

      if (response.statusCode != 200) {
        final body = response.body;
        final excerpt = body.substring(0, min(200, body.length));
        throw Exception('Server error ${response.statusCode}: $excerpt');
      }

      // 4. Parse timing headers from backend
      final backendMs = int.tryParse(
            response.headers['x-processing-time-ms'] ?? '',
          ) ??
          0;
      final resizeServerMs = int.tryParse(
            response.headers['x-resize-time-ms'] ?? '',
          ) ??
          0;
      final photoroomMs = int.tryParse(
            response.headers['x-photoroom-time-ms'] ?? '',
          ) ??
          0;

      // 5. Navigate to result
      final resultPng = response.bodyBytes;
      perf.dump();

      debugPrint(
        '[PERF] backend total=${backendMs}ms '
        '(server_resize=${resizeServerMs}ms photoroom=${photoroomMs}ms) '
        '| phone total=${perf.totalMs}ms',
      );

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            originalFile: file,
            resultBytes: resultPng,
            fromCamera: fromCamera,
            totalMs: perf.totalMs,
            backendMs: backendMs,
          ),
        ),
      );
    } on Exception catch (e) {
      if (mounted) setState(() => _errorMessage = _friendlyError(e));
    } finally {
      if (mounted) setState(() {
        _isProcessing = false;
        _statusMessage = '';
      });
    }
  }

  String _friendlyError(Exception e) {
    final msg = e.toString();
    if (msg.contains('SocketException') || msg.contains('Connection refused')) {
      return 'Cannot reach server.\nCheck backend URL in config.dart.';
    }
    if (msg.contains('TimeoutException')) {
      return 'Processing timed out — try again.';
    }
    if (msg.contains('Server error 502')) {
      return 'Background service error — try again.';
    }
    if (msg.contains('Server error 504')) {
      return 'Processing timed out on the server — try again.';
    }
    return 'Processing failed:\n$msg';
  }

  // ── Background picker ──────────────────────────────────────────────────────

  void _showBackgroundPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _BackgroundPickerSheet(
        selectedId: _selectedBackgroundId,
        onSelect: (id) {
          setState(() => _selectedBackgroundId = id);
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

  BackgroundOption get _selectedBackground =>
      kBackgrounds.firstWhere((b) => b.id == _selectedBackgroundId);

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Car Photo'),
        centerTitle: true,
        backgroundColor: Colors.black,
      ),
      body: _buildBody(),
      floatingActionButton: _isCameraReady && !_isProcessing
          ? _buildFab()
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildFab() {
    final bg = _selectedBackground;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Background selector chip
          GestureDetector(
            onTap: _showBackgroundPicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: bg.color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white38),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    bg.name,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.expand_more, color: Colors.white54, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Camera + Gallery buttons
          Row(
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
                onPressed: _capture,
                child: const Icon(Icons.camera_alt),
              ),
            ],
          ),
        ],
      ),
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
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Retry re-processes the same image — no need to recapture
                  if (_lastFile != null)
                    ElevatedButton.icon(
                      onPressed: () => _processWithBackend(
                        _lastFile!,
                        fromCamera: _lastFromCamera,
                      ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  if (_lastFile != null) const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => setState(() => _errorMessage = null),
                    child: const Text('Dismiss'),
                  ),
                ],
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
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Background Picker Sheet ──────────────────────────────────────────────────

class _BackgroundPickerSheet extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onSelect;

  const _BackgroundPickerSheet({
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Choose Background',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: kBackgrounds.map((bg) {
              final selected = bg.id == selectedId;
              return GestureDetector(
                onTap: () => onSelect(bg.id),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: bg.color,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected ? Colors.blue : Colors.white24,
                          width: selected ? 3 : 1,
                        ),
                      ),
                      child: selected
                          ? const Center(
                              child: Icon(Icons.check, color: Colors.blue, size: 28),
                            )
                          : null,
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: 72,
                      child: Text(
                        bg.name,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white60,
                          fontSize: 11,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom),
      ],
    );
  }
}

// ─── Result Screen ────────────────────────────────────────────────────────────

enum _ViewMode { original, result }

class ResultScreen extends StatefulWidget {
  final File originalFile;
  final Uint8List resultBytes;
  final bool fromCamera;
  final int totalMs;    // phone-side total (read + resize + upload + download)
  final int backendMs;  // server-side total (resize + Photoroom)

  const ResultScreen({
    super.key,
    required this.originalFile,
    required this.resultBytes,
    required this.fromCamera,
    this.totalMs = 0,
    this.backendMs = 0,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  _ViewMode _mode = _ViewMode.result;
  bool _saving = false;
  final TransformationController _xController = TransformationController();

  @override
  void dispose() {
    _xController.dispose();
    super.dispose();
  }

  void _resetZoom() => _xController.value = Matrix4.identity();

  // ── Save to gallery ────────────────────────────────────────────────────────

  Future<void> _saveToGallery() async {
    setState(() => _saving = true);
    try {
      final name = 'car_${DateTime.now().millisecondsSinceEpoch}.png';
      await Gal.putImageBytes(widget.resultBytes, name: name);

      // Clean up temp camera file after successful save
      if (widget.fromCamera) {
        try {
          await widget.originalFile.delete();
        } catch (_) {
          // Non-fatal — temp cleanup is best-effort
        }
      }

      if (mounted) _snack('Saved to gallery ✓');
    } catch (e) {
      if (mounted) _snack('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  Widget get _activeImage {
    return switch (_mode) {
      _ViewMode.original =>
        Image.file(widget.originalFile, fit: BoxFit.contain),
      _ViewMode.result => Image.memory(
          widget.resultBytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(_mode == _ViewMode.original ? 'Original' : 'Result'),
        centerTitle: true,
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.save_alt),
                  tooltip: 'Save result to gallery',
                  onPressed: _mode == _ViewMode.result ? _saveToGallery : null,
                ),
          IconButton(
            icon: const Icon(Icons.fit_screen),
            tooltip: 'Reset zoom',
            onPressed: _resetZoom,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Zoomable image ─────────────────────────────────────────────
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

          // ── Timing badge + hint ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Column(
              children: [
                if (widget.totalMs > 0)
                  Text(
                    '⚡ ${(widget.totalMs / 1000).toStringAsFixed(1)}s total'
                    '${widget.backendMs > 0 ? ' · ${(widget.backendMs / 1000).toStringAsFixed(1)}s server' : ''}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                const SizedBox(height: 2),
                const Text(
                  'Pinch to zoom · Double-tap to reset',
                  style: TextStyle(color: Colors.white30, fontSize: 11),
                ),
              ],
            ),
          ),

          // ── 2-way toggle ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                for (final mode in _ViewMode.values) ...[
                  if (mode.index > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _ModeButton(
                      label: switch (mode) {
                        _ViewMode.original => 'Original',
                        _ViewMode.result => 'Result',
                      },
                      icon: switch (mode) {
                        _ViewMode.original => Icons.photo_camera,
                        _ViewMode.result => Icons.auto_fix_high,
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
        padding: const EdgeInsets.symmetric(vertical: 12),
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
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
