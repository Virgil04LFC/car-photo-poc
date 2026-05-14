/// Batch processing + review screen.
///
/// Two phases in a single widget:
///   1. [_Phase.processing] — live list showing status of each item as it runs
///   2. [_Phase.reviewing]  — 2-col grid; dealer ticks/unticks, then saves
///   3. [_Phase.saving]     — spinner while writing to gallery
///   4. [_Phase.saved]      — confirmation + "Back to Camera"

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saver_gallery/saver_gallery.dart';

import 'batch.dart';

enum _Phase { processing, reviewing, saving, saved }

// ─── BatchScreen ──────────────────────────────────────────────────────────────

class BatchScreen extends StatefulWidget {
  final BatchController controller;
  const BatchScreen({super.key, required this.controller});

  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  _Phase _phase = _Phase.processing;
  String? _saveError;
  int _savedCount = 0;

  BatchController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onUpdate);
    _ctrl.start(); // fire-and-forget
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onUpdate);
    _ctrl.cancel();
    super.dispose();
  }

  void _onUpdate() {
    if (!mounted) return;
    if (_ctrl.isComplete && _phase == _Phase.processing) {
      setState(() => _phase = _Phase.reviewing);
    } else {
      setState(() {}); // refresh progress counts
    }
  }

  Future<void> _saveSelected() async {
    setState(() {
      _phase = _Phase.saving;
      _saveError = null;
      _savedCount = 0;
    });

    final tmpDir = await getTemporaryDirectory();
    try {
      for (final item in _ctrl.items) {
        if (!item.selectedForSave || item.resultBytes == null) continue;
        // Write to temp file, then SaverGallery.saveFile with androidRelativePath.
        // This maps to MediaStore RELATIVE_PATH = "Pictures/Car Photo", which
        // creates a dedicated named album on Android 10+ (API 29+).
        final name = 'car_${(item.index + 1).toString().padLeft(3, '0')}_result.png';
        final tmpFile = File('${tmpDir.path}/$name');
        await tmpFile.writeAsBytes(item.resultBytes!);
        await SaverGallery.saveFile(
          filePath: tmpFile.path,
          fileName: name,
          androidRelativePath: 'Pictures/Car Photo',
          skipIfExists: false,
        );
        await tmpFile.delete();
        _savedCount++;
        item.resultBytes = null; // free memory
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.reviewing;
          _saveError = 'Save failed: $e';
        });
      }
      return;
    }

    if (mounted) setState(() => _phase = _Phase.saved);
  }

  // ── Navigation guard ──────────────────────────────────────────────────────

  Future<bool> _onWillPop() async {
    if (_phase == _Phase.processing || _phase == _Phase.saved) return true;
    if (_phase == _Phase.saving) return false;

    // reviewing — confirm discard
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Discard results?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Processed images will be lost.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    return confirm ?? false;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _buildAppBar(),
        body: _buildBody(),
        bottomNavigationBar: _buildBottom(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    String title;
    switch (_phase) {
      case _Phase.processing:
        title = 'Processing ${_ctrl.totalCount} photos';
      case _Phase.reviewing:
        title = 'Review Results';
      case _Phase.saving:
        title = 'Saving…';
      case _Phase.saved:
        title = 'Done';
    }
    return AppBar(
      backgroundColor: Colors.black,
      title: Text(title),
      centerTitle: true,
      leading: _phase == _Phase.reviewing || _phase == _Phase.processing
          ? IconButton(
              icon: const Icon(Icons.close),
              onPressed: () async {
                if (await _onWillPop()) Navigator.of(context).pop();
              },
            )
          : null,
      automaticallyImplyLeading: false,
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.processing:
        return _ProcessingBody(ctrl: _ctrl);
      case _Phase.reviewing:
        return _ReviewBody(ctrl: _ctrl, saveError: _saveError);
      case _Phase.saving:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('Saving to Car Photo album…',
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
        );
      case _Phase.saved:
        return _SavedBody(savedCount: _savedCount);
    }
  }

  Widget? _buildBottom() {
    switch (_phase) {
      case _Phase.reviewing:
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_saveError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_saveError!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12)),
                  ),
                ElevatedButton(
                  onPressed: _ctrl.selectedCount > 0 ? _saveSelected : null,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: Colors.blue,
                    disabledBackgroundColor: Colors.white12,
                  ),
                  child: Text(
                    'Save selected (${_ctrl.selectedCount})',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        );
      case _Phase.saved:
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).popUntil((r) => r.isFirst),
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
              child: const Text('Back to Camera'),
            ),
          ),
        );
      default:
        return null;
    }
  }
}

// ─── Processing body ──────────────────────────────────────────────────────────

