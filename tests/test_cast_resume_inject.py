"""Unit tests for scripts/cast-resume-inject.py (post-selection race guard).

Ported from the former PATH-shim bats tests: the race window between select()
and read_body() is now inside one process, so the swap is deterministic.
"""
import contextlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import types
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_PATH = os.path.join(REPO, "scripts", "cast-resume-inject.py")


def _load():
    spec = importlib.util.spec_from_file_location("cast_resume_inject", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Hang(Exception):
    pass


class PostSelectionRaceTests(unittest.TestCase):
    SLUG = "repo"
    NAME = "2026-11-22-repo-auto.md"

    def setUp(self):
        self.mod = _load()
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = os.path.join(self._tmp.name, "resume-prompts")
        os.mkdir(self.dir)
        self.path = os.path.join(self.dir, self.NAME)
        with open(self.path, "w") as f:
            f.write("AUTO-BODY\n")
        self.calls = 0

    def _install_swap(self, swap):
        real = self.mod.select

        def wrapped(d, slug):
            self.calls += 1
            chosen = real(d, slug)
            if swap is not None and chosen:
                swap(chosen[1])
            return chosen

        self.mod.select = wrapped

    def _run_main(self):
        raw = io.BytesIO()
        out = io.TextIOWrapper(raw, encoding="utf-8", write_through=True)
        stdin = types.SimpleNamespace(buffer=io.BytesIO(b'{"source": "startup"}'))
        old_stdin = sys.stdin
        sys.stdin = stdin
        old_handler = signal.signal(signal.SIGALRM, self._on_alarm)
        signal.setitimer(signal.ITIMER_REAL, 5)
        try:
            with contextlib.redirect_stdout(out):
                rc = self.mod.main(["cast-resume-inject.py", self.dir, self.SLUG])
        except _Hang:
            self.fail("main() hung on the swapped file (no O_NONBLOCK guard?)")
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, old_handler)
            sys.stdin = old_stdin
        out.flush()
        return rc, raw.getvalue().decode("utf-8")

    @staticmethod
    def _on_alarm(signum, frame):
        raise _Hang()

    def test_control_no_swap_injects_body(self):
        self._install_swap(None)
        rc, out = self._run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls, 1)
        data = json.loads(out)
        self.assertIn("AUTO-BODY", data["hookSpecificOutput"]["additionalContext"])

    def test_swapped_to_fifo_rc3_no_hang(self):
        def swap(path):
            os.unlink(path)
            os.mkfifo(path)

        self._install_swap(swap)
        # Unblock a stuck reader (if the guard ever regresses) so nothing leaks.
        def _unstick():
            try:
                fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
                os.close(fd)
            except OSError:
                pass

        self.addCleanup(_unstick)
        rc, out = self._run_main()
        self.assertEqual(self.calls, 1)
        self.assertEqual(rc, 3)
        self.assertEqual(out, self.NAME)
        self.assertNotIn("additionalContext", out)

    def test_swapped_to_symlink_not_followed(self):
        target = os.path.join(self._tmp.name, "raced.md")
        with open(target, "w") as f:
            f.write("RACED-BODY\n")

        def swap(path):
            os.unlink(path)
            os.symlink(target, path)

        self._install_swap(swap)
        rc, out = self._run_main()
        self.assertEqual(self.calls, 1)
        self.assertEqual(rc, 3)
        self.assertEqual(out, self.NAME)
        self.assertNotIn("RACED-BODY", out)


def _run(mod, argv, payload=b"", stdin_obj=None):
    raw = io.BytesIO()
    out = io.TextIOWrapper(raw, encoding="utf-8", write_through=True)
    old = sys.stdin
    sys.stdin = stdin_obj or types.SimpleNamespace(buffer=io.BytesIO(payload))
    try:
        with contextlib.redirect_stdout(out):
            rc = mod.main(["x"] + argv)
    finally:
        sys.stdin = old
    out.flush()
    return rc, raw.getvalue().decode("utf-8")


class ReadPayloadTests(unittest.TestCase):
    def setUp(self):
        self.mod = _load()

    def _rp(self, data):
        old = sys.stdin
        sys.stdin = types.SimpleNamespace(buffer=io.BytesIO(data))
        try:
            return self.mod._read_payload()
        finally:
            sys.stdin = old

    def test_nuls_dropped_and_trailing_newlines_stripped(self):
        self.assertEqual(self._rp(b'{"a"\x00:1}\n\n'), '{"a":1}')

    def test_cap_4096_chars(self):
        self.assertEqual(len(self._rp(b"x" * 10000)), 4096)

    def test_huge_payload_is_drained_not_hung(self):
        class Stream(io.RawIOBase):
            def __init__(self, n):
                self.left = n
                self.served = 0

            def readable(self):
                return True

            def readinto(self, b):
                k = min(len(b), self.left)
                b[:k] = b"y" * k
                self.left -= k
                self.served += k
                return k

        st = Stream(5 * 1024 * 1024)
        buf = io.BufferedReader(st)
        old = sys.stdin
        sys.stdin = types.SimpleNamespace(buffer=buf)
        try:
            out = self.mod._read_payload()
        finally:
            sys.stdin = old
        self.assertEqual(len(out), 4096)
        self.assertEqual(st.left, 0)   # fully consumed, so a writer never blocks

    def test_endless_stdin_is_bounded_by_discard_cap(self):
        class Endless(io.RawIOBase):
            served = 0

            def readable(self):
                return True

            def readinto(self, b):
                b[:] = b"y" * len(b)
                Endless.served += len(b)
                return len(b)

        def on_alarm(signum, frame):
            raise AssertionError("_read_payload spun on endless stdin (no discard cap)")

        st = Endless()
        old = sys.stdin
        sys.stdin = types.SimpleNamespace(buffer=io.BufferedReader(st))
        old_h = signal.signal(signal.SIGALRM, on_alarm)
        signal.setitimer(signal.ITIMER_REAL, 5)
        try:
            out = self.mod._read_payload()
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, old_h)
            sys.stdin = old
        self.assertEqual(len(out), 4096)
        self.assertLess(Endless.served, self.mod.DISCARD_CAP + 64 * 1024 + 192 * 1024)  # one chunk + BufferedReader read-ahead slack


