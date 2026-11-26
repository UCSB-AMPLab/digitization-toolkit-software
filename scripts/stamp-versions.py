#!/usr/bin/env python3
"""Sets each file's Version: line at release time, from git history.

One version belongs to the product: the superproject's release tag. A file's
Version: line names the release in which the file last changed. Nobody writes
it by hand; this script sets it when a release is made, and a new file carries
no Version: line until then.

    python3 scripts/stamp-versions.py --version 0.3.0                  # check
    python3 scripts/stamp-versions.py --version 0.3.0 --write          # apply
    python3 scripts/stamp-versions.py --version 0.3.0 --write --set-release-files

It runs on the superproject and on the frontend and backend submodules. For
the superproject, "the previous release" is the --since tag; for a submodule,
it is the commit the superproject pinned at that tag, compared with the
submodule's own HEAD.

The forms, per file type. Each file names its release on exactly one line:

    Python      Version: 0.3.0          (last line of the module docstring,
                                         or "# Version: ..." with none)
    TS/JS       // Version: 0.3.0       (last line of the opening comment)
    Svelte      // Version: 0.3.0       (in the <script> opening comment,
                                         or <!-- Version: ... --> with none)
    CSS         /* Version: 0.3.0 */
    Shell, ps1  # Version: 0.3.0
    bat         REM Version: 0.3.0

Files that carry the line: the backend's Python (not alembic/versions, whose
migrations record past schemas and are never stamped or listed), the
frontend's src/ and e2e/ (.ts .js .svelte .css, test files included), and
the superproject's scripts (shell, PowerShell and batch, and extensionless
files with a sh or bash shebang; not the systemd units or config files).

Recognition. A line is a file's own Version: line when, ignoring the line
ending, it consists only of an optional indent, a comment marker the file's
type uses, "Version:" and a version (digits.digits.digits with an optional
-suffix), and nothing after it but the comment's closer and spaces; and it
lies in the file's leading region (everything before the first line of code:
shebang, blank lines, comments, a Python module docstring, a Svelte <script>
opening tag; in Svelte each top-level <script> opens such a region, so the
instance script's header counts after a module script) or in its trailing
region (the run of comment lines at the end). The markers are # for Python,
shell, PowerShell and extensionless scripts with a shebang; REM and :: for
batch; // and /* */ for TypeScript and JavaScript; /* */ for CSS; //, /* */
and <!-- --> for Svelte; <!-- --> for HTML. A bare "Version: X" (or
" * Version: X") counts only inside a block comment or a Python module
docstring. Any other file type has no Version: line. A "Version:" anywhere
else, in a string, a function docstring, a line with trailing text, a
Markdown heading, is never touched.

Never stamped: package.json, pixi.toml, VERSION, CITATION.cff, lock files,
CHANGELOG and release notes, migrations, anything under node_modules,
vendor, third_party or a build output folder, minified files, binary files.

Categories, per repository:

    stamp       changed since the previous release; its line is set to
                --version
    already     changed, and its line already names --version
    insert      changed, of a type that carries the line, but without one; the
                line is added in the form above, at the end of the file's
                header comment or module docstring, after a blank comment
                line (Python: a blank line), as the existing headers end
    no-header   as insert, but the file has no header comment or docstring to
                put it in; listed for a person to decide, never invented
    unreleased  unchanged, but its line names a version that is not a release
                tag, or is newer than --since; set to the release in which the
                file last changed
    unresolved  as unreleased, but that release could not be computed; left
    ambiguous   more than one recognised Version: line; left

"Changed" means added, or modified so that its content differs once its own
Version: token is set aside. A pure rename, a mode change, or a change to the
Version: line alone is not a change.

Release tags are the tags of the form X.Y.Z, and the earlier releases listed
in HISTORICAL_RELEASE_TAGS (0.1.0-beta). Release candidates (-rc.N), -pre.N
snapshots and other names are not releases.

The release in which an unchanged file last changed. Take the release tags up
to --since, oldest first; for a submodule, each tag stands for the commit the
superproject pinned at it. Start at --since, where the file's content equals
HEAD's (it is unchanged). Step to the previous tag, following a rename
between the two, while the file's content there still equals HEAD's once the
Version: token is set aside. The tag where the stepping stops is the release
in which the file took its present content; a file unchanged since before the
first tag gets the first tag. If a tag's commit is missing from the
repository, the answer is unresolved.

Release files. The release commit also sets the product's number in the
superproject's VERSION, the frontend's package.json "version" (and the two
top-level "version" fields of package-lock.json, when they mirror it), and
the version in the [workspace] or [project] table of the backend's
pixi.toml. --check lists those not at --version under "release files"; with
--set-release-files and --write they are set, the version token alone
changing.

Exit status: 0 when nothing is left to do or the write succeeded; 1 when
--check (the default) finds a changed file of a covered type that does not
name --version (stamp, insert, no-header), an unreleased version, an
ambiguous file, or, with --set-release-files, a release file not at
--version; 2 on a usage or repository error, including --write on a
repository with uncommitted changes unless --allow-dirty is given. Python 3.9
standard library; no network.
"""

