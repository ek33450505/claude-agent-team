#!/usr/bin/env python3
"""RULE 5 of scripts/cast-command-guard.py -- Bash WRITE guard for the installed exec surface (U6e).

Git hooks now run from `~/.claude/githooks` and call `~/.claude/scripts`; the Edit/Write TOOLS are
denied there but Bash was not (only a recursive `rm -r[f]` of the .claude subtree was blocked).
RULE 5 blocks a Bash command that WRITES / MOVES / LINKS / CHMODs / DELETES (recursive or not) a
path under `~/.claude/githooks/`, `~/.claude/scripts/`, `~/.claude/config/`,
`~/.claude/install-manifest.sha256`, or the roots themselves. READS stay allowed.

Table-driven: every BLOCK / ALLOW case is evaluated with HOME redirected to a scratch dir (nothing
is ever written -- the guard only ANALYSES the string). The accepted residuals (interpreter
writes, editors, variable-built paths, symlink-through-elsewhere) are pinned as ALLOW so the gap
is honest and a future tightening shows up as a deliberate test change.

CAST_CMD_GUARD_PATH selects the module under test (used by the mutation checks).
"""
import importlib.util
import json
import os
import pwd
import random
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent
_GUARD = Path(os.environ.get("CAST_CMD_GUARD_PATH") or (_REPO / "scripts" / "cast-command-guard.py"))
HATCH = "CAST_PROTECTED_WRITE_OK"


def _load():
    spec = importlib.util.spec_from_file_location("cast_command_guard_pw", str(_GUARD))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cg = _load()

    def setUp(self):
        # Scratch HOME must NOT sit under /tmp: the ALLOW cases name /tmp (`find /tmp ... -delete`,
        # `TMPDIR=/tmp ...`), and if /tmp is an ancestor of the protected roots the guard correctly
        # BLOCKS them. Linux's default tempdir IS /tmp; macOS's is /var/folders. Prefer /var/tmp.
        base = "/var/tmp" if os.access("/var/tmp", os.W_OK | os.X_OK) else None
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="pwguard-", dir=base))
        self.home = os.path.join(self.tmp, "home")
        self.work = os.path.join(self.tmp, "work")
        for d in ("githooks", "scripts", "config", "logs"):
            os.makedirs(os.path.join(self.home, ".claude", d))
        os.makedirs(self.work)
        self._cwd = os.getcwd()
        os.chdir(self.work)
        patcher = mock.patch.dict(os.environ, {"HOME": self.home})
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        os.chdir(self._cwd)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def check(self, cmd, expect_block, label=""):
        blocked, msg = self.cg.is_blocked(cmd)
        if expect_block:
            self.assertTrue(blocked, f"expected BLOCK {label}: {cmd!r}")
            self.assertIn(HATCH, msg, f"blocked by the wrong rule {label}: {cmd!r} -> {msg}")
        else:
            self.assertFalse(blocked, f"expected ALLOW {label}: {cmd!r} -> {msg}")


# ---------------------------------------------------------------------------------------------
BLOCK = [
    # --- redirections (the shapes the dispatcher ALLOWED before) --------------------------
    "echo x > ~/.claude/githooks/pre-commit",
    "echo x >> ~/.claude/scripts/cast-hook-lib.sh",
    "echo x >| ~/.claude/scripts/y",
    "echo x &> ~/.claude/scripts/y",
    "echo x &>> ~/.claude/scripts/y",
    "echo x >& ~/.claude/scripts/y",
    "echo x 2> ~/.claude/config/policies.json",
    "echo x 2>~/.claude/config/policies.json",
    "echo x 1>>~/.claude/config/policies.json",
    "echo x>~/.claude/scripts/y",
    "> ~/.claude/install-manifest.sha256",
    "echo x <> ~/.claude/scripts/y",
    "exec > ~/.claude/scripts/y",
    "cat <<EOF > ~/.claude/scripts/x\nbody\nEOF",
    # --- spellings of the same path --------------------------------------------------------
    "echo x > $HOME/.claude/scripts/y",
    'echo x > "$HOME/.claude/scripts/y"',
    'echo x > "${HOME}/.claude/scripts/y"',
    'echo x > "$HOME"/.claude/scripts/y',
    "echo x > ${HOME}/.claude/scripts/y",
    "echo x > '@H@/.claude/scripts/y'",
    "echo x > @H@/.claude/scripts/y",
    "echo x > ~/.cla\"\"ude/scripts/y",
    "echo x > ~/.cl'a'ude/scr\\ipts/y",
    "echo x > ~/.claude/scr\\\nipts/y",
    "echo x > ~/.claude/./scripts/../scripts/y",
    "echo x > ~/.claude/logs/../scripts/y",
    "echo x > ~/.claude//scripts//y",
    "echo x > ~/.CLAUDE/Scripts/y",
    "echo x > ~/.claude/scripts",
    "echo x > ~/.claude/scripts/",
    "echo x > $'@H@/.claude/scripts/y'",
    # --- brace / glob / dynamic tail -------------------------------------------------------
    "cp /tmp/x ~/.claude/{scripts,config}/",
    "rm ~/.claude/{logs,githooks}/pre-push",
    "rm ~/.claude/scripts/*",
    "rm ~/.claude/scr*/x",
    "rm ~/.cl*/scripts/x",
    "echo x > ~/.claude/scripts/$NAME",
    "echo x > ~/.claude/$NAME",
    'echo x > "$D/.claude/scripts/x"',
    "echo x > ~/.claude/$(echo scripts)/y",
    "echo x > ~/.claude/`echo scripts`/y",
    "echo x > ~/.claude/scripts/$(date)",
    "mv ~/.claude/githooks/pre-commit{,.bak}",
    "echo x > ~/.claude/scripts/y 2>&1",
    # --- tee / sponge ----------------------------------------------------------------------
    "echo x | tee ~/.claude/githooks/pre-commit",
    "echo x | tee -a ~/.claude/scripts/x",
    "echo x | tee /tmp/a ~/.claude/scripts/x",
    "echo x | sponge ~/.claude/scripts/x",
    "echo a | tee ~/.claude/scripts/x | cat",
    # --- cp / mv / install / rsync / ditto -------------------------------------------------
    "cp /tmp/x ~/.claude/scripts/x",
    "cp -t ~/.claude/scripts /tmp/x",
    "cp --target-directory=~/.claude/scripts /tmp/x",
    "cp -R /tmp/new ~/.claude/githooks",
    "install -m 755 /tmp/x ~/.claude/scripts/x",
    "install -d ~/.claude/githooks/sub",
    "rsync -a /tmp/s/ ~/.claude/scripts/",
    "rsync -a --exclude=x /tmp/s/ ~/.claude/config/",
    "rsync -a --remove-source-files ~/.claude/scripts/ /tmp/s/",
    "ditto /tmp/x ~/.claude/config/x",
    "mv /tmp/x ~/.claude/githooks/pre-commit",
    "mv -t ~/.claude/scripts /tmp/x",
    "mv ~/.claude/githooks ~/.claude/gh.bak",
    "mv ~/.claude/scripts/x /tmp/",
    "mv ~/.claude ~/old-claude",
    "mv ~/.claude/install-manifest.sha256 /tmp/",
    # --- ln (link NAME is the write) -------------------------------------------------------
    "ln -sfn /tmp/x ~/.claude/githooks",
    "ln -s /tmp/x ~/.claude/scripts/y",
    "ln -sf /tmp/x ~/.claude",
    "ln -s -t ~/.claude/scripts /tmp/x",
    # --- delete (non-recursive) ------------------------------------------------------------
    "rm -f ~/.claude/githooks/pre-push",
    "rm ~/.claude/scripts/x",
    "rm -f ~/.claude",
    "unlink ~/.claude/scripts/x",
    "rmdir ~/.claude/githooks",
    "shred -u ~/.claude/scripts/x",
    # --- chmod family ----------------------------------------------------------------------
    "chmod -x ~/.claude/githooks/pre-commit",
    "chmod 000 ~/.claude/scripts/x",
    "chmod -R 777 ~/.claude",
    "chmod -R a-x ~/.claude/githooks",
    "chown ed ~/.claude/config/x",
    "chgrp staff ~/.claude/config/x",
    "chflags uchg ~/.claude/scripts/x",
    "xattr -w a b ~/.claude/scripts/x",
    "xattr -d com.apple.quarantine ~/.claude/scripts/x",
    "touch ~/.claude/scripts/x",
    "touch -r /tmp/ref ~/.claude/scripts/x",
    "truncate -s 0 ~/.claude/scripts/x",
    # --- in-place editors ------------------------------------------------------------------
    "sed -i '' 's/a/b/' ~/.claude/scripts/x",
    "sed -i.bak s/a/b/ ~/.claude/scripts/x",
    "sed -ni p ~/.claude/scripts/x",
    "sed --in-place=.b s/a/b/ ~/.claude/scripts/x",
    "gsed -i s/a/b/ ~/.claude/scripts/x",
    "perl -pi -e 's/a/b/' ~/.claude/scripts/x",
    "perl -i.bak -pe 's/a/b/' ~/.claude/scripts/x",
    "ruby -i -pe 'x' ~/.claude/scripts/x",
    "ed ~/.claude/scripts/x",
    "ex -s ~/.claude/scripts/x",
    "awk -i inplace '{print}' ~/.claude/scripts/x",
    "patch ~/.claude/scripts/x < /tmp/p.diff",
    "patch -p1 -d ~/.claude/scripts < /tmp/p.diff",
    # --- dd / curl / wget ------------------------------------------------------------------
    "dd if=/dev/zero of=~/.claude/scripts/x",
    'dd of="$HOME/.claude/scripts/x" if=/tmp/y',
    "curl -o ~/.claude/scripts/x http://h/x",
    "curl --output=~/.claude/scripts/x http://h/x",
    "wget -O ~/.claude/scripts/x http://h/x",
    "wget -P ~/.claude/scripts http://h/x",
    # --- find ------------------------------------------------------------------------------
    "find ~/.claude/githooks -delete",
    "find ~/.claude/scripts -name x -exec rm {} \\;",
    "find ~/.claude -name x -delete",
    "find ~/.claude/scripts -name x -exec sed -i s/a/b/ {} +",
    "find /tmp -name x -fprint ~/.claude/scripts/x",
    # --- tar / unzip -----------------------------------------------------------------------
    "tar -xf /tmp/a.tar -C ~/.claude/scripts",
    "tar xzf /tmp/a.tgz -C ~/.claude/githooks",
    "tar --extract --directory=~/.claude/config -f /tmp/a.tar",
    "tar -cf ~/.claude/scripts/a.tar /tmp/x",
    "unzip /tmp/a.zip -d ~/.claude/scripts",
    # --- wrappers / prefixes ---------------------------------------------------------------
    "sudo rm ~/.claude/scripts/x",
    "sudo -u root tee ~/.claude/scripts/x",
    "env FOO=1 tee ~/.claude/scripts/x",
    "command mv /tmp/x ~/.claude/scripts/x",
    "nohup cp /tmp/x ~/.claude/scripts/x",
    "\\rm ~/.claude/scripts/x",
    "/bin/rm ~/.claude/scripts/x",
    "FOO=1 rm ~/.claude/scripts/x",
    "grm ~/.claude/scripts/x",
    # --- payloads --------------------------------------------------------------------------
    "bash -c 'echo x > ~/.claude/scripts/x'",
    'sh -c "rm ~/.claude/githooks/pre-commit"',
    "bash -lc 'tee ~/.claude/scripts/x'",
    'eval "echo x > ~/.claude/scripts/y"',
    "eval echo x '>' ~/.claude/scripts/y",
    "bash -c \"bash -c 'rm ~/.claude/scripts/x'\"",
    "env bash -c 'rm ~/.claude/scripts/x'",
    # --- compounds -------------------------------------------------------------------------
    "true && echo x > ~/.claude/scripts/y",
    "ls; rm ~/.claude/scripts/x",
    "echo $(rm ~/.claude/scripts/x)",
    "echo `rm ~/.claude/scripts/x`",
    "(rm ~/.claude/scripts/x)",
    "{ rm ~/.claude/scripts/x; }",
    "false || chmod -x ~/.claude/githooks/pre-commit",
    "echo hi > >(tee ~/.claude/scripts/x)",
    # --- cd-relative -----------------------------------------------------------------------
    "cd ~/.claude/githooks && echo x > pre-commit",
    "cd ~/.claude/scripts; rm x",
    "cd ~/.claude && rm scripts/x",
    "cd ~/.claude/scripts && cd .. && rm scripts/x",
    "pushd ~/.claude/githooks && chmod -x pre-commit",
    "cd ~/.claude/scripts && tar -xf /tmp/a.tar",
    "cd ~/.claude/scripts && echo $(rm x)",
    "cat <(rm ~/.claude/scripts/x)",
    "xargs -I{} rm ~/.claude/scripts/{}",
    "sed -E -i '' 's/a/b/' ~/.claude/scripts/x",
    "link /tmp/x ~/.claude/scripts/y",
    # parameters assigned earlier in the SAME command resolve
    'D=~/.claude; echo x > "$D/scripts/x"',
    'export D=$HOME/.claude && rm $D/githooks/pre-push',
    'D=~/.claude/scripts; cp /tmp/x "$D/"',
    'F=~/.claude/scripts/x; tee "$F" < /dev/null',
    'D=~/.claude; E="$D/scripts"; echo x > "$E/x"',
    'for f in ~/.claude/scripts/*.sh; do rm "$f"; done',
    'for f in /tmp/a ~/.claude/githooks/x; do chmod -x $f; done',
    'declare -x D=~/.claude; mv $D/githooks /tmp/gh',
    "if true; then rm ~/.claude/scripts/x; fi",
    "{rm,~/.claude/scripts/x}",
    "{tee,~/.claude/githooks/pre-commit} < /dev/null",
    "t''ee ~/.claude/scripts/x",
    'r"m" -f ~/.claude/scripts/x',
    "/bin/r\\m ~/.claude/scripts/x",
    "$'rm' ~/.claude/scripts/x",
    "sudo 'tee' ~/.claude/scripts/x",
    "mv ~/.claude/{githooks,gh.bak}",
    "rm ~/.claude/{logs,scripts}/x",
    "while :; do tee ~/.claude/scripts/x; done",
    "! rm ~/.claude/scripts/x",
    "bash <<'EOF'\necho x > ~/.claude/scripts/y\nEOF",
    "cat <<EOF | sh\nrm ~/.claude/githooks/pre-commit\nEOF",
    "source /dev/stdin <<EOF\ntee ~/.claude/scripts/x\nEOF",
    "bash <<EOF\nbash <<EOF2\nrm ~/.claude/scripts/x\nEOF2\nEOF",
    "{ echo x; } > ~/.claude/scripts/y",
    "( echo x ) > ~/.claude/scripts/y",
    "exec 3<> ~/.claude/scripts/y",
    "echo x > ~/.claude/scripts/y # comment",
]

