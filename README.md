# emu: SnowRunner for macOS on iPhone

emu runs **your own Steam copy of SnowRunner for macOS** on an iPhone. The game's
original Apple silicon (ARM64) code runs on the phone itself. Nothing is streamed from
the Mac. There is no JIT, no debugger and no jailbreak.

This is an experiment for one exact game build. It is not a general emulator, and it
does not make other Mac games run.

```
  On your Mac                              On your iPhone
  -----------                              --------------
  Steam: SnowRunner.app
     | ./emu setup
     v
  Prepared app  ----- ./emu install ------> Signed iOS app
  Game files    ----- ./emu resources ----> Local game files
                      (USB, resumable)
```

## Status

Tested setup, and nothing else:

| Item | Version |
| --- | --- |
| Phone | iPhone Air, iOS 27 |
| Mac | Apple silicon, Xcode 27 |
| Game | SnowRunner for macOS from Steam, version 53.5 (111), Steam build 25096372 |
| Signing | free Apple ID ("Personal Team") |

Seen working on that setup: main menu, audio, the first map (Black River), driving,
local saves, touch controls.

Not yet verified:

- Maps other than Black River. `./emu resources` copies every installed game file,
  but only Black River has been played.
- A complete fresh install with these tools (empty app, full copy, play).
- The latest on-screen HUD touch fix during real play.
- Game controllers.

## What you need

- A Mac with Apple silicon and Xcode 27 (Python 3 comes with Xcode's command line tools).
- SnowRunner for macOS installed through Steam, at the supported build above.
- Your Apple ID added in Xcode > Settings > Accounts. Under Manage Certificates,
  create an Apple Development certificate if you do not have one. A free account was enough.
- An iPhone connected by cable, with Developer Mode on
  (Settings > Privacy & Security > Developer Mode), and **at least 55 GB free**.

## First run

Download or clone this repository, open a terminal in its folder, then:

```sh
./emu doctor      # 1. check Xcode, the game and the phone (changes nothing)
./emu setup       # 2. save your settings, fetch SDL, prepare local copies
./emu install     # 3. build, sign and install the app
```

4. On the iPhone, trust your developer certificate if asked:
   Settings > General > VPN & Device Management > your Apple ID > Trust.

```sh
./emu resources   # 5. copy the game files (~52 GB, can take half an hour or more)
./emu launch      # 6. start the game
```

`./emu setup` detects what it can and asks for the rest. You can also pass values:

```sh
./emu setup --team ABCDE12345 --bundle-id dev.yourname.emu.snowrunner
```

All settings live in one file, `config.local.json`. It is not committed.

If a copy stops halfway, run `./emu resources` again. It continues where it stopped.
After the first run you can also start the game by tapping the SnowRunner icon.

## Touch controls

Tap the game's menus directly. The controller icon shows the driving controls:
steering on the left, pedals and a camera stick on the right. The spacebar symbol
does the same thing as Space on a keyboard, including the handbrake.

To move controls, tap the four-arrow button, drag them, then tap the checkmark.
Positions are saved automatically. The keyboard icon switches back to menu keys.

## Keep your saves

The game files and your saves live inside the app's data container on the phone.
iOS deletes that container when the app is deleted.

- **Back up** saves and the touch layout: `./emu backup` (copies them to `build/backups/`).
  Return to the game's main menu first.
- **Updates keep your data** as long as the team and `bundle_id` stay the same.
  Do not change them after the first install.
- **Every 7 days** a free-account signature expires. Run `./emu install` again.
  This reuses the prepared copies in `build/`, so it works even if Steam has updated or
  removed the Mac game. Do not delete `build/`.
- **Already copied the files before?** `./emu resources --verify` checks them on the phone
  and records them as complete, so nothing is copied again.

## Commands

| Command | What it does |
| --- | --- |
| `./emu doctor` | Checks tools, signing, the game files and the phone. Changes nothing. |
| `./emu devices` | Lists connected iPhones. |
| `./emu setup` | Saves settings, downloads SDL, prepares local copies. No phone changes. |
| `./emu install` | Builds, signs and installs or updates the app. Data is kept. |
| `./emu resources` | Copies missing game files. `--dry-run` only lists them. `--verify` checks files already on the phone. |
| `./emu launch` | Starts the game. `--diagnostics` writes extra logs. |
| `./emu run` | `install` then `launch`, for later updates. |
| `./emu backup` | Copies saves and the touch layout to `build/backups/`. |
| `./emu logs` | Copies app and game logs to `build/logs/`. |
| `./emu check` | Installs the app and tests graphics, input and touch without loading game code or resources. |
| `./emu prepare`, `./emu build` | The individual steps behind `setup` and `install`. |

## What gets changed

Only local copies in `build/` are changed. The Steam installation is only read.

- The game library, the Epic Online Services library and the Steam API library are
  marked as iOS libraries and pointed at this project's adapters.
- In the game library: Mac SDL class names are renamed, the `steam.enabled` setting is
  disconnected so Steam stays off (the game's default), saves go to local files, and the
  game's own offline mod.io mode is used.

Every change is checked against pinned hashes in `data/supported-game.json` before and
after. Details and diagrams: [docs/architecture.md](docs/architecture.md).

## Limitations

- Steam is off: no Steam Cloud, achievements, friends or multiplayer. Nothing pretends to be
  signed in, and DLC ownership is not faked. DLC availability has not been tested.
  Copying all resource files does not guarantee that every map or feature works.
- Saves exist only on the phone. They do not sync with the Mac or Steam Cloud.
- Many macOS desktop functions are not implemented. If the game needs one, it stops on
  purpose and logs its name. See [docs/troubleshooting.md](docs/troubleshooting.md).
- Performance, heat and battery use have not been measured systematically.

## Repository contents

No game files, game binaries, shaders, credentials or device identifiers are included.
Game files come only from your own Steam install. `build/`, `config.local.json` and
`Config/Local.xcconfig` stay on your Mac and are ignored by Git.

## License

Our code is MIT licensed, see [LICENSE](LICENSE). Third-party notices:
[THIRD_PARTY.md](THIRD_PARTY.md). SnowRunner, Steam and the Epic Online Services SDK belong
to their owners and are not part of this repository.