import argparse
import os
import re
import subprocess
import sys
from collections import namedtuple

# --------------------------------------------------------------------------
# Versions and tags
# --------------------------------------------------------------------------

_VERSION = re.compile(r"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*))?$")
_PLAIN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def is_plain_version(s):
    return bool(_PLAIN.match(s))


def version_key(s):
    """Semantic-version precedence; None for a string that is not a version."""
    m = _VERSION.match(s)
    if not m:
        return None
    pre = m.group(4)
    parts = ()
    if pre:
        parts = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), 0 if pre else 1, parts)


# Releases made before every release was a plain X.Y.Z.
HISTORICAL_RELEASE_TAGS = ("0.1.0-beta",)


def is_release_tag(name):
    return is_plain_version(name) or name in HISTORICAL_RELEASE_TAGS


def release_tags(names):
    """The release tags among names, oldest first."""
    return sorted((n for n in names if is_release_tag(n)), key=version_key)


# --------------------------------------------------------------------------
# Recognition of a file's own Version: line
# --------------------------------------------------------------------------

VersionLine = namedtuple("VersionLine", "index start end value")

_V = rb"(?P<v>[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?)"
_SP = rb"[ \t]*"
_FORM_LINE = {
    b"#": re.compile(rb"^" + _SP + rb"#" + _SP + rb"Version:" + _SP + _V + _SP + rb"$"),
    b"//": re.compile(rb"^" + _SP + rb"//" + _SP + rb"Version:" + _SP + _V + _SP + rb"$"),
    b"REM": re.compile(rb"^" + _SP + rb"(?:REM|rem)[ \t]+Version:" + _SP + _V + _SP + rb"$"),
    b"::": re.compile(rb"^" + _SP + rb"::" + _SP + rb"Version:" + _SP + _V + _SP + rb"$"),
}
_FORM_ONE_BLOCK = {
    b"/*": re.compile(rb"^" + _SP + rb"/\*" + _SP + rb"Version:" + _SP + _V + _SP + rb"\*/" + _SP + rb"$"),
    b"<!--": re.compile(rb"^" + _SP + rb"<!--" + _SP + rb"Version:" + _SP + _V + _SP + rb"-->" + _SP + rb"$"),
}
_FORM_BARE = re.compile(rb"^" + _SP + rb"(?:\*" + _SP + rb")?Version:" + _SP + _V + _SP + rb"$")
_CLOSERS = {b"/*": b"*/", b"<!--": b"-->"}

# Comment syntax per file type: line markers, block openers, docstring, tags.
_SYNTAX = {
    "py": dict(line=[b"#"], block=[], doc=True),
    "hash": dict(line=[b"#"], block=[], doc=False),
    "bat": dict(line=[b"REM", b"::"], block=[], doc=False),
    "c": dict(line=[b"//"], block=[b"/*"], doc=False),
    "css": dict(line=[], block=[b"/*"], doc=False),
    "svelte": dict(line=[b"//"], block=[b"/*", b"<!--"], doc=False),
    "html": dict(line=[], block=[b"<!--"], doc=False),
}
_EXT = {
    ".py": "py", ".sh": "hash", ".bash": "hash", ".ps1": "hash",
    ".bat": "bat", ".cmd": "bat",
    ".ts": "c", ".js": "c", ".mjs": "c", ".cjs": "c", ".tsx": "c", ".jsx": "c",
    ".css": "css", ".svelte": "svelte", ".html": "html",
}
_TAG_LINE = re.compile(rb"^(?:<script\b[^>]*>|<svelte:options\b[^>]*/>)$")
_SCRIPT_OPEN = re.compile(rb"^<script\b[^>]*>[ \t]*$")
_BAT_PREAMBLE = re.compile(rb"^@?echo[ \t]+off$", re.I)
_DOC_OPEN = re.compile(rb'^[rRuU]?("""|\'\'\')')


def syntax_of(path, data):
    kind = _EXT.get(os.path.splitext(path)[1].lower())
    if kind is None and data.startswith(b"#!"):
        first = data.split(b"\n", 1)[0]
        kind = "py" if b"python" in first else "hash"
    return _SYNTAX.get(kind) if kind else None


