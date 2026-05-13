# Car Photo POC

**Flutter‑based on‑device AI segmentation test for car photos.**

## Goal
Test whether Google ML Kit Subject Segmentation works well enough for car‑background removal on‑device, or if a server‑side AI service is needed.

## What it does
1. Opens on an Android phone
2. Lets you take a photo of a car using the phone camera
3. Runs Google ML Kit Subject Segmentation on‑device to remove the background
4. Shows the result on screen
5. **No backend, no login, no background library, no saving, no upload**

## Tech Stack
- **Flutter** (mobile UI)
- **Camera** (camera plugin)
- **Google ML Kit Subject Segmentation** (on‑device AI)
- **Android** (minimum SDK 21)

## Prerequisites
- Flutter SDK (≥ 3.22)
- Android Studio (or Android SDK command‑line tools)
- Android phone with USB debugging enabled (API ≥ 21)

## Setup & Run

### 1. Clone & Install Dependencies
```bash
cd car-photo-poc
flutter pub get
```

### 2. Connect Your Android Phone
- Enable **Developer Options** (tap Build Number 7 times in Settings → About Phone)
- Enable **USB debugging**
- Connect via USB, allow “Allow USB debugging” prompt
- Verify device: `flutter devices`

### 3. Build & Run
```bash
flutter run
```
The app will install and launch on your phone.

## Usage
1. Grant camera permission when prompted.
2. Point camera at a car (or any object).
3. Tap the **camera FAB** (floating button) to capture.
4. Wait for segmentation (≈ 1‑3 seconds).
5. View result in the overlay (top‑right corner).

## Testing Car Segmentation
- Try different car angles, colors, lighting.
- Test against varied backgrounds (street, garage, plain wall).
- Observe edge accuracy, handling of glossy surfaces, wheel wells.

## Known Limitations
- ML Kit Subject Segmentation is trained on general subjects, not specifically cars.
- On‑device processing may be slower on older phones.
- Mask resolution is limited (model‑dependent).
- Complex backgrounds may reduce accuracy.

## Next Steps (If On‑Device Works)
- Add background replacement (solid color, custom image).
- Save processed image to device gallery.
- Build iOS version (same codebase).
- Add dealer‑only login & backend.

## If On‑Device Fails
- Evaluate server‑side AI options (Remove.bg API, custom model).
- Consider TensorFlow Lite custom model fine‑tuned on car images.
- Hybrid approach: on‑device fallback, cloud for high‑quality.

## Troubleshooting
- **Camera fails to initialize**: Check phone camera permissions.
- **Segmentation crashes**: Ensure Google Play Services updated.
- **App won’t install**: Verify USB debugging enabled, `adb devices` lists phone.
- **Slow performance**: Reduce camera resolution in `main.dart` (`ResolutionPreset.low`).

## License
MIT