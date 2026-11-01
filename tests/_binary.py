"""The binary under test, and a throwaway Firetower to run it against.

FIRETOWER_BIN points the suite at any build of the CLI: the tests are
black-box on purpose, so they are the conformance suite for any
implementation. Unset, the checkout is built once into a temp directory.
"""

import atexit
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _build() -> str:
    out = tempfile.mkdtemp(prefix="firetower-test-")
    atexit.register(shutil.rmtree, out, ignore_errors=True)
    path = os.path.join(out, "firetower")
    subprocess.run(["go", "build", "-o", path, "./cmd/firetower"], cwd=ROOT, check=True,
                   env={**os.environ, "CGO_ENABLED": "0"})
    return path


BIN = os.environ.get("FIRETOWER_BIN") or _build()

T0 = "2026-10-31T12:00:00Z"


def at(minutes: float) -> str:
    """T0 plus some minutes, as FIRETOWER_NOW wants it."""
    from datetime import datetime, timedelta, timezone
    t = datetime(2026, 10, 31, 12, 0, tzinfo=timezone.utc) + timedelta(minutes=minutes)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class Firetower(unittest.TestCase):
    """Each test gets its own state dir and config, and a pinned clock."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="firetower-case-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.dir = self.tmp / "state"
        self.config = self.tmp / "config.toml"
        self.clock = T0

    def env(self, **extra):
        e = {k: v for k, v in os.environ.items() if not k.startswith(("FIRETOWER_", "CRONTINENTAL_"))}
        e.update(FIRETOWER_DIR=str(self.dir), FIRETOWER_CONFIG=str(self.config), FIRETOWER_NOW=self.clock)
        e.update(extra)
        return e

    def ft(self, *args, ok=True, input=None, timeout=30, **env):
        p = subprocess.run([BIN, *args], capture_output=True, text=True, env=self.env(**env),
                           input=input, timeout=timeout)
        if ok is True and p.returncode != 0:
            self.fail(f"firetower {' '.join(args)} exited {p.returncode}:\n{p.stdout}{p.stderr}")
        if ok is False and p.returncode == 0:
            self.fail(f"firetower {' '.join(args)} should have failed:\n{p.stdout}")
        return p

    def ls(self, **env):
        return {v["id"]: v for v in json.loads(self.ft("ls", "--json", **env).stdout)}

    def one(self, id, **env):
        vs = self.ls(**env)
        self.assertIn(id, vs, f"{id} not in {list(vs)}")
        return vs[id]

    def file(self, id):
        return json.loads((self.dir / (id + ".json")).read_text())