_NEVER_NAMES = {
    "package.json", "pixi.toml", "version", "citation.cff", "package-lock.json",
    "npm-shrinkwrap.json", "pixi.lock", "yarn.lock", "pnpm-lock.yaml",
    "poetry.lock", "uv.lock", "pipfile.lock", "cargo.lock", "composer.lock",
}
_NEVER_DIRS = {
    "node_modules", "vendor", "vendored", "third_party", "third-party",
    ".svelte-kit", "build", "dist", "__pycache__", ".venv", ".pixi",
    "release-notes", "releases",
}
_BINARY_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".bmp", ".tif", ".tiff",
    ".woff", ".woff2", ".ttf", ".otf", ".eot", ".pdf", ".zip", ".gz", ".tgz",
    ".xz", ".bz2", ".7z", ".mp4", ".mov", ".webm", ".mp3", ".wav", ".dng",
    ".cr2", ".jar", ".so", ".dylib", ".pyc", ".db", ".sqlite",
}


def never_touch(path):
    parts = path.replace("\\", "/").split("/")
    name = parts[-1].lower()
    if name in _NEVER_NAMES or name.endswith(".lock"):
        return True
    if name.startswith("changelog") or name.startswith("release-notes") or name.startswith("release_notes"):
        return True
    if ".min." in name or os.path.splitext(name)[1] in _BINARY_EXT:
        return True
    return any(p.lower() in _NEVER_DIRS for p in parts[:-1])


def _is_text(data):
    if b"\0" in data[:8192]:
        return False
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def _lines(data):
    """(offset, content without line ending) for each line of data."""
    out, pos = [], 0
    for raw in data.splitlines(True):
        body = raw.rstrip(b"\r\n")
        out.append((pos, body))
        pos += len(raw)
    return out


def _hit(index, offset, m):
    return VersionLine(index, offset + m.start("v"), offset + m.end("v"), m.group("v").decode())


def _line_marker(syn, s):
    for mark in syn["line"]:
        if s.startswith(mark) and (mark != b"REM" or s[3:4] in (b"", b" ", b"\t")):
            return mark
        if mark == b"REM" and s.startswith(b"rem") and s[3:4] in (b"", b" ", b"\t"):
            return mark
    return None


def _leading(syn, lines, start=0):
    hits = []
    state = None          # None, or the closer of an open block or docstring
    doc_done = False
    for i in range(start, len(lines)):
        off, body = lines[i]
        s = body.strip()
        if state is not None:
            m = _FORM_BARE.match(body)
            if m:
                hits.append(_hit(i, off, m))
            if state in s:
                state = None
            continue
        if not s or (i == 0 and s.startswith(b"#!")) or (i == start and _TAG_LINE.match(s)):
            continue
        mark = _line_marker(syn, s)
        if mark:
            m = _FORM_LINE[mark].match(body)
            if m:
                hits.append(_hit(i, off, m))
            continue
        opener = next((o for o in syn["block"] if s.startswith(o)), None)
        if opener:
            closer = _CLOSERS[opener]
            if closer in s[len(opener):]:
                m = _FORM_ONE_BLOCK[opener].match(body)
                if m:
                    hits.append(_hit(i, off, m))
            else:
                state = closer
            continue
        if _TAG_LINE.match(s):
            continue
        if syn is _SYNTAX["bat"] and _BAT_PREAMBLE.match(s):
            continue
        if syn["doc"] and not doc_done:
            d = _DOC_OPEN.match(s)
            if d:
                quote = d.group(1)
                doc_done = True
                if quote not in s[d.end():]:
                    state = quote
                continue
        break
    return hits


def _trailing(syn, lines):
    hits = []
    for i in range(len(lines) - 1, -1, -1):
        off, body = lines[i]
        s = body.strip()
        if not s:
            continue
        mark = _line_marker(syn, s)
        if mark:
            m = _FORM_LINE[mark].match(body)
            if m:
                hits.append(_hit(i, off, m))
            continue
        opener = next((o for o in syn["block"] if s.startswith(o) and s.endswith(_CLOSERS[o])
                       and len(s) >= len(o) + len(_CLOSERS[o])), None)
        if opener:
            m = _FORM_ONE_BLOCK[opener].match(body)
            if m:
                hits.append(_hit(i, off, m))
            continue
        break
    return hits


def find_version_lines(path, data):
    """The file's own Version: lines, in file order (normally zero or one)."""
    if never_touch(path) or not _is_text(data):
        return []
    syn = syntax_of(path, data)
    if syn is None:
        return []
    lines = _lines(data)
    starts = [0]
    if syn is _SYNTAX["svelte"]:
        # Each top-level <script> (module and instance) opens a leading region.
        starts += [i for i, (_, b) in enumerate(lines) if i and _SCRIPT_OPEN.match(b)]
    found = {}
    for start in starts:
        for h in _leading(syn, lines, start):
            found.setdefault(h.index, h)
    for h in _trailing(syn, lines):
        found.setdefault(h.index, h)
    return [found[k] for k in sorted(found)]


