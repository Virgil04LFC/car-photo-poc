import 'package:flutter/material.dart';

// ─── Backend URL ──────────────────────────────────────────────────────────────
//
// Local dev on a real device (same WiFi as your PC):
//   → Replace with your PC's LAN IP, e.g. http://192.168.1.100:8080
//
// Android emulator connecting to host machine:
//   → http://10.0.2.2:8080
//
// Fly.io (once deployed):
//   → https://car-photo-api.fly.dev   (or whatever name Fly assigned)
//
const String kBackendBaseUrl = 'http://10.0.2.2:8080';

// ─── Image resize ─────────────────────────────────────────────────────────────
/// Longest edge to resize to before upload.
/// 2000px: buffer above typical 1500–1920px dealer display width, keeps upload fast.
const int kMaxLongEdgePx = 2000;

/// JPEG quality for the upload copy. 92 = visually lossless.
const int kUploadJpegQuality = 92;

// ─── Defaults ─────────────────────────────────────────────────────────────────
const String kDefaultBackgroundId = 'showroom-light';

// ─── Background library (Step 2 — static) ────────────────────────────────────
// Step 3 will replace this const list with a live fetch from GET /backgrounds.
// IDs must match exactly what the backend expects.
const List<BackgroundOption> kBackgrounds = [
  BackgroundOption(
    id: 'showroom-light',
    name: 'Light Showroom',
    color: Color(0xFFEBEBEB),
  ),
  BackgroundOption(
    id: 'showroom-dark',
    name: 'Dark Showroom',
    color: Color(0xFF2A2A2A),
  ),
  BackgroundOption(
    id: 'studio-white',
    name: 'Studio White',
    color: Color(0xFFFFFFFF),
  ),
  BackgroundOption(
    id: 'studio-black',
    name: 'Studio Black',
    color: Color(0xFF111111),
  ),
  BackgroundOption(
    id: 'midnight-blue',
    name: 'Midnight Blue',
    color: Color(0xFF0D1B2A),
  ),
  BackgroundOption(
    id: 'slate-grey',
    name: 'Slate Grey',
    color: Color(0xFF708090),
  ),
  BackgroundOption(
    id: 'outdoor-sky',
    name: 'Open Sky',
    color: Color(0xFF87CEEB),
  ),
];

// ─── Model ────────────────────────────────────────────────────────────────────
class BackgroundOption {
  final String id;
  final String name;
  final Color color;

  const BackgroundOption({
    required this.id,
    required this.name,
    required this.color,
  });
}
