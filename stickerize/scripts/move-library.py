#!/usr/bin/env python3
"""Moves sticker libraries from other Stickerize builds on an iPhone into the build with this repository's bundle ID.

An app can only read its own App Group, so stickers saved by a build with another bundle ID (one built with an
earlier BUNDLE_ID_PREFIX) are invisible to the new one. With the phone
connected to this Mac:

    scripts/move-library.py --backup-only   # first: copies every Stickerize library to this Mac and lists the apps
    # install the new build from this Mac, then:
    scripts/move-library.py --dry-run       # back up and merge on this Mac only; nothing on the phone is written
    scripts/move-library.py                 # the real run

If an old build has to be deleted before the new one installs (the same bundle ID signed by another team), merge its
backup in with --add-library "<backup>/<its App Group>/Stickers".

1. Lists the apps on the phone whose bundle ID contains "stickerize", and their App Groups.
2. Copies each group's Stickers folder to ~/Stickerize Backups/<date>/ (only reading the phone).
3. Merges them with `stickerize merge-library`: the new app's own library, then the others, most recently used first.
   Folders with the same name at the same place combine; a sticker identical to one already there isn't doubled.
4. Copies the result into the new app's group, then reads it back and compares every file.

The other apps keep their stickers until you delete them. Deleting an app deletes its group's data, so delete them
only after checking the new one; the backups stay on this Mac. Don't use Stickerize on the phone while this runs.

Copying an app's data needs it to have been installed from this Mac (Xcode, xcodebuild or devicectl), and the phone
paired and unlocked. A simulator works too (`--device <its UDID>`), for trying this out.
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
KIT = ROOT / "StickerizeKit"
IMAGE_SUFFIXES = (".png", ".gif")
# The files of a library, as named in the app's Stickers folder.
LIBRARY_FILE = re.compile(r"manifest\.json|[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}\.(png|gif)", re.I)
FILE_LIKE = re.compile(r"\.(png|gif|jpe?g|heic|webp|json|plist)$", re.I)
VERBOSE = False


class Failure(Exception):
    pass


def bundle_id_prefix():
    """BUNDLE_ID_PREFIX as the build sees it: Config/Local.xcconfig overrides Config/Base.xcconfig."""
    value = None
    for name in ("Base.xcconfig", "Local.xcconfig"):
        path = ROOT / "Config" / name
        if path.exists():
            for line in path.read_text().splitlines():
                match = re.match(r"\s*BUNDLE_ID_PREFIX\s*=\s*(\S+)\s*$", line)
                if match:
                    value = match.group(1)
    return value


def run(command, **kwargs):
    try:
        return subprocess.run(command, capture_output=True, text=True, **kwargs)
    except OSError as error:
        raise Failure(f"couldn't run {command[0]}: {error}")


def devicectl(*args):
    """`xcrun devicectl` with JSON output; returns its "result"."""
    with tempfile.TemporaryDirectory() as tmp:
        output = pathlib.Path(tmp) / "result.json"
        if VERBOSE:
            print("    $ xcrun devicectl " + " ".join(args), file=sys.stderr)
        process = run(["xcrun", "devicectl", *args, "--quiet", "--json-output", str(output)])
        result = json.loads(output.read_text()) if output.exists() and output.stat().st_size else {}
        if process.returncode != 0:
            message = (process.stderr or process.stdout).strip() or json.dumps(result.get("error", result))
            raise Failure(f"devicectl {' '.join(args[:2])} failed: {message}")
        return result.get("result", {})


def strings_in(value):
    """Every string in a JSON value, however nested."""
    if isinstance(value, dict):
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            yield from strings_in(item)
    elif isinstance(value, str):
        yield value


def names_in(listing):
    """The last path component of every string in a devicectl file listing, whose format isn't documented."""
    return {text.rstrip("/").rsplit("/", 1)[-1] for text in strings_in(listing)}


def library_files(folder):
    """The library's files: manifest.json and the sticker images (not set-aside manifests or anything else)."""
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir() if p.is_file() and (p.name == "manifest.json" or p.suffix.lower() in IMAGE_SUFFIXES))


