# Architecture

How SnowRunner's ARM64 machine code runs inside an iOS app, with two changed calls and
adapted library metadata. Scope: one game build, pinned in `data/supported-game.json`.

## The big picture

```
+-------------------------------- iPhone app process ---------------------------------+
|                                                                                     |
|  Host app (app/Host)                                                                |
|    loads the frameworks below, then calls the game's own main()                    |
|                                                                                     |
|  GameClient  (original game code, ARM64)                                            |
|    |                                                                                |
|    |-- SDL calls ------------> SDLBridge ------> SDL 2.32.10 for iOS --> UIKit       |
|    |-- AppKit, CoreGraphics,                                                        |
|    |   IOKit, ... ------------> Compat* ------> MacCompat --> UIKit / iOS system     |
|    |-- Metal -----------------------------------------------> iOS Metal             |
|    |-- files -----------------------------------------------> Documents/SnowRunner/ |
|    |-- Steam API, EOS (loaded, Steam integration off)                               |
|                                                                                     |
+-------------------------------------------------------------------------------------+
```

## Mac side: preparing the copies

```
Steam install (read only)             build/Vendor/
lib_MR2_SpinTires.dylib  --+
libEOSSDK-Mac-Shipping   --+-- 1 validate --> 2 retarget --> 3 patch --> 4 verify -->  GameClient, EOS,
libsteam_api.dylib       --+                                                           SteamAPI frameworks
app/Compat sources ------------------------------------ clang -------------------->  MacCompat, Compat*,
SDL 2.32.10 release + patches/sdl2-ios.patch ---------- xcodebuild --------------->  SDLBridge, SDL2
```

1. **Validate.** The ARM64 slice of each library must match the pinned SHA-256 of the whole
   slice and of its `__text` (machine code) section. The app's version must be 53.5 (111).
   Anything else is refused before any output is written.
2. **Retarget (metadata only).**
   - The Mach-O platform is changed from macOS to iOS.
   - Library paths are redirected: macOS frameworks such as AppKit, Carbon, CoreGraphics,
     IOKit and Foundation go to small `Compat<Name>.framework` images, `libSystem` goes to
     `CompatSystem`, and the EOS and Steam API libraries go to their prepared frameworks.
   - The original signature is removed. Xcode signs everything with your team.
   - EOS and the Steam API keep their machine code byte for byte.
3. **Patch the game library.**

   | Change | Why |
   | --- | --- |
   | Byte strings that name Mac SDL classes (`SDL…`, `METAL_…`) are renamed to `SRM…`, `SRMTL_…` everywhere in the file | The game contains its own desktop SDL 2.26.4. Its Objective-C class names would clash with the real iOS SDL in the same process. The whole-file replacement is safe only because the input is pinned by its full hash. |
   | Config key `steam.enabled` renamed to `ios.no_steam_` | The retail config can no longer switch Steam on, so the setting keeps its built-in default: off. |
   | Call at `0xdb5800` goes to another save factory | Saves use the game's local-file storage instead of Steam storage. |
   | Call at `0x39d568` goes to another mod provider | Uses the game's own offline mod.io provider. `Mods.enabled` stays on, because turning it off broke the UI. |

   Each instruction is compared with the expected old word before anything is written.
4. **Verify.** The prepared library must match the pinned SHA-256 of the prepared file and
   of its machine code.

Nothing here signs a user in, grants a license, or unlocks DLC.

### Caches

```
build/Vendor/GameClient, EOS, SteamAPI   <- reused if their full SHA-256 matches the pin
build/Vendor/MacCompat, Compat*, SDLBridge, SDL2
                                         <- rebuilt when app/Compat, tools, data, the SDL
                                            patch, Xcode or the iOS SDK change
```

Because the prepared game libraries are checked against pinned hashes, `./emu install` can
rebuild the adapters and re-sign the app without the Mac game. That is what makes the
weekly re-signing work after Steam updates or removes the game.

## The adapters (`app/Compat`)

**SDLBridge** (`SDLBridge.m`). The game's built-in SDL supports SDL's *dynamic API*: if the
environment variable `SDL_DYNAMIC_API` names a library, every SDL call goes through that
library's function table. SDLBridge fills the exact 833-entry table of SDL 2.26.4
(`SDL2264Indices.h`, `SDL2264Names.inc`) with functions from the native iOS SDL 2.32.10.
A few entries are wrapped. The important ones:

