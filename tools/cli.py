"""Command-line workflow for one reproducible SnowRunner experiment."""
import argparse
import fcntl
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from .common import BUILD, CONFIG, UserError, config, run, write_json
from . import device, resources
from .build import build, validate_settings, write_local_settings
from .prepare import prepare, validate_game


def signing_teams():
    """Read public certificate metadata, never export a private key."""
    try:
        identities = run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True)
        valid = set(re.findall(r"\b[A-Fa-f0-9]{40}\b", identities.upper()))
        pem = run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"], capture=True)
    except UserError:
        return []
    result = set()
    for certificate in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S):
        process = subprocess.run(["openssl", "x509", "-noout", "-subject", "-fingerprint", "-sha1", "-nameopt", "RFC2253"],
                                 input=certificate, capture_output=True, text=True)
        if process.returncode:
            continue
        match = re.search(r"Fingerprint=([A-Fa-f0-9:]+)", process.stdout)
        team = re.search(r"\bOU\s*=\s*([A-Z0-9]{10})\b", process.stdout)
        if match and team and match.group(1).replace(":", "").upper() in valid:
            result.add(team.group(1))
    return sorted(result)


def choose(label, values):
    if len(values) == 1:
        print(label + ": " + values[0])
        return values[0]
    if not sys.stdin.isatty():
        raise UserError("Cannot choose {} automatically. Pass its setup option explicitly.".format(label))
    if values:
        print(label + " options: " + ", ".join(values))
    return input(label + ": ").strip()


def setup(args):
    settings = config(required=False)
    if args.game:
        settings["game"] = str(Path(args.game).expanduser().resolve())
    if not Path(settings["game"]).is_dir():
        raise UserError("SnowRunner.app was not found. Use ./emu setup --game /path/to/SnowRunner.app.")
    settings["team"] = args.team or settings.get("team") or choose("Apple Development team ID", signing_teams())
    settings["bundle_id"] = args.bundle_id or settings.get("bundle_id") or "local.emu.t{}.snowrunner".format(settings["team"].lower())
    settings["device"] = args.device or settings.get("device", "")
    if not settings["device"]:
        found = device.devices()
        if len(found) == 1:
            settings["device"] = found[0]["id"]
    validate_settings(settings)
    write_json(CONFIG, settings)
    write_local_settings(settings)
    prepare(Path(settings["game"]))
    print("Setup complete. Next: ./emu install, then ./emu resources, then ./emu launch.")


def doctor():
    settings = config(required=False)
    print(run(["xcodebuild", "-version"], capture=True))
    print("iOS SDK: " + run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], capture=True))
    teams = signing_teams()
    print("Signing teams: " + (", ".join(teams) if teams else "none; create an Apple Development certificate in Xcode Settings > Accounts"))
    with tempfile.TemporaryDirectory(prefix="emu-doctor-") as temporary:
        manifest, _ = validate_game(Path(settings["game"]), Path(temporary))
    print("Game: {} ({}) — all ARM64 fingerprints match.".format(manifest["version"], manifest["bundle_version"]))
    missing = [item["path"] for item in resources.manifest_files() if "text" not in item and
               not (Path(settings["game"]) / "Contents/Resources" / item["path"]).is_file()]
    print("Source resources: " + ("all present" if not missing else "missing: " + ", ".join(missing)))
    print_devices()
    if missing:
        raise UserError("Finish downloading the supported Mac game before copying resources.")


def print_devices():
    found = device.devices()
    for item in found:
        print("{}  {}  {}  iOS {}".format(item["id"], item["name"], item["model"], item["os"]))
    if not found:
        print("No paired physical iOS device found. Connect and trust your iPhone, then enable Developer Mode.")


def require_resources(settings):
    pending = resources.pending_files(settings)
    if pending:
        raise UserError("{} game files are missing or unverified. Run ./emu resources first.\n"
                        "For files copied previously, use ./emu resources --verify.".format(len(pending)))


def launch_game(settings, diagnostics=False):
    require_resources(settings)
    device.launch(settings, diagnostics=diagnostics)
    print("SnowRunner launched on the phone.")


