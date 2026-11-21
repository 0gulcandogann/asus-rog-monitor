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
        self.assertNotIn('killProc.exec(["kill"]', source)
        self.assertIn('"close"', source)



def load_module(name):
    s = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", name + ".py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


class CloseTest(unittest.TestCase):
    """Close must signal only the exact process (PID + start time) that was shown."""

    def setUp(self):
        import subprocess
        self.actions = load_module("actions")
        self.child = subprocess.Popen(["sleep", "60"])
        self.started = self.actions.start_time(self.child.pid)

    def tearDown(self):
        self.child.kill()
        self.child.wait()

    def test_scan_tokens_carry_start_time(self):
        rows = stats.Processes().scan()
        self.assertEqual(rows[self.child.pid][4], self.started)

    def test_matching_start_time_is_terminated(self):
        self.actions.close(f"{self.child.pid}:{self.started}")
        self.assertEqual(self.child.wait(timeout=5), -15)

    def test_recycled_pid_with_other_start_time_survives(self):
        self.actions.close(f"{self.child.pid}:{int(self.started) + 1}")
        self.assertIsNone(self.child.poll())

    def test_malformed_target_is_rejected(self):
        with self.assertRaises(SystemExit):
            self.actions.close("123")


class GpuSamplerTest(unittest.TestCase):
    """The pmon sampler must not block on a full pipe or a hung child."""

    def run_with_fake_smi(self, script):
        import stat as st, tempfile
        tmp = tempfile.mkdtemp()
        path = os.path.join(tmp, "nvidia-smi")
        with open(path, "w") as f:
            f.write("#!/bin/bash\n" + script)
        os.chmod(path, os.stat(path).st_mode | st.S_IXUSR)
        old = os.environ["PATH"]
        os.environ["PATH"] = tmp + os.pathsep + old
        self.addCleanup(lambda: os.environ.update(PATH=old))
        p = stats.Processes()

        def cleanup():
            if p.gpu_job:
                p.gpu_job[0].kill()
                p.gpu_job[0].wait()
                p.gpu_job[1].close()
        self.addCleanup(cleanup)
        return p

    def test_large_output_does_not_block_and_is_parsed(self):
        p = self.run_with_fake_smi('for i in $(seq 1 20000); do echo "0 $i G 50 1 0 0 0 1 100 x"; done\n')
        p.poll_gpu()
        deadline = __import__("time").monotonic() + 10
        while p.gpu_job and p.gpu_job[0].poll() is None and __import__("time").monotonic() < deadline:
            __import__("time").sleep(0.05)
        p.cycles = 0
        p.poll_gpu()
        self.assertEqual(len(p.gpu_rows), 20000)

    def test_hung_job_is_killed_after_limit(self):
        p = self.run_with_fake_smi("exec sleep 60\n")
        p.GPU_JOB_LIMIT = 0.2
        p.poll_gpu()
        job = p.gpu_job[0]
        __import__("time").sleep(0.4)
        p.cycles = 1  # do not start a new job in this call
        p.poll_gpu()
        self.assertIsNone(p.gpu_job)
        self.assertIsNotNone(job.poll())


if __name__ == "__main__":
    unittest.main()
