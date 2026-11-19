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


class ThemeHookQuotingTest(unittest.TestCase):
    """The generated hook must treat the plugin path as data (review of 5df53ec)."""

    def test_hostile_path_is_not_executed(self):
        import shutil, subprocess, tempfile
        with tempfile.TemporaryDirectory() as tmp:
            evil = os.path.join(tmp, 'x"; touch PWNED; echo "')
            os.makedirs(evil)
            shutil.copy(os.path.join(HERE, "..", "install-theme-hook.sh"), evil)
            with open(os.path.join(evil, "actions.py"), "w") as f:
                f.write("import sys\nprint(sys.argv[1:])\n")
            home = os.path.join(tmp, "home")
            os.makedirs(home)
            env = dict(os.environ, HOME=home)
            subprocess.run(["bash", os.path.join(evil, "install-theme-hook.sh")], check=True, env=env, cwd=tmp, capture_output=True)
            hook = os.path.join(home, ".config/omarchy/hooks/theme-set.d/asus-rog-monitor-keyboard")
            out = subprocess.run(["bash", hook], env=env, cwd=tmp, capture_output=True, text=True)
            self.assertEqual(out.stdout.strip(), "['keyboard-reapply']")
            self.assertFalse(os.path.exists(os.path.join(tmp, "PWNED")))


class KillConfirmationTest(unittest.TestCase):
    """Confirming Close must only signal PIDs captured at the first click."""

    def test_panel_freezes_pids(self):
        with open(os.path.join(HERE, "..", "Panel.qml")) as f:
            source = f.read()
        self.assertIn("confirmKillPids = row.pids.slice()", source)
        self.assertNotIn('killProc.exec(["kill"].concat(row.pids', source)


if __name__ == "__main__":
    unittest.main()
