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