def is_library(folder):
    """A Stickers folder: a manifest, or sticker images named by their ID."""
    uuid = re.compile(r"[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}", re.I)
    return any(p.name == "manifest.json" or uuid.fullmatch(p.stem) for p in library_files(folder))


def newest_sticker(folder):
    try:
        return max((s.get("createdAt", "") for s in json.loads((folder / "manifest.json").read_text()).get("stickers", [])), default="")
    except (OSError, ValueError):
        return ""


def sticker_count(folder):
    try:
        return len(json.loads((folder / "manifest.json").read_text()).get("stickers", []))
    except (OSError, ValueError):
        return sum(1 for p in library_files(folder) if p.name != "manifest.json")


class Device:
    """A paired iPhone, through devicectl's app group file access."""

    def __init__(self, identifier, name):
        self.identifier, self.name = identifier, name
        # What devicectl listed for each group, kept in the backup folder to look at if something's off.
        self.listings = {}

    def _copy_from(self, group, source, destination):
        devicectl("device", "copy", "from", "--device", self.identifier, "--domain-type", "appGroupDataContainer",
                  "--domain-identifier", group, "--source", source, "--destination", str(destination))

    def _list(self, group, *options):
        return devicectl("device", "info", "files", "--device", self.identifier, "--domain-type", "appGroupDataContainer",
                         "--domain-identifier", group, *options)

    def pull(self, group, destination):
        """Copies the library files in the group's Stickers folder into `destination` (a new folder), one at a time from
        the folder's listing: devicectl copies files, not folders. False if the group has no Stickers folder."""
        try:
            listing = self._list(group, "--subdirectory", "Stickers")
        except Failure as error:
            # Only a group seen to have no Stickers folder has no library. Any other failure (the phone dropping off
            # for a moment, say) stops the run rather than leave a library out.
            root = self._list(group, "--no-recurse")
            self.listings[group] = {"Stickers": str(error), "group": root}
            if "Stickers" in names_in(root):
                raise Failure(f"{group} has a Stickers folder that couldn't be listed: {error}")
            return False
        self.listings[group] = {"Stickers": listing}
        names = names_in(listing)
        files = sorted(name for name in names if LIBRARY_FILE.fullmatch(name))
        if not files and any(FILE_LIKE.search(name) for name in names):
            # Never taken for an empty library: that could hide the stickers it has.
            raise Failure(f"{group}'s Stickers folder lists files this doesn't recognize; nothing was written")
        destination.mkdir(parents=True)
        for index, name in enumerate(files, 1):
            if index % 50 == 0:
                print(f"    {index} of {len(files)} files")
            path = destination / name
            self._copy_from(group, f"Stickers/{name}", path)
            if path.is_dir() and (path / name).is_file():
                # Copied into a folder of that name rather than to it.
                held = path.with_name(name + ".copying")
                path.rename(held)
                (held / name).rename(path)
                held.rmdir()
            if not path.is_file():
                raise Failure(f"Copying {group}'s Stickers/{name} left no file at {path}")
        return True

    def _copy_to(self, group, paths, destination):
        sources = [arg for path in paths for arg in ("--source", str(path))]
        devicectl("device", "copy", "to", "--device", self.identifier, "--domain-type", "appGroupDataContainer",
                  "--domain-identifier", group, *sources, "--destination", destination)

    def push(self, group, files):
        """Copies `files` into the group's Stickers folder, in batches, in the order given."""
        for start in range(0, len(files), 50):
            batch = files[start:start + 50]
            if len(batch) == 1:
                # One source is copied to the destination path itself, so name the file (a folder would be replaced).
                self._copy_to(group, batch, f"Stickers/{batch[0].name}")
                continue
            try:
                self._copy_to(group, batch, "Stickers")
            except Failure:
                # E.g. no Stickers folder yet for several files to go into: one at a time, each to its own path.
                for path in batch:
                    self._copy_to(group, [path], f"Stickers/{path.name}")