| Wrapped call | Reason |
| --- | --- |
| `SDL_PollEvent` | Drops raw finger events. iOS SDL already turns touches into mouse events, and the Mac game misreads finger events. |
| `SDL_SetRelativeMouseMode`, `SDL_WarpMouseInWindow`, `SDL_GetRelativeMouseState` | A finger is an absolute position. Stops camera lock and cursor warps from moving taps. |
| `SDL_GameControllerGetAxis` | Ignores the touch gamepad's camera stick while a finger is on the game view. |
| `SDL_CreateWindow` | Puts the SDL window into the active window scene and adds the touch controls. |
| `SDL_GetBasePath` | Points at the copied game resources. |

**Touch controls** (`MenuControls.m`, `TouchInput.m`). A transparent window above the game
holds the menu keys, pedals, steering pad and camera stick. Keys are sent as SDL key events.
Driving goes through an SDL virtual gamepad that reports itself as an Xbox 360 controller,
because the game rejects SDL's generic virtual type. The layout is saved in
`Documents/touch-controls-layout.plist`.

**MacCompat.** Real implementations of what the tested path needs:

- display information from `UIScreen`, including lower render sizes (`Displays.m`);
- an `NSApp` stand-in (`Application.m`);
- the game keeps control of its Metal drawable size (`MetalPresentation.m`);
- GPU description for the built-in GPU (`MetalDeviceInfo.m`);
- file calls passed straight through, with failures logged only in diagnostics mode
  (`FileDiagnostics.c`).

**Fail-fast stubs.** Every other macOS symbol the game imports is listed in
`data/desktop-symbols.json`. At build time each becomes a function that stops the app and
logs `UNIMPLEMENTED <name>` with the caller. String constants use the values recorded in
that file. Nothing returns a fake success.

**Compat\<Name\>.** Empty images that re-export MacCompat and the matching iOS frameworks,
so the game's dependency list stays recognizable.

## iPhone side

The host app starts in one of four modes, chosen by `./emu`:

| Mode | Used by | What it does |
| --- | --- | --- |
| game (default, also the Home Screen icon) | `./emu launch` | Checks resources, then starts the game |
| maintenance | `./emu resources` | Creates resource folders, reports free space, stays idle while files are copied |
| verify-resources | `./emu resources --verify` | Hashes the files on the phone and writes completion records |
| check | `./emu check` | SDL, Metal, touch and input self-test; no game files |

Starting the game:

1. Refuse to start unless every file in the resource manifest has the right size and a
   completion record.
2. Change the working directory to `Documents/SnowRunner/SnowRunner.app/Contents/Resources`.
   This mirrors the Mac layout, so the game writes its data to `Documents/SnowRunner/sandbox/`.
3. Set `SDL_DYNAMIC_API` to SDLBridge and load MacCompat, SteamAPI, EOS and GameClient.
4. Call the game's exported `main`.

The game uses its original Mac Metal shader libraries. The tested iOS 27 device accepted
them without conversion. The app requests the `increased-memory-limit` entitlement, which a
free Personal Team accepted on the tested device, and declares Game Mode support.

## Copying game files safely

```
for each missing file:
   remove its completion record on the phone
   copy the file                      (USB, can be interrupted)
   check its size on the phone
   add its completion record          (only now counts as done)
```

- Completion records live in one file on the phone, `Documents/emu-resources.json`.
- A file counts as done only with the right size **and** a record. An interrupted copy has
  no record, so it is copied again.
- If the record file is damaged, copying stops. `./emu resources --verify` rebuilds it by
  hashing the files on the phone.
- The Mac-side source files are hashed before copying, and the result is cached by path,
  size and modification time.

## Files in the app container

| Path | Contents |
| --- | --- |
| `Documents/SnowRunner/SnowRunner.app/Contents/Resources/` | Game files |
| `Documents/SnowRunner/sandbox/base/storage/` | Saves and game settings |
| `Documents/SnowRunner/sandbox/base/logs/` | The game's own logs |
| `Documents/touch-controls-layout.plist` | Touch control positions |
| `Documents/emu-resources.json` | Completion records for copied files |
| `Documents/guest-load.log`, `guest-console.log` | Start-up stages, game output |

## Not covered

- Steam services, Steam Cloud, achievements, multiplayer and DLC.
- All installed map archives are included in the copy manifest; only Black River has been played.
- macOS functions outside the tested path stop the app with a clear log line.
- Other game builds need new pins and a new review of every change.
