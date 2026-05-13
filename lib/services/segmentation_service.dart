import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:image/image.dart' as img;

class SegmentationService {
  final SubjectSegmenter _segmenter;

  SegmentationService()
      : _segmenter = SubjectSegmenter(
          options: SubjectSegmenterOptions(
            enableForegroundConfidenceMask: true,
            enableForegroundBitmap: true,
            enableMultipleSubjects: SubjectResultOptions(
              enableConfidenceMask: false,
              enableSubjectBitmap: false,
            ),
          ),
        );

  Future<Uint8List?> segmentCarImage(File imageFile) async {
    try {
      // Create input image from file (auto-detects rotation)
      final inputImage = InputImage.fromFile(imageFile);

      // Process segmentation
      final result = await _segmenter.processImage(inputImage);
      if (result == null) return null;

      // Get mask data (confidence mask values)
      final confidenceMask = result.foregroundConfidenceMask;
      if (confidenceMask == null) return null;

      // Get original image dimensions
      final originalBytes = await imageFile.readAsBytes();
      final original = img.decodeImage(originalBytes);
      if (original == null) return null;

      // Mask dimensions match original image size (from InputImage metadata)
      final maskWidth = inputImage.metadata?.size.width.toInt() ?? original.width;
      final maskHeight = inputImage.metadata?.size.height.toInt() ?? original.height;

      // Resize original to mask dimensions for pixel-perfect mapping
      final resized = img.copyResize(original, width: maskWidth, height: maskHeight);
      final output = img.Image.from(resized);

      // Apply mask: set alpha to 0 where confidence < threshold (0.5)
      const threshold = 0.5;
      for (var y = 0; y < output.height; y++) {
        for (var x = 0; x < output.width; x++) {
          final maskIndex = y * maskWidth + x;
          final confidence = confidenceMask[maskIndex];
          if (confidence < threshold) {
            output.setPixelRgba(x, y, 0, 0, 0, 0); // Fully transparent
          }
        }
      }

      // Encode as PNG (supports transparency)
      return Uint8List.fromList(img.encodePng(output));
    } catch (e) {
      print('Segmentation error: $e');
      rethrow;
    }
  }

  Future<void> close() async {
    await _segmenter.close();
  }
}