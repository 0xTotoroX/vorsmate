#!/usr/bin/env python3
"""Copy the selected SayAll RC003 key settings into a standalone Vorsmate profile."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import tempfile

KEYS = ("power", "up", "left", "ok", "right", "down", "back", "home",
        "menu", "tv", "volume_up", "volume_down")
GESTURES = {"singleClick": "single", "doubleClick": "double", "longPress": "long"}
ACTIONS = {"disabled": "none", "volumeUp": "volumeUp", "volumeDown": "volumeDown",
           "volumeMute": "mute", "playPause": "playPause", "previousCommandLeft": "previousTrack",
           "nextCommandRight": "nextTrack"}
DICTATION_SHORTCUT = {"kind": "shortcut", "keyCode": 9, "label": "V", "flags": 0xC0021}
KEYCODES = {"escape": (53, "Esc"), "returnKey": (36, "回车"), "deleteBackward": (51, "退格"),
            "arrowLeft": (123, "←"), "arrowRight": (124, "→"), "arrowUp": (126, "↑"), "arrowDown": (125, "↓")}


def convert_action(record, apps):
    name = record["action"]
    if name in ACTIONS:
        return {"kind": ACTIONS[name]}
    if name in KEYCODES:
        code, label = KEYCODES[name]
        return {"kind": "shortcut", "keyCode": code, "label": label, "flags": 0}
    if name == "customShortcut":
        shortcut = record["shortcut"]
        return {"kind": "shortcut", "keyCode": shortcut["keyCode"], "label": shortcut["keyLabel"],
                "flags": shortcut["modifierFlagsRawValue"]}
    if name == "openCustomApplication":
        app = apps[record["applicationProfileID"]]
        if app.get("focusStrategy", "none") != "none":
            raise ValueError("此应用启动动作带有尚不支持的聚焦操作")
        return {"kind": "openApplication", "bundleID": app["bundleIdentifier"],
                "path": app["applicationPath"], "label": app["displayName"]}
    raise ValueError(f"尚未支持的动作 {name}")


def convert(data):
    def unpack(key, default):
        return json.loads(data[key]) if key in data else default

    selected = data["selectedRemoteProfileID"]
    device = next(p for p in unpack("remoteDeviceProfiles", []) if p["id"] == selected)
    if device["model"] != "rc003":
        raise ValueError("所选设备不是 RC003")
    mappings = device["mappings"]
    apps = {a["id"]: a for a in unpack("customApplicationProfiles", [])}
    timing = mappings["interactionSettings"]
    if timing.get("modes") or data.get("voiceKeyMode") != "fn" or data.get("voiceFnTapModeEnabled"):
        raise ValueError("该设备的长按模式或语音键设置与目前支持的配置不同")
    bindings = {}
    for key in dict.fromkeys((*KEYS, *mappings["buttonBindings"])):
        single = {"action": mappings["buttonBindings"][key], "shortcut": mappings["buttonShortcuts"].get(key),
                  "applicationProfileID": mappings["buttonApplicationProfileIDs"].get(key)}
        gestures = {"singleClick": single, **mappings["secondaryButtonBindings"].get(key, {})}
        for item in unpack("unifiedBaseBindings", []):
            if item.get("remoteProfileID") == selected and item["button"] == key:
                gestures[item["trigger"]] = item["configured"]
        binding = {slot: {"kind": "none"} for slot in GESTURES.values()}
        for trigger, record in gestures.items():
            binding[GESTURES[trigger]] = convert_action(record, apps)
        binding["rapid"] = mappings["buttonRapidPressEnabled"].get(key, False)
        bindings[key] = binding
    # The user explicitly replaced this one gesture with the tested dictation toggle.
    bindings["ok"]["single"] = DICTATION_SHORTCUT.copy()
    return {"version": 1, "buttons": bindings, "voiceFn": True,
            "doubleMilliseconds": timing["doubleClickMilliseconds"], "longMilliseconds": timing["longPressMilliseconds"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.home() / "Library/Preferences/com.hd838a.RemoteMic.plist")
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Application Support/VorsmateRemote/buttons.json")
    args = parser.parse_args()
    profile = convert(plistlib.loads(args.source.read_bytes()))
    if args.output.exists():
        existing = json.loads(args.output.read_bytes())
        # Compare the old named preset without rewriting the user's file.
        if isinstance(existing, dict) and isinstance(existing.get("buttons"), dict):
            ok = existing["buttons"].get("ok")
            if isinstance(ok, dict) and ok.get("single") == {"kind": "typeless"}:
                ok["single"] = DICTATION_SHORTCUT
        if existing != profile:
            parser.error("目标已有不同配置。请用 --output 选择另一个文件，不会覆盖已有编辑。")
    else:
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=args.output.parent, mode="w", encoding="utf8", delete=False) as file:
            temp = Path(file.name)
            try:
                json.dump(profile, file, ensure_ascii=False, indent=2, sort_keys=True)
                file.write("\n")
                file.flush()
                os.fsync(file.fileno())
                os.link(temp, args.output)
            finally:
                temp.unlink(missing_ok=True)
    print(f"已核对 12 个普通键、语音键和各键手势。配置位置 {args.output}")


if __name__ == "__main__":
    main()
