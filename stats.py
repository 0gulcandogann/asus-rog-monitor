#!/usr/bin/env python3
"""Print one JSON line of system stats every <interval> seconds until stdout closes."""
import fcntl
import glob
import json
import os
import shutil
import subprocess
import sys
import threading
import time

GPU_FIELDS = "power.draw,enforced.power.limit,power.default_limit,utilization.gpu,temperature.gpu,clocks.gr,memory.used,memory.total"


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def hwmon(name):
    for path in glob.glob("/sys/class/hwmon/hwmon*"):
        if read(path + "/name") == name:
            return path
    return None


def cpu_temp_path():
    """Package temperature input: AMD k10temp (Tctl), else Intel coretemp (Package id 0)."""
    k10 = hwmon("k10temp")
    if k10:
        return k10 + "/temp1_input"
    core = hwmon("coretemp")
    if core:
        for label in sorted(glob.glob(core + "/temp*_label")):
            if read(label).startswith("Package id"):
                return label[: -len("_label")] + "_input"
        return core + "/temp1_input"
    return None


def milli(path):
    value = number(read(path)) if path else None
    return None if value is None else value / 1000


class TempWindow:
    """Average of the readings from the last `span` seconds.

    Tctl on these Ryzen laptops swings 45 -> 95 C within seconds; a single
    sample every few seconds made the bar number jump. The bar shows this
    average; the detailed panel keeps the instant value.
    """

    def __init__(self, span):
        self.span = span
        self.samples = []

    def add(self, now, value):
        if value is not None:
            self.samples.append((now, value))
        self.samples = [(t, v) for t, v in self.samples if now - t <= self.span]

    def mean(self):
        if not self.samples:
            return None
        return sum(v for _, v in self.samples) / len(self.samples)


def cpu_times():
    times = []
    with open("/proc/stat") as f:
        for line in f:
            if not line.startswith("cpu"):
                break
            values = [int(v) for v in line.split()[1:]]
            times.append((sum(values[:8]), values[3] + values[4]))
    return times


def usage(before, after):
    result = []
    for (total_a, idle_a), (total_b, idle_b) in zip(before, after):
        total = total_b - total_a
        result.append(round(100 * (total - (idle_b - idle_a)) / total, 1) if total > 0 else 0)
    return result


