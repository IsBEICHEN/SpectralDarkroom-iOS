# Spectral Darkroom for iPhone (unofficial prototype)

This iOS 18+ prototype uses the SpektraLab C++/Metal engine and bundles
all 28 base profiles plus six product profiles: 25 films and nine print stocks.
The stock catalog is generated from the bundled profiles at build time, rather
than maintained as a separate hard-coded list. The black-and-white paper's
neutral filter packs and grades 00–5 are also bundled. It imports images from
the system Photos picker, renders a preview with
selectable film and paper, and saves a Display P3 JPEG to the system Photos library.
The bottom navigation switches film, paper, and adjustment panels by tap or
by dragging across the three items; export history
keeps local copies for later review and sharing. It has a new SwiftUI phone
interface and a different name; it is not the full desktop application.
Each stock picker supports a persistent custom order edited by dragging rows,
and a most recently used order that updates when a stock is selected.
Material cards display bundled example thumbnails rendered from reference
photographs through the engine. They do not update for the imported photo;
the main image preview does. Reference image credits and licenses are in
`Tools/reference-images/NOTICE.md`.
Switching between film and paper returns the horizontal picker to the selected
stock. The search list groups stocks by type and marks the recommended paper
and calibrated alternatives. Compatible papers are listed first; papers
without a neutral filter pack for the selected negative are dimmed and disabled.
Positive slide stocks use direct film scanning
and do not expose paper choices. CineStill 800T's strong halation is identified in the
picker and can be reduced with the halation adjustment.
The base bundle name is ASCII `Darkroom` for sideloading tools; the Simplified
Chinese localized Home Screen name is 光谱暗房. The bundle identifier must be
an ASCII reverse-domain identifier from the signing profile, never the display
name. A signed IPA is tied to its team's profile and registered devices.
The advanced adjustment sheet exposes exposure, format, lens and scanner
blur, film curve, scene latitude, enlarger filter shifts and exposure, grain,
halation, couplers, paper glare, B&W paper grade and contrast mask. Desktop
features such as the full RAW editing workflow, overscan and date imprint remain outside this
phone interface.
Imported images are currently limited to a 4096-pixel long edge.
The app icon source is `SpectralDarkroom/Icon/AppIcon-1024.png`; its editable
Core Graphics drawing is `Tools/make-app-icon.swift`. The build compiles the
icon asset catalog with `actool`.

Build on an Apple silicon Mac with Xcode and the iOS SDK:

```sh
./ios/build-iphone.sh /path/to/output-directory
```

The script creates `SpectralDarkroom-unsigned.ipa`. It has an ad-hoc signature,
which **does not permit direct installation on an iPhone**. Sign the app using
your own Apple development team and an appropriate provisioning profile before
installing. Do not share credentials or private signing keys. If Xcode's Metal
Toolchain is not available, the iOS build bundles MSL source files for runtime
compilation. This runtime path must be checked on a real device.

Licenses: app and engine GPL-3.0-or-later, film profiles and LUTs CC BY-SA 4.0,
metal-cpp Apache-2.0. Keep the notices when redistributing source or binaries.