ALLOW = [
    # --- reads / execution of installed scripts (the orchestrator does these routinely) ---
    "cat ~/.claude/scripts/x",
    "cat ~/.claude/scripts/x > /tmp/y",
    "cat ~/.claude/scripts/x >> /tmp/y",
    'D=/tmp/x; echo x > "$D/scripts/x"',
    'D=~/.claude; echo x > "$D/logs/x"',
    'for f in /tmp/a /tmp/b; do rm "$f"; done',
    'for f in ~/.claude/scripts/*.sh; do cat "$f" > /tmp/o; done',
    'D=~/.claude/scripts; cat "$D/x" > /tmp/y',
    "echo x > ~root/y",
    "echo hi # > ~/.claude/scripts/x",
    "echo hi # rm ~/.claude/scripts/x",
    "cat > /tmp/s.sh <<'EOF'\nrm ~/.claude/scripts/x\necho x > ~/.claude/githooks/y\nEOF",
    "cat <<EOF\nrm ~/.claude/scripts/x\nEOF",
    "bash /tmp/s.sh <<EOF\nfine\nEOF",
    "for f in ~/.claude/scripts/*.py; do shasum -a 256 $f; done",
    "cp -p ~/.claude/scripts/x scripts/x",
    "{ cat ~/.claude/scripts/x; } > /tmp/y",
    "ls -l ~/.claude/githooks",
    "cmp scripts/x ~/.claude/scripts/x",
    "shasum -a 256 ~/.claude/scripts/* ~/.claude/install-manifest.sha256",
    "diff ~/.claude/scripts/x scripts/x",
    "diff <(cat ~/.claude/scripts/x) y",
    "head -5 ~/.claude/githooks/pre-commit",
    "grep -r foo ~/.claude/scripts",
    "grep -rn foo ~/.claude/config > /tmp/out",
    "echo ~/.claude/scripts/x",
    "echo 2>&1 ~/.claude/scripts/x",
    'echo "x > ~/.claude/scripts/y"',
    "echo 'rm ~/.claude/scripts/x'",
    "git commit -m 'tee ~/.claude/scripts/x' -m 'write > ~/.claude/scripts/y'",
    "bash ~/.claude/githooks/pre-commit",
    "bash ~/.claude/scripts/cast-hook-lib.sh arg > /tmp/o",
    "source ~/.claude/scripts/cast-hook-lib.sh",
    "python3 ~/.claude/scripts/foo.py > /tmp/o",
    "bash install.sh",
    "CAST_INSTALL_FORCE=1 bash install.sh",
    "bash -c 'cat ~/.claude/scripts/x > /tmp/y'",
    "eval 'cat ~/.claude/scripts/x'",
    # --- the source of a copy / archive is a READ ------------------------------------------
    "cp ~/.claude/scripts/x /tmp/",
    "cp -r ~/.claude/scripts /tmp/scripts-copy",
    "rsync -a ~/.claude/scripts/ /tmp/s/",
    "tar -cf /tmp/a.tar ~/.claude/scripts",
    "tar -tf /tmp/a.tar",
    "tar -xf /tmp/a.tar -C /tmp/x",
    "unzip -l /tmp/a.zip",
    "unzip /tmp/a.zip -d /tmp/x",
    "ln -s ~/.claude/scripts /tmp/s",
    "ditto ~/.claude/scripts /tmp/s",
    # --- other roots / look-alike paths ----------------------------------------------------
    "echo x > /tmp/.claude/scripts/x",
    "rm /tmp/.claude/scripts/x",
    "cp x /tmp/.claude/githooks/",
    "cp x ~/.claude/scripts.bak",
    "mv ~/.claude/scripts.bak /tmp/",
    "echo x > ~/.claude/logs/x.log",
    "touch ~/.claude/agent-status/x",
    "rm ~/.claude/logs/old.log",
    "cp x ~/.claude/agents/y",
    "echo x > ~/$FILE",
    "echo x > ~/.claude/logs/$NAME",
    "echo $(cat ~/.claude/scripts/x) > /tmp/y",
    "echo x > ~/.claude/scriptsx",
    "echo x > ~/.claude/scripts.d/x",
    "echo x > ~/.claude/configs/x",
    "cp x ~/.claude/install-manifest.sha256.new",
    "echo x > ~/.claude/agents/$NAME",
    "find ~/.claude/logs -mtime +30 -delete",
    # --- tools that only read, or write elsewhere ------------------------------------------
    "sed -n p ~/.claude/scripts/x",
    "sed -e 's/x/y/' ~/.claude/scripts/x > /tmp/o",
    "sed -i s/a/b/ /tmp/f",
    "perl -pi -e 's/a/b/' /tmp/f",
    "chmod +x /tmp/x",
    "chmod -R u+w /tmp/x",
    "touch /tmp/x",
    "curl -o /tmp/x http://h/x",
    "wget -O /tmp/x http://h/x",
    "dd if=~/.claude/scripts/x of=/tmp/x",
    "find ~/.claude/scripts -name '*.sh'",
    "find ~/.claude/scripts -name x -exec grep foo {} +",
    "find ~/.claude/githooks -type f -exec shasum {} \\;",
    "find ~/.claude -name x -print",
    "find /tmp -name x -delete",
    "cd ~/.claude/scripts && cat x > /tmp/y",
    "cd ~/.claude/scripts; cd /tmp; rm x",
    "cd ~/.claude && cat scripts/x",
    "ls ~/.claude/scripts | xargs -n1 basename",
    # --- ACCEPTED RESIDUALS (pinned: the rule does not see these) --------------------------
    'echo x > "$D/scripts/x"',
    'read D; echo x > "$D/scripts/x"',
    "ln -s ~/.claude/scripts /tmp/s2; echo x > /tmp/s2/x",
    "echo ~/.claude/scripts/x | xargs rm",   # path arrives on stdin
    "ls ~/.claude/scripts | xargs rm",
    "ln ~/.claude/scripts/x /tmp/h; echo x > /tmp/h",  # hard link made elsewhere
    "python3 <<EOF\nopen('@H@/.claude/scripts/x','w')\nEOF",
]


class TestBlockMatrix(_Base):
    def test_block_matrix(self):
        for cmd in BLOCK:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, True)

    def test_allow_matrix(self):
        for cmd in ALLOW:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, False)


# --- security round: the rule is INVERTED (fail closed) -----------------------------------------
# An unknown command (or wrapper) that names a protected path anywhere in its arguments is
# blocked unless it is on an exact READ/EXEC allowlist; ancestors of the roots (`~/.claude`,
# `~`, `/`) are protected against merge / extract / delete tools.
SEC_BLOCK = [
    # H1 firmlink spelling of the same path
    "echo x > /System/Volumes/Data@H@/.claude/scripts/x",
    "rm /System/Volumes/Data@H@/.claude/githooks/pre-push",
    "cp a /System/Volumes/Data@H@/.claude/scripts/",
    "mv /system/volumes/DATA@H@/.claude/githooks /tmp/g",
    "chmod -x /System/Volumes/Data@H@/.claude/scripts/x",
    # H2 bracket classes
    "echo x > ~/.claude/[s]cripts/x",
    "echo x > ~/.claude/s[c]ripts/x",
    "echo x > ~/.claude/script[s]/x",
    "rm ~/.claude/[a-z]cripts/x",
    "rm ~/.claude/[!x]cripts/x",
    "rm ~/.claude/[^x]cripts/x",
    "rm ~/.claude/[[:lower:]]cripts/x",
    "rm ~/.claude/[sx]cripts/*",
    "echo x > ~/.claude/githooks/pre-[c]ommit",
    "echo x > ~/.claude/[g]ithooks/[p]re-commit",
    # H3 merges into / deletes from an ANCESTOR of the roots
    "cp -R src/. ~/.claude/",
    "cp -R /tmp/evil/scripts ~/.claude/",
    "cp -a /tmp/evil ~/.claude",
    "cp -r /tmp/evil/.claude ~/",
    "rsync -a src/ ~/.claude/",
    "rsync -a --delete src/ ~/.claude/",
    "tar -C ~/.claude -xf a.tar",
    "tar -xf a.tar -C ~/.claude",
    "tar -xzf a.tgz --directory=$HOME",
    "unzip a.zip -d ~/.claude",
    "ditto src ~/.claude",
    "find ~ -name '*.sh' -delete",
    "find / -name x -exec rm {} +",
    "find ~/.claude -name x -execdir rm {} \\;",
    "cd ~/.claude && cp -R /tmp/evil/scripts .",
    "cd ~/.claude && tar -xf /tmp/a.tar",
    "cd ~/.claude && unzip /tmp/a.zip",
    "mv /tmp/evil/scripts ~/.claude/",
    "pax -rw src ~/.claude/",
    "cpio -pdm ~/.claude/ < list",
    "chmod -R 777 ~",
    "chown -R me $HOME",
    # H4 glob-leading words with a tracked cwd
    "cd ~/.claude/scripts && rm -f *",
    "cd ~/.claude/scripts && rm *.sh",
    "cd ~/.claude/scripts && rm [a-z]*",
    "cd ~/.claude/scripts && rm ?",
    "cd ~/.claude/scripts && rm -- *",
    "cd ~/.claude/scripts && mv * /tmp",
    "cd ~/.claude/scripts && sed -i s/a/b/ *",
    "cd ~/.claude/scripts && chmod -x *",
    "cd ~/.claude/githooks && rm -f pre-*",
    "cd ~/.claude/scripts; touch *",
    # H5 bash option parsing
    "bash -o errexit -c 'echo x > ~/.claude/scripts/y'",
    "bash -O extglob -c 'echo x > ~/.claude/scripts/y'",
    "bash --rcfile /tmp/x -c 'echo x > ~/.claude/scripts/y'",
    "bash +o history -c 'echo x > ~/.claude/scripts/y'",
    "bash -c -- 'echo x > ~/.claude/scripts/y'",
    "bash --noprofile --norc -c 'echo x > ~/.claude/scripts/y'",
    "bash -eo pipefail -c 'echo x > ~/.claude/scripts/y'",
    "sh -c -- 'rm ~/.claude/scripts/x'",
    "bash --init-file /tmp/x -c 'rm ~/.claude/scripts/x'",
    # the payload must be PARSED, not merely string-scanned: no whitespace around the redirect
    "bash --rcfile /tmp/x -c 'echo x>~/.claude/scripts/y'",
    "bash --init-file /tmp/x -c 'echo x>~/.claude/scripts/y'",
    "bash -o errexit -c 'echo x>~/.claude/scripts/y'",
    "bash +o history -c 'echo x>~/.claude/scripts/y'",
    "trap 'echo x>~/.claude/scripts/y' EXIT",
    "env -S 'echo x>~/.claude/scripts/y'",
    # M6 unlisted wrappers: the verb is hidden, the path is not
    "arch -arm64 cp a ~/.claude/scripts/x",
    "caffeinate -i cp a ~/.claude/scripts/x",
    "taskpolicy -b cp a ~/.claude/scripts/x",
    "stdbuf -o0 cp a ~/.claude/scripts/x",
    "setsid cp a ~/.claude/scripts/x",
    "script -q /dev/null cp a ~/.claude/scripts/x",
    "su -c 'cp a ~/.claude/scripts/x' root",
    "sandbox-exec -p '(version 1)' cp a ~/.claude/scripts/x",
    "exec -a n cp a ~/.claude/scripts/x",
    "env -S 'cp a ~/.claude/scripts/x'",
    "nohup setsid cp a ~/.claude/scripts/x",
    "somenewwrapper --flag cp a ~/.claude/scripts/x",
    # M7 tools that write but were never listed
    "mkfifo ~/.claude/scripts/f",
    "mknod ~/.claude/scripts/n p",
    "zip ~/.claude/scripts/a.zip /tmp/x",
    "split -b 1 /tmp/x ~/.claude/scripts/p",
    "cpio -pd ~/.claude/scripts < l",
    "pax -rw d ~/.claude/scripts",
    "sqlite3 ~/.claude/config/x.db 'create table t(a)'",
    "defaults write ~/.claude/config/x k v",
    "plutil -replace k -string v ~/.claude/config/x.plist",
    "git checkout-index --prefix=~/.claude/scripts/ -a",
    "git clone /tmp/r ~/.claude/scripts",
    "git init ~/.claude/scripts/r",
    "git worktree add ~/.claude/scripts/w",
    "git -C ~/.claude/scripts commit -am x",
    "git config --file ~/.claude/config/x k v",
    "openssl enc -in a -out ~/.claude/scripts/x",
    "ruff check --fix ~/.claude/scripts",
    "python3 -m py_compile ~/.claude/scripts/x.py",
    "shfmt -w ~/.claude/scripts/x",
    "python3 ~/.claude/scripts/x.py ~/.claude/config/policies.json",
    "perl -ne print ~/.claude/scripts/x",   # interpreter + protected data operand: fail closed
    "vim -es ~/.claude/scripts/x",          # editors are unknown commands now
    "nano ~/.claude/githooks/pre-commit",
    "emacs --batch ~/.claude/scripts/x -f save-buffer",
    "git -C ~/.claude/scripts add -A",
    # L8 payloads fed through channels other than -c / heredoc
    "bash <<< 'echo x > ~/.claude/scripts/y'",
    "bash <<<'rm ~/.claude/scripts/x'",
    "sh <<< \"tee ~/.claude/scripts/x\"",
    "source <(echo 'rm ~/.claude/scripts/x')",
    ". <(printf 'tee ~/.claude/scripts/x')",
    "trap \"cp a ~/.claude/scripts/x\" EXIT",
    "trap 'rm ~/.claude/scripts/x' EXIT INT",
    "fish -c 'echo x > ~/.claude/scripts/y'",
    "busybox sh -c 'rm ~/.claude/scripts/x'",
    "zsh -c 'rm ~/.claude/scripts/x'",
]