class _ProcessingBody extends StatelessWidget {
  final BatchController ctrl;
  const _ProcessingBody({required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final done = ctrl.completedCount;
    final total = ctrl.totalCount;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '$done / $total complete',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  if (ctrl.failedCount > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      '· ${ctrl.failedCount} failed',
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 14),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : done / total,
                  backgroundColor: Colors.white12,
                  color: Colors.blue,
                  minHeight: 6,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: ctrl.totalCount,
            itemBuilder: (_, i) => _ItemTile(item: ctrl.items[i]),
          ),
        ),
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  final BatchItem item;
  const _ItemTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final isDone = item.status == BatchItemStatus.done;
    final isFailed = item.status == BatchItemStatus.failed;
    final isProcessing = item.status == BatchItemStatus.processing;

    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 56,
        height: 42,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: isDone && item.resultBytes != null
              ? Image.memory(item.resultBytes!, fit: BoxFit.cover)
              : Container(
                  color: Colors.white10,
                  child: Center(
                    child: isProcessing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isFailed
                                ? Icons.error_outline
                                : Icons.photo_outlined,
                            color: isFailed
                                ? Colors.redAccent
                                : Colors.white30,
                            size: 20,
                          ),
                  ),
                ),
        ),
      ),
      title: Text(
        item.filename,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        isFailed
            ? (item.errorMessage ?? 'Failed')
            : isProcessing
                ? 'Processing…'
                : isDone
                    ? '${(item.totalMs / 1000).toStringAsFixed(1)}s'
                    : 'Queued',
        style: TextStyle(
          color: isFailed ? Colors.redAccent : Colors.white38,
          fontSize: 12,
        ),
      ),
      trailing: Icon(
        isFailed
            ? Icons.error_outline
            : isDone
                ? Icons.check_circle
                : isProcessing
                    ? Icons.sync
                    : Icons.schedule,
        color: isFailed
            ? Colors.redAccent
            : isDone
                ? Colors.green
                : Colors.white24,
        size: 20,
      ),
    );
  }
}

// ─── Review body ──────────────────────────────────────────────────────────────

class _ReviewBody extends StatelessWidget {
  final BatchController ctrl;
  final String? saveError;
  const _ReviewBody({required this.ctrl, this.saveError});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                '${ctrl.doneCount} processed',
                style:
                    const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              if (ctrl.failedCount > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '· ${ctrl.failedCount} failed',
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 13),
                ),
              ],
              const Spacer(),
              Text(
                '${ctrl.selectedCount} selected',
                style:
                    const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
              childAspectRatio: 4 / 3,
            ),
            itemCount: ctrl.totalCount,
            itemBuilder: (_, i) => _GridTile(
              item: ctrl.items[i],
              onToggle: () => ctrl.toggleSelected(i),
              onRetry: () => ctrl.retryItem(i),
            ),
          ),
        ),
      ],
    );
  }
}

class _GridTile extends StatelessWidget {
  final BatchItem item;
  final VoidCallback onToggle;
  final VoidCallback onRetry;
  const _GridTile(
      {required this.item,
      required this.onToggle,
      required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isDone = item.status == BatchItemStatus.done;
    final isFailed = item.status == BatchItemStatus.failed;
    final isProcessing = item.status == BatchItemStatus.processing;
    final selected = item.selectedForSave;

    return GestureDetector(
      onTap: isDone ? onToggle : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Background image or placeholder ────────────────────────
            isDone && item.resultBytes != null
                ? Image.memory(item.resultBytes!, fit: BoxFit.cover)
                : Container(
                    color: Colors.white10,
                    child: Center(
                      child: isProcessing
                          ? const CircularProgressIndicator(
                              strokeWidth: 2)
                          : Icon(
                              isFailed
                                  ? Icons.error_outline
                                  : Icons.schedule,
                              color: isFailed
                                  ? Colors.redAccent
                                  : Colors.white24,
                              size: 32,
                            ),
                    ),
                  ),

            // ── Dim overlay when deselected ────────────────────────────
            if (isDone && !selected)
              Container(color: Colors.black.withOpacity(0.55)),

            // ── Selection badge ────────────────────────────────────────
            if (isDone)
              Positioned(
                top: 6,
                right: 6,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? Colors.blue : Colors.black45,
                    border: Border.all(
                      color: selected ? Colors.blue : Colors.white54,
                      width: 2,
                    ),
                  ),
                  child: selected
                      ? const Icon(Icons.check,
                          color: Colors.white, size: 15)
                      : null,
                ),
              ),

            // ── Failed overlay ─────────────────────────────────────────
            if (isFailed)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: GestureDetector(
                  onTap: onRetry,
                  child: Container(
                    color: Colors.red.withOpacity(0.85),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.refresh,
                            color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text('Retry',
                            style: TextStyle(
                                color: Colors.white, fontSize: 12)),
                      ],
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

// ─── Saved body ───────────────────────────────────────────────────────────────

class _SavedBody extends StatelessWidget {
  final int savedCount;
  const _SavedBody({required this.savedCount});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline,
                color: Colors.green, size: 72),
            const SizedBox(height: 20),
            Text(
              '$savedCount photo${savedCount == 1 ? '' : 's'} saved',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Open your gallery and look in the\n"Car Photo" album.',
              style: TextStyle(color: Colors.white60, fontSize: 15),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
