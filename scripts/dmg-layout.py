#!/usr/bin/env python3
"""Writes and reads the Finder window layout (.DS_Store) of the release disk image.

Run through dmg_layout in scripts/release-functions.sh, which pins the two libraries:

  dmg-layout.py write <mounted volume> --app NAME --background PATH
                      --icon X Y --window WIDTH HEIGHT [--icon-size N] [--text-size N]
  dmg-layout.py read <.DS_Store>     prints what the file says, as JSON
  dmg-layout.py selftest             proves the libraries load and a layout round-trips

The file is written directly. Finder is not scripted: that needs an Automation permission
and a window on screen. The record layout is the one dmgbuild writes.
"""
import argparse
import json
import os
import sys
import tempfile

try:
    from ds_store import DSStore
    from mac_alias import Alias, Bookmark
    from mac_alias.bookmark import URL, kBookmarkPath, kBookmarkVolumePath, kBookmarkVolumeURL
except ImportError as error:  # pragma: no cover - reported to the release script
    sys.exit(f"dmg-layout: {error}; run it through dmg_layout in scripts/release-functions.sh")

# Where the window opens on the screen; Finder moves it if that is off-screen.
WINDOW_ORIGIN = (200, 120)
# WindowBounds is the whole window. Without a toolbar the title bar takes this much.
TITLE_BAR = 28


def write_store(store_path, app, icon, window, icon_size, text_size, alias=None, bookmark=None):
    width, height = window
    window_settings = {
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "SidebarWidth": 0,
        "WindowBounds": f"{{{{{WINDOW_ORIGIN[0]}, {WINDOW_ORIGIN[1]}}}, {{{width}, {height + TITLE_BAR}}}}}",
    }
    icon_view = {
        "viewOptionsVersion": 1,
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundType": 2 if alias else 0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": float(icon_size),
        "labelOnBottom": True,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": False,
        "showItemInfo": False,
        "textSize": float(text_size),
    }
    if alias:
        icon_view["backgroundImageAlias"] = alias.to_bytes()
    with DSStore.open(store_path, "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = window_settings
        store["."]["icvp"] = icon_view
        if bookmark:
            store["."]["pBBk"] = bookmark
        store["."]["icvl"] = (b"type", b"icnv")
        store[app]["Iloc"] = tuple(icon)


def write(args):
    volume = os.path.realpath(args.volume)
    if not os.path.ismount(volume):
        sys.exit(f"dmg-layout: {volume} is not a mounted volume")
    for name in (args.app, args.background):
        if not os.path.exists(os.path.join(volume, name)):
            sys.exit(f"dmg-layout: {name} is not on the volume")
    background = os.path.join(volume, args.background)
    alias = Alias.for_file(background)
    bookmark = Bookmark.for_file(background)
    if alias.volume.posix_path != volume.encode() or bookmark.tocs[0][1][kBookmarkVolumePath] != volume:
        sys.exit(f"dmg-layout: {background} is not on the volume mounted at {volume}")
    # Both records note where the volume was mounted when they were made. Users get it at
    # /Volumes/<name>, which is also where dmgbuild has it while it writes these records.
    name = alias.volume.name
    name = name.decode() if isinstance(name, bytes) else name
    mounted_as = "/Volumes/" + name
    alias.volume.posix_path = mounted_as.encode()
    toc = bookmark.tocs[0][1]
    toc[kBookmarkVolumePath] = mounted_as
    toc[kBookmarkVolumeURL] = URL("file://" + mounted_as)
    write_store(os.path.join(volume, ".DS_Store"), args.app, args.icon, args.window,
                args.icon_size, args.text_size, alias, bookmark)


def text(value):
    return value.decode() if isinstance(value, bytes) else value


def describe(store_path):
    """What a .DS_Store says, in plain values. Missing records come out as None."""
    result = {"window": None, "icon_view": None, "background": None, "bookmark": None, "view": None, "icons": {}}
    with DSStore.open(store_path, "r") as store:
        for entry in store:
            if entry.filename != ".":
                if entry.code == b"Iloc":
                    result["icons"][entry.filename] = list(entry.value[:2])
                continue
            if entry.code == b"bwsp":
                result["window"] = dict(entry.value)
            elif entry.code == b"icvl":
                result["view"] = text(entry.value[1]) if isinstance(entry.value, tuple) else text(entry.value)
            elif entry.code == b"icvp":
                view = dict(entry.value)
                data = view.pop("backgroundImageAlias", None)
                result["icon_view"] = view
                if data:
                    alias = Alias.from_bytes(bytes(data))
                    result["background"] = {
                        "volume": text(alias.volume.name),
                        "volume_path": text(alias.volume.posix_path),
                        "path": text(alias.target.posix_path),
                        "carbon_path": text(alias.target.carbon_path).replace("\0", ""),
                    }
            elif entry.code == b"pBBk":
                value = entry.value
                bookmark = value if isinstance(value, Bookmark) else Bookmark.from_bytes(bytes(value))
                toc = bookmark.tocs[0][1]
                result["bookmark"] = {"path": "/".join(toc[kBookmarkPath]), "volume_path": toc[kBookmarkVolumePath]}
    return result


def selftest(_args):
    with tempfile.TemporaryDirectory() as folder:
        store = os.path.join(folder, ".DS_Store")
        write_store(store, "RimeLingo.app", (144, 196), (640, 400), 128, 13)
        found = describe(store)
    if found["icons"] != {"RimeLingo.app": [144, 196]} or found["view"] != "icnv" \
            or found["window"]["WindowBounds"] != f"{{{{200, 120}}, {{640, {400 + TITLE_BAR}}}}}" \
            or found["icon_view"]["iconSize"] != 128.0:
        sys.exit(f"dmg-layout: a layout did not survive being written and read: {found}")
    print("dmg-layout: ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    writing = commands.add_parser("write")
    writing.add_argument("volume")
    writing.add_argument("--app", required=True)
    writing.add_argument("--background", required=True)
    writing.add_argument("--icon", required=True, nargs=2, type=int, metavar=("X", "Y"))
    writing.add_argument("--window", required=True, nargs=2, type=int, metavar=("WIDTH", "HEIGHT"))
    writing.add_argument("--icon-size", type=int, default=128)
    writing.add_argument("--text-size", type=int, default=13)
    writing.set_defaults(run=write)
    reading = commands.add_parser("read")
    reading.add_argument("store")
    reading.set_defaults(run=lambda args: print(json.dumps(describe(args.store), ensure_ascii=False, indent=2, sort_keys=True)))
    commands.add_parser("selftest").set_defaults(run=selftest)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