def normalise(path, data):
    """data with its own Version: token(s) set aside, for comparing contents."""
    out = data
    for h in reversed(find_version_lines(path, data)):
        out = out[:h.start] + b"<VERSION>" + out[h.end:]
    return out


def set_version(path, data, version):
    """data with its single Version: token replaced; nothing else changes."""
    hits = find_version_lines(path, data)
    if len(hits) != 1:
        raise ValueError("%s: expected one Version: line, found %d" % (path, len(hits)))
    h = hits[0]
    return data[:h.start] + version.encode("ascii") + data[h.end:]


def _raw_lines(data):
    """[(content, line ending)] for each line of data."""
    out = []
    for raw in data.splitlines(True):
        body = raw.rstrip(b"\r\n")
        out.append((body, raw[len(body):]))
    return out


def _eol(lines):
    return next((e for _, e in lines if e), b"\n")


def _join(lines):
    return b"".join(b + e for b, e in lines)


def _insert_after(lines, j, new_bodies):
    """lines with new_bodies inserted after line j, in that line's ending."""
    eol = lines[j][1] or _eol(lines)
    out = list(lines)
    tail_eol = lines[j][1]
    out[j] = (lines[j][0], eol)
    added = [(b, eol) for b in new_bodies]
    if not tail_eol:                       # line j ended the file without one
        added[-1] = (added[-1][0], b"")
    return out[:j + 1] + added + out[j + 1:]


def _insert_python(lines, version):
    i = 0
    while i < len(lines):
        s = lines[i][0].strip()
        if not s or s.startswith(b"#"):
            i += 1
            continue
        break
    if i == len(lines):
        return None
    d = _DOC_OPEN.match(lines[i][0].strip())
    if not d or not lines[i][0].startswith(lines[i][0].strip()[:1]):
        return None
    quote = d.group(1)
    body = lines[i][0]
    start = body.index(quote) + 3
    if quote in body[start:]:
        j = i                                  # docstring closes on its first line
    else:
        j = next((k for k in range(i + 1, len(lines)) if quote in lines[k][0]), None)
        if j is None:
            return None
    close_at = lines[j][0].rindex(quote)
    pre, post = lines[j][0][:close_at], lines[j][0][close_at:]
    tag = b"Version: " + version.encode()
    eol = lines[j][1] or _eol(lines)
    if pre.strip() == b"" and j > i:
        prev_blank = lines[j - 1][0].strip() == b""
        bodies = [tag] if prev_blank else [b"", tag]
        return lines[:j] + [(b, eol) for b in bodies] + lines[j:]
    return lines[:j] + [(pre, eol), (b"", eol), (tag, eol), (post, lines[j][1])] + lines[j + 1:]


def _insert_comment(kind, lines, start, version):
    """After the header comment that begins at the first non-blank line from start."""
    i = start
    if i == 0 and lines and lines[0][0].startswith(b"#!"):
        i = 1
    while i < len(lines) and not lines[i][0].strip():
        i += 1
    if i == len(lines):
        return None
    body = lines[i][0]
    s = body.strip()
    indent = body[:len(body) - len(body.lstrip())]
    v = version.encode()
    markers = {"c": [b"//"], "svelte": [b"//"], "hash": [b"#"], "bat": [b"REM", b"::"]}.get(kind, [])
    mark = next((m for m in markers if s.startswith(m) and not s.startswith(b"#!")), None)
    if mark:
        j = i
        while j + 1 < len(lines) and any(lines[j + 1][0].strip().startswith(m) for m in markers):
            j += 1
        if kind == "bat":
            return _insert_after(lines, j, [indent + b"REM Version: " + v])
        line = indent + mark + b" Version: " + v
        if lines[j][0].strip() == mark:
            return _insert_after(lines, j, [line])
        return _insert_after(lines, j, [indent + mark, line])
    if kind in ("c", "svelte", "css") and s.startswith(b"/*"):
        j = next((k for k in range(i, len(lines))
                  if b"*/" in (lines[k][0].strip()[2:] if k == i else lines[k][0])), None)
        if j is None:
            return None
        if kind == "css":
            return _insert_after(lines, j, [indent + b"/* Version: " + v + b" */"])
        return _insert_after(lines, j, [indent + b"// Version: " + v])
    return None


