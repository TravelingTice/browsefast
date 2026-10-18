<p align="center"><img src="brand/logo.png" width="96" alt="BrowseFast logo"></p>

# BrowseFast

An agentic web browser for macOS. Type what you want to do on the web and BrowseFast does it for you.

> Early stage: this is the native SwiftUI shell. The browser engine (Chromium) and the agent are not wired in yet.

## Structure

- `app/` is the native macOS app, a Swift package.
  - `BrowseFastUI` is a library with all views, the theme, fonts and the logo. It's a library so Xcode previews work.
  - `BrowseFast` is the executable that launches the window.
- `brand/` is the brand sheet with the logo, palette and typography.

## Run

Requires macOS 15+ and Xcode 26 (Swift 6).

```sh
cd app
swift run
```

You can also open `app/Package.swift` in Xcode. Use the `BrowseFastUI` scheme for SwiftUI previews and `BrowseFast` to run the app.

To see the brand sheet:

```sh
cd brand
python3 -m http.server 4747
```

Then open http://localhost:4747.

## Brand

| Role | Color |
|---|---|
| Primary (Violet Light) | `#9B74FF` |
| Background (Ink) | `#0B0B12` |
| Surface (Ink Raised) | `#15151F` |
| Light mode accent (Electric Violet) | `#5201FC` |

The type is [Figtree](https://github.com/erikdkennedy/figtree), bundled under the SIL Open Font License (`app/Sources/BrowseFastUI/Resources/OFL.txt`).