def cpu_frequency():
    values = [number(read(p)) for p in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")]
    values = [v for v in values if v]
    if not values:
        return None, None
    return round(sum(values) / len(values) / 1e6, 2), round(max(values) / 1e6, 2)


def memory():
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, _, rest = line.partition(":")
            info[key] = int(rest.split()[0]) / 1048576
    return {
        "used": round(info["MemTotal"] - info["MemAvailable"], 1),
        "total": round(info["MemTotal"], 1),
        "swapUsed": round(info["SwapTotal"] - info["SwapFree"], 1),
        "swapTotal": round(info["SwapTotal"], 1),
    }


def gpu():
    try:
        output = subprocess.run(
            ["nvidia-smi", "--query-gpu=" + GPU_FIELDS, "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=3, check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    values = [number(v.strip()) for v in output.splitlines()[0].split(",")]
    if len(values) != 8:
        return None
    keys = ["power", "limit", "defaultLimit", "util", "temp", "clock", "memUsed", "memTotal"]
    return dict(zip(keys, values))


STATE_FILE = os.path.expanduser("~/.local/state/asus-rog-monitor/state.json")
# Closing these would end the desktop session or this panel, so the panel offers no button for them.
PROTECTED = {
    "systemd", "Hyprland", "quickshell", "qs", "uwsm", "python3", "dbus-daemon", "dbus-broker",
    "dbus-broker-launch", "pipewire", "pipewire-pulse", "wireplumber", "Xwayland", "sddm",
    "xdg-desktop-portal", "xdg-desktop-portal-hyprland", "start-hyprland", "polkitd", "nvidia-powerd",
}
HAS_ASUS = shutil.which("asusctl") is not None
MODEL = read("/sys/class/dmi/id/product_name").split("_")[0].upper()
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
CLOCK_TICKS = os.sysconf("SC_CLK_TCK")
CPU_COUNT = os.cpu_count() or 1


class Processes:
    """Per-application CPU, RAM and GPU use, grouped by process name."""

    def __init__(self):
        self.previous = {}
        self.previous_time = time.monotonic()
        self.gpu_job = None
        self.gpu_rows = []
        self.cycles = 0

    def scan(self):
        rows = {}
        for entry in os.scandir("/proc"):
            if not entry.name.isdigit():
                continue
            try:
                with open(f"/proc/{entry.name}/stat") as f:
                    stat = f.read()
                with open(f"/proc/{entry.name}/statm") as f:
                    resident = int(f.read().split()[1])
                owner = entry.stat().st_uid
            except (OSError, IndexError, ValueError):
                continue
            name = stat[stat.find("(") + 1:stat.rfind(")")]
            fields = stat[stat.rfind(")") + 2:].split()
            rows[int(entry.name)] = (name, int(fields[11]) + int(fields[12]), resident * PAGE_SIZE, owner)
        return rows

    def poll_gpu(self):
        # pmon takes about a second, so it runs beside the sampler and is collected later.
        if self.gpu_job and self.gpu_job.poll() is not None:
            rows = []
            for line in self.gpu_job.stdout.read().splitlines():
                parts = line.split()
                if line.startswith("#") or len(parts) < 11 or not parts[1].isdigit():
                    continue
                rows.append((int(parts[1]), number(parts[3]) or 0, number(parts[9]) or 0))
            self.gpu_rows = rows
            self.gpu_job = None
        if self.gpu_job is None and self.cycles % 5 == 0:
            try:
                self.gpu_job = subprocess.Popen(
                    ["nvidia-smi", "pmon", "-c", "1", "-s", "um"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                )
            except OSError:
                self.gpu_job = None
        self.cycles += 1

    def snapshot(self):
        now = time.monotonic()
        elapsed = max(0.1, now - self.previous_time)
        rows = self.scan()
        uid = os.getuid()
        groups = {}
        for pid, (name, ticks, resident, owner) in rows.items():
            group = groups.setdefault(name, {"name": name, "cpu": 0.0, "ram": 0, "pids": [], "own": True})
            earlier = self.previous.get(pid)
            if earlier:
                group["cpu"] += max(0, ticks - earlier[1]) / CLOCK_TICKS / elapsed / CPU_COUNT * 100
            group["ram"] += resident
            group["pids"].append(pid)
            group["own"] = group["own"] and owner == uid
        self.previous = rows
        self.previous_time = now
        self.poll_gpu()

        def row(group, value, order):
            killable = group["own"] and group["name"] not in PROTECTED
            return {"name": group["name"], "value": value, "order": order, "pids": group["pids"] if killable else []}

        cpu = sorted(groups.values(), key=lambda g: -g["cpu"])[:5]
        ram = sorted(groups.values(), key=lambda g: -g["ram"])[:5]
        gpu_groups = {}
        for pid, usage, framebuffer in self.gpu_rows:
            if pid not in rows:
                continue
            name = rows[pid][0]
            total = gpu_groups.setdefault(name, [0, 0])
            total[0] += usage
            total[1] += framebuffer
        gpu_top = sorted(gpu_groups.items(), key=lambda item: (-item[1][0], -item[1][1]))[:5]
        return {
            "cpu": [row(g, f"{g['cpu']:.1f}%", g["cpu"]) for g in cpu],
            "ram": [row(g, f"{g['ram'] / 1073741824:.1f} GB", g["ram"]) for g in ram],
            "gpu": [row(groups[n], f"{v[0]:.0f}%  {v[1]:.0f} MB", v[0]) for n, v in gpu_top],
        }, any(name == "nvidia-powerd" for name, *_ in rows.values())


class DriverStatus:
    """NVIDIA driver version, and whether pacman has a newer one. Checks at most every six hours."""

    MAX_AGE = 6 * 3600
    # A failed check, usually from running before the network is up, should not count for six hours.
    RETRY_AGE = 15 * 60
    PACKAGES = ("nvidia-utils", "nvidia-open-dkms", "nvidia-dkms", "nvidia")

    def __init__(self):
        self.cache_file = os.path.join(os.path.dirname(STATE_FILE), "driver.json")
        self.worker = None
        self.installed = None
        self.installed_at = -1000.0

    def load(self):
        try:
            with open(self.cache_file) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def is_fresh(self, cache):
        if not cache:
            return False
        limit = self.MAX_AGE if cache.get("ok") else self.RETRY_AGE
        return time.time() - cache.get("checked", 0) < limit

    def check(self):
        # One panel per monitor runs this, so a lock keeps the check and notification single.
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file + ".lock", "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return
            previous = self.load() or {}
            if self.is_fresh(previous):
                return
            result = {"checked": time.time(), "available": None, "ok": False, "notified": previous.get("notified")}
            try:
                run = subprocess.run(["checkupdates"], capture_output=True, text=True, timeout=120)
                # checkupdates exits 0 with updates, 2 with none, and anything else on failure.
                if run.returncode in (0, 2):
                    result["ok"] = True
                    for line in run.stdout.splitlines():
                        parts = line.split()
                        if len(parts) >= 4 and parts[0] in self.PACKAGES:
                            result["available"] = parts[3].split("-")[0]
                            break
            except (OSError, subprocess.SubprocessError):
                result["available"] = previous.get("available")
                result["ok"] = previous.get("ok", False)
            if result["available"] and result["available"] != result["notified"]:
                result["notified"] = result["available"]
                try:
                    subprocess.run(
                        ["notify-send", "GPU driver update", "NVIDIA " + result["available"] + " is available."],
                        timeout=5, check=False,
                    )
                except (OSError, subprocess.SubprocessError):
                    pass
            with open(self.cache_file + ".tmp", "w") as f:
                json.dump(result, f)
            os.replace(self.cache_file + ".tmp", self.cache_file)

    def installed_version(self):
        # A pacman call for every sample would be wasteful, and the version rarely changes.
        if time.monotonic() - self.installed_at > 60:
            self.installed_at = time.monotonic()
            try:
                output = subprocess.run(["pacman", "-Q", "nvidia-utils"], capture_output=True, text=True, timeout=3).stdout
                self.installed = output.split()[1].split("-")[0]
            except (OSError, IndexError, subprocess.SubprocessError):
                self.installed = None
        return self.installed

    def snapshot(self):
        loaded = read("/sys/module/nvidia/version")
        if not loaded:
            return None
        cache = self.load()
        running = self.worker is not None and self.worker.is_alive()
        if not self.is_fresh(cache) and not running and shutil.which("checkupdates"):
            self.worker = threading.Thread(target=self.check, daemon=True)
            self.worker.start()
        installed = self.installed_version()
        # The cache can still name a version that has since been installed.
        available = (cache or {}).get("available")
        if available == installed:
            available = None
        if installed and installed != loaded:
            state = "restart"
        elif cache and cache.get("ok"):
            state = "update" if available else "current"
        else:
            state = "unknown"
        return {"version": loaded, "state": state, "available": available}


def preferences():
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    return {key: state[key] for key in ("systemColor", "barItems") if key in state}


def controls(profile):
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    battery = glob.glob("/sys/class/power_supply/BAT*")
    adapter = glob.glob("/sys/class/power_supply/A*/online")
    return {
        "keyboard": state.get("keyboard") or {"mode": "static", "colour": ""},
        "keyboardLevel": number(read("/sys/class/leds/asus::kbd_backlight/brightness")),
        "fanPreset": state.get("fan", {}).get(profile, "AUTO"),
        "batteryLimit": number(read(battery[0] + "/charge_control_end_threshold")) if battery else None,
        "batteryPercent": number(read(battery[0] + "/capacity")) if battery else None,
        "onAc": read(adapter[0]) == "1" if adapter else None,
    }


def is_asus_system():
    return any(read("/sys/class/dmi/id/" + name).upper().startswith("ASUS") for name in ("sys_vendor", "board_vendor"))


def wait_as_unsupported():
    """Other hardware only gets the notice, so nothing is read or checked in the background."""
    try:
        print(json.dumps({"supported": False, "model": MODEL}), flush=True)
    except BrokenPipeError:
        os._exit(0)
    while True:
        time.sleep(3600)


def main():
    if not is_asus_system():
        wait_as_unsupported()
    detailed = len(sys.argv) > 2 and sys.argv[2] == "detail"
    processes = Processes() if detailed else None
    driver = DriverStatus()
    if processes:
        processes.snapshot()
    interval = max(0.5, float(sys.argv[1])) if len(sys.argv) > 1 else 3.0
    before = cpu_times()
    cpu_temp_window = TempWindow(5.0)
    time.sleep(0.25)
    while True:
        after = cpu_times()
        cores = usage(before, after)
        before = after
        cpu_temp = cpu_temp_path()
        asus = hwmon("asus")
        nvme = hwmon("nvme")
        average, peak = cpu_frequency()
        stats = {
            "cpu": cores[0] if cores else 0,
            "cores": cores[1:],
            "cpuTemp": milli(cpu_temp),
            "cpuTempAvg": None,
            "cpuGhz": average,
            "cpuPeakGhz": peak,
            "load": read("/proc/loadavg").split()[:3],
            "ram": memory(),
            "gpu": gpu(),
            "cpuFan": number(read(asus + "/fan1_input")) if asus else None,
            "gpuFan": number(read(asus + "/fan2_input")) if asus else None,
            "nvmeTemp": milli(nvme + "/temp1_input") if nvme else None,
            "profile": read("/sys/firmware/acpi/platform_profile"),
            "supported": True,
            "hasAsus": HAS_ASUS,
            "model": MODEL,
        }
        cpu_temp_window.add(time.monotonic(), stats["cpuTemp"])
        stats["cpuTempAvg"] = cpu_temp_window.mean()
        stats["prefs"] = preferences()
        stats["driver"] = driver.snapshot()
        if processes:
            stats["top"], stats["powerd"] = processes.snapshot()
            stats.update(controls(stats["profile"]))
        try:
            print(json.dumps(stats), flush=True)
        except BrokenPipeError:
            os._exit(0)
        # Sample the CPU temperature twice a second between reports so the
        # average covers the whole span, not one reading per report.
        deadline = time.monotonic() + interval
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            time.sleep(min(0.5, left))
            if cpu_temp:
                cpu_temp_window.add(time.monotonic(), milli(cpu_temp))


if __name__ == "__main__":
    main()
