/// Batch processing engine.
///
/// Manages a queue of [BatchItem]s with a [_Semaphore]-limited concurrency pool.
/// Each item is independently resized, uploaded, and processed by the backend.
/// Results stream in via [ChangeNotifier] as each item completes.

import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

// ─── Status ───────────────────────────────────────────────────────────────────

enum BatchItemStatus { pending, processing, done, failed }

// ─── BatchItem ────────────────────────────────────────────────────────────────

class BatchItem {
  final int index;
  final File originalFile;
  final String filename;

  BatchItemStatus status;
  Uint8List? resultBytes;
  int totalMs;
  int backendMs;
  String? errorMessage;
  bool selectedForSave;

  BatchItem({required this.index, required this.originalFile})
      : filename = originalFile.path.split('/').last,
        status = BatchItemStatus.pending,
        totalMs = 0,
        backendMs = 0,
        selectedForSave = false;
}

// ─── Semaphore ────────────────────────────────────────────────────────────────

class _Semaphore {
  int _available;
  final _waiters = <Completer<void>>[];

  _Semaphore(int count) : _available = count;

  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _available++;
    }
  }
}

// ─── BatchController ──────────────────────────────────────────────────────────

class BatchController extends ChangeNotifier {
  final List<BatchItem> items;
  final String backgroundId;
  final int maxConcurrent;

  bool _cancelled = false;

  BatchController({
    required List<File> files,
    required this.backgroundId,
    this.maxConcurrent = 5,
  }) : items = List.generate(
          files.length,
          (i) => BatchItem(index: i, originalFile: files[i]),
        );

  // ── Derived counts ────────────────────────────────────────────────────────

  int get totalCount => items.length;
  int get doneCount => items.where((i) => i.status == BatchItemStatus.done).length;
  int get failedCount => items.where((i) => i.status == BatchItemStatus.failed).length;
  int get completedCount => items
      .where((i) =>
          i.status == BatchItemStatus.done || i.status == BatchItemStatus.failed)
      .length;
  bool get isComplete => completedCount == totalCount;
  int get selectedCount => items.where((i) => i.selectedForSave).length;

  // ── Processing ────────────────────────────────────────────────────────────

  /// Fire-and-forget: starts the queue and returns immediately.
  /// Callers listen via [ChangeNotifier] for progress updates.
  Future<void> start() async {
    final sem = _Semaphore(maxConcurrent);
    final futures = <Future<void>>[];

    for (final item in items) {
      if (_cancelled) break;
      await sem.acquire();
      if (_cancelled) {
        sem.release();
        break;
      }
      futures.add(_processItem(item).whenComplete(sem.release));
    }

    await Future.wait(futures);
  }

  Future<void> _processItem(BatchItem item) async {
    if (_cancelled) return;
    _update(item, status: BatchItemStatus.processing);

    final sw = Stopwatch()..start();
    try {
      // Resize on native platform thread
      final raw = await item.originalFile.readAsBytes();
      final compressed = await FlutterImageCompress.compressWithList(
        raw,
        minWidth: kMaxLongEdgePx,
        minHeight: kMaxLongEdgePx,
        quality: kUploadJpegQuality,
        format: CompressFormat.jpeg,
      );

      // Upload to backend
      final uri = Uri.parse('$kBackendBaseUrl/process');
      final req = http.MultipartRequest('POST', uri)
        ..fields['background_id'] = backgroundId
        ..files.add(
            http.MultipartFile.fromBytes('image', compressed, filename: 'car.jpg'));

      final streamed = await req.send().timeout(const Duration(seconds: 90));
      final res = await http.Response.fromStream(streamed);

      if (res.statusCode != 200) {
        final excerpt = res.body.substring(0, min(200, res.body.length));
        throw Exception('Server error ${res.statusCode}: $excerpt');
      }

      _update(
        item,
        status: BatchItemStatus.done,
        resultBytes: res.bodyBytes,
        totalMs: sw.elapsedMilliseconds,
        backendMs: int.tryParse(res.headers['x-processing-time-ms'] ?? '') ?? 0,
        selectedForSave: true,
      );
    } on Exception catch (e) {
      _update(item, status: BatchItemStatus.failed, errorMessage: _friendly(e));
    }
  }

  /// Retry a single failed item.
  Future<void> retryItem(int index) => _processItem(items[index]);

  /// Toggle save selection for a single item.
  void toggleSelected(int index) {
    items[index].selectedForSave = !items[index].selectedForSave;
    notifyListeners();
  }

  /// Cancel all pending work.
  void cancel() => _cancelled = true;

  // ── Internal ──────────────────────────────────────────────────────────────

  void _update(
    BatchItem item, {
    required BatchItemStatus status,
    Uint8List? resultBytes,
    int? totalMs,
    int? backendMs,
    String? errorMessage,
    bool selectedForSave = false,
  }) {
    item.status = status;
    if (resultBytes != null) item.resultBytes = resultBytes;
    if (totalMs != null) item.totalMs = totalMs;
    if (backendMs != null) item.backendMs = backendMs;
    item.errorMessage = errorMessage;
    item.selectedForSave = selectedForSave;
    notifyListeners();
  }

  String _friendly(Exception e) {
    final m = e.toString();
    if (m.contains('SocketException') || m.contains('Connection refused')) {
      return 'Cannot reach server';
    }
    if (m.contains('TimeoutException')) return 'Timed out';
    if (m.contains('502')) return 'Service error — retry';
    if (m.contains('504')) return 'Server timeout — retry';
    return m.length > 80 ? '${m.substring(0, 80)}…' : m;
  }
}