class MainBehaviourTests(unittest.TestCase):
    SLUG = "repo"

    def setUp(self):
        self.mod = _load()
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = os.path.join(self._tmp.name, "rp")
        os.mkdir(self.dir)

    def _w(self, name, data, mode="w"):
        with open(os.path.join(self.dir, name), mode) as f:
            f.write(data)

    def test_newline_in_dir_path_injects_nothing(self):
        d = os.path.join(self._tmp.name, "h\nx")
        os.mkdir(d)
        with open(os.path.join(d, "2026-11-22-repo-auto.md"), "w") as f:
            f.write("BODY\n")
        self.assertEqual(_run(self.mod, [d, self.SLUG]), (0, ""))

    def test_empty_body_rc4_prints_basename(self):
        self._w("2026-11-22-repo-auto.md", "")
        self.assertEqual(_run(self.mod, [self.dir, self.SLUG]), (4, "2026-11-22-repo-auto.md"))

    def test_64kib_cap_adds_truncation_note(self):
        self._w("2026-11-22-repo-auto.md", "a" * (70 * 1024))
        rc, out = _run(self.mod, [self.dir, self.SLUG])
        self.assertEqual(rc, 0)
        ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("[resume handoff truncated at 64 KiB]", ctx)

    def _title(self, payload):
        self._w("2026-11-22-repo-my-topic.md", "# Hand\n")
        rc, out = _run(self.mod, [self.dir, self.SLUG], payload)
        self.assertEqual(rc, 0)
        return json.loads(out)["hookSpecificOutput"].get("sessionTitle")

    def test_title_set_on_manual_startup(self):
        self.assertEqual(self._title(b'{"source":"startup"}'), "repo: my-topic")

    def test_no_title_on_resume_or_garbage(self):
        self.assertIsNone(self._title(b'{"source":"resume"}'))
        os.unlink(os.path.join(self.dir, "2026-11-22-repo-my-topic.md"))
        self.assertIsNone(self._title(b"not json"))

    def test_stdin_drained_even_when_nothing_chosen(self):
        buf = io.BytesIO(b"z" * 100000)
        rc, out = _run(self.mod, [self.dir, self.SLUG], stdin_obj=types.SimpleNamespace(buffer=buf))
        self.assertEqual((rc, out), (0, ""))
        self.assertEqual(buf.read(), b"")


class SubprocessLocaleTests(unittest.TestCase):
    def test_non_ascii_basename_on_rc4_under_c_locale(self):
        name = "2026-11-22-repo-\u00f1.md"
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "rp")
            os.mkdir(d)
            try:
                open(os.path.join(d, name), "w").close()
            except (OSError, UnicodeEncodeError):
                self.skipTest("filesystem refuses non-ASCII name")
            env = {k: v for k, v in os.environ.items() if k != "PYTHONIOENCODING"}
            env.update({"LC_ALL": "C", "LANG": "C"})
            # On Linux, LC_ALL=C with -X utf8=0 also makes the child's FILESYSTEM
            # encoding ASCII: os.listdir returns the name surrogate-escaped, the
            # selector's UTF-8-encodability check (_name_ok) rejects it, and nothing is
            # selectable (rc 0, fail-closed, same as the old inline selector). The rc-4
            # path is then unreachable, so probe first; this test discriminates only
            # where the fs encoding stays utf-8 (e.g. macOS).
            probe = subprocess.run(
                [sys.executable, "-I", "-X", "utf8=0", "-c",
                 "import sys; print(sys.getfilesystemencoding())"],
                capture_output=True, env=env, timeout=30,
            )
            if probe.returncode != 0:
                self.fail("locale probe child failed: %r" % probe.stderr)
            fsenc = probe.stdout.decode("ascii", "replace").strip().lower()
            if fsenc.replace("-", "") != "utf8":
                self.skipTest(
                    "child fs encoding is %r under C locale: non-ASCII names are "
                    "unselectable (fail-closed); rc-4 path unreachable" % fsenc
                )
            r = subprocess.run(
                [sys.executable, "-I", "-X", "utf8=0", MOD_PATH, d, "repo"],
                input=b"", capture_output=True, env=env, timeout=30,
            )
        self.assertEqual(r.returncode, 4)
        self.assertEqual(r.stdout.decode("utf-8"), name)
        self.assertNotIn(b"UnicodeEncodeError", r.stderr)


if __name__ == "__main__":
    unittest.main()