class Simulator:
    """A simulator: its App Groups are folders on this Mac."""

    def __init__(self, identifier, name):
        self.identifier, self.name = identifier, name
        self.groups = {}
        self.listings = {}

    def note_app(self, bundle_id):
        process = run(["xcrun", "simctl", "get_app_container", self.identifier, bundle_id, "groups"])
        for line in process.stdout.splitlines():
            group, _, path = line.partition("\t")
            if path:
                self.groups[group.strip()] = pathlib.Path(path.strip())

    def pull(self, group, destination):
        source = self.groups[group] / "Stickers"
        if not source.is_dir():
            return False
        destination.mkdir(parents=True)
        for path in library_files(source):
            shutil.copy2(path, destination / path.name)
        return True

    def push(self, group, files):
        target = self.groups[group] / "Stickers"
        target.mkdir(parents=True, exist_ok=True)
        for path in files:
            shutil.copy2(path, target / path.name)


def pick_device(requested):
    devices = devicectl("list", "devices").get("devices", [])

    def reality(device):
        return device.get("hardwareProperties", {}).get("reality") or device.get("properties", {}).get("hardware", {}).get("reality")

    def names(device):
        return {device.get("identifier"), device.get("hardwareProperties", {}).get("udid"), device.get("deviceProperties", {}).get("name")}

    if requested:
        matches = [d for d in devices if requested in names(d)]
    else:
        matches = [d for d in devices if reality(d) == "physical"]
    if len(matches) != 1:
        listed = "\n".join(f"  {d.get('deviceProperties', {}).get('name')}  {d.get('identifier')}  ({reality(d)})" for d in devices)
        raise Failure(("No device matches " + repr(requested) if requested else
                       "Pass --device: " + ("no iPhone is paired with this Mac" if not matches else "more than one is paired"))
                      + (f"\nDevices:\n{listed}" if listed else ""))
    device = matches[0]
    kind = Simulator if reality(device) == "simulated" else Device
    return kind(device["identifier"], device.get("deviceProperties", {}).get("name") or device["identifier"])


def build_cli():
    print("Building the stickerize command-line tool…")
    process = run(["swift", "build", "-c", "release", "--package-path", str(KIT), "--product", "stickerize"])
    if process.returncode != 0:
        raise Failure("swift build failed:\n" + (process.stderr or process.stdout)[-3000:])
    bin_path = run(["swift", "build", "-c", "release", "--package-path", str(KIT), "--show-bin-path"]).stdout.strip()
    return pathlib.Path(bin_path) / "stickerize"


def backup_folder(args):
    backups = args.backup_dir or pathlib.Path.home() / "Stickerize Backups" / datetime.datetime.now().strftime("%Y-%m-%d %H.%M.%S")
    if backups.exists() and any(backups.iterdir()):
        raise Failure(f"{backups} isn't empty; pass another --backup-dir")
    backups.mkdir(parents=True, exist_ok=True)
    print(f"Backing up to {backups}")
    return backups


def save_listings(device, backups):
    (backups / "devicectl-listings.json").write_text(json.dumps(device.listings, indent=1, default=str))


def nothing_found(groups, backups):
    return Failure(f"No sticker library found in {', '.join(groups)}. If Stickerize shows stickers on the phone, they are "
                   f"somewhere this can't see: don't delete anything. Run this again with --verbose, and send the output "
                   f"and {backups / 'devicectl-listings.json'}.")