def command(args):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise UserError("The tested build workflow requires an Apple Silicon Mac and Xcode 27.")
    if args.command == "doctor":
        doctor()
        return
    if args.command == "devices":
        print_devices()
        return
    if args.command == "setup":
        setup(args)
        return
    settings = config(required=args.command not in ["prepare", "build"])
    if args.command == "prepare":
        prepare(Path(settings["game"]))
    elif args.command == "build":
        build(settings, unsigned=args.unsigned)
    elif args.command in ["install", "run", "check"]:
        settings["device"] = device.select_device(settings)
        if args.command == "run":
            require_resources(settings)
        app = build(settings)
        device.install(settings, app)
        if args.command == "run":
            launch_game(settings, diagnostics=args.diagnostics)
        elif args.command == "check":
            report = device.run_check(settings, "check", "sdl-check.json", timeout=180)
            fields = ["tableReady", "initialized", "windowCreated", "diagnosticFrameCompleted", "eventRoundTrip", "rawFingerEventsHidden", "mouseEventsPreserved", "nativeMousePositionPreserved"]
            groups = ["touchGamepad", "touchLayout", "displayModes", "touchMouseRouting", "touchKeyboardRouting"]
            failed = [name for name in fields if not report.get(name)] + [name for name in groups if not report.get(name, {}).get("passed")]
            if failed:
                raise UserError("Device checks failed: {}. See build/reports/sdl-check.json.".format(", ".join(failed)))
            print("Device checks passed. This tests the adapters, not gameplay. Run ./emu launch to play.")
    elif args.command == "resources":
        if args.verify:
            resources.verify(settings)
        else:
            resources.transfer(settings, dry_run=args.dry_run)
    elif args.command == "launch":
        launch_game(settings, diagnostics=args.diagnostics)
    elif args.command == "logs":
        device.logs(settings)
    elif args.command == "backup":
        device.backup(settings)


def parser():
    result = argparse.ArgumentParser(description="Build and run the SnowRunner macOS ARM64 experiment on iPhone.")
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="Read-only checks of tools, signing, game and device")
    commands.add_parser("devices", help="List paired physical devices")
    setup_parser = commands.add_parser("setup", help="Save local settings and prepare frameworks; no phone changes")
    for name in ["game", "team", "bundle-id", "device"]:
        setup_parser.add_argument("--" + name)
    commands.add_parser("prepare", help="Validate local game libraries and build native adapters")
    build_parser = commands.add_parser("build", help="Build the host app; prepared binaries can be re-signed without the Mac game")
    build_parser.add_argument("--unsigned", action="store_true", help="Build without Apple signing or an attached device")
    commands.add_parser("install", help="Build, sign and update the app while keeping its data")
    copy_parser = commands.add_parser("resources", help="Explicitly transfer all supported game resources with resume")
    copy_options = copy_parser.add_mutually_exclusive_group()
    copy_options.add_argument("--dry-run", action="store_true", help="Show missing files without phone writes")
    copy_options.add_argument("--verify", action="store_true", help="Hash files on the phone and create completion receipts")
    for name in ["run", "launch"]:
        launch_parser = commands.add_parser(name, help="Build/install/launch" if name == "run" else "Launch the installed app")
        launch_parser.add_argument("--diagnostics", action="store_true", help="Enable memory and file-error diagnostics")
    commands.add_parser("check", help="Build/install and run native SDL/Metal/input checks")
    commands.add_parser("backup", help="Copy saves and touch layout to build/backups; no phone changes")
    commands.add_parser("logs", help="Copy host and game logs into build/logs")
    return result


def main():
    args = parser().parse_args()
    try:
        if args.command in ["doctor", "devices", "logs", "backup"]:
            command(args)
        else:
            BUILD.mkdir(parents=True, exist_ok=True)
            with (BUILD / ".operation.lock").open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise UserError("Another emu operation is running for this checkout. Wait for it to finish.") from error
                command(args)
    except (UserError, OSError, subprocess.TimeoutExpired) as error:
        print("Error: " + str(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted. Completed resource files are retained; rerun to resume.", file=sys.stderr)
        sys.exit(130)