SEC_ALLOW = [
    # the orchestrator's routine commands
    "cmp scripts/x ~/.claude/scripts/x",
    "ls -la ~/.claude/githooks",
    "bash ~/.claude/githooks/pre-commit",
    "bash ~/.claude/scripts/x.sh arg",
    "bash -n ~/.claude/scripts/x.sh",
    "bash -n ~/.claude/scripts/*.sh",
    "sh ~/.claude/githooks/pre-push",
    "python3 ~/.claude/scripts/foo.py arg",
    "python3 -I ~/.claude/scripts/foo.py arg > /tmp/o",
    "source ~/.claude/scripts/x",
    ". ~/.claude/scripts/x",
    "shasum -a 256 -c /tmp/manifest",
    "shasum -a 256 ~/.claude/scripts/* | head",
    "grep -rn x ~/.claude/scripts",
    "rg foo ~/.claude/scripts",
    "cat ~/.claude/config/policies.json | jq .",
    "jq . ~/.claude/config/policies.json > /tmp/p.json",
    "cp ~/.claude/scripts/x /tmp/",
    "diff -r scripts ~/.claude/scripts",
    "shellcheck ~/.claude/scripts/*.sh",
    "plutil -p ~/.claude/config/x.plist",
    "plutil -lint ~/.claude/config/x.plist",
    "xxd ~/.claude/scripts/x | head",
    "strings ~/.claude/scripts/x",
    "wc -l ~/.claude/scripts/*",
    "stat -f %p ~/.claude/githooks/pre-commit",
    "file ~/.claude/scripts/x",
    "test -x ~/.claude/githooks/pre-commit",
    "[ -f ~/.claude/scripts/x ]",
    "echo ~/.claude/scripts/x",
    "printf '%s\\n' ~/.claude/scripts/x",
    "realpath ~/.claude/scripts/x",
    "readlink ~/.claude/githooks",
    "du -sh ~/.claude/scripts",
    "tree ~/.claude/scripts",
    "git diff --no-index scripts ~/.claude/scripts",
    "git -C ~/.claude/scripts status",
    "git log -- ~/.claude/scripts/x",
    "git commit -m 'mention ~/.claude/scripts/x'",
    "git config core.hooksPath ~/.claude/githooks",
    "find ~/.claude/scripts -name x",
    "rsync -a ~/.claude/scripts/ /tmp/s/",
    "ditto ~/.claude/scripts /tmp/s",
    "tar -cf /tmp/a.tar ~/.claude/scripts",
    "tar -czf /tmp/scripts.tgz -C ~/.claude scripts",
    "awk '{print}' ~/.claude/scripts/x",
    "sed -n p ~/.claude/scripts/x",
    "cd ~/.claude/scripts && ls *",
    "cd ~/.claude/scripts && grep foo *.sh",
    "cd ~/.claude/scripts && shasum *",
    "cd ~/.claude/scripts && cat x > /tmp/y",
    "cd ~/.claude/scripts && bash x.sh",
    # same verbs against OTHER parts of ~/.claude / the home stay usable
    "cp -R ~/Projects/x /tmp/y",
    "cp x ~/.claude/logs/",
    "cp -R /tmp/a ~/.claude/logs/",
    "cp -R /tmp/a ~/.claude/agents",
    "mv /tmp/a ~/.claude/reports/",
    "rsync -a /tmp/a/ ~/.claude/agents/",
    "chmod -R u+w ~/.claude/agents",
    "find ~/.claude/logs -name x -delete",
    "tar -xf a.tar -C ~/.claude/agents",
    "unzip a.zip -d ~/.claude/agents",
    "cp ~/Projects/x.txt ~/",
    "echo x > /System/Volumes/Data/tmp/y",
    "echo x > ~/.claude/[l]ogs/x",
    "echo x > ~/.claude/[a-f]gents/x",
    "somenewtool --flag /tmp/x",
]


# --- security round 2 ---------------------------------------------------------------------
# H-A: allowlisted readers that WRITE through an operand; H-B: protected paths hidden in
# environment-assignment values; M-C: command-string options of readers.
SEC2_BLOCK = [
    # sort / uniq / xxd / sdiff / tree / less / yq / file: write slots of "readers"
    "sort -o ~/.claude/scripts/x in",
    "sort -o~/.claude/scripts/x in",
    "sort --output=~/.claude/scripts/x in",
    "sort --output ~/.claude/scripts/x in",
    "sort in -o ~/.claude/scripts/x",
    "sort -T ~/.claude/scripts in",
    "sort --temporary-directory=~/.claude/scripts in",
    "sort --compress-program='tee ~/.claude/scripts/x' in",
    "sort --compress-program 'tee ~/.claude/scripts/x' in",
    "uniq in ~/.claude/scripts/x",
    "uniq -c in ~/.claude/scripts/x",
    "uniq -c -f 1 in ~/.claude/scripts/x",
    "xxd in ~/.claude/scripts/x",
    "xxd -r in ~/.claude/scripts/x",
    "xxd -r -p in ~/.claude/scripts/x",
    "xxd -ps in ~/.claude/scripts/x",
    "sdiff -o ~/.claude/scripts/x a b",
    "sdiff --output=~/.claude/scripts/x a b",
    "tree -o ~/.claude/scripts/x .",
    "less -o ~/.claude/scripts/x f",
    "less -O ~/.claude/scripts/x f",
    "less --log-file=~/.claude/scripts/x f",
    "less --LOG-FILE ~/.claude/scripts/x f",
    "more -o ~/.claude/scripts/x f",
    "yq -i . ~/.claude/config/x.yaml",
    "yq e -i '.a=1' ~/.claude/config/x.yaml",
    "yq --inplace . ~/.claude/config/x.yaml",
    "yq -s foo ~/.claude/config/x.yaml",
    "file -C -m ~/.claude/scripts/magic",
    "file --compile -m ~/.claude/scripts/magic",
    "sed -n 'w @H@/.claude/scripts/y' in",
    "awk '{print > \"@H@/.claude/scripts/y\"}' in",
    # M-C: command-string options
    "rg --pre 'tee ~/.claude/scripts/x' foo .",
    "rg --pre='tee ~/.claude/scripts/x' foo .",
    "rg --hostname-bin 'tee ~/.claude/scripts/x' foo .",
    "ag --pager 'tee ~/.claude/scripts/x' foo",
    "ack --pager='tee ~/.claude/scripts/x' foo",
    # H-B: environment assignments
    "CAST_REPO_ROOT=~/.claude/scripts bash ~/.claude/scripts/gen-plugin.sh",
    "export CAST_REPO_ROOT=~/.claude/scripts; bash x.sh",
    "env CAST_REPO_ROOT=~/.claude/scripts bash x.sh",
    "env -i TMPDIR=~/.claude/scripts sort in",
    "sudo CAST_REPO_ROOT=~/.claude/scripts bash x.sh",
    "LESSHISTFILE=~/.claude/scripts/h less a",
    "TMPDIR=~/.claude/scripts sort in",
    "PYTHONPYCACHEPREFIX=~/.claude/scripts python3 foo.py",
    "FOO=~/.claude/scripts cp a b",
    "FOO=~/.claude/scripts/x unknowntool",
    "export D=~/.claude/scripts",
    "declare -x D=~/.claude/scripts",
    "typeset -x D=~/.claude/githooks",
    "D=~/.claude/scripts; export D",
    "D=~/.claude/scripts; declare -x D",
    "set -a; D=~/.claude/scripts",
    "set -o allexport; D=~/.claude/config",
    "CAST_REPO_ROOT=~/.claude bash x.sh",
    "TMPDIR=~ sort in",
    "XDG_CACHE_HOME=~/.claude python3 x.py",
    "HOME=~/.claude/scripts bash x.sh",
    "TMPDIR=/System/Volumes/Data@H@/.claude/scripts sort in",
    # python's bytecode cache prefix is a write slot
    "python3 -X pycache_prefix=~/.claude/scripts foo.py",
    "python3 -Xpycache_prefix=~/.claude/scripts foo.py",
]

SEC2_ALLOW = [
    "sort in", "sort -o /tmp/o in", "sort ~/.claude/scripts/x",
    "sort -u ~/.claude/config/a ~/.claude/config/b > /tmp/o",
    "sort -T /tmp ~/.claude/scripts/x",
    "uniq -c ~/.claude/scripts/x", "uniq ~/.claude/logs/x", "uniq -c in /tmp/out",
    "xxd ~/.claude/scripts/x", "xxd -r in /tmp/out", "xxd -r -p ~/.claude/scripts/x | head",
    "tree ~/.claude/scripts", "tree -L 2 ~/.claude/githooks", "tree -o /tmp/t ~/.claude/scripts",
    "file ~/.claude/scripts/x", "file -b ~/.claude/githooks/pre-commit",
    "rg foo ~/.claude/scripts", "rg --pre cat foo ~/.claude/scripts",
    "rg -n --glob '*.sh' x ~/.claude/scripts",
    "sdiff ~/.claude/scripts/a /tmp/b", "sdiff -o /tmp/o ~/.claude/scripts/a /tmp/b",
    "sed -n p ~/.claude/scripts/x", "awk '{print $1}' ~/.claude/scripts/x",
    "awk -F: '{print $1}' ~/.claude/scripts/x > /tmp/o",
    "sed -n 'w /tmp/y' ~/.claude/scripts/x",
    # environment assignments that are NOT a protected value, or are read-only contexts
    "env FOO=1 cat ~/.claude/scripts/x",
    "FOO=~/.claude/scripts cat x",
    "LANG=C sort ~/.claude/scripts/x",
    "CAST_RM_OK=1 echo x",
    "PATH=~/.claude/scripts:$PATH echo x",
    'PATH="$HOME/.claude/scripts:$PATH" python3 foo.py',
    "export PATH=~/.claude/scripts:$PATH",
    "TMPDIR=/tmp sort in",
    "export FOO=bar", "export D=~/Projects", "declare -a arr", "declare D=~/.claude/scripts",
    "D=~/.claude/scripts; cat \"$D/x\"",
    "CAST_X=1 bash ~/.claude/scripts/x.sh",
    "TMPDIR=/tmp python3 -X dev ~/.claude/scripts/foo.py",
    "python3 -X utf8 ~/.claude/scripts/foo.py",
    # pinned residuals (documented): ~/.claude is not a git repo, and git's exec keys belong
    # to the git guard
    "cd ~/.claude/scripts && git add -A",
    "cd ~/.claude/scripts && git status --short",
    "git -c core.pager='tee ~/.claude/scripts/x' log",
]