def insert_version(path, data, version):
    """data with a Version: line added to its header, or None if it has none."""
    if never_touch(path) or not _is_text(data):
        return None
    syn = syntax_of(path, data)
    if syn is None:
        return None
    kind = next(k for k, v in _SYNTAX.items() if v is syn)
    lines = _raw_lines(data)
    if kind == "py":
        out = _insert_python(lines, version)
    elif kind == "svelte":
        out = None
        for i, (b, _) in enumerate(lines):
            if _SCRIPT_OPEN.match(b):
                out = _insert_comment(kind, lines, i + 1, version)
                if out is not None:
                    break
    elif kind in ("c", "css", "hash", "bat"):
        out = _insert_comment(kind, lines, 0, version)
    else:
        out = None
    if out is None:
        return None
    result = _join(out)
    hits = find_version_lines(path, result)
    if len(hits) != 1 or hits[0].value != version:
        return None
    return result


# --------------------------------------------------------------------------
# Which files carry a line (the covered types in the header comment)
# --------------------------------------------------------------------------

def conventional(repo_name, path, data):
    ext = os.path.splitext(path)[1]
    if repo_name == "backend":
        return ext == ".py" and not path.startswith("alembic/versions/")
    if repo_name == "frontend":
        return path.split("/", 1)[0] in ("src", "e2e") and ext in (".ts", ".js", ".svelte", ".css")
    if not path.startswith("scripts/"):
        return False
    if ext in (".sh", ".ps1", ".bat"):
        return True
    if ext in (".service", ".conf"):
        return False
    first = data.split(b"\n", 1)[0]
    return bool(re.match(rb"^#!.*\b(ba)?sh\b", first))


# --------------------------------------------------------------------------
# Git
# --------------------------------------------------------------------------

class RepoError(Exception):
    pass


