#!/usr/bin/env python3
"""Control actions for the System Monitor panel.

keyboard <static|breathe|rainbow> [rrggbb]   apply and remember a keyboard effect
keyboard-reapply                             apply the remembered effect again
fan <AUTO|COOL|MAX>                          set the active profile's fan curve
system-color <rrggbb>                        set the colour of the panel, bar and logo
bar-items <item,item,...>                    choose what the bar shows
close <pid:start> ...                        ask those exact processes to quit
"""
import json
import os
import re
import signal
import subprocess
import sys

STATE_FILE = os.path.expanduser("~/.local/state/asus-rog-monitor/state.json")
# Every preset stays above the stock curves, so it can only add cooling.
FAN_TEMPS = [40, 50, 55, 60, 65, 70, 75, 90]
FAN_PRESETS = {
    "COOL": [30, 40, 50, 60, 70, 85, 100, 100],
    "MAX": [100, 100, 100, 100, 100, 100, 100, 100],
}


BAR_ITEMS = {"logo", "cpu", "cpuTemp", "cores", "ram", "gpu", "gpuTemp"}


def colour_value(text):
    colour = text.lstrip("#").lower()
    if not re.fullmatch(r"[0-9a-f]{6}", colour):
        raise SystemExit("invalid colour: " + text)
    return colour


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    temporary = STATE_FILE + ".tmp"
    with open(temporary, "w") as f:
        json.dump(state, f)
    os.replace(temporary, STATE_FILE)


def asusctl(*args):
    subprocess.run(["asusctl", *args], check=True, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)


def apply_keyboard(mode, colour):
    if mode == "static":
        asusctl("aura", "effect", "static", "-c", colour)
    elif mode == "breathe":
        asusctl("aura", "effect", "breathe", "--colour", colour, "--colour2", "000000", "--speed", "med")
    elif mode == "rainbow":
        asusctl("aura", "effect", "rainbow-wave", "--direction", "right", "--speed", "med")
    else:
        raise SystemExit("unknown keyboard mode: " + mode)


def keyboard(mode, colour=None):
    state = load_state()
    saved = state.get("keyboard", {})
    colour = colour_value(colour or saved.get("colour") or "ff0033")
    apply_keyboard(mode, colour)
    state["keyboard"] = {"mode": mode, "colour": colour}
    save_state(state)


def keyboard_reapply():
    saved = load_state().get("keyboard")
    if saved:
        apply_keyboard(saved["mode"], saved["colour"])


def fan(preset):
    with open("/sys/firmware/acpi/platform_profile") as f:
        profile = f.read().strip().capitalize()
    if preset == "AUTO":
        asusctl("fan-curve", "--mod-profile", profile, "--enable-fan-curves", "false")
    elif preset in FAN_PRESETS:
        data = ",".join(f"{t}c:{p}%" for t, p in zip(FAN_TEMPS, FAN_PRESETS[preset]))
        for name in ("cpu", "gpu"):
            asusctl("fan-curve", "--mod-profile", profile, "--fan", name, "--data", data)
        asusctl("fan-curve", "--mod-profile", profile, "--enable-fan-curves", "true")
    else:
        raise SystemExit("unknown fan preset: " + preset)
    state = load_state()
    state.setdefault("fan", {})[profile.lower()] = preset
    save_state(state)


def save_preference(key, value):
    state = load_state()
    state[key] = value
    save_state(state)


def start_time(pid):
    """Start time of a process (field 22 of /proc/<pid>/stat), or None if it is gone."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            stat = f.read()
    except OSError:
        return None
    return stat[stat.rfind(")") + 2:].split()[19]


def close(*targets):
    """Send SIGTERM to processes named as pid:start, only if they are still exactly those processes.

    A pidfd refers to one process for good, so once the start time matches there is no window
    in which a recycled PID could receive the signal."""
    for target in targets:
        pid, _, started = target.partition(":")
        if not (pid.isdigit() and started.isdigit()):
            raise SystemExit("invalid target: " + target)
        try:
            fd = os.pidfd_open(int(pid))
        except OSError:
            continue
        try:
            # Checked after the pidfd is open: from here on the pidfd cannot point at a newer process.
            if start_time(pid) != started or os.stat(f"/proc/{pid}").st_uid != os.getuid():
                continue
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        except OSError:
            pass
        finally:
            os.close(fd)


def is_asus_system():
    for name in ("sys_vendor", "board_vendor"):
        try:
            with open("/sys/class/dmi/id/" + name) as f:
                if f.read().strip().upper().startswith("ASUS"):
                    return True
        except OSError:
            pass
    return False


def main():
    if not is_asus_system():
        raise SystemExit("This plugin only works on ASUS and ROG devices.")
    command, args = sys.argv[1], sys.argv[2:]
    if command == "keyboard":
        keyboard(*args)
    elif command == "keyboard-reapply":
        keyboard_reapply()
    elif command == "close":
        close(*args)
    elif command == "fan":
        fan(*args)
    elif command == "system-color":
        save_preference("systemColor", colour_value(args[0]))
    elif command == "bar-items":
        items = [item for item in args[0].split(",") if item in BAR_ITEMS]
        if not items:
            raise SystemExit("no valid bar items")
        save_preference("barItems", items)
    else:
        raise SystemExit("unknown command: " + command)


if __name__ == "__main__":
    main()