class TestSecurityRound2(_Base):
    def test_block(self):
        for cmd in SEC2_BLOCK:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, True)

    def test_allow(self):
        for cmd in SEC2_ALLOW:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, False)

    def test_hatch_exempts(self):
        for cmd in ("sort -o ~/.claude/scripts/x in", "CAST_REPO_ROOT=~/.claude/scripts bash x.sh",
                    "rg --pre 'tee ~/.claude/scripts/x' foo ."):
            with self.subTest(cmd=cmd):
                self.check(f"{HATCH}=1 {cmd}", False)

    def test_every_allowlisted_reader_has_a_spec(self):
        """Structural: the allowlist is a spec table of STRICT readers. Every entry is either
        `nowrite` (audited: no option can write) or declares its COMPLETE option table."""
        table = self.cg._PW_READERS
        self.assertIsInstance(table, dict)
        self.assertGreater(len(table), 40)
        keys = {"nowrite", "envsafe", "short", "long", "exact", "last", "text", "danger", "dpos"}
        for name, spec in table.items():
            with self.subTest(command=name):
                self.assertEqual(set(spec), keys)
                if spec["nowrite"]:
                    self.assertTrue(spec["envsafe"])
                    self.assertFalse(spec["short"] or spec["long"] or spec["danger"])
                else:
                    self.assertTrue(spec["short"] or spec["exact"])
                    for arity in list(spec["short"].values()) + list(spec["long"].values()):
                        self.assertIn(arity, "NAWCO")
        strict = sorted(n for n, s in table.items() if not s["nowrite"])
        self.assertEqual(strict, ["ag", "awk", "bat", "file", "less", "more", "rg", "sdiff", "sed",
                                  "sort", "tree", "uniq", "xxd", "yq"])
        t = table
        self.assertEqual(t["sort"]["short"]["-o"], "W")
        self.assertEqual(t["sort"]["short"]["-T"], "W")
        self.assertEqual(t["sort"]["short"]["-z"], "N")  # -z takes NO value (round-3 finding 2)
        self.assertEqual(t["sort"]["long"]["--output"], "W")
        self.assertEqual(t["sort"]["long"]["--compress-program"], "C")
        self.assertTrue(t["uniq"]["last"] and t["xxd"]["last"])
        self.assertEqual(t["xxd"]["exact"]["-ps"], "N")
        self.assertEqual(t["xxd"]["short"]["-l"], "A")
        self.assertEqual(t["sdiff"]["long"]["--diff-program"], "C")
        self.assertEqual(t["tree"]["short"]["-o"], "W")
        self.assertEqual(t["rg"]["long"]["--pre"], "C")
        self.assertIn("-C", t["file"]["danger"])
        # fail closed: commands that cannot be characterised are NOT allowlisted
        for gone in ("mdls", "lsof", "most", "colordiff", "xargs", "ll", "la", "ack", "ssed",
                     "gawk", "mawk"):
            self.assertNotIn(gone, table)
        # round 4: string-carrying builtins are NOT pure readers; less/more/bat/yq/ag are tabled
        for carrier in ("echo", "printf", "alias", "set", "declare", "typeset", "local", "readonly",
                        "read", "export", "hash", "for", "select", "case", "in", "unset", "shift"):
            self.assertNotIn(carrier, table)
            self.assertIn(carrier, self.cg._PW_STRBUILTINS)
        self.assertEqual(t["less"]["short"]["-o"], "W")
        self.assertEqual(t["less"]["short"]["-O"], "W")
        self.assertEqual(t["less"]["long"]["--log-file"], "W")
        self.assertEqual(t["less"]["long"]["--LOG-FILE"], "W")
        self.assertEqual(t["more"], t["less"])
        self.assertEqual(t["bat"]["long"]["--pager"], "C")
        self.assertIn("cache", t["bat"]["dpos"])
        self.assertEqual(t["ag"]["long"]["--pager"], "C")
        self.assertIn("-i", t["yq"]["danger"])
        self.assertIn("-s", t["yq"]["danger"])
        for n_ in ("uniq", "xxd", "tree", "rg", "file", "sed", "awk", "bat", "ag"):
            self.assertTrue(t[n_]["envsafe"], n_)
        for n_ in ("sort", "sdiff", "less", "more", "yq"):
            self.assertFalse(t[n_]["envsafe"], n_)

    def test_long_options_resolve_by_unique_prefix(self):
        sort = self.cg._PW_READERS["sort"]
        parse = self.cg._pw_strict_parse
        for flag in ("--output", "--outpu", "--outp", "--out", "--ou", "--o"):
            with self.subTest(flag=flag):
                self.assertEqual(parse(sort, [flag, "P", "in"])[1], [("W", "P")])
                self.assertEqual(parse(sort, [flag + "=P", "in"])[1], [("W", "P")])
        self.assertEqual(parse(sort, ["--temp", "D"])[1], [("W", "D")])
        self.assertEqual(parse(sort, ["--comp", "cmd"])[1], [("C", "cmd")])
        self.assertIsNone(parse(sort, ["--s", "x"]))          # ambiguous: --sort --stable
        self.assertIsNone(parse(sort, ["--frobnicate"]))      # unknown
        self.assertIsNone(parse(sort, ["--merge=1"]))         # wrong arity
        self.assertIsNone(parse(sort, ["-j"]))                # unknown short
        self.assertEqual(parse(sort, ["-zo", "P"])[1], [("W", "P")])
        self.assertEqual(parse(sort, ["-zoP"])[1], [("W", "P")])
        self.assertEqual(parse(sort, ["-zr", "in"])[0], ["in"])


class TestRealShellConfirmation2(_Base):
    """The round-2 spellings really write into a root: confirmed in a real /bin/bash."""

    def _real(self, cmd, rel, soft=False, shell="/bin/bash"):
        Path(self.work, "in").write_text("b\na\nb\n")
        Path(self.work, "hex").write_text("41")
        Path(self.work, "a").write_text("A")
        Path(self.work, "gen.sh").write_text('echo hi > "$CAST_REPO_ROOT/gen-out"\n')
        target = os.path.join(self.home, ".claude", *rel)
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        subprocess.run([shell, "-c", cmd], cwd=self.work, env=env, capture_output=True,
                       timeout=30)
        if not os.path.exists(target):
            if soft:
                self.skipTest(f"this host's tool did not write ({cmd!r})")
            self.fail(f"premise: the real shell did not write {target}: {cmd!r}")
        self.check(cmd, True, "(real write confirmed)")

    def test_sort_output_forms(self):
        self._real("sort -o ~/.claude/scripts/s1 in", ("scripts", "s1"))
        self._real("sort in -o ~/.claude/scripts/s3", ("scripts", "s3"))
        self._real("sort --output ~/.claude/scripts/s4 in", ("scripts", "s4"))

    def test_uniq_output_operand(self):
        self._real("uniq in ~/.claude/scripts/u1", ("scripts", "u1"))
        self._real("uniq -c in ~/.claude/scripts/u2", ("scripts", "u2"))

    def test_xxd_output_operand(self):
        if not os.path.exists("/usr/bin/xxd"):
            self.skipTest("no xxd")
        self._real("xxd in ~/.claude/scripts/x1", ("scripts", "x1"))
        self._real("xxd -r -p hex ~/.claude/scripts/x2", ("scripts", "x2"))

    def test_tree_and_sdiff_output(self):
        if os.path.exists("/usr/bin/tree") or os.path.exists("/opt/homebrew/bin/tree"):
            self._real("tree -o ~/.claude/scripts/t1 .", ("scripts", "t1"), soft=True)
        self._real("sdiff -o ~/.claude/scripts/d1 in in", ("scripts", "d1"), soft=True)

    def test_environment_assignment_reaches_a_script(self):
        self._real("CAST_REPO_ROOT=~/.claude/scripts bash gen.sh", ("scripts", "gen-out"))

    def test_export_reaches_a_script(self):
        self._real("export CAST_REPO_ROOT=~/.claude/scripts; bash gen.sh",
                   ("scripts", "gen-out"))

    def test_env_wrapper_assignment_reaches_a_script(self):
        self._real("env CAST_REPO_ROOT=~/.claude/scripts bash gen.sh", ("scripts", "gen-out"))

    def test_export_by_name_reaches_a_script(self):
        self._real("D=~/.claude/scripts; export D; CAST_REPO_ROOT=$D bash gen.sh",
                   ("scripts", "gen-out"))


# --- security round 3: strict readers, mention scan, ancestor values, git selectors, exports ------
SEC3_BLOCK = [
    # (1) GNU unique-prefix abbreviations of write options (1,2: the arity of -z too)
    "sort --outp ~/.claude/scripts/x in",
    "sort --out ~/.claude/scripts/x in",
    "sort --o ~/.claude/scripts/x in",
    "sort --out=$HOME/.claude/scripts/x in",
    "sort --outpu=$HOME/.claude/scripts/x in",
    "sort --temp ~/.claude/scripts in",
    "sort --temporary ~/.claude/scripts in",
    "sort --tempor=$HOME/.claude/scripts in",
    "sort --comp 'tee ~/.claude/scripts/x' in",
    "sdiff --out ~/.claude/scripts/x a b",
    "sdiff --diff 'tee ~/.claude/scripts/x' a b",
    "uniq --skip-f 1 in ~/.claude/scripts/x",
    "sort --frobnicate -o ~/.claude/scripts/x in",
    "sort --s ~/.claude/scripts/x in",
    "sort -zo ~/.claude/scripts/x in",
    "sort -znro ~/.claude/scripts/x in",
    "sort -zo~/.claude/scripts/x in",
    "sort -rz -T ~/.claude/scripts in",
    "uniq -c -d in ~/.claude/scripts/x",
    "rg --pr 'tee ~/.claude/scripts/x' foo .",
    "rg --pre-g '*.x' --pre 'tee ~/.claude/scripts/x' foo .",
    "rg --bogus --pre 'tee ~/.claude/scripts/x' foo",
    # commands that are not (or no longer) readers
    "ack foo ~/.claude/scripts",
    "mdls -plist ~/.claude/scripts/x f",
    "lsof ~/.claude/scripts/x",
    # (3) command-string environment variables are SCRIPTS
    "PS4='$(cp a ~/.claude/scripts/x)' bash -xc true",
    "env PS4='$(cp a ~/.claude/scripts/x)' bash -xc true",
    "GIT_EXTERNAL_DIFF=\"cp ../a ~/.claude/scripts/x;:\" git -C r diff",
    "LESSOPEN=\"|cp a ~/.claude/scripts/x; cat %s\" less in",
    "LESSCLOSE='cp a ~/.claude/scripts/x' less in",
    "PAGER='tee ~/.claude/scripts/x' git log",
    "MANPAGER='cp a ~/.claude/scripts/x' man ls",
    "EDITOR='cp a ~/.claude/scripts/x' git commit",
    "VISUAL='cp a ~/.claude/scripts/x' git commit",
    "GIT_PAGER='tee ~/.claude/scripts/x' git log",
    "GIT_SSH_COMMAND='cp a ~/.claude/scripts/x' git fetch",
    "GIT_ASKPASS='cp a ~/.claude/scripts/x' git fetch",
    "PROMPT_COMMAND='cp a ~/.claude/scripts/x' bash -i",
    "MY_COMMAND='cp a ~/.claude/scripts/x' mytool",
    "MY_CMD='cp a ~/.claude/scripts/x' mytool",
    "export PAGER='tee ~/.claude/scripts/x'",
    "PAGER='tee ~/.claude/scripts/x'; echo done",
    "FOO='x ~/.claude/scripts/y' mytool",
    "FOO=\"a:$HOME/.claude/scripts\" mytool",
    # (4) git repository / work-tree selectors
    "GIT_WORK_TREE=~/.claude git checkout-index -f -- scripts/x",
    "git --work-tree ~/.claude checkout-index -f -- scripts/x",
    "git --work-tree=$HOME/.claude checkout-index -f -- scripts/x",
    "git -C ~/.claude checkout-index -f -- scripts/x",
    "git -C ~ checkout-index -f -- .claude/scripts/x",
    "git -C / checkout-index -f -- Users/x",
    "git --git-dir ~/.claude/scripts/.git add -A",
    "git --git-dir=$HOME/.claude/scripts/.git commit -m x",
    "GIT_DIR=~/.claude/scripts/.git git add -A",
    "git --work-tree ~/.claude reset --hard",
    "git --work-tree ~/.claude restore scripts/x",
    # (5) export tracking in any order / form
    "declare CAST_REPO_ROOT=~/.claude/scripts; export CAST_REPO_ROOT",
    "readonly X=~/.claude/scripts; export X",
    "printf -v X %s ~/.claude/scripts; export X",
    "export X; X=~/.claude/scripts",
    "typeset X=~/.claude/scripts; typeset -x X",
    "declare -x X; X=~/.claude/scripts",
    "local X=~/.claude/scripts; export X",
    "X=; X+=~/.claude/scripts; export X",
    "export X=a; X=~/.claude/scripts",
    "set -a; declare X=~/.claude/scripts",
    "env -S\"X=~/.claude/scripts bash gen.sh\"",
    "env -S'X=~/.claude/scripts bash gen.sh'",
    "env -S 'X=~/.claude/scripts bash gen.sh'",
    "env --split-string='X=~/.claude/scripts bash gen.sh'",
    # (6) sed / awk program text
    "sed -n \"w$HOME/.claude/scripts/y\" in",
    "sed \"s/a/b/;w$HOME/.claude/scripts/y\" in",
    "sed -n 'w@H@/.claude/scripts/y' in",
    "awk '{print>\"@H@/.claude/scripts/y\"}' in",
    "awk 'BEGIN{system(\"cp a @H@/.claude/scripts/y\")}'",
    # interpreter code strings are mentions too (the old residual is closed)
    "python3 -c \"open('@H@/.claude/scripts/x','w').write('x')\"",
    "perl -e 'open(F,\">@H@/.claude/scripts/x\")'",
    "node -e \"require('fs').writeFileSync('@H@/.claude/scripts/x','x')\"",
    # (7) ancestor values in ANY variable name
    "PYTHONUSERBASE=~/.claude python3 x.py",
    "PIP_TARGET=~/.claude pip install x",
    "TARGET=~/.claude mytool", "DEST=~/.claude mytool", "BASE=~/.claude mytool",
    "GOBIN=~/.claude go install x",
    "FOO=~ mytool", "FOO=/ mytool", "FOO=$HOME mytool",
]