class Repo(object):

    def __init__(self, name, path):
        self.name = name
        self.path = path
        self._cat = None
        self._renames = {}

    def git(self, *args, **kw):
        p = subprocess.run(["git", "-C", self.path] + list(args), capture_output=True)
        if p.returncode != 0 and not kw.get("ok_fail"):
            raise RepoError("%s: git %s: %s" % (self.name, " ".join(args), p.stderr.decode(errors="replace").strip()))
        return p.stdout if p.returncode == 0 else None

    def rev(self, ref):
        out = self.git("rev-parse", "--verify", "--quiet", ref, ok_fail=True)
        return out.decode().strip() if out else None

    def has_commit(self, sha):
        return self.git("cat-file", "-e", sha + "^{commit}", ok_fail=True) is not None

    def blob(self, commit, path):
        """The bytes of path at commit, or None if absent."""
        if self._cat is None:
            self._cat = subprocess.Popen(["git", "-C", self.path, "cat-file", "--batch"],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self._cat.stdin.write(("%s:%s\n" % (commit, path)).encode())
        self._cat.stdin.flush()
        header = self._cat.stdout.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            return None
        size = int(header[2])
        data = self._cat.stdout.read(size)
        self._cat.stdout.read(1)
        return data

    def close(self):
        if self._cat is not None:
            self._cat.stdin.close()
            self._cat.wait()
            self._cat = None

    def raw_diff(self, a, b):
        """[(status, oldmode, newmode, oldpath, newpath)] between commits a and b."""
        out = self.git("diff", "--raw", "-z", "-M", "--no-abbrev", a, b)
        fields = out.split(b"\0")
        res, i = [], 0
        while i < len(fields) and fields[i]:
            meta = fields[i].decode().lstrip(":").split()
            status = meta[4][0]
            if status in "RC":
                old, new = fields[i + 1].decode(), fields[i + 2].decode()
                i += 3
            else:
                old = new = fields[i + 1].decode()
                i += 2
            res.append((status, meta[0], meta[1], old, new))
        return res

    def renames(self, a, b):
        """{new path: old path} for renames between commits a and b."""
        key = (a, b)
        if key not in self._renames:
            self._renames[key] = {new: old for st, _, _, old, new in self.raw_diff(a, b) if st == "R"}
        return self._renames[key]

    def head_files(self):
        out = self.git("ls-tree", "-r", "-z", "--full-tree", "HEAD")
        files = []
        for entry in out.split(b"\0"):
            if not entry:
                continue
            meta, path = entry.split(b"\t", 1)
            mode = meta.split()[0]
            if mode in (b"100644", b"100755"):
                files.append(path.decode())
        return sorted(files)

    def dirty(self):
        out = self.git("status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all")
        return bool(out.strip())


# --------------------------------------------------------------------------
# Analysis of one repository
# --------------------------------------------------------------------------

Entry = namedtuple("Entry", "category path old new")
CATEGORIES = ["stamp", "already", "insert", "no-header", "unreleased", "unresolved", "ambiguous"]
WRITES = ("stamp", "unreleased", "insert")
FAILS = ("stamp", "insert", "no-header", "unreleased", "ambiguous")


def excluded(repo_name, path):
    """Never stamped, corrected or listed."""
    return never_touch(path) or (repo_name == "backend" and path.startswith("alembic/versions/"))


def changed_paths(repo, base):
    """Paths at HEAD whose content changed since base, and HEAD's renames."""
    changed, renames = set(), {}
    for status, oldmode, newmode, old, new in repo.raw_diff(base, "HEAD"):
        if status == "D" or newmode in ("160000", "120000") or oldmode == "160000":
            continue
        if status == "R":
            renames[new] = old
        if status in ("A", "C"):
            changed.add(new)
            continue
        a, b = repo.blob(base, old), repo.blob("HEAD", new)
        if a is None or b is None or normalise(old, a) != normalise(new, b):
            changed.add(new)
    return changed, renames


def last_changed_release(repo, path, anchors, head_norm, since_path):
    """The release tag in which path took HEAD's content, or None.

    anchors: [(tag, commit or None)], oldest first, ending with --since.
    """
    k = len(anchors) - 1
    tag, commit = anchors[k]
    if commit is None or not repo.has_commit(commit):
        return None
    cur_path = since_path
    data = repo.blob(commit, cur_path)
    if data is None or normalise(cur_path, data) != head_norm:
        return None
    while k > 0:
        prev_tag, prev_commit = anchors[k - 1]
        if prev_commit is None:
            break
        if not repo.has_commit(prev_commit):
            return None
        prev_path = repo.renames(prev_commit, anchors[k][1]).get(cur_path, cur_path)
        data = repo.blob(prev_commit, prev_path)
        if data is None or normalise(prev_path, data) != head_norm:
            break
        k, cur_path = k - 1, prev_path
    return anchors[k][0]


def analyse(repo, base, anchors, since, version, releases):
    changed, renames = changed_paths(repo, base)
    since_key = version_key(since)
    entries = []
    for path in repo.head_files():
        if excluded(repo.name, path):
            continue
        disk = os.path.join(repo.path, path)
        if not os.path.isfile(disk) or os.path.islink(disk):
            continue
        with open(disk, "rb") as f:
            data = f.read()
        hits = find_version_lines(path, data)
        if len(hits) > 1:
            entries.append(Entry("ambiguous", path, ",".join(h.value for h in hits), None))
            continue
        if path in changed:
            if hits:
                cat = "already" if hits[0].value == version else "stamp"
                entries.append(Entry(cat, path, hits[0].value, version))
            elif _is_text(data) and conventional(repo.name, path, data):
                cat = "insert" if insert_version(path, data, version) is not None else "no-header"
                entries.append(Entry(cat, path, None, version if cat == "insert" else None))
            continue
        if not hits:
            continue
        value = hits[0].value
        vkey = version_key(value)
        if value in releases and since_key is not None and vkey <= since_key:
            continue
        head = repo.blob("HEAD", path)
        head_norm = normalise(path, head if head is not None else data)
        target = last_changed_release(repo, path, anchors, head_norm, renames.get(path, path))
        if target is None:
            entries.append(Entry("unresolved", path, value, None))
        elif target != value:
            entries.append(Entry("unreleased", path, value, target))
    return entries


def apply(repo, entries):
    for e in entries:
        if e.category not in WRITES:
            continue
        disk = os.path.join(repo.path, e.path)
        with open(disk, "rb") as f:
            data = f.read()
        if e.category == "insert":
            out = insert_version(e.path, data, e.new)
        else:
            out = set_version(e.path, data, e.new)
        if out is not None and out != data:
            with open(disk, "wb") as f:
                f.write(out)


# --------------------------------------------------------------------------
# Release files: VERSION, package.json and its lock, pixi.toml
# --------------------------------------------------------------------------

def _json_string_spans(data):
    """{key path: (start, end)} of every string value in a JSON document."""
    spans, stack, i, n = {}, [], 0, len(data)
    while i < n:
        c = data[i:i + 1]
        if c in b" \t\r\n":
            i += 1
        elif c == b",":
            if stack and stack[-1][0] == "o":
                stack[-1][2] = True
            i += 1
        elif c == b":":
            stack[-1][2] = False
            i += 1
        elif c in b"{[":
            stack.append(["o" if c == b"{" else "a", None, c == b"{"])
            i += 1
        elif c in b"}]":
            stack.pop()
            i += 1
        elif c == b'"':
            j = i + 1
            while data[j:j + 1] != b'"':
                j += 2 if data[j:j + 1] == b"\\" else 1
            top = stack[-1] if stack else None
            if top is not None and top[0] == "o" and top[2]:
                top[1] = data[i + 1:j].decode("utf-8")
            else:
                path = tuple(f[1] if f[0] == "o" else "[]" for f in stack)
                spans.setdefault(path, (i + 1, j))
            i = j + 1
        else:
            while i < n and data[i:i + 1] not in b",}] \t\r\n":
                i += 1
    return spans


def _replace_spans(data, spans, value):
    out = data
    for start, end in sorted(spans, reverse=True):
        out = out[:start] + value.encode("ascii") + out[end:]
    return out


def _release_version_file(data, version):
    m = re.match(rb"^([^\s]+)(\r?\n)?$", data)
    if not m:
        return None, None
    return m.group(1).decode(), data[:m.start(1)] + version.encode() + data[m.end(1):]


def _release_json(data, paths, version):
    import json
    spans = _json_string_spans(data)
    found = [spans.get(p) for p in paths]
    if any(s is None for s in found):
        return None, None
    olds = {data[s:e].decode() for s, e in found}
    if len(olds) != 1:
        return ",".join(sorted(olds)), None
    out = _replace_spans(data, found, version)
    before, after = json.loads(data.decode("utf-8")), json.loads(out.decode("utf-8"))
    for p in paths:                         # the named fields, and nothing else
        node = before
        for k in p[:-1]:
            node = node[k]
        node[p[-1]] = version
    if before != after:
        return None, None
    return olds.pop(), out


def _release_pixi(data, version):
    lines, pos, in_table = data.splitlines(True), 0, False
    for raw in lines:
        s = raw.strip()
        if s.startswith(b"["):
            in_table = s in (b"[workspace]", b"[project]")
        elif in_table:
            m = re.match(rb'^version[ \t]*=[ \t]*"([^"]*)"', raw)
            if m:
                start, end = pos + m.start(1), pos + m.end(1)
                return data[start:end].decode(), data[:start] + version.encode() + data[end:]
        pos += len(raw)
    return None, None


def release_files(dirs, names, version, notes):
    """[(repo name, path, disk path, old, new bytes)] for release files not at version."""
    todo = []
    plan = {"superproject": [("VERSION", "version")],
            "frontend": [("package.json", "package"), ("package-lock.json", "lock")],
            "backend": [("pixi.toml", "pixi")]}
    package_old = None
    for name in names:
        for rel, kind in plan[name]:
            disk = os.path.join(dirs[name], rel)
            if not os.path.isfile(disk):
                if kind != "lock":
                    notes.append("note: %s/%s not found" % (name, rel))
                continue
            with open(disk, "rb") as f:
                data = f.read()
            if kind == "version":
                old, out = _release_version_file(data, version)
            elif kind == "package":
                old, out = _release_json(data, [("version",)], version)
                package_old = old
            elif kind == "lock":
                old, out = _release_json(data, [("version",), ("packages", "", "version")], version)
                if old is not None and old != package_old:
                    notes.append("note: package-lock.json does not mirror package.json's version "
                                 "(%s, %s); left" % (old, package_old))
                    continue
            else:
                old, out = _release_pixi(data, version)
            if out is None:
                notes.append("note: %s/%s: no single version field found (%s); left" % (name, rel, old))
                continue
            if old != version:
                todo.append((name, rel, disk, old, out))
    return todo


# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------

def _is_repo(path):
    if not os.path.isdir(path):
        return False
    p = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True)
    return p.returncode == 0 and os.path.realpath(p.stdout.decode().strip()) == os.path.realpath(path)


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(
        prog="stamp-versions.py",
        description="Set Version: lines from the diff since the previous release tag.")
    ap.add_argument("--version", required=True, help="the release being made, X.Y.Z")
    ap.add_argument("--since", help="previous release tag (default: the latest release tag)")
    ap.add_argument("--repo", choices=["superproject", "frontend", "backend", "all"], default="all")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="change nothing; exit 1 if anything would change (default)")
    mode.add_argument("--write", action="store_true", help="apply the changes")
    ap.add_argument("--set-release-files", action="store_true",
                    help="also set VERSION, package.json (and its lock) and pixi.toml to --version")
    ap.add_argument("--allow-dirty", action="store_true", help="write even with uncommitted changes")
    ap.add_argument("--verbose", "-v", action="store_true", help="list the files in each category")
    ap.add_argument("--root", default=os.path.dirname(here), help="the superproject (default: this script's)")
    ap.add_argument("--frontend-dir", help="the frontend checkout (default: ROOT/frontend)")
    ap.add_argument("--backend-dir", help="the backend checkout (default: ROOT/backend)")
    args = ap.parse_args(argv)

    def fail(msg):
        print("stamp-versions: " + msg, file=sys.stderr)
        return 2

    if not is_plain_version(args.version):
        return fail("--version must be a plain X.Y.Z, not %r" % args.version)
    root = os.path.abspath(args.root)
    if not _is_repo(root):
        return fail("%s is not a git repository" % root)
    sp = Repo("superproject", root)
    tags = sp.git("tag", "-l").decode().split()
    releases = release_tags(tags)
    if args.since:
        since, how = args.since, "given"
        if sp.rev(since + "^{commit}") is None:
            return fail("--since %s does not name a commit in %s" % (since, root))
    else:
        if not releases:
            return fail("no release tags in %s; pass --since" % root)
        since, how = releases[-1], "latest release tag"
    since_key = version_key(since)
    if since_key is not None and version_key(args.version) <= since_key:
        return fail("--version %s is not newer than --since %s" % (args.version, since))

    anchor_tags = [t for t in releases if since_key is None or version_key(t) <= since_key]
    if since not in anchor_tags:
        anchor_tags.append(since)

    names = ["superproject", "frontend", "backend"] if args.repo == "all" else [args.repo]
    dirs = {"superproject": root,
            "frontend": os.path.abspath(args.frontend_dir or os.path.join(root, "frontend")),
            "backend": os.path.abspath(args.backend_dir or os.path.join(root, "backend"))}
    repos, notes = [], []
    try:
        for name in names:
            if not _is_repo(dirs[name]):
                return fail("%s is not checked out at %s; pass --%s-dir or choose --repo"
                            % (name, dirs[name], name))
            repo = Repo(name, dirs[name])
            if name == "superproject":
                base = sp.rev(since + "^{commit}")
                anchors = [(t, sp.rev(t + "^{commit}")) for t in anchor_tags]
            else:
                base = sp.rev("%s:%s" % (since, name))
                if base is None or not repo.has_commit(base):
                    return fail("%s: the commit pinned at %s is not in %s" % (name, since, dirs[name]))
                anchors = [(t, sp.rev("%s:%s" % (t, name))) for t in anchor_tags]
                pinned = sp.rev("HEAD:%s" % name)
                head = repo.rev("HEAD")
                if pinned and head and pinned != head:
                    notes.append("note: %s HEAD %s is not the commit the superproject's HEAD pins (%s)"
                                 % (name, head[:12], pinned[:12]))
            if args.write and not args.allow_dirty and repo.dirty():
                return fail("%s has uncommitted changes at %s; commit them or pass --allow-dirty"
                            % (name, dirs[name]))
            repos.append((repo, base, anchors))

        print("stamp-versions: release %s, since %s (%s), %s"
              % (args.version, since, how, "write" if args.write else "check"))
        work = 0
        release_todo = release_files(dirs, names, args.version, notes)
        for n in notes:
            print(n)
        for repo, base, anchors in repos:
            entries = analyse(repo, base, anchors, since, args.version, set(releases))
            counts = {c: 0 for c in CATEGORIES}
            for e in entries:
                counts[e.category] += 1
            work += sum(counts[c] for c in FAILS)
            print("%s: %s" % (repo.name, ", ".join("%d %s" % (counts[c], c) for c in CATEGORIES)))
            if args.verbose:
                prefix = "" if repo.name == "superproject" else repo.name + "/"
                for cat in CATEGORIES:
                    for e in entries:
                        if e.category != cat:
                            continue
                        line = "  %-11s %s%s" % (cat, prefix, e.path)
                        if e.old and e.new and e.old != e.new:
                            line += "  %s -> %s" % (e.old, e.new)
                        elif e.old:
                            line += "  %s" % e.old
                        print(line)
            if args.write:
                apply(repo, entries)
        print("release files not at %s: %d%s" % (args.version, len(release_todo),
              "" if args.set_release_files else " (set with --set-release-files)"))
        if args.verbose:
            for name, rel, _, old, _ in release_todo:
                prefix = "" if name == "superproject" else name + "/"
                print("  %-11s %s%s  %s -> %s" % ("release", prefix, rel, old, args.version))
        if args.set_release_files:
            work += len(release_todo)
            if args.write:
                for _, _, disk, _, out in release_todo:
                    with open(disk, "wb") as f:
                        f.write(out)
        if args.write:
            return 0
        return 1 if work else 0
    except RepoError as exc:
        return fail(str(exc))
    finally:
        for repo, _, _ in repos:
            repo.close()


if __name__ == "__main__":
    sys.exit(main())
