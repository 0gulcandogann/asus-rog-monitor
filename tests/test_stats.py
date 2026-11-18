"""Run: python3 -I -m unittest discover -s tests (from the plugin folder)."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("stats", os.path.join(HERE, "..", "stats.py"))
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)


class TempWindowTest(unittest.TestCase):
    def test_empty_window_has_no_value(self):
        self.assertIsNone(stats.TempWindow(5).mean())

    def test_mean_of_recent_samples(self):
        w = stats.TempWindow(5)
        for t, v in [(0, 48), (1, 90), (2, 50)]:
            w.add(t, v)
        self.assertAlmostEqual(w.mean(), (48 + 90 + 50) / 3)

    def test_a_single_spike_is_damped(self):
        w = stats.TempWindow(5)
        for t in range(10):
            w.add(t * 0.5, 48)
        w.add(5.0, 92)
        self.assertLess(w.mean(), 55)

    def test_old_samples_drop_out(self):
        w = stats.TempWindow(5)
        w.add(0, 90)
        w.add(10, 50)
        self.assertEqual(w.mean(), 50)

    def test_none_readings_are_ignored(self):
        w = stats.TempWindow(5)
        w.add(0, None)
        w.add(1, 60)
        self.assertEqual(w.mean(), 60)


class CpuTempPathTest(unittest.TestCase):
    """AMD laptops expose k10temp; Intel ones (e.g. Zephyrus M16 GU604) only coretemp."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sensors = {}
        original = stats.hwmon
        stats.hwmon = lambda name: self.sensors.get(name)
        self.addCleanup(setattr, stats, "hwmon", original)

    def sensor(self, name, files):
        path = os.path.join(self.tmp.name, name)
        os.makedirs(path)
        for file, text in files.items():
            with open(os.path.join(path, file), "w") as f:
                f.write(text + "\n")
        self.sensors[name] = path
        return path

    def test_prefers_k10temp(self):
        k10 = self.sensor("k10temp", {"temp1_input": "55000"})
        self.sensor("coretemp", {"temp1_input": "70000", "temp1_label": "Package id 0"})
        self.assertEqual(stats.cpu_temp_path(), k10 + "/temp1_input")

    def test_intel_uses_package_sensor(self):
        core = self.sensor("coretemp", {
            "temp2_input": "58000", "temp2_label": "Core 0",
            "temp1_input": "61000", "temp1_label": "Package id 0",
        })
        path = stats.cpu_temp_path()
        self.assertEqual(path, core + "/temp1_input")
        self.assertEqual(stats.milli(path), 61.0)

    def test_intel_without_labels_falls_back_to_temp1(self):
        core = self.sensor("coretemp", {"temp1_input": "61000"})
        self.assertEqual(stats.cpu_temp_path(), core + "/temp1_input")

    def test_no_cpu_sensor(self):
        self.assertIsNone(stats.cpu_temp_path())
        self.assertIsNone(stats.milli(stats.cpu_temp_path()))


if __name__ == "__main__":
    unittest.main()


class NoEditableTextControlsTest(unittest.TestCase):
    """Qt's editable text controls probe the Wayland clipboard on every
    clipboard change (canPaste), which can stall the shared shell on a huge or
    slow clipboard owner (marketplace review of eff8a8d). The plugin must use
    its own key-driven entry instead."""

    def test_no_text_field_input_or_edit(self):
        import re
        for name in os.listdir(os.path.join(HERE, "..")):
            if not name.endswith(".qml"):
                continue
            with open(os.path.join(HERE, "..", name)) as f:
                source = f.read()
            found = re.findall(r"^\s*(TextField|TextInput|TextEdit|TextArea)\s*\{", source, re.M)
            self.assertEqual(found, [], name)