SEC3_ALLOW = [
    # (8) xxd value options are declared
    "xxd -l 64 ~/.claude/scripts/x", "xxd -s 10 -l 64 ~/.claude/scripts/x",
    "xxd -c 8 ~/.claude/scripts/x", "xxd -ps ~/.claude/scripts/x",
    "xxd -cols 8 ~/.claude/scripts/x", "xxd -r -p ~/.claude/scripts/x",
    # complete tables accept their legitimate read forms
    "sort -zr ~/.claude/scripts/x", "sort -k2,2 -t: ~/.claude/scripts/x",
    "sort --reverse ~/.claude/scripts/x", "sort --key=2 ~/.claude/scripts/x",
    "sort --ignore-case --unique ~/.claude/scripts/x",
    "uniq --count ~/.claude/scripts/x", "uniq -c -f 1 ~/.claude/scripts/x",
    "tree -L 2 -a ~/.claude/scripts", "tree --gitignore ~/.claude/scripts",
    "rg --no-ignore -n foo ~/.claude/scripts", "rg -g '*.sh' foo ~/.claude/scripts",
    "rg --type sh foo ~/.claude/scripts", "rg -A 2 -B 1 foo ~/.claude/scripts",
    "file -b ~/.claude/scripts/x", "file --mime-type ~/.claude/scripts/x",
    "sed -n '1,5p' ~/.claude/scripts/x", "sed -E 's/a/b/' ~/.claude/scripts/x",
    "awk -F: '{print $1}' ~/.claude/scripts/x", "awk -v x=1 '{print}' ~/.claude/scripts/x",
    "sdiff -s ~/.claude/scripts/a /tmp/b",
    # (9) pure readers are exempt from selection variables
    "FOO=~/.claude cat x", "CAST_SCRIPTS_DIR=~/.claude/scripts ls", "FOO=~ ls",
    "PATH=~/.claude/scripts:$PATH mytool", "TMPDIR=/tmp sort in", "LESS=-R cat x",
    "PAGER=less git log", "GIT_PAGER=cat git log", "EDITOR=vim git commit",
    # git: pure-read subcommands may point anywhere
    "git -C ~/.claude status", "git --work-tree ~/.claude diff",
    "GIT_WORK_TREE=~/.claude git status", "git --git-dir ~/.claude/scripts/.git log",
    "git -C / log", "git -C ~ status --short", "git -C ~ show HEAD",
    # variables that are never exported stay private
    "D=~/.claude/scripts; ls \"$D\"", "declare D=~/.claude/scripts; cat $D/x",
    "readonly D=~/.claude/scripts; cat $D/x", "printf -v D %s ~/.claude/scripts; cat $D/x",
    "local D=~; ls $D",
    # a mention inside pure data
    "echo 'see ~/.claude/scripts/x'", "git commit -m 'update ~/.claude/scripts/x docs'",
    "grep -rn '~/.claude/scripts' docs", "printf '%s\\n' \"$HOME/.claude/scripts\"",
    # residual pins: heredoc into a non-shell interpreter is still inert text
    "python3 <<EOF\nopen('@H@/.claude/scripts/x','w')\nEOF",
]


class TestSecurityRound3(_Base):
    def test_block(self):
        for cmd in SEC3_BLOCK:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, True)

    def test_allow(self):
        for cmd in SEC3_ALLOW:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, False)

    def test_hatch_exempts(self):
        for cmd in ("sort --outp ~/.claude/scripts/x in",
                    "PS4='$(cp a ~/.claude/scripts/x)' bash -xc true",
                    "git --work-tree ~/.claude checkout-index -f -- scripts/x",
                    "export X=~/.claude/scripts"):
            with self.subTest(cmd=cmd):
                self.check(f"{HATCH}=1 {cmd}", False)


class TestRealShellConfirmation3(_Base):
    """The round-3 spellings really write into a root, confirmed in a real /bin/bash."""

    _real = TestRealShellConfirmation2._real

    def test_abbreviated_and_clustered_sort_options(self):
        self._real("sort --outp ~/.claude/scripts/a1 in", ("scripts", "a1"))
        self._real("sort --out=$HOME/.claude/scripts/a2 in", ("scripts", "a2"))
        self._real("sort -zo ~/.claude/scripts/a3 in", ("scripts", "a3"))

    def test_command_string_env_var(self):
        self._real("PS4='$(cp a ~/.claude/scripts/ps4)' bash -xc true", ("scripts", "ps4"))

    def test_git_work_tree_selector(self):
        git = shutil.which("git")
        if not git:
            self.skipTest("no git")
        repo = os.path.join(self.work, "r")
        env = {"HOME": self.tmp, "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        run = lambda *a: subprocess.run([git, *a], cwd=self.work, env=env, capture_output=True)
        run("init", "-q", repo)
        os.makedirs(os.path.join(repo, "scripts"))
        Path(repo, "scripts", "gw").write_text("from-git")
        subprocess.run([git, "-C", repo, "add", "-A"], env=env, capture_output=True)
        subprocess.run([git, "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t",
                        "commit", "-q", "-m", "m"], env=env, capture_output=True)
        self._real(f"git --git-dir={repo}/.git --work-tree=$HOME/.claude checkout-index -f -- "
                   "scripts/gw", ("scripts", "gw"))

    def test_export_in_any_order_or_form(self):
        self._real("declare CAST_REPO_ROOT=~/.claude/scripts; export CAST_REPO_ROOT; bash gen.sh",
                   ("scripts", "gen-out"))
        self._real("export CAST_REPO_ROOT; CAST_REPO_ROOT=~/.claude/scripts; bash gen.sh",
                   ("scripts", "gen-out"))
        self._real("readonly CAST_REPO_ROOT=~/.claude/scripts; export CAST_REPO_ROOT; bash gen.sh",
                   ("scripts", "gen-out"))
        self._real("printf -v CAST_REPO_ROOT %s ~/.claude/scripts; export CAST_REPO_ROOT; "
                   "bash gen.sh", ("scripts", "gen-out"))

    def test_env_split_string_attached(self):
        self._real('env -S"CAST_REPO_ROOT=$HOME/.claude/scripts bash gen.sh"',
                   ("scripts", "gen-out"))

    def test_sed_write_command_without_space(self):
        self._real('sed -n "w$HOME/.claude/scripts/sw" in', ("scripts", "sw"), soft=True)


# --- security round 4: string-carrying builtins, substitutions in values, tables, new roots -----
SEC4_BLOCK = [
    # H1: string-carrying builtins are not pure readers
    "shopt -s expand_aliases; alias w='cp a ~/.claude/scripts/x'; eval w",
    "shopt -s expand_aliases\nalias w='cp a ~/.claude/scripts/x'\nw",
    "alias w='cp a ~/.claude/scripts/x'",
    "set -- cp a ~/.claude/scripts/x; \"$@\"",
    "set -- cp a ~/.claude/scripts/x; $@",
    "set -- cp a ~/.claude/scripts/x; eval \"$*\"",
    "set -- cp a ~/.claude/scripts/x; bash -c \"$*\"",
    "X='cp a ~/.claude/scripts/x'; eval $X",
    "X='cp a ~/.claude/scripts/x'; $X",
    "X=\"cp a $HOME/.claude/scripts/x\"; $X",
    "X=\"cp a ~/.claude/scripts/x\"; bash -c \"$X\"",
    "declare X='cp a ~/.claude/scripts/x'; eval \"$X\"",
    "local X='cp a ~/.claude/scripts/x'; eval \"$X\"",
    "readonly X='cp a ~/.claude/scripts/x'; eval \"$X\"",
    "typeset X='cp a ~/.claude/scripts/x'; eval \"$X\"",
    "export X='cp a ~/.claude/scripts/x'; bash -c \"$X\"",
    "read X <<< 'cp a ~/.claude/scripts/x'; eval \"$X\"",
    "for c in 'cp a ~/.claude/scripts/x'; do eval \"$c\"; done",
    "for c in 'cp a ~/.claude/scripts/x'; do $c; done",
    "printf -v X 'cp a %s' ~/.claude/scripts/x; eval \"$X\"",
    "case 'cp a ~/.claude/scripts/x' in x) :;; esac",
    "select c in 'cp a ~/.claude/scripts/x'; do break; done",
    # echo / printf are data -- unless the command also contains something that can RUN text
    "echo 'echo x > ~/.claude/scripts/y' | bash",
    "echo 'cp a ~/.claude/scripts/x' | sh",
    "printf 'cp a ~/.claude/scripts/x\\n' | zsh",
    "echo 'cp a ~/.claude/scripts/x' > /tmp/s.sh; bash /tmp/s.sh",
    "printf '%s\\n' 'tee ~/.claude/scripts/x' | python3",
    "echo 'cp a ~/.claude/scripts/x' | /bin/bash",
    # M2: substitutions inside assignment values, quoted globs, quote splices
    "CAST_REPO_ROOT=\"$(dirname ~/.claude/scripts/x)\" bash gen.sh",
    "CAST_REPO_ROOT=$(dirname ~/.claude/scripts/x) bash gen.sh",
    "CAST_REPO_ROOT=`dirname ~/.claude/scripts/x` bash gen.sh",
    "FOO=\"$(dirname ~/.claude/scripts/x)\" mytool",
    "export X=\"$(cd ~/.claude && pwd)\"",
    "X=\"$(echo ~/.claude/scripts)\"; export X",
    "mytool 'cp a ~/.claude/s*/x'",
    "mytool 'cp a ~/.cl*/scripts/x'",
    "mytool 'cp a ~/.claude/[s]cripts/x'",
    "FOO='cp a ~/.claude/s*/x' mytool",
    "mytool 'cp a ~/.claude/s'\"'\"'cripts/x'",
    "mytool \"cp a ~/.claude/sc\"'rip'\"ts/x\"",
    "FOO='x;y=~/.claude/s'\"'\"'cripts' mytool",
    "FOO='x;y=~/.claude/sc'\"'\"'ripts' mytool",
    # M3: tabled readers still block their write slots / command strings
    "bat cache --build --target ~/.claude/config",
    "bat --pager 'tee ~/.claude/scripts/x' f",
    "ag --pager 'tee ~/.claude/scripts/x' foo",
    "less --log-file ~/.claude/scripts/x f",
    "less --LOG-FILE=$HOME/.claude/scripts/x f",
    "less +'s ~/.claude/scripts/x' f",
    "less '+|tee ~/.claude/scripts/x' f",
    "yq -i . ~/.claude/config/x",
    "LESSHISTFILE=~/.claude/scripts/h less f",
    # ROOTS: macOS python cache, user site-packages, LaunchAgents
    "echo x > ~/Library/LaunchAgents/com.evil.plist",
    "cp a ~/Library/LaunchAgents/x.plist",
    "mv /tmp/x.plist ~/Library/LaunchAgents/",
    "rm ~/Library/LaunchAgents/x.plist",
    "mv ~/Library/LaunchAgents /tmp/la",
    "ln -s /tmp/x ~/Library/LaunchAgents/x.plist",
    "chmod 777 ~/Library/LaunchAgents/x",
    "touch ~/Library/LaunchAgents/x",
    "tee ~/Library/LaunchAgents/x.plist < /dev/null",
    "defaults write ~/Library/LaunchAgents/x RunAtLoad -bool true",
    "plutil -replace Label -string x ~/Library/LaunchAgents/x.plist",
    "sed -i '' s/a/b/ ~/Library/LaunchAgents/x.plist",
    "cp x ~/Library/Python/3.9/lib/python/site-packages/sitecustomize.py",
    "echo x > ~/Library/Python/3.9/lib/python/site-packages/usercustomize.py",
    "echo x > ~/Library/Caches/com.apple.python/x.pyc",
    "rm ~/Library/Caches/com.apple.python/x.pyc",
    "cp -R src/. ~/Library/",
    "cp -R /tmp/evil/LaunchAgents ~/Library/",
    "tar -xf a.tar -C ~/Library/Caches",
    "tar -xf a.tar -C ~/Library",
    "mv /tmp/evil/Python ~/Library/",
    "echo x > $HOME/Library/LaunchAgents/x",
    "echo x > ~/LIBRARY/launchagents/x",
    "echo x > ~/Library/LaunchAgents/../LaunchAgents/x",
    "echo x > ~/Library/Launch[A]gents/x",
    "echo x > /System/Volumes/Data@H@/Library/LaunchAgents/x",
    "cd ~/Library/LaunchAgents && rm -f *",
    "export X=~/Library/Python",
    "FOO=~/Library/LaunchAgents mytool",
    "sort -o ~/Library/LaunchAgents/x in",
    # ~/.claude/cast-state: pyc-verification snapshot + hook state
    "echo x > ~/.claude/cast-state/pyc-snapshot.json",
    "echo x >> ~/.claude/cast-state/state",
    "cp a ~/.claude/cast-state/",
    "cp a ~/.claude/cast-state/pyc.sha256",
    "mv /tmp/x ~/.claude/cast-state/y",
    "mv ~/.claude/cast-state /tmp/cs",
    "rm ~/.claude/cast-state/pyc-snapshot.json",
    "rm -f ~/.claude/cast-state/*",
    "ln -sfn /tmp/x ~/.claude/cast-state",
    "touch ~/.claude/cast-state/x",
    "chmod 666 ~/.claude/cast-state/x",
    "tee ~/.claude/cast-state/x < /dev/null",
    "sed -i '' s/a/b/ ~/.claude/cast-state/x",
    "sort -o ~/.claude/cast-state/x in",
    "echo x > ~/.claude/cast-state/$NAME",
    "echo x > ~/.claude/cast-st[a]te/x",
    "echo x > ~/.CLAUDE/Cast-State/x",
    "echo x > /System/Volumes/Data@H@/.claude/cast-state/x",
    "cd ~/.claude/cast-state && echo x > snapshot",
    "export X=~/.claude/cast-state",
    "FOO=~/.claude/cast-state mytool",
    "tar -xf a.tar -C ~/.claude/cast-state",
    "python3 -c \"open('@H@/.claude/cast-state/x','w')\"",
]

SEC4_ALLOW = [
    # H1 fences: plain data, no sink, plain path operands
    "echo 'see ~/.claude/scripts/x'",
    "echo \"installed to $HOME/.claude/scripts\"",
    "printf '%s\\n' \"$HOME/.claude/scripts\"",
    "export D=~/Projects", "declare -a arr", "alias ll='ls -l'", "alias x=~/.claude/scripts/x.sh",
    "set -- a b c; echo \"$@\"", "X='hello world'; eval $X", "read X <<< 'hello'; echo $X",
    "case $X in a) echo hi;; esac", "printf -v X %s hello; echo $X",
    "for f in ~/.claude/scripts/*.sh; do cat \"$f\"; done",
    "echo done; bash ~/.claude/scripts/x.sh",
    # M3: plain reads of installed files work again
    "less ~/.claude/scripts/x", "less -N ~/.claude/scripts/x", "less -o /tmp/l ~/.claude/scripts/x",
    "more ~/.claude/scripts/x", "yq . ~/.claude/config/x.yaml",
    "yq e '.a' ~/.claude/config/x.yaml", "yq -o json . ~/.claude/config/x.yaml",
    "bat ~/.claude/scripts/x", "bat -n --paging=never ~/.claude/scripts/x",
    "bat --style=plain ~/.claude/scripts/x", "bat cache --build",
    "ag foo ~/.claude/scripts", "ag -i --depth 3 foo ~/.claude/scripts",
    "PYTHONPATH=~/.claude/scripts python3 -m json.tool in",
    "RIPGREP_CONFIG_PATH=~/.claude/config/rg rg foo .",
    "BAT_CONFIG_PATH=~/.claude/config/bat bat x",
    "CAST_X=~/.claude/scripts uniq -c f", "CAST_X=~/.claude/scripts tree .",
    # new roots: reads stay allowed
    "ls ~/Library/LaunchAgents", "ls -la ~/Library/LaunchAgents/",
    "plutil -p ~/Library/LaunchAgents/x.plist", "plutil -lint ~/Library/LaunchAgents/x.plist",
    "cat ~/Library/LaunchAgents/x.plist", "cp ~/Library/LaunchAgents/x.plist /tmp/",
    "grep -r Label ~/Library/LaunchAgents", "launchctl list", "ls ~/Library/Python",
    "ls ~/Library/Caches/com.apple.python", "diff -r ~/Library/LaunchAgents /tmp/la",
    "echo x > ~/Library/Logs/x.log", "cp a ~/Library/Preferences/x.plist",
    "rm ~/Library/Caches/other/x", "echo x > ~/Library/Caches/com.apple.other/x",
    "cp x ~/Library/Application\\ Support/y", "touch ~/Library/Logs/x",
    # cast-state: reads (cat / ls / jq / cmp / shasum) stay allowed like every other root
    "cat ~/.claude/cast-state/pyc-snapshot.json", "ls -la ~/.claude/cast-state",
    "jq . ~/.claude/cast-state/pyc-snapshot.json", "cp ~/.claude/cast-state/x /tmp/",
    "cmp /tmp/snap ~/.claude/cast-state/pyc-snapshot.json",
    "shasum -a 256 ~/.claude/cast-state/*", "grep -rn x ~/.claude/cast-state",
    "diff /tmp/a ~/.claude/cast-state/x", "cat ~/.claude/cast-state/x | jq .",
    "echo x > ~/.claude/cast-state-other/x", "echo x > ~/.claude/logs/cast-state",
]


class TestSecurityRound4(_Base):
    def test_block(self):
        for cmd in SEC4_BLOCK:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, True)

    def test_allow(self):
        for cmd in SEC4_ALLOW:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, False)

    def test_hatch_exempts(self):
        for cmd in ("alias w='cp a ~/.claude/scripts/x'",
                    "set -- cp a ~/.claude/scripts/x; \"$@\"",
                    "CAST_REPO_ROOT=\"$(dirname ~/.claude/scripts/x)\" bash gen.sh",
                    "echo 'cp a ~/.claude/scripts/x' | bash",
                    "cp a ~/Library/LaunchAgents/x.plist"):
            with self.subTest(cmd=cmd):
                self.check(f"{HATCH}=1 {cmd}", False)

    def test_new_roots_are_roots(self):
        ctx = self.cg._pw_context()
        h = self.home.lower()
        for rel in ("library/caches/com.apple.python", "library/python", "library/launchagents"):
            self.assertIn(f"{h}/{rel}", ctx.roots)
        self.assertIn(f"{h}/.claude/cast-state", ctx.roots)
        self.assertIn(f"{h}/library", ctx.far)
        self.assertIn(f"{h}/library/caches", ctx.far)