def backup(device, group, backups):
    """Copies the group's library to backups/<group>/Stickers and returns that folder, or None if it has none."""
    folder = backups / group / "Stickers"
    if not device.pull(group, folder):
        print(f"  {group}: no library")
        return None
    print(f"  {group}: {sticker_count(folder)} sticker(s)")
    return folder


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--device", help="name or identifier of the iPhone (default: the one paired with this Mac)")
    parser.add_argument("--to", help="bundle ID of the app to move into (default: BUNDLE_ID_PREFIX from Config/)")
    parser.add_argument("--from", dest="sources", action="append", metavar="BUNDLE_ID",
                        help="only from this app (repeatable; default: every other app whose bundle ID contains 'stickerize')")
    parser.add_argument("--backup-dir", type=pathlib.Path, help="where to put the backups (default: ~/Stickerize Backups/<date>)")
    parser.add_argument("--dry-run", action="store_true", help="back up and merge on this Mac, but don't write to the phone")
    parser.add_argument("--cli", type=pathlib.Path, help="a built stickerize tool (default: build it with swift build)")
    parser.add_argument("--backup-only", action="store_true",
                        help="only back up every Stickerize app's library; works before the new build is installed")
    parser.add_argument("--verbose", action="store_true", help="show every devicectl command")
    parser.add_argument("--add-library", action="append", type=pathlib.Path, default=[], metavar="DIR",
                        help="also merge this Stickers folder on the Mac, e.g. a backup of an app since deleted (repeatable)")
    args = parser.parse_args()
    global VERBOSE
    VERBOSE = args.verbose

    if args.cli and not (args.cli.is_file() and os.access(args.cli, os.X_OK)):
        raise Failure(f"--cli: not an executable file: {args.cli}")
    for folder in args.add_library:
        if not is_library(folder):
            raise Failure(f"--add-library: no sticker library in {folder} (a Stickers folder: manifest.json and images)")
    target_id = args.to or bundle_id_prefix()
    if not target_id:
        raise Failure("No BUNDLE_ID_PREFIX in Config/Base.xcconfig or Config/Local.xcconfig; pass --to")
    device = pick_device(args.device)
    print(f"Device: {device.name}")

    installed = devicectl("device", "info", "apps", "--device", device.identifier, "--include-app-group-identifiers").get("apps", [])
    # Every build is named Stickerize; a bundle ID without the word is still found by that.
    apps = [a for a in installed if "stickerize" in a.get("bundleIdentifier", "").lower()
            or (a.get("name") or "").strip().lower() == "stickerize" or a.get("bundleIdentifier") in (args.sources or [])]
    for app in apps:
        groups = ", ".join(app.get("appGroupIdentifiers") or []) or "no App Group"
        note = "" if app.get("containerAccessible", True) else "  (data not reachable: not installed from a Mac)"
        print(f"  {app.get('name')}  {app['bundleIdentifier']}  [{groups}]{note}")
        if isinstance(device, Simulator):
            device.note_app(app["bundleIdentifier"])
    by_id = {a["bundleIdentifier"]: a for a in apps}
    if args.backup_only:
        groups = []
        for app in apps:
            if not app.get("containerAccessible", True):
                print(f"  Skipping {app['bundleIdentifier']}: its data can't be read")
                continue
            groups += [g for g in app.get("appGroupIdentifiers") or [] if g not in groups]
        backups = backup_folder(args)
        try:
            copied = [group for group in groups if backup(device, group, backups)]
        finally:
            save_listings(device, backups)
        if groups and not copied:
            raise nothing_found(groups, backups)
        print(f"Backed up {len(copied)} librar{'y' if len(copied) == 1 else 'ies'}. Nothing on the phone was changed.")
        return
    target = by_id.get(target_id)
    if not target:
        raise Failure(f"{target_id} isn't installed on {device.name}. Build and install it first, then run this again.")
    target_groups = target.get("appGroupIdentifiers") or []
    target_group = f"group.{target_id}" if f"group.{target_id}" in target_groups else (target_groups[0] if len(target_groups) == 1 else None)
    if not target_group:
        raise Failure(f"Can't tell which App Group {target_id} uses: {target_groups}")
    if args.sources and any(s not in by_id for s in args.sources):
        raise Failure("Not installed: " + ", ".join(s for s in args.sources if s not in by_id))
    source_apps = [by_id[s] for s in args.sources] if args.sources else apps
    source_apps = [a for a in source_apps if a is not target]
    for app in [a for a in source_apps if not a.get("appGroupIdentifiers")]:
        # Its stickers, if any, are in its own container (a build signed without the App Group), which this doesn't move.
        print(f"  Leaving out {app['bundleIdentifier']}: it has no App Group. Keep it; this can't move its stickers.")
    source_apps = [a for a in source_apps if a.get("appGroupIdentifiers")]
    unreachable = [a["bundleIdentifier"] for a in [target, *source_apps] if not a.get("containerAccessible", True)]
    if unreachable:
        raise Failure("Can't read the data of " + ", ".join(unreachable) + " (only apps installed from a Mac with a valid "
                      "profile can be read). Leave them out with --from, or install them again from this Mac over the "
                      "existing app, with the same bundle ID and the same DEVELOPMENT_TEAM they were built with (iOS refuses "
                      "an install from another team). Don't delete them first: deleting an app deletes its stickers.")
    source_groups = []
    for app in source_apps:
        for group in app.get("appGroupIdentifiers") or []:
            if group != target_group and group not in source_groups:
                source_groups.append(group)
    if not source_groups and not args.add_library:
        print("No other Stickerize library to move.")
        return

    backups = backup_folder(args)
    try:
        pulled = {group: folder for group in [target_group, *source_groups] for folder in [backup(device, group, backups)] if folder}
    finally:
        save_listings(device, backups)
    if target_group in pulled and (pulled[target_group] / "manifest.json").exists():
        try:
            json.loads((pulled[target_group] / "manifest.json").read_text())
        except ValueError:
            print(f"  Warning: {target_id}'s library file is damaged, so its own stickers come back unnamed (stickers from "
                  f"the other apps get their names back). The damaged file is kept in {pulled[target_group]}.")
    if target_group not in pulled:
        # The new app has never saved a sticker. A copy that failed for another reason must not be taken for that, or the
        # merged manifest would hide the stickers it has.
        print(f"  ({target_id} has no library yet: its stickers start empty)")

    merged = backups / "merged" / "Stickers"
    merged.mkdir(parents=True)
    if target_group in pulled:
        for path in library_files(pulled[target_group]):
            shutil.copy2(path, merged / path.name)
    sources = sorted([*(pulled[g] for g in source_groups if g in pulled), *args.add_library], key=newest_sticker, reverse=True)
    if not sources:
        raise nothing_found(source_groups, backups)
    cli = args.cli or build_cli()
    process = run([str(cli), "merge-library", *[str(s) for s in sources], "--into", str(merged)])
    if process.returncode != 0:
        raise Failure("Merging failed: " + (process.stderr or process.stdout).strip())
    print("Merged:")
    for line in process.stdout.splitlines():
        print("  " + line.replace(str(backups) + "/", ""))
    print(f"  {sticker_count(merged)} sticker(s) in all, in {merged}")

    before = {p.name: p.read_bytes() for p in library_files(pulled[target_group])} if target_group in pulled else {}
    after = {p.name: p.read_bytes() for p in library_files(merged)}
    changed = [merged / name for name, data in after.items() if before.get(name) != data]
    if not changed:
        print("The new app already has everything.")
        return
    if args.dry_run:
        print(f"Dry run: {len(changed)} file(s) would be copied to {target_id}. Nothing on the phone was changed.")
        return

    # The new app's library must still be what was merged; a sticker saved meanwhile would be hidden by the new manifest.
    with tempfile.TemporaryDirectory() as tmp:
        check = pathlib.Path(tmp) / "check"
        now = {p.name: p.read_bytes() for p in library_files(check)} if device.pull(target_group, check) else {}
    if now != before:
        raise Failure(f"{target_id}'s library changed while this ran. Nothing was written; run it again without using the app.")

    def verify(names):
        with tempfile.TemporaryDirectory() as tmp:
            readback = pathlib.Path(tmp) / "readback"
            on_device = {p.name: p.read_bytes() for p in library_files(readback)} if device.pull(target_group, readback) else {}
        missing = [name for name in names if on_device.get(name) != after[name]]
        if missing:
            raise Failure(f"{len(missing)} file(s) didn't arrive intact on the phone (e.g. {missing[0]}). The old apps still "
                          f"have everything, and the backups are in {backups}. Run this again, and don't delete the old "
                          f"apps until it says Done.")

    print(f"Copying {len(changed)} file(s) to {target_id}…")
    images = [p for p in changed if p.name != "manifest.json"]
    device.push(target_group, images)
    verify([p.name for p in images])
    # The manifest last, once every image is there: until then the new app shows its library as it was.
    device.push(target_group, [merged / "manifest.json"])
    verify(list(after))
    print(f"Done: {target_id} has {sticker_count(merged)} sticker(s). Every file was read back and checked.")
    print(f"Backups: {backups}")
    print("Open it to check. Then delete the old apps by bundle ID (every build looks the same on the Home Screen):")
    for app in source_apps:
        print(f"  xcrun devicectl device uninstall app --device {device.identifier} {app['bundleIdentifier']}")


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
