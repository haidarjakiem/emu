# Third-party software

## In this repository

**SDL 2.26.4 dynamic API table** — `app/Compat/SDL2264Indices.h` and
`app/Compat/SDL2264Names.inc` list the order and names of the SDL 2.26.4 dynamic API
function table.

**SDL patch** — `patches/sdl2-ios.patch` changes five SDL 2.32.10 source files and contains
lines of SDL source as context.

Both are derived from SDL (Simple DirectMedia Layer) by Sam Lantinga and contributors, under
the zlib license: [third_party/SDL-LICENSE.txt](third_party/SDL-LICENSE.txt).

## Downloaded during setup

**SDL 2.32.10**

- Release: https://github.com/libsdl-org/SDL/releases/tag/release-2.32.10
- Archive URL and SHA-256: `data/sdl.json`
- License: zlib, [third_party/SDL-LICENSE.txt](third_party/SDL-LICENSE.txt)

`./emu setup` downloads it into `build/`, applies `patches/sdl2-ios.patch` and builds it
locally. The patch adds UIKit window-scene geometry and exports
`SDL_SendVirtualKeyboardKey`. As the zlib license requires, this is a modified version of
SDL and is marked as such here and in the patch. The built framework is embedded in your app
and is not distributed by this repository. The SDL license text is included in the app.

## From your own game install (never included)

These files are read from your own Steam installation of SnowRunner for macOS, prepared
locally in `build/`, and signed with your own developer team:

- the SnowRunner game library (`lib_MR2_SpinTires.dylib`) and all game resources;
- `libEOSSDK-Mac-Shipping.dylib` (Epic Online Services SDK), shipped with the game;
- `libsteam_api.dylib` (Steamworks API), shipped with the game.

They are proprietary software of their owners. This repository contains none of their files,
shaders, textures or other assets. `data/` holds only file names, sizes and hashes used to
check them.

## Apple SDKs

The app links against system frameworks from the iOS SDK in Xcode. No SDK headers or
libraries are included. `data/desktop-symbols.json` lists the names of macOS symbols the game
imports, and the values of some string constants.

## Our code

Everything else is licensed under the MIT license, see [LICENSE](LICENSE).