class TestRealShellConfirmation4(_Base):
    """The round-4 string-carrying spellings really write into a root (real /bin/bash)."""

    _real = TestRealShellConfirmation2._real

    def test_alias_and_eval(self):
        self._real("shopt -s expand_aliases; alias w='cp a ~/.claude/scripts/al'; eval w",
                   ("scripts", "al"))

    def test_positional_parameters(self):
        self._real("set -- cp a ~/.claude/scripts/sa; \"$@\"", ("scripts", "sa"))
        self._real("set -- cp a ~/.claude/scripts/sb; eval \"$*\"", ("scripts", "sb"))

    def test_variable_as_command_or_eval_or_payload(self):
        self._real("X='cp a ~/.claude/scripts/v1'; eval $X", ("scripts", "v1"))
        self._real("X=\"cp a $HOME/.claude/scripts/v2\"; $X", ("scripts", "v2"))
        self._real("X=\"cp a ~/.claude/scripts/v3\"; bash -c \"$X\"", ("scripts", "v3"))

    def test_declaration_forms(self):
        self._real("declare X='cp a ~/.claude/scripts/d1'; eval \"$X\"", ("scripts", "d1"))
        self._real("readonly X='cp a ~/.claude/scripts/d2'; eval \"$X\"", ("scripts", "d2"))

    def test_read_here_string_loop_and_printf(self):
        self._real("read X <<< 'cp a ~/.claude/scripts/r1'; eval \"$X\"", ("scripts", "r1"))
        self._real("for c in 'cp a ~/.claude/scripts/f1'; do eval \"$c\"; done",
                   ("scripts", "f1"))
        self._real("printf -v X 'cp a %s' ~/.claude/scripts/p1; eval \"$X\"", ("scripts", "p1"))

    def test_echo_into_a_shell(self):
        self._real("echo 'cp a ~/.claude/scripts/e1' | bash", ("scripts", "e1"))

    def test_substitution_inside_an_assignment_value(self):
        self._real('CAST_REPO_ROOT="$(dirname ~/.claude/scripts/x)" bash gen.sh',
                   ("scripts", "gen-out"))
        self._real("CAST_REPO_ROOT=`dirname ~/.claude/scripts/x` bash gen.sh",
                   ("scripts", "gen-out"))

    def test_cast_state_write(self):
        os.makedirs(os.path.join(self.home, ".claude", "cast-state"))
        self._real("cp a ~/.claude/cast-state/snap", ("cast-state", "snap"))
        self._real("echo x > ~/.claude/cast-state/snap2", ("cast-state", "snap2"))

    def test_new_root_write(self):
        os.makedirs(os.path.join(self.home, "Library", "LaunchAgents"))
        self._real("cp a ~/Library/LaunchAgents/r1.plist", ("..", "Library", "LaunchAgents",
                                                           "r1.plist"))


# --- security round 5 (final): the TEXT-RUNNER rule, joined echo operands, wider sinks --------------
SEC5_BLOCK = [
    # HIGH: stored text that something later EXECUTES, however it is spelled
    'X="cp a $HOME/.claude/scripts/x"; ${X:-}',
    'X="cp a $HOME/.claude/scripts/x"; command $X',
    'X="cp a $HOME/.claude/scripts/x"; env $X',
    'X="cp a $HOME/.claude/scripts/x"; nohup $X',
    'X="cp a $HOME/.claude/scripts/x"; timeout 5 $X',
    'X="cp a $HOME/.claude/scripts/x"; exec $X',
    'X="cp a $HOME/.claude/scripts/x"; time $X',
    'X="cp a $HOME/.claude/scripts/x"; nice $X',
    'X="cp a $HOME/.claude/scripts/x"; sudo $X',
    "X='cp a '; X+=$HOME/.claude/scripts/x; $X",
    'X="cp:a:$HOME/.claude/scripts/x"; IFS=:; $X',
    "X='cp${IFS}a${IFS}'\"$HOME/.claude/scripts/x\"; eval $X",
    'declare -A m; m[k]="cp a $HOME/.claude/scripts/x"; eval "${m[k]}"',
    'X="cp a $HOME/.claude/scripts/x"; $(echo $X)',
    "arr=('cp a ~/.claude/scripts/x'); eval \"${arr[0]}\"",
    "arr=('cp a ~/.claude/scripts/x'); eval \"${arr[*]}\"",
    "declare -a arr=('cp a ~/.claude/scripts/x'); eval \"${arr[0]}\"",
    "arr=(cp a ~/.claude/scripts/x); \"${arr[@]}\"",
    "read -a arr <<< 'cp a ~/.claude/scripts/x'; \"${arr[@]}\"",
    "set -- 'cp a ~/.claude/scripts/x'; $1",
    "X=$'cp a ~/.claude/scripts/x'; $X",
    "X=cp\\ a\\ ~/.claude/scripts/x; $X",
    "X=$(echo 'cp a ~/.claude/scripts/x'); eval $X",
    "export X='cp a ~/.claude/scripts/x'; sh -c \"$X\"",
    "typeset -r X='cp a ~/.claude/scripts/x'; eval \"$X\"",
    "for c in cp:a:~/.claude/scripts/x; do IFS=:; $c; done",
    "X='cp a ~/.cl*/scripts/x'; eval $X",
    "read X <<< cp:a:~/.claude/scripts/x; IFS=:; $X",
    "read -r X <<< cp:a:~/.claude/scripts/x; IFS=:; $X",
    # accepted false positives (pinned): a stored root + ANY executor of text
    "X=~/.claude/scripts/x.sh; source $X",
    "X=~/.claude/scripts/x.sh; . $X",
    "D=~/.claude/scripts; bash -c 'echo hi'",
    "D=~/.claude/scripts; sh -c 'true'",
    "X=~/.claude/scripts/x.sh; $X",
    'for f in ~/.claude/scripts/*.sh; do "$f"; done',
    # M1: echo / printf operands are JOINED before the mention check
    "echo cp a ~/.claude/scripts/x | sh",
    "printf 'cp a %s\\n' ~/.claude/scripts/x | sh",
    "printf '%s ' cp a ~/.claude/scripts/x | bash",
    "echo cp a ~/.claude/scripts/x > s.sh; bash s.sh",
    # M2: the wider sink list
    "echo '.shell cp a ~/.claude/scripts/x' | sqlite3 :memory:",
    "echo 'cp a ~/.claude/scripts/x' | awk -f /dev/stdin",
    "echo 'cp a ~/.claude/scripts/x' | ssh host",
    "echo 'cp a ~/.claude/scripts/x' | at now",
    "echo 'cp a ~/.claude/scripts/x' | batch",
    "echo 'cp a ~/.claude/scripts/x' | parallel",
    "echo 'cp a ~/.claude/scripts/x' | tclsh",
    "echo 'cp a ~/.claude/scripts/x' | expect",
    "echo 'cp a ~/.claude/scripts/x' | script -q /dev/null",
    "echo 'cp a ~/.claude/scripts/x' | crontab -",
    "echo 'cp a ~/.claude/scripts/x' > Makefile; make",
    # defaults / launchctl: the WRITING verbs still block
    "defaults write ~/Library/LaunchAgents/x k v",
    "defaults delete ~/Library/LaunchAgents/x k",
    "defaults export x ~/Library/LaunchAgents/y.plist",
]

