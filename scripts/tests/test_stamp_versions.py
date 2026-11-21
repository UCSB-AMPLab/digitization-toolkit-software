"""Tests for scripts/stamp-versions.py, the release-time Version: stamper.

Run from the superproject, with the Python 3 that ships with macOS or any
later one, and nothing else installed:

    python3 -m unittest discover -s scripts/tests -p 'test_*.py'

The recognition tests call the script's functions directly. The rest build
small throwaway git repositories in a temporary directory: a superproject
whose tags pin two plain repositories standing in for the frontend and the
backend (gitlinks written with update-index, so no submodule clone is needed),
and run the script on them as a release would, through its command line.
Git runs with an empty global configuration, so a developer's hooks, signing
or default branch settings cannot change the outcome.
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "stamp-versions.py")

_spec = importlib.util.spec_from_file_location("stamp_versions", SCRIPT)
sv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sv)


# --------------------------------------------------------------------------
# Recognition of a file's own Version: line
# --------------------------------------------------------------------------

def values(path, text):
    data = text.encode("utf-8") if isinstance(text, str) else text
    return [m.value for m in sv.find_version_lines(path, data)]


class RecognitionTest(unittest.TestCase):

    def test_ts_line_comment_header(self):
        src = "// The queue.\n//\n// Version: 0.3.3\n\nimport { a } from 'b';\n"
        self.assertEqual(values("src/lib/queue.ts", src), ["0.3.3"])

    def test_svelte_indented_inside_script(self):
        src = ('<script lang="ts">\n\t// The dialog.\n\t//\n'
               '\t// Version: 0.1.0-beta\n\timport { m } from "x";\n</script>\n')
        self.assertEqual(values("src/A.svelte", src), ["0.1.0-beta"])
        src2 = src.replace("\t", "  ")
        self.assertEqual(values("src/A.svelte", src2), ["0.1.0-beta"])

    def test_svelte_instance_script_after_module_script(self):
        src = ('<script module lang="ts">\n  import { w } from "s";\n  const o = w(1);\n</script>\n\n'
               '<script lang="ts">\n  // The row menu.\n  //\n  // Version: 0.3.4\n'
               '  import { m } from "x";\n  // Version: 9.9.9\n</script>\n<p>x</p>\n')
        self.assertEqual(values("src/Row.svelte", src), ["0.3.4"])

    def test_svelte_html_comment_before_markup(self):
        src = "<!--\n  A static badge.\n\n  Version: 0.2.0\n-->\n<span>x</span>\n"
        self.assertEqual(values("src/B.svelte", src), ["0.2.0"])
        one = "<!-- Version: 0.2.0 -->\n<span>x</span>\n"
        self.assertEqual(values("src/B.svelte", one), ["0.2.0"])

    def test_css_block_comment(self):
        src = "/* Fonts. */\n/* Version: 0.3.2 */\n\n@font-face { }\n"
        self.assertEqual(values("src/app.css", src), ["0.3.2"])

    def test_jsdoc_star_line(self):
        src = "/**\n * The pipeline.\n *\n * Version: 0.1.1\n */\nexport const a = 1;\n"
        self.assertEqual(values("src/lib/p.ts", src), ["0.1.1"])

    def test_python_docstring_last_line(self):
        src = '"""The bag export.\n\nVersion: 0.1.0-beta\n"""\n\nimport os\n'
        self.assertEqual(values("app/core/bag.py", src), ["0.1.0-beta"])

    def test_python_hash_line_before_docstring_or_code(self):
        self.assertEqual(values("app/api/x.py", "# Version: 0.3.3\nimport os\n"), ["0.3.3"])
        src = '# Version: 0.3.3\n"""Routes."""\nimport os\n'
        self.assertEqual(values("app/api/y.py", src), ["0.3.3"])

    def test_shell_after_shebang(self):
        src = "#!/bin/bash\n# Starts it.\n#\n# Version: 0.1.0-beta\n\nset -e\n"
        self.assertEqual(values("scripts/start.sh", src), ["0.1.0-beta"])
        self.assertEqual(values("scripts/dtk-system-helper", src), ["0.1.0-beta"])
        self.assertEqual(values("scripts/dtk-mdns-alias.dispatcher", src), ["0.1.0-beta"])
        ps1 = "# Starts it.\n#\n# Version: 0.1.0-beta\n\n$ErrorActionPreference = 'Stop'\n"
        self.assertEqual(values("scripts/start-dev.ps1", ps1), ["0.1.0-beta"])

    def test_bat_rem(self):
        src = "@echo off\nREM Starts it.\nREM Version: 0.1.0-beta\n:: notes\necho hi\n"
        self.assertEqual(values("scripts/start-dev.bat", src), ["0.1.0-beta"])

    def test_footer_line_comment(self):
        src = "import os\n\nprint(1)\n\n# Version: 0.2.0\n"
        self.assertEqual(values("a.py", src), ["0.2.0"])
        src = "export const a = 1;\n// Version: 0.2.0"
        self.assertEqual(values("a.ts", src), ["0.2.0"])

    def test_not_a_version_line(self):
        cases = [
            ("a.ts", "// Header.\nconst s = 'Version: 1.0.0';\n"),
            ("a.ts", "import x from 'y';\nfunction f() {\n  // Version: 1.0.0\n  return 1;\n}\n"),
            ("a.py", '"""Mod."""\nX = 1\n\ndef f():\n    """Version: 1.0.0\n    """\n    return 2\n'),
            ("a.py", 'BAG = "BagIt-Version: 0.97\\n"\n'),
            ("README.md", "# Version: 1.0.0\n\nText.\n"),
            ("check.sh", "#!/bin/bash\n#   TS/JS       // Version: 0.1.0-beta\nset -e\n"),
            ("a.ts", "// Version: 0.1.0 (draft)\nimport a from 'b';\n"),
            ("a.ts", "// Version: next\nimport a from 'b';\n"),
            ("data.json", '{"Version: 1.0.0": 1}\n'),
            ("a.css", "// Version: 1.0.0\nbody {}\n"),
        ]
        for path, src in cases:
            with self.subTest(path=path, src=src):
                self.assertEqual(values(path, src), [])

    def test_never_touch_names(self):
        for path in ["package.json", "frontend/package.json", "pixi.toml",
                     "package-lock.json", "pixi.lock", "CHANGELOG.md",
                     "node_modules/x/index.js", "docs/release-notes/0.2.0.md",
                     "src/vendor/lib.js", "static/fonts/a.woff2"]:
            with self.subTest(path=path):
                self.assertTrue(sv.never_touch(path))
        self.assertFalse(sv.never_touch("src/lib/queue.ts"))

    def test_binary_is_never_read(self):
        self.assertEqual(values("a.ts", b"// Version: 0.1.0\n\x00\x01"), [])

    def test_insert_version(self):
        ins = sv.insert_version
        cases = [
            ("a.ts", "// Header.\nimport a from 'b';\n", "// Header.\n//\n// Version: 0.3.0\nimport a from 'b';\n"),
            ("a.ts", "// Header.\n//\n\nimport a from 'b';\n", "// Header.\n//\n// Version: 0.3.0\n\nimport a from 'b';\n"),
            ("a.ts", "/**\n * Header.\n */\nexport const a = 1;\n", "/**\n * Header.\n */\n// Version: 0.3.0\nexport const a = 1;\n"),
            ("a.py", '"""Doc.\n\nMore.\n"""\nA = 1\n', '"""Doc.\n\nMore.\n\nVersion: 0.3.0\n"""\nA = 1\n'),
            ("a.py", '"""Doc.\n\n"""\nA = 1\n', '"""Doc.\n\nVersion: 0.3.0\n"""\nA = 1\n'),
            ("a.py", '"""Doc, closed on its line."""\nA = 1\n', '"""Doc, closed on its line.\n\nVersion: 0.3.0\n"""\nA = 1\n'),
            ("a.py", '#!/usr/bin/env python3\n"""Doc.\n  More."""\n', '#!/usr/bin/env python3\n"""Doc.\n  More.\n\nVersion: 0.3.0\n"""\n'),
            ("A.svelte", '<script lang="ts">\n\t// The row.\n\timport { m } from "x";\n</script>\n',
                         '<script lang="ts">\n\t// The row.\n\t//\n\t// Version: 0.3.0\n\timport { m } from "x";\n</script>\n'),
            ("A.svelte", '<script module lang="ts">\n  const o = 1;\n</script>\n<script lang="ts">\n  // The row.\n  import x from "y";\n</script>\n',
                         '<script module lang="ts">\n  const o = 1;\n</script>\n<script lang="ts">\n  // The row.\n  //\n  // Version: 0.3.0\n  import x from "y";\n</script>\n'),
            ("a.css", "/* Fonts\n   and more. */\n\nbody {}\n", "/* Fonts\n   and more. */\n/* Version: 0.3.0 */\n\nbody {}\n"),
            ("s.sh", "#!/bin/bash\n# Does it.\n\nset -e\n", "#!/bin/bash\n# Does it.\n#\n# Version: 0.3.0\n\nset -e\n"),
            ("s.bat", "REM Starts it.\n@echo off\n", "REM Starts it.\nREM Version: 0.3.0\n@echo off\n"),
            ("a.ts", "// Header.\r\nimport a from 'b';\r\n", "// Header.\r\n//\r\n// Version: 0.3.0\r\nimport a from 'b';\r\n"),
        ]
        for path, src, want in cases:
            with self.subTest(path=path, src=src):
                out = ins(path, src.encode(), "0.3.0")
                self.assertEqual(out, want.encode())
                self.assertEqual(values(path, out), ["0.3.0"])
        for path, src in [("a.ts", "import a from 'b';\n"), ("a.py", "A = 1\n"),
                          ("a.py", "# A comment, no docstring.\nA = 1\n"),
                          ("A.svelte", '<script lang="ts">\n\timport x from "y";\n</script>\n'),
                          ("s.sh", "#!/bin/bash\nset -e\n")]:
            with self.subTest(path=path, src=src):
                self.assertIsNone(ins(path, src.encode(), "0.3.0"))

    def test_set_version_preserves_bytes(self):
        crlf = b"// Header.\r\n//\r\n// Version: 0.3.3\r\nimport a from 'b';\r\n"
        out = sv.set_version("a.ts", crlf, "0.3.0")
        self.assertEqual(out, crlf.replace(b"0.3.3", b"0.3.0"))
        notrail = b"import os\n# Version: 0.1.0-beta"
        self.assertEqual(sv.set_version("a.py", notrail, "0.3.0"),
                         b"import os\n# Version: 0.3.0")
        spaced = b"  \t// Version:   0.1.0-beta  \nimport a from 'b';\n"
        self.assertEqual(sv.set_version("a.ts", spaced, "0.3.0"),
                         b"  \t// Version:   0.3.0  \nimport a from 'b';\n")

    def test_normalise_ignores_only_the_token(self):
        a = b"// Version: 0.1.0\nconst x = 1;\n"
        b = b"// Version: 0.3.3\nconst x = 1;\n"
        c = b"// Version: 0.3.3\nconst x = 2;\n"
        self.assertEqual(sv.normalise("a.ts", a), sv.normalise("a.ts", b))
        self.assertNotEqual(sv.normalise("a.ts", a), sv.normalise("a.ts", c))


class VersionOrderTest(unittest.TestCase):

    def test_release_tags(self):
        tags = ["pre-alpha", "0.0.0-pre.2", "0.0.0-pre.3", "0.1.0-beta", "0.2.0",
                "0.3.0-rc.1", "0.3.0-rc.2", "0.2.0-beta", "0.4.0-alpha",
                "v0.9.0", "latest", "1.0.0"]
        self.assertEqual(sv.release_tags(tags), ["0.1.0-beta", "0.2.0", "1.0.0"])
        self.assertEqual(sv.HISTORICAL_RELEASE_TAGS, ("0.1.0-beta",))

    def test_order(self):
        key = sv.version_key
        self.assertLess(key("0.1.0-beta"), key("0.1.0"))
        self.assertLess(key("0.1.0"), key("0.2.0"))
        self.assertLess(key("0.2.0"), key("0.10.0"))

    def test_plain_version(self):
        for ok in ["0.3.0", "1.0.10"]:
            self.assertTrue(sv.is_plain_version(ok))
        for bad in ["0.3", "v0.3.0", "0.3.0-rc.1", "0.03.0", "0.3.0 ", ""]:
            self.assertFalse(sv.is_plain_version(bad), bad)


# --------------------------------------------------------------------------
# Whole runs on throwaway repositories
# --------------------------------------------------------------------------

class GitFixture(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="stamp-versions-test-")
        cfg = os.path.join(self.tmp, "gitconfig")
        with open(cfg, "w") as f:
            f.write("[user]\n\tname = Test\n\temail = test@example.invalid\n"
                    "[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n"
                    "[tag]\n\tgpgsign = false\n")
        self.env = dict(os.environ)
        self.env.update(GIT_CONFIG_GLOBAL=cfg, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_DATE="2026-01-01T00:00:00Z",
                        GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
        self.root = self.repo("sp")
        self.fe = self.repo("fe")
        self.be = self.repo("be")
        os.makedirs(os.path.join(self.root, "frontend"))
        os.makedirs(os.path.join(self.root, "backend"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, repo, *args):
        return subprocess.run(["git", "-C", repo] + list(args), env=self.env,
                              check=True, capture_output=True, text=True).stdout.strip()

    def repo(self, name):
        path = os.path.join(self.tmp, name)
        os.makedirs(path)
        self.git(path, "init", "-q")
        return path

    def write(self, repo, rel, content, mode=None):
        path = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(content.encode("utf-8") if isinstance(content, str) else content)
        if mode:
            os.chmod(path, mode)

    def read(self, repo, rel):
        with open(os.path.join(repo, rel), "rb") as f:
            return f.read()

    def commit(self, repo, msg="change"):
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-q", "--allow-empty", "-m", msg)
        return self.git(repo, "rev-parse", "HEAD")

    def pin_and_tag(self, tag=None):
        """Commit the superproject with the submodules' current HEADs pinned."""
        for name, repo in (("frontend", self.fe), ("backend", self.be)):
            sha = self.git(repo, "rev-parse", "HEAD")
            self.git(self.root, "update-index", "--add", "--cacheinfo",
                     "160000,%s,%s" % (sha, name))
        self.git(self.root, "add", "-A", "--", ".", ":!frontend", ":!backend")
        self.git(self.root, "commit", "-q", "--allow-empty", "-m", "pin")
        if tag:
            self.git(self.root, "tag", tag)

    def run_script(self, *args):
        cmd = [sys.executable, SCRIPT, "--root", self.root,
               "--frontend-dir", self.fe, "--backend-dir", self.be] + list(args)
        p = subprocess.run(cmd, env=self.env, capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr

    def base_history(self):
        """Two releases. Files last changed in 0.1.0-beta, in 0.2.0, or after."""
        self.write(self.be, "app/old.py", '"""Old.\n\nVersion: 0.1.0-beta\n"""\nA = 1\n')
        self.write(self.be, "app/mid.py", '"""Mid.\n\nVersion: 0.1.0-beta\n"""\nB = 1\n')
        self.write(self.fe, "src/lib/old.ts", "// Old.\n// Version: 0.1.0-beta\nexport const a = 1;\n")
        self.write(self.root, "scripts/old.sh", "#!/bin/bash\n# Old.\n# Version: 0.1.0-beta\nset -e\n")
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag("0.1.0-beta")
        self.write(self.be, "app/mid.py", '"""Mid.\n\nVersion: 0.2.0\n"""\nB = 2\n')
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag("0.2.0")


class EndToEndTest(GitFixture):

    def test_changed_files_are_stamped_and_unchanged_left(self):
        self.base_history()
        self.write(self.be, "app/old.py", '"""Old.\n\nVersion: 0.1.0-beta\n"""\nA = 3\n')
        self.commit(self.be); self.pin_and_tag()
        code, out = self.run_script("--write", "--version", "0.3.0", "--verbose")
        self.assertEqual(code, 0, out)
        self.assertIn(b"Version: 0.3.0", self.read(self.be, "app/old.py"))
        self.assertIn(b"Version: 0.2.0", self.read(self.be, "app/mid.py"))
        self.assertIn(b"Version: 0.1.0-beta", self.read(self.fe, "src/lib/old.ts"))

    def test_version_line_only_and_pure_rename_and_mode_are_not_changes(self):
        self.base_history()
        # Someone bumped the header by hand; content is the same as at 0.2.0.
        self.write(self.be, "app/mid.py", '"""Mid.\n\nVersion: 0.3.3\n"""\nB = 2\n')
        self.git(self.fe, "mv", "src/lib/old.ts", "src/lib/renamed.ts")
        os.chmod(os.path.join(self.root, "scripts/old.sh"), 0o755)
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag()
        code, out = self.run_script("--write", "--version", "0.3.0", "--verbose")
        self.assertEqual(code, 0, out)
        # Not a change: corrected to the release where its content last changed.
        self.assertIn(b"Version: 0.2.0", self.read(self.be, "app/mid.py"))
        self.assertIn(b"Version: 0.1.0-beta", self.read(self.fe, "src/lib/renamed.ts"))
        self.assertIn(b"Version: 0.1.0-beta", self.read(self.root, "scripts/old.sh"))
        self.assertNotIn("0.3.0", self.git(self.root, "diff"))

    def test_unreleased_version_on_unchanged_file_gets_earlier_release(self):
        self.base_history()
        # Hand-written unreleased numbers on files whose content did not change.
        self.write(self.be, "app/old.py", '"""Old.\n\nVersion: 0.3.3\n"""\nA = 1\n')
        self.write(self.fe, "src/lib/old.ts", "// Old.\n// Version: 0.1.4\nexport const a = 1;\n")
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag()
        code, out = self.run_script("--check", "--version", "0.3.0", "--verbose")
        self.assertEqual(code, 1, out)
        self.assertIn("unreleased", out)
        self.assertIn("backend/app/old.py", out)
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertIn(b"Version: 0.1.0-beta", self.read(self.be, "app/old.py"))
        self.assertIn(b"Version: 0.1.0-beta", self.read(self.fe, "src/lib/old.ts"))

    def test_file_older_than_first_tag_gets_first_tag(self):
        self.write(self.be, "app/a.py", "# Version: 0.0.9\nA = 1\n")
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag()
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag("0.1.0-beta")
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag("0.2.0")
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.be, "app/a.py"), b"# Version: 0.1.0-beta\nA = 1\n")

    def test_changed_file_without_line_gets_one_in_its_header(self):
        self.base_history()
        self.write(self.fe, "src/lib/new.ts", "// A new module.\n\nexport const n = 1;\n")
        self.write(self.fe, "src/lib/bare.ts", "export const n = 1;\n")
        self.write(self.fe, "vite.config.ts", "// Config.\nexport default {};\n")
        self.write(self.be, "tests/unit/test_new.py", '"""A new test.\n\nMore.\n"""\nN = 1\n')
        self.write(self.be, "app/bare.py", "N = 1\n")
        self.write(self.be, "alembic/versions/abc_new.py", '"""Migration."""\nN = 1\n')
        self.write(self.root, "scripts/new.sh", "#!/bin/bash\n# Does it.\nset -e\n")
        self.write(self.root, "scripts/new.service", "[Unit]\n")
        self.commit(self.be); self.commit(self.fe); self.commit(self.root); self.pin_and_tag()
        code, out = self.run_script("--check", "--version", "0.3.0", "--verbose")
        self.assertEqual(code, 1, out)
        for p in ["frontend/src/lib/new.ts", "backend/tests/unit/test_new.py", "scripts/new.sh"]:
            self.assertIn("insert      " + p, out)
        for p in ["frontend/src/lib/bare.ts", "backend/app/bare.py"]:
            self.assertIn("no-header   " + p, out)
        for p in ["vite.config.ts", "abc_new.py", "new.service"]:
            self.assertNotIn(p, out)
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.fe, "src/lib/new.ts"),
                         b"// A new module.\n//\n// Version: 0.3.0\n\nexport const n = 1;\n")
        self.assertEqual(self.read(self.be, "tests/unit/test_new.py"),
                         b'"""A new test.\n\nMore.\n\nVersion: 0.3.0\n"""\nN = 1\n')
        self.assertEqual(self.read(self.root, "scripts/new.sh"),
                         b"#!/bin/bash\n# Does it.\n#\n# Version: 0.3.0\nset -e\n")
        self.assertEqual(self.read(self.fe, "src/lib/bare.ts"), b"export const n = 1;\n")
        self.assertEqual(self.read(self.be, "alembic/versions/abc_new.py"), b'"""Migration."""\nN = 1\n')
        # The header-less files still fail the check until a person decides.
        code, out = self.run_script("--check", "--version", "0.3.0")
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"frontend: .*\b1 no-header")
        self.assertRegex(out, r"backend: .*\b1 no-header")

    def test_migrations_are_never_stamped_or_corrected(self):
        self.base_history()
        self.write(self.be, "alembic/versions/a1_old.py", '"""Old.\n\nVersion: 0.3.3\n"""\nA = 1\n')
        self.commit(self.be); self.pin_and_tag("0.2.1")  # an unchanged file below
        self.write(self.be, "alembic/versions/b2_new.py", '"""New.\n\nVersion: 0.1.0\n"""\nB = 1\n')
        self.commit(self.be); self.pin_and_tag()
        code, out = self.run_script("--write", "--version", "0.3.0", "--verbose")
        self.assertEqual(code, 0, out)
        self.assertNotIn("alembic", out)
        self.assertIn(b"Version: 0.3.3", self.read(self.be, "alembic/versions/a1_old.py"))
        self.assertIn(b"Version: 0.1.0\n", self.read(self.be, "alembic/versions/b2_new.py"))

    def release_files(self):
        self.write(self.root, "VERSION", "0.2.0\n")
        self.write(self.fe, "package.json",
                   '{\n\t"name": "frontend",\n\t"version": "0.2.0",\n\t"private": true,\n'
                   '\t"devDependencies": {\n\t\t"x": "^0.2.0"\n\t}\n}\n')
        self.write(self.fe, "package-lock.json",
                   '{\n\t"name": "frontend",\n\t"version": "0.2.0",\n\t"lockfileVersion": 3,\n'
                   '\t"packages": {\n\t\t"": {\n\t\t\t"name": "frontend",\n\t\t\t"version": "0.2.0"\n\t\t},\n'
                   '\t\t"node_modules/x": {\n\t\t\t"version": "0.2.0"\n\t\t}\n\t}\n}\n')
        self.write(self.be, "pixi.toml",
                   '[workspace]\nname = "b"\nversion = "0.1.0"  # the release\n\n'
                   '[dependencies]\nversion = "0.1.0"\n')

    def test_release_files_only_with_flag(self):
        self.release_files()
        self.base_history()
        before = {(r, p): self.read(r, p) for r, p in [(self.root, "VERSION"),
                  (self.fe, "package.json"), (self.fe, "package-lock.json"), (self.be, "pixi.toml")]}
        code, out = self.run_script("--check", "--version", "0.3.0", "--verbose")
        self.assertEqual(code, 0, out)
        self.assertIn("release files not at 0.3.0", out)
        self.assertIn("release     frontend/package.json  0.2.0 -> 0.3.0", out)
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        for (r, p), b in before.items():
            self.assertEqual(self.read(r, p), b, p)
        code, out = self.run_script("--check", "--set-release-files", "--version", "0.3.0")
        self.assertEqual(code, 1, out)
        code, out = self.run_script("--write", "--set-release-files", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.root, "VERSION"), b"0.3.0\n")
        self.assertEqual(self.read(self.fe, "package.json"),
                         before[(self.fe, "package.json")].replace(b'"version": "0.2.0"', b'"version": "0.3.0"'))
        lock = before[(self.fe, "package-lock.json")]
        self.assertEqual(self.read(self.fe, "package-lock.json"),
                         lock.replace(b'\t"version": "0.2.0",', b'\t"version": "0.3.0",', 1)
                             .replace(b'\t\t\t"version": "0.2.0"\n\t\t},', b'\t\t\t"version": "0.3.0"\n\t\t},', 1))
        self.assertIn(b'"node_modules/x": {\n\t\t\t"version": "0.2.0"', self.read(self.fe, "package-lock.json"))
        self.assertEqual(self.read(self.be, "pixi.toml"),
                         b'[workspace]\nname = "b"\nversion = "0.3.0"  # the release\n\n'
                         b'[dependencies]\nversion = "0.1.0"\n')
        for r in (self.root, self.fe, self.be):
            self.git(r, "commit", "-q", "-am", "release")
        self.pin_and_tag()
        code, out = self.run_script("--check", "--set-release-files", "--version", "0.3.0")
        self.assertEqual(code, 0, out)

    def test_lock_not_mirroring_package_json_is_left(self):
        self.release_files()
        self.base_history()
        lock = self.read(self.fe, "package-lock.json").replace(b'"version": "0.2.0",', b'"version": "0.1.9",', 1)
        self.write(self.fe, "package-lock.json", lock)
        self.commit(self.fe); self.pin_and_tag()
        code, out = self.run_script("--write", "--set-release-files", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.fe, "package-lock.json"), lock)
        self.assertIn("package-lock.json does not mirror", out)

    def test_code_string_untouched_and_bytes_preserved(self):
        self.base_history()
        crlf = (b"// Header.\r\n// Version: 0.1.0-beta\r\n"
                b"const s = 'Version: 0.1.0-beta';\r\nexport const v = s;")
        self.write(self.fe, "src/lib/old.ts", crlf)
        self.commit(self.fe); self.pin_and_tag()
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.fe, "src/lib/old.ts"),
                         b"// Header.\r\n// Version: 0.3.0\r\n"
                         b"const s = 'Version: 0.1.0-beta';\r\nexport const v = s;")

    def test_never_touch_files_even_when_changed(self):
        self.base_history()
        self.write(self.be, "pixi.toml", "# Version: 0.1.0\n[project]\nversion = \"0.1.0\"\n")
        self.write(self.fe, "node_modules/x/index.js", "// Version: 0.1.0\nmodule.exports = 1;\n")
        self.commit(self.be); self.commit(self.fe); self.pin_and_tag()
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertIn(b"# Version: 0.1.0\n", self.read(self.be, "pixi.toml"))
        self.assertIn(b"// Version: 0.1.0\n", self.read(self.fe, "node_modules/x/index.js"))

    def test_check_exit_codes_and_idempotence(self):
        self.base_history()
        self.write(self.root, "scripts/old.sh", "#!/bin/bash\n# Old.\n# Version: 0.1.0-beta\nset -eu\n")
        self.commit(self.root); self.pin_and_tag()
        code, out = self.run_script("--version", "0.3.0")   # --check is the default
        self.assertEqual(code, 1, out)
        self.assertEqual(self.git(self.root, "status", "--porcelain", "--ignore-submodules=all"), "")
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        first = self.read(self.root, "scripts/old.sh")
        self.assertIn(b"# Version: 0.3.0\n", first)
        self.commit(self.root, "release")
        code, out = self.run_script("--check", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.root, "scripts/old.sh"), first)
        self.assertEqual(self.git(self.root, "status", "--porcelain", "--ignore-submodules=all"), "")

    def test_dirty_tree_refused_unless_allowed(self):
        self.base_history()
        self.write(self.be, "app/old.py", '"""Old.\n\nVersion: 0.1.0-beta\n"""\nA = 9\n')
        self.commit(self.be); self.pin_and_tag()
        self.write(self.be, "app/mid.py", '"""Mid.\n\nVersion: 0.2.0\n"""\nB = 99\n')
        code, out = self.run_script("--write", "--version", "0.3.0")
        self.assertEqual(code, 2, out)
        self.assertIn("uncommitted", out)
        self.assertIn(b"Version: 0.1.0-beta", self.read(self.be, "app/old.py"))
        code, out = self.run_script("--write", "--version", "0.3.0", "--repo", "frontend")
        self.assertEqual(code, 0, out)
        code, out = self.run_script("--write", "--version", "0.3.0", "--allow-dirty")
        self.assertEqual(code, 0, out)
        self.assertIn(b"Version: 0.3.0", self.read(self.be, "app/old.py"))

    def test_since_default_skips_rc_and_non_version_tags(self):
        self.base_history()
        self.git(self.root, "tag", "pre-alpha")
        self.pin_and_tag("0.3.0-rc.1")
        self.git(self.root, "tag", "0.0.0-pre.2")
        code, out = self.run_script("--check", "--version", "0.3.0")
        self.assertIn(code, (0, 1), out)
        self.assertIn("since 0.2.0 (latest release tag)", out)

    def test_bad_arguments(self):
        self.base_history()
        for v in ["0.3", "v0.3.0", "0.3.0-rc.1", "0.2.0", "0.1.0"]:
            with self.subTest(v=v):
                code, out = self.run_script("--check", "--version", v)
                self.assertEqual(code, 2, out)
        code, out = self.run_script("--check", "--version", "0.3.0", "--since", "nope")
        self.assertEqual(code, 2, out)
        code, out = self.run_script("--check", "--write", "--version", "0.3.0")
        self.assertEqual(code, 2, out)

    def test_submodule_compared_from_its_pin(self):
        self.base_history()
        # Frontend changes after 0.2.0's pin but the superproject is not re-pinned:
        # the submodule's own HEAD is what counts.
        self.write(self.fe, "src/lib/old.ts", "// Old.\n// Version: 0.1.0-beta\nexport const a = 2;\n")
        self.commit(self.fe)
        code, out = self.run_script("--check", "--version", "0.3.0", "--verbose", "--repo", "frontend")
        self.assertEqual(code, 1, out)
        self.assertIn("stamp       frontend/src/lib/old.ts  0.1.0-beta -> 0.3.0", out)

    def test_output_is_deterministic(self):
        self.base_history()
        for n in ["b", "a", "c"]:
            self.write(self.fe, "src/lib/%s.ts" % n, "// %s\n// Version: 0.1.0-beta\nexport const x = 1;\n" % n)
        self.commit(self.fe); self.pin_and_tag()
        _, one = self.run_script("--check", "--version", "0.3.0", "--verbose")
        _, two = self.run_script("--check", "--version", "0.3.0", "--verbose")
        self.assertEqual(one, two)
        self.assertLess(one.index("src/lib/a.ts"), one.index("src/lib/b.ts"))
        self.assertLess(one.index("src/lib/b.ts"), one.index("src/lib/c.ts"))


if __name__ == "__main__":
    unittest.main()
