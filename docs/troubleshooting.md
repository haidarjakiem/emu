# Troubleshooting

Most problems show up with these:

```sh
./emu doctor                  # tools, signing, game files, phone
./emu launch --diagnostics    # start with extra logging
./emu logs                    # copy logs to build/logs/
```

## Setup and signing

**"Unsupported SnowRunner version" or "Unsupported ... ARM64 binary".**
Your Mac game does not match the pinned build, usually because Steam updated it. The
changes depend on exact byte positions, so another build is refused rather than patched
blindly. An app that is already installed keeps working, and `./emu install` can still
re-sign it from the prepared copies in `build/`.

**The game is not found.**
Run `./emu setup --game "/path/to/SnowRunner.app"`. Steam's default location is
`~/Library/Application Support/Steam/steamapps/common/SnowRunner/SnowRunner.app`.

**The SDL download fails or its checksum does not match.**
Check the network and run `./emu setup` again. A file with the wrong checksum is never used.

**No signing team, no profile, or "failed to register bundle identifier".**
- Add your Apple ID in Xcode > Settings > Accounts, then run `./emu doctor`.
- If no team appears, use Manage Certificates to create an Apple Development certificate.
- Pass the team shown there: `./emu setup --team ABCDE12345`.
- The bundle ID must be unique for your account, for example
  `dev.yourname.emu.snowrunner`. Keep it after the first install.
- Free accounts can hold only a few development apps. Removing unused ones helps.

**Installation is refused after changing the team.**
Do not delete the app: that deletes your saves and game files. Put the previous team back in
`config.local.json` and run `./emu install`. If you really need to change it, run
`./emu backup` first.

## Installing and launching

**"Untrusted Developer".**
On the iPhone: Settings > General > VPN & Device Management > your Apple ID > Trust.

**The phone is not listed.**
Connect it by cable, unlock it and accept "Trust This Computer". Turn on Developer Mode in
Settings > Privacy & Security > Developer Mode and restart the phone.

**The app stopped opening after a week.**
The free signature expired. Run `./emu install`. Saves and game files stay.

**Launching says game files are missing or unverified.**
Run `./emu resources`. If the files were copied earlier, for example before an update of
these tools, run `./emu resources --verify` instead.

## Copying game files

**The copy was interrupted.**
Run `./emu resources` again. Finished files are skipped. The interrupted one is copied again.

**"Resource completion records are damaged".**
Run `./emu resources --verify`. It hashes the files on the phone and rebuilds the records
without copying anything.

**"Not enough free space".**
All game files take about 52 GB. Keep at least 55 GB free.

**The copy is slow.**
The observed rate was roughly 35 MB/s over USB, so a full copy takes about half an hour or
more. Keep the phone unlocked and the app open on the "Ready to transfer" screen.

## While playing

**The app closes and `guest-load.log` contains `UNIMPLEMENTED <name>`.**
The game needed a macOS function that has no iOS version here yet. This is deliberate: the
function is not faked. The line also names the caller. Please include it in reports.

**The app closes with no `UNIMPLEMENTED` line.**
Look at `guest-console.log` (game output) and the crash reports in Xcode > Window > Devices
and Simulators. Run with `--diagnostics` to also record memory use (`game-memory.jsonl`).

**A map other than Black River does not load or misbehaves.**
Only Black River has been tested. Please report it with `./emu logs`.

**Touch controls are in the wrong place.**
Tap the move button in driving mode, drag the controls, and tap the checkmark. The reset
button restores the default layout.

**Steam features or cloud saves do not work.**
Expected: Steam is off. DLC ownership is not faked, and DLC availability is untested.

## Checking the platform without the game

```sh
./emu check
```

This installs the app and runs a self-test: SDL window, Metal frame, events, touch layout and
the virtual gamepad. It does not load game code or resources. Failures are recorded in
`build/reports/sdl-check.json`.