SEC5_ALLOW = [
    # L1: defaults read / launchctl lifecycle verbs do not write the plist
    "defaults read ~/Library/LaunchAgents/x", "defaults read-type ~/Library/LaunchAgents/x k",
    "launchctl print gui/501/com.x", "launchctl list",
    "launchctl load ~/Library/LaunchAgents/x.plist",
    "launchctl load -w ~/Library/LaunchAgents/x.plist",
    "launchctl bootstrap gui/501 ~/Library/LaunchAgents/x.plist",
    "launchctl bootout gui/501 ~/Library/LaunchAgents/x.plist",
    "launchctl unload -w ~/Library/LaunchAgents/x.plist",
    "launchctl enable gui/501/x", "launchctl disable gui/501/x",
    "launchctl kickstart -k gui/501/x",
    # M3: accepted residual (pinned): package managers write ~/Library/Python without naming it
    "pip install --user requests", "python3 -m pip install --user requests",
    "pipx install black", "uv pip install ruff", "pip install requests",
    "/usr/bin/python3 -m pip install requests",
    # the text-runner rule needs BOTH halves
    "D=~/.claude/scripts; cat \"$D/x\"", "X=hello; $X", "X='ls'; $X ~/.claude/scripts",
    "export PATH=~/.claude/scripts:$PATH; python3 foo.py", "source ~/.claude/scripts/cast-events.sh",
    "eval \"$(cat /tmp/x)\"", "bash -c 'echo hi'; ls ~/.claude/scripts",
    "for f in ~/.claude/scripts/*.sh; do bash \"$f\"; done",
    "echo cp a /tmp/x | sh", "printf '%s\\n' hi | bash", "echo ~/.claude/scripts/x | sh",
    "echo 'see ~/.claude/scripts/x'; ls", "X='a b'; eval \"$X\"",
]


class TestSecurityRound5(_Base):
    def test_block(self):
        for cmd in SEC5_BLOCK:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, True)

    def test_allow(self):
        for cmd in SEC5_ALLOW:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, False)

    def test_hatch_exempts(self):
        for cmd in ('X="cp a $HOME/.claude/scripts/x"; ${X:-}',
                    "echo cp a ~/.claude/scripts/x | sh",
                    "defaults write ~/Library/LaunchAgents/x k v"):
            with self.subTest(cmd=cmd):
                self.check(f"{HATCH}=1 {cmd}", False)
        # the hatch is segment-scoped: it exempts ITS segment, not the text-runner elsewhere
        self.check(f"{HATCH}=1 true; X=\"cp a $HOME/.claude/scripts/x\"; $X", True)

    def test_both_halves_are_needed(self):
        runner, mention = self.cg._pw_tr_analyze('X="cp a $HOME/.claude/scripts/x"; $X',
                                                 self.cg._pw_context(), 0)
        self.assertTrue(runner and mention)
        runner, mention = self.cg._pw_tr_analyze('X=hello; $X', self.cg._pw_context(), 0)
        self.assertTrue(runner and not mention)
        runner, mention = self.cg._pw_tr_analyze('D=~/.claude/scripts; cat $D/x',
                                                 self.cg._pw_context(), 0)
        self.assertTrue(mention and not runner)


class TestRealShellConfirmation5(_Base):
    """The round-5 spellings really write into a root (real /bin/bash)."""

    _real = TestRealShellConfirmation2._real

    def test_dynamic_command_word_forms(self):
        for i, cmd in enumerate((
                'X="cp a $HOME/.claude/scripts/h1"; ${X:-}',
                'X="cp a $HOME/.claude/scripts/h1"; command $X',
                'X="cp a $HOME/.claude/scripts/h1"; env $X',
                'X="cp a $HOME/.claude/scripts/h1"; nohup $X',
                'X="cp a $HOME/.claude/scripts/h1"; timeout 5 $X',
                'X="cp a $HOME/.claude/scripts/h1"; $(echo $X)')):
            with self.subTest(cmd=cmd):
                target = os.path.join(self.home, ".claude", "scripts", "h1")
                if os.path.exists(target):
                    os.remove(target)
                self._real(cmd, ("scripts", "h1"))

    def test_plus_equals_ifs_and_eval_tricks(self):
        self._real("X='cp a '; X+=$HOME/.claude/scripts/h2; $X", ("scripts", "h2"))
        self._real('X="cp:a:$HOME/.claude/scripts/h3"; IFS=:; $X', ("scripts", "h3"))
        self._real("X='cp${IFS}a${IFS}'\"$HOME/.claude/scripts/h4\"; eval $X", ("scripts", "h4"))

    def test_array_elements(self):
        self._real("arr=('cp a ~/.claude/scripts/h6'); eval \"${arr[0]}\"", ("scripts", "h6"))
        self._real("arr=(cp a ~/.claude/scripts/h6b); \"${arr[@]}\"", ("scripts", "h6b"))

    def test_associative_array(self):
        for sh in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"):
            if os.path.exists(sh):
                out = subprocess.run([sh, "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True,
                                     text=True).stdout.strip()
                if out.isdigit() and int(out) >= 4:
                    self._real('declare -A m; m[k]="cp a $HOME/.claude/scripts/h5"; '
                               'eval "${m[k]}"', ("scripts", "h5"), shell=sh)
                    return
        self.skipTest("no bash >= 4 for associative arrays")

    def test_echo_and_printf_words_joined(self):
        self._real("echo cp a ~/.claude/scripts/h7 | sh", ("scripts", "h7"))
        self._real("printf 'cp a %s\\n' ~/.claude/scripts/h8 | sh", ("scripts", "h8"))
        self._real("echo cp a ~/.claude/scripts/h9 > s.sh; bash s.sh", ("scripts", "h9"))


class TestSecurityRound(_Base):
    def test_findings_block(self):
        for cmd in SEC_BLOCK:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, True)

    def test_fences_allow(self):
        for cmd in SEC_ALLOW:
            cmd = cmd.replace("@H@", self.home)
            with self.subTest(cmd=cmd):
                self.check(cmd, False)

    def test_hatch_still_exempts_the_new_shapes(self):
        for cmd in ("arch -arm64 cp a ~/.claude/scripts/x", "cp -R src/. ~/.claude/",
                    "bash -o errexit -c 'rm ~/.claude/scripts/x'", "mkfifo ~/.claude/scripts/f",
                    "bash <<< 'rm ~/.claude/scripts/x'"):
            with self.subTest(cmd=cmd):
                self.check(f"{HATCH}=1 {cmd}", False)

    def test_redirect_to_a_protected_path_blocks_even_for_allowlisted_readers(self):
        for cmd in ("cat x > ~/.claude/scripts/y", "ls > ~/.claude/githooks/y",
                    "echo hi >> ~/.claude/config/y", "jq . a > ~/.claude/config/y"):
            with self.subTest(cmd=cmd):
                self.check(cmd, True)

    def test_dynamic_word_in_an_unknown_command_with_protected_prefix_blocks(self):
        self.check("unknowntool ~/.claude/scripts/$X", True)
        self.check("unknowntool --out=~/.claude/scripts/$X", True)
        self.check("unknowntool $X", False)


