import 'dart:typed_data';
import 'package:image/image.dart' as img;

enum ShowroomBackground { light, dark }

/// Top-level function required by Flutter's compute() — must not be a closure.
Uint8List runComposite(CompositeArgs args) =>
    CompositorService.composite(args.segmented, args.background);

class CompositeArgs {
  final Uint8List segmented;
  final ShowroomBackground background;
  const CompositeArgs(this.segmented, this.background);
}

class CompositorService {
  static const labels = {
    ShowroomBackground.light: 'Light Showroom',
    ShowroomBackground.dark: 'Dark Showroom',
  };

  /// Alpha-composite the segmented car PNG over a generated showroom backdrop.
  /// Runs synchronously — call via compute() to avoid blocking the UI.
  ///
  /// Uses manual per-pixel blending instead of img.compositeImage because
  /// compositeImage silently breaks when src (RGBA) and dst (RGB) channel
  /// counts differ, producing a black output.
  static Uint8List composite(Uint8List segmentedPng, ShowroomBackground bg) {
    final car = img.decodePng(segmentedPng)!;
    final result = _generate(bg, car.width, car.height);

    // Diagnostic 1: backdrop sanity check
    final bdCentre = result.getPixel(result.width ~/ 2, result.height ~/ 2);
    print('[COMP] backdrop: \${result.width}x\${result.height} '
        'numChannels=\${result.numChannels} '
        'centre pixel r=\${bdCentre.r.toInt()} g=\${bdCentre.g.toInt()} '
        'b=\${bdCentre.b.toInt()} a=\${bdCentre.a.toInt()}');
    // Diagnostic 2: car image format
    print('[COMP] car: \${car.width}x\${car.height} numChannels=\${car.numChannels}');

    int copied = 0, transparent = 0, blended = 0;
    for (var y = 0; y < car.height; y++) {
      for (var x = 0; x < car.width; x++) {
        final src = car.getPixel(x, y);
        final a = src.a.toDouble() / 255.0;
        if (a <= 0.0) {
          transparent++;
          continue; // fully transparent — keep backdrop pixel
        }
        if (a >= 1.0) {
          // fully opaque — copy car pixel directly
          result.setPixelRgba(
              x, y, src.r.toInt(), src.g.toInt(), src.b.toInt(), 255);
          copied++;
        } else {
          // partial transparency — blend over backdrop
          final dst = result.getPixel(x, y);
          final inv = 1.0 - a;
          result.setPixelRgba(
            x,
            y,
            (src.r.toDouble() * a + dst.r.toDouble() * inv).round().clamp(0, 255),
            (src.g.toDouble() * a + dst.g.toDouble() * inv).round().clamp(0, 255),
            (src.b.toDouble() * a + dst.b.toDouble() * inv).round().clamp(0, 255),
            255,
          );
          blended++;
        }
      }
    }
    print('[COMP] pixels: copied=\$copied blended=\$blended transparent=\$transparent');
    // Diagnostic 3: sample result pixel at backdrop area (top-left corner = should be backdrop)
    final corner = result.getPixel(10, 10);
    print('[COMP] result top-left pixel: r=\${corner.r.toInt()} g=\${corner.g.toInt()} '
        'b=\${corner.b.toInt()} a=\${corner.a.toInt()}');

    return Uint8List.fromList(img.encodePng(result));
  }

  /// Small thumbnail for the background picker — cheap to generate synchronously.
  static Uint8List thumbnail(ShowroomBackground bg,
          {int w = 200, int h = 120}) =>
      Uint8List.fromList(img.encodePng(_generate(bg, w, h)));

  // ─── Internal ─────────────────────────────────────────────────────────────

  static img.Image _generate(ShowroomBackground bg, int w, int h) {
    final im = img.Image(width: w, height: h, numChannels: 4);
    bg == ShowroomBackground.light ? _light(im) : _dark(im);
    return im;
  }

  // Light showroom: white top → warm grey floor, subtle floor reflection.
  static void _light(img.Image im) {
    final fy = (im.height * 0.65).toInt(); // wall/floor join
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        int v;
        if (y < fy) {
          // Wall: 252 → 218 top-to-floor
          final t = y / fy;
          v = (252 - t * 34).toInt().clamp(0, 255);
        } else {
          // Floor: 215 → 170 with side vignette
          final t = (y - fy) / (im.height - fy);
          v = (215 - t * 45).toInt().clamp(0, 255);
          final xn = ((x / im.width) - 0.5).abs() * 2.0;
          v = (v * (1.0 - xn * xn * 0.14)).toInt().clamp(0, 255);
        }
        im.setPixelRgba(x, y, v, v, v, 255);
      }
    }
    _reflectionStripe(im, fy, boost: 24, radius: 14);
  }

  // Dark showroom: deep charcoal top → dark grey floor, subtle reflection.
  static void _dark(img.Image im) {
    final fy = (im.height * 0.65).toInt();
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        int v;
        if (y < fy) {
          // Wall: 24 → 50
          final t = y / fy;
          v = (24 + t * 26).toInt().clamp(0, 255);
        } else {
          // Floor: 52 → 70 with stronger side vignette
          final t = (y - fy) / (im.height - fy);
          v = (52 + t * 18).toInt().clamp(0, 255);
          final xn = ((x / im.width) - 0.5).abs() * 2.0;
          v = (v * (1.0 - xn * xn * 0.28)).toInt().clamp(0, 255);
        }
        im.setPixelRgba(x, y, v, v, v, 255);
      }
    }
    _reflectionStripe(im, fy, boost: 38, radius: 14);
  }

  /// Soft horizontal highlight at the wall/floor boundary — fakes a floor reflection.
  static void _reflectionStripe(img.Image im, int fy,
      {required int boost, required int radius}) {
    final y0 = (fy - radius).clamp(0, im.height - 1);
    final y1 = (fy + radius).clamp(0, im.height - 1);
    for (var y = y0; y <= y1; y++) {
      final dist = (y - fy).abs();
      final b = (boost * (1.0 - dist / radius)).toInt().clamp(0, 255);
      if (b == 0) continue;
      for (var x = 0; x < im.width; x++) {
        final px = im.getPixel(x, y);
        final v = (px.r.toInt() + b).clamp(0, 255);
        im.setPixelRgba(x, y, v, v, v, 255);
      }
    }
  }
}
