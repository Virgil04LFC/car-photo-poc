import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_segmentation/google_mlkit_segmentation.dart';
import 'package:image/image.dart' as img;

class SegmentationService {
  final Segmenter _segmenter;

  SegmentationService()
      : _segmenter = Segmenter(
          mode: SegmentationMode.stream,
          isStream: false,
        );

  Future<Uint8List?> segmentCarImage(File imageFile) async {
    try {
      // Create input image from file (auto-detects rotation)
      final inputImage = InputImage.fromFile(imageFile);

      // Process segmentation
      final segmentedImage = await _segmenter.processImage(inputImage);
      if (segmentedImage == null) return null;

      // Get mask
      final mask = segmentedImage.getMask();

      // Load original image
      final originalBytes = await imageFile.readAsBytes();
      final original = img.decodeImage(originalBytes);
      if (original == null) return null;

      // Resize original to mask dimensions for pixel-perfect mapping
      final resized = img.copyResize(original, width: mask.width, height: mask.height);
      final maskData = mask.getData();

      // Create output image with transparency
      final output = img.Image.from(resized);

      // Apply mask: set alpha to 0 where mask value < threshold
      const threshold = 128;
      for (var y = 0; y < output.height; y++) {
        for (var x = 0; x < output.width; x++) {
          final maskIndex = y * mask.width + x;
          final maskValue = maskData[maskIndex];
          if (maskValue < threshold) {
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