class TestRealShellConfirmation(_Base):
    """Premise check: the spellings above are not theoretical. Run the command in a REAL
    /bin/bash against the scratch HOME and prove it really lands in the protected dir; then
    prove the guard blocks that same command string."""

    def _real(self, cmd, expect_path, setup=None, preexisting=False, shell="/bin/bash"):
        if not os.path.isdir("/bin"):
            self.skipTest("no /bin")
        os.makedirs(os.path.join(self.work, "src", "scripts"), exist_ok=True)
        Path(self.work, "a").write_text("A")
        Path(self.work, "src", "scripts", "evil").write_text("E")
        if setup:
            setup()
        target = os.path.join(self.home, ".claude", *expect_path)
        if preexisting:
            Path(target).write_text("old")  # a glob only matches what EXISTS
        else:
            self.assertFalse(os.path.exists(target), "premise: target must not pre-exist")
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        subprocess.run([shell, "-c", cmd], cwd=self.work, env=env,
                       capture_output=True, timeout=30)
        self.assertTrue(os.path.exists(target), f"real shell did not write {target}: {cmd!r}")
        if preexisting:
            self.assertNotEqual(Path(target).read_text(), "old", f"not overwritten: {cmd!r}")
        self.check(cmd, True, "(real write confirmed)")

    def test_bracket_class_glob(self):
        self._real("echo x > ~/.claude/[s]cripts/x", ("scripts", "x"), preexisting=True)
        self._real("echo x > ~/.claude/script[s]/y", ("scripts", "y"), preexisting=True)

    def test_cwd_glob_delete(self):
        p = os.path.join(self.home, ".claude", "scripts", "victim")
        Path(p).write_text("v")
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        cmd = "cd ~/.claude/scripts && rm -f *"
        self.check(cmd, True)
        subprocess.run(["/bin/bash", "-c", cmd], cwd=self.work, env=env, timeout=30)
        self.assertFalse(os.path.exists(p), "premise: the glob delete really removes the file")

    def test_bash_option_before_dash_c(self):
        self._real("bash -o errexit -c 'echo x > ~/.claude/scripts/y'", ("scripts", "y"))
        self._real("bash -c -- 'echo x > ~/.claude/githooks/y'", ("githooks", "y"))

    def test_here_string_to_shell(self):
        self._real("bash <<< 'echo x > ~/.claude/config/y'", ("config", "y"))

    def test_trap(self):
        self._real("trap 'echo x > ~/.claude/scripts/t' EXIT", ("scripts", "t"))

    def test_process_substitution_source(self):
        # bash 3.2 (macOS /bin/bash) cannot `source <(...)`: use a newer bash if there is one
        for sh in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash", "/bin/bash"):
            if os.path.exists(sh):
                out = subprocess.run([sh, "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True,
                                     text=True).stdout.strip()
                if out.isdigit() and int(out) >= 4:
                    self._real("source <(echo 'echo x > ~/.claude/scripts/p')", ("scripts", "p"),
                               shell=sh)
                    return
        self.skipTest("no bash >= 4 for process-substitution source")

    def test_merge_into_ancestor(self):
        self._real("cp -R src/. ~/.claude/", ("scripts", "evil"))

    def test_env_dash_s_wrapper(self):
        if not os.path.exists("/usr/bin/env"):
            self.skipTest("no env")
        probe = subprocess.run(["/usr/bin/env", "-S", "true"], capture_output=True)
        if probe.returncode != 0:
            self.skipTest("env -S unsupported")
        self._real('env -S "cp a $HOME/.claude/scripts/x"', ("scripts", "x"))

    def test_firmlink_spelling(self):
        if not os.path.isdir("/System/Volumes/Data"):
            self.skipTest("not an APFS firmlink host")
        fl = "/System/Volumes/Data" + self.home
        if not os.path.isdir(fl):
            self.skipTest("scratch home not reachable through the firmlink")
        self._real(f"echo x > {fl}/.claude/scripts/f", ("scripts", "f"))


class TestResolution(_Base):
    def test_real_user_home_is_protected_even_when_home_is_overridden(self):
        real = pwd.getpwuid(os.getuid()).pw_dir
        self.assertNotEqual(os.path.realpath(real), self.home)
        self.check(f"echo x > {real}/.claude/githooks/pre-commit", True)
        self.check(f"mv {real}/.claude/githooks /tmp/x", True)
        self.check(f"echo x > {real}/.claude/logs/x", False)

    def test_tilde_user_form_resolves_to_the_account_home(self):
        user = pwd.getpwuid(os.getuid()).pw_name
        self.check(f"echo x > ~{user}/.claude/scripts/y", True)
        self.check(f"echo x > ~{user}/.claude/logs/y", False)
        self.check("echo x > ~nosuchuser_zz/.claude/scripts/y", False)  # not an account

    def test_existing_symlink_into_protected_root_is_followed(self):
        link = os.path.join(self.tmp, "s")
        os.symlink(os.path.join(self.home, ".claude", "scripts"), link)
        self.check(f"echo x > {link}/x", True)
        self.check(f"rm {link}/x", True)
        self.check(f"cat {link}/x > /tmp/y", False)

    def test_process_cwd_inside_protected_root(self):
        os.chdir(os.path.join(self.home, ".claude", "githooks"))
        self.check("echo x > pre-commit", True)
        self.check("rm pre-push", True)
        self.check("cat pre-commit > /tmp/y", False)
        self.check("echo x > /tmp/y", False)
        self.check("cd /tmp && echo x > y", False)

    def test_relative_path_outside_protected_cwd_is_allowed(self):
        self.check("echo x > scripts/x", False)  # cwd = scratch work dir
        self.check("rm scripts/x", False)


class TestHatch(_Base):
    def test_hatch_exempts_its_own_segment(self):
        self.check(f"{HATCH}=1 tee ~/.claude/scripts/x", False)
        self.check(f"{HATCH}=1 echo x > ~/.claude/scripts/x", False)
        self.check(f"{HATCH}=1 rm ~/.claude/githooks/pre-push", False)
        self.check(f"{HATCH}='1' mv /tmp/x ~/.claude/scripts/x", False)

    def test_hatch_is_segment_scoped(self):
        self.check(f"{HATCH}=1 true; rm ~/.claude/scripts/x", True)
        self.check(f"{HATCH}=1 true && echo x > ~/.claude/scripts/x", True)
        self.check(f"echo {HATCH}=1; rm ~/.claude/scripts/x", True)

    def test_only_value_one_counts(self):
        self.check(f"{HATCH}=0 rm ~/.claude/scripts/x", True)
        self.check(f"{HATCH}= rm ~/.claude/scripts/x", True)
        self.check(f"{HATCH}=yes rm ~/.claude/scripts/x", True)

    def test_other_hatches_do_not_exempt(self):
        self.check("CAST_RM_OK=1 rm ~/.claude/scripts/x", True)
        self.check("CAST_KILL_OK=1 tee ~/.claude/scripts/x", True)

    def test_hatch_inside_payload(self):
        self.check(f"bash -c '{HATCH}=1 rm ~/.claude/scripts/x'", False)
        self.check(f"{HATCH}=1 bash -c 'rm ~/.claude/scripts/x'", False)

    def test_existing_rules_unchanged(self):
        blocked, msg = self.cg.is_blocked("rm -rf ~/.claude")
        self.assertTrue(blocked)
        self.assertIn("CAST_RM_OK", msg)
        blocked, msg = self.cg.is_blocked("pkill -9 bash")
        self.assertTrue(blocked)
        self.assertIn("CAST_KILL_OK", msg)
        # RULE 3's hatch already authorises a RECURSIVE rm of the .claude subtree (the bats
        # suite pins `CAST_RM_OK=1 rm -rf ~/.claude` as allowed); RULE 5 does not ask twice.
        for cmd in ("CAST_RM_OK=1 rm -rf ~/.claude/scripts/old", "CAST_RM_OK=1 rm -rf ~/.claude",
                    "CAST_RM_OK=1 rm -R ~/.claude/githooks"):
            blocked, _ = self.cg.is_blocked(cmd)
            self.assertFalse(blocked, cmd)
        # ...but only for a recursive rm, and only for rm.
        self.check("CAST_RM_OK=1 rm ~/.claude/scripts/x", True)
        self.check("CAST_RM_OK=1 rm -f ~/.claude/githooks/pre-push", True)
        self.check("CAST_RM_OK=1 mv ~/.claude/githooks /tmp/x", True)
        self.check("CAST_RM_OK=1 rm -rf /tmp/x; rm ~/.claude/scripts/x", True)


# Shell reserved words made the KEYWORD the command word, so RULES 1-5 all missed the command
# behind it (`for x in 1; do rm -rf ~/.claude; done` passed RULE 3). Every form must expose it.
KEYWORD_FORMS = [
    "for x in 1; do @@; done",
    "select x in a; do @@; done",
    "while true; do @@; done",
    "while @@; do :; done",
    "until false; do @@; done",
    "until @@; do :; done",
    "if true; then @@; fi",
    "if @@; then :; fi",
    "if false; then :; else @@; fi",
    "if false; then :; elif true; then @@; fi",
    "if false; then :; elif @@; then :; fi",
    "{ @@; }",
    "( @@ )",
    "(@@)",
    "! @@",
    "! time @@",
    "time @@",
    "case x in x) @@;; esac",
    "case x in\nx) @@\n;;\nesac",
    "function f { @@; }; f",
    "f() { @@; }; f",
    "coproc @@",
    "coproc NAME { @@; }",
    "do @@",
    "then @@",
    "else @@",
    "x=1; do @@",
]
KEYWORD_BODIES = {
    "RULE 3 rm -rf ~/.claude": ("rm -rf ~/.claude", "CAST_RM_OK"),
    "RULE 3 rm -rf $HOME": ("rm -rf $HOME", "CAST_RM_OK"),
    "RULE 1 pkill": ("pkill -9 bash", "CAST_KILL_OK"),
    "RULE 2 mass kill": ("kill -9 -1", "CAST_KILL_OK"),
    "RULE 4 tee workflow": ("tee .github/workflows/ci.yml", ".github/workflows"),
    "RULE 4 redirect workflow": ("echo x > .github/workflows/ci.yml", ".github/workflows"),
    "RULE 5 tee exec surface": ("tee ~/.claude/scripts/x", HATCH),
}
KEYWORD_SAFE_BODIES = ["echo hi", "rm -rf /tmp/x", "rm -rf ~/Projects/x/node_modules",
                       "kill -9 1234", "cat ~/.claude/scripts/x", "echo x > /tmp/y"]


class TestShellKeywordsDoNotHideCommands(_Base):
    def test_every_rule_sees_the_command_behind_each_keyword(self):
        for body_name, (body, marker) in KEYWORD_BODIES.items():
            for form in KEYWORD_FORMS:
                cmd = form.replace("@@", body)
                with self.subTest(rule=body_name, form=form):
                    blocked, msg = self.cg.is_blocked(cmd)
                    self.assertTrue(blocked, f"keyword hid the command: {cmd!r}")
                    self.assertIn(marker, msg, cmd)

    def test_benign_commands_behind_keywords_stay_allowed(self):
        for body in KEYWORD_SAFE_BODIES:
            for form in KEYWORD_FORMS:
                cmd = form.replace("@@", body)
                with self.subTest(form=form, body=body):
                    self.check(cmd, False)

    def test_hatch_still_works_behind_a_keyword(self):
        for form in ("for x in 1; do @@; done", "if true; then @@; fi", "! @@", "{ @@; }"):
            for cmd in ("CAST_RM_OK=1 rm -rf ~/.claude", "CAST_KILL_OK=1 pkill -9 bash",
                        f"{HATCH}=1 tee ~/.claude/scripts/x"):
                with self.subTest(form=form, cmd=cmd):
                    self.assertFalse(self.cg.is_blocked(form.replace("@@", cmd))[0])

    def test_keyword_as_a_word_is_not_a_keyword(self):
        # only a LEADING reserved word is skipped; as an argument it is just a word
        self.check("echo do rm -rf ~/.claude", False)
        self.check("echo then pkill bash", False)
        self.check("echo '!' tee ~/.claude/scripts/x", False)


class TestFuzzNeverCrashes(_Base):
    """The Bash guard fails OPEN on a crash (safe_is_blocked swallows it), so a crash is a
    bypass: no input may raise out of is_blocked / protected_write_via_bash."""

    POOL = ["rm", "cp", "mv", "tee", "ln", "sed", "-i", "-rf", "-R", "-a", "-c", "-o", "--", "of=",
            ">", ">>", ">|", "&>", "2>&1", "<<<", "<<EOF", "EOF", "<(", ">(", "$(", ")", "`", '"',
            "'", "\\", "{", "}", ",", "[", "]", "*", "?", "~", "~/.claude/scripts/x", "$HOME",
            "${HOME}", "/System/Volumes/Data", "[s]cripts", "{a,b}", "bash", "eval", "trap",
            "source", ".", "do", "done", "then", "fi", "if", "for", "x", "in", "!", "&&", "||",
            ";", "|", "\n", "&", "(", " ", "\t", "#", "cd", "find", "-delete", "-exec", "\\;", "tar",
            "-xf", "-C", "unzip", "-d", "git", "env", "-S", "sudo", "xargs", "D=~/.claude", "$D",
            "$_S", "$_PS", "/tmp/x", "..", "/", "$((1+2))", "${X:-y}", "\x00", "\ue000", "\ue004",
            "[!a]", "[[:alpha:]]", "[]", "[!]", "{,}", "{1..3}"]

    def test_random_and_mutated_inputs(self):
        rnd = random.Random(11)
        corpus = (BLOCK + ALLOW + SEC_BLOCK + SEC_ALLOW + SEC2_BLOCK + SEC2_ALLOW + SEC3_BLOCK
                  + SEC3_ALLOW + SEC4_BLOCK + SEC4_ALLOW + SEC5_BLOCK + SEC5_ALLOW)
        cases = []
        for _ in range(1200):
            cases.append("".join(rnd.choice(self.POOL) + rnd.choice((" ", "")) for _ in
                                 range(rnd.randint(1, 25))))
        for _ in range(900):
            c = rnd.choice(corpus).replace("@H@", self.home)
            i = rnd.randrange(len(c))
            j = rnd.randrange(i, len(c) + 1)
            op = rnd.randrange(4)
            if op == 0:
                c = c[:i] + c[j:]
            elif op == 1:
                c = c[:i] + rnd.choice(self.POOL) + c[i:]
            elif op == 2:
                c = c[:i] + c[i:j] * rnd.randint(2, 5) + c[j:]
            else:
                c = c[:i] + c[i:j][::-1] + c[j:]
            cases.append(c)
        for _ in range(200):
            cases.append("".join(chr(rnd.randint(0, 0x2FFF)) for _ in range(rnd.randint(1, 80))))
        cases += ["$(" * 3000 + ")" * 3000, "{a," * 500 + "}" * 500, 'bash -c "' * 40 + "x" + '"' * 40,
                  "bash -c '" * 10 + "rm ~/.claude/scripts/x" + "'" * 10]
        self.assertGreaterEqual(len(cases), 2000)
        for c in cases:
            try:
                self.cg.is_blocked(c)
                self.cg.protected_write_via_bash(c)
            except BaseException as exc:  # noqa: BLE001 -- the point of the test
                self.fail(f"{type(exc).__name__} on {c[:120]!r}")


class TestEndToEnd(_Base):
    def _run(self, cmd, tool="Bash"):
        payload = json.dumps({"tool_name": tool, "tool_input": {"command": cmd}})
        env = dict(os.environ)
        env["HOME"] = self.home
        env.pop("CAST_CMD_GUARD_INPUT", None)
        return subprocess.run([sys.executable, str(_GUARD)], input=payload, text=True,
                              capture_output=True, env=env, cwd=self.work, timeout=30)

    def test_exit_2_and_message_names_the_hatch(self):
        r = self._run("echo x > ~/.claude/githooks/pre-commit")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn(HATCH, r.stderr)
        self.assertIn("[CAST]", r.stderr)

    def test_read_and_hatched_exit_0(self):
        self.assertEqual(self._run("cat ~/.claude/githooks/pre-commit").returncode, 0)
        self.assertEqual(self._run(f"{HATCH}=1 tee ~/.claude/scripts/x").returncode, 0)

    def test_non_bash_tool_ignored(self):
        self.assertEqual(self._run("echo x > ~/.claude/scripts/x", tool="Write").returncode, 0)

    def test_guard_bug_fails_open(self):
        with mock.patch.object(self.cg, "protected_write_via_bash", side_effect=RuntimeError("boom")):
            self.assertEqual(self.cg.safe_is_blocked("echo x > ~/.claude/scripts/x"), (False, ""))


class TestPerformance(_Base):
    """The dispatcher gives the command guard ~3.5 s total and a hook TIMEOUT is an ALLOW (the
    dispatcher blocks instead, fail-closed -- but a slow guard still means a refused command),
    so RULE 5 must stay near-linear on the same 200 KB paddings. Each case is timed in a FRESH
    process, like the real hook: inside one long-lived interpreter the pre-existing
    string-concatenating tokenizer degrades 10x once the heap is fragmented (head: 0.09 s ->
    1.2 s on the same input), which would make an in-process timing a flaky proxy."""

    BUDGET = 2.5
    _CHILD = (
        "import importlib.util, sys, time\n"
        "spec = importlib.util.spec_from_file_location('g', sys.argv[1])\n"
        "g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)\n"
        "cmd = sys.stdin.read()\n"
        "t = time.perf_counter(); blocked, _ = g.is_blocked(cmd)\n"
        "print(time.perf_counter() - t, int(blocked))\n"
    )

    def _timed(self, cmd):
        env = dict(os.environ, HOME=self.home)
        r = subprocess.run([sys.executable, "-c", self._CHILD, str(_GUARD)], input=cmd, text=True,
                           capture_output=True, env=env, cwd=self.work, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        secs, blocked = r.stdout.split()
        return float(secs), bool(int(blocked))

    def test_200kb_paddings(self):
        pad = "A" * 200_000
        cases = {
            "single echo word": f"echo {pad}",
            "many segments": "echo x; " * 25_000,
            "many tee args": "tee " + "a " * 100_000,
            "many rm args": "rm " + "a " * 100_000,
            "many redirects": "echo x > /tmp/a; " * 12_000,
            "many in-place seds": "sed -i s/a/b/ /tmp/x; " * 8_000,
            "huge quoted arg": f"echo '{pad}' > /tmp/y",
            "huge payload": f"bash -c 'echo {pad}'",
            "nested braces": "cp x " + "{a,b}" * 2_000,
            "unknown command, huge word": f"mytool {pad}",
            "unknown command, many args": "mytool " + "a " * 100_000,
            "env value, huge": f"FOO={pad} mytool",
            "strict reader, many operands": "sort " + "a " * 100_000,
            "mention scan, long text": f"python3 -c '{pad}'",
            "many substitutions": "echo $(true) " * 5_000,
            "deep substitution nesting": "echo " + "$(echo " * 200 + "x" + ")" * 200,
        }
        for name, cmd in cases.items():
            with self.subTest(case=name):
                secs, _blocked = self._timed(cmd)
                self.assertLess(secs, self.BUDGET, name)

    def test_write_behind_200kb_padding_still_blocked_in_time(self):
        pad = "A" * 200_000
        for cmd in (f"echo {pad}; echo x > ~/.claude/scripts/y",
                    f"echo x > ~/.claude/scripts/y; echo {pad}"):
            secs, blocked = self._timed(cmd)
            self.assertTrue(blocked)
            self.assertLess(secs, self.BUDGET)

    def test_padding_does_not_hide_the_write(self):
        pad = "A" * 60_000
        self.check(f"echo {pad}; echo x > ~/.claude/scripts/y", True)
        self.check(f"echo x > ~/.claude/scripts/y; echo {pad}", True)


if __name__ == "__main__":
    unittest.main()
