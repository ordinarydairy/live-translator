# LiveLingo

An iOS 18 SwiftUI prototype for live, on-device screen translation. A ReplayKit broadcast upload extension captures screen frames, Vision recognizes text, and Apple's Translation framework translates it inside the app.

## Requirements

- macOS with Xcode 16+
- iPhone or iPad running iOS 18+ (ReplayKit broadcasts are best tested on a physical device)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A free or paid Apple Developer team for App Groups and device signing

## Run

1. Replace every `com.example.LiveLingo` occurrence with your own reverse-DNS bundle ID.
2. In Apple Developer/Xcode, enable the same App Group for both targets. Update `AppGroup.identifier` and both entitlement files if the group name changes.
3. From this folder, run `xcodegen generate`.
4. Open `LiveLingo.xcodeproj`, select your development team on both targets, and run on a physical device.
5. Tap **Start Screen Broadcast**, select **LiveLingo Broadcast**, and begin broadcasting.

The green broadcast card contains Apple's system ReplayKit picker. LiveLingo
discovers the installed broadcast extension identifier at runtime, so the
system sheet opens directly for the re-signed LiveLingo extension instead of
listing every installed broadcast provider.

For Chinese, Japanese, and Korean, select the correct source language before
starting the broadcast. The broadcast extension reads that choice from the
shared App Group and applies the corresponding Vision recognition languages.

## Floating translator (experimental)

After a translated frame appears, tap **Open floating translator**. LiveLingo
uses `AVSampleBufferDisplayLayer` Picture in Picture to show the composited
translated mirror above other apps. Start the ReplayKit broadcast first, then
start PiP before switching apps. This is a video-style PiP window, not a
system-wide transparent overlay, and sideloaded/background behavior can vary
across iOS versions.

When ReplayKit starts, the extension publishes a heartbeat through the App
Group and LiveLingo automatically opens the **Live translator** session page.
That page contains the active languages, connection status, translated preview,
original-text toggle, and an always-available PiP control with a waiting frame.

The first use of a language pair may ask permission to download Apple's on-device language model.

## Build an IPA without a Mac

This repository includes `.github/workflows/build-ipa.yml`. Keep the workflow
at the repository root under `.github/workflows/`; `project.yml` may be at the
root or inside the `LiveLingo` folder. Then open the
repository's **Actions** tab, choose **Build unsigned IPA**, and select
**Run workflow**. Download the `LiveLingo-unsigned-IPA` artifact when it
finishes. The IPA is intentionally unsigned; install it with AltStore or
Sideloadly so it can be signed for your device.

## Architecture

- `BroadcastUploadExtension/SampleHandler.swift`: throttles ReplayKit video frames, runs Vision OCR, and atomically stores the latest JPEG plus normalized text rectangles in the shared App Group.
- `LiveTranslationModel.swift`: polls the shared snapshot, submits OCR strings to `TranslationSession`, and joins responses back to their screen rectangles.
- `ContentView.swift`: shows the screen mirror and paints translated text in place.

## Platform constraint

iOS does not provide public APIs for arbitrary always-on-top overlays over other apps. This project therefore renders the translated mirror inside LiveLingo. A production app that promises translation while another app remains visible generally needs a substantially different UX (for example, user-initiated screenshots, Split View on iPad, or server-assisted streaming displayed on another device). Do not rely on undocumented overlay or Picture-in-Picture behavior for App Store distribution.

LiveContainer cannot register guest-app extensions, so the ReplayKit upload
extension and Start Broadcast control cannot work from inside LiveContainer.
Use **Translate photo** there, or install the IPA directly with an installer
that preserves and signs the embedded extension.

## Production hardening

- Add duplicate-line tracking so stable text is not translated repeatedly.
- Persist user language choices and expose supported-language availability.
- Add rotation-aware OCR orientation and aspect-fit coordinate conversion.
- Redact frames from logs and define a clear privacy/retention policy.
- Profile the broadcast extension under its tight memory limit on older devices.

