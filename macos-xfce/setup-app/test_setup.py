"""Tests for setup_core (no GUI, nothing installed)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import setup_core as core  # noqa: E402


class Commands(unittest.TestCase):
    def test_install_asks_for_the_password_first_then_runs_the_installer(self):
        cmds = core.install_commands(root="/r")
        self.assertEqual(cmds[0], ["sudo", "-A", "-v"])
        self.assertEqual(cmds[1], ["bash", "/r/macos-xfce/install.sh"])
        self.assertEqual(len(cmds), 2)

    def test_options_become_flags_and_extras_follow(self):
        cmds = core.install_commands(trim=True, english=True, extras=["net-badge", "vpntray"], root="/r")
        self.assertEqual(cmds[1], ["bash", "/r/macos-xfce/install.sh", "--trim", "--english-only"])
        self.assertEqual(cmds[2:], [["bash", "/r/extras/net-badge/install.sh"], ["bash", "/r/extras/vpntray/install.sh"]])

    def test_restore_variants(self):
        self.assertEqual(core.restore_commands(root="/r"), [["bash", "/r/macos-xfce/install.sh", "--restore", "--yes"]])
        self.assertEqual(core.restore_commands(dry_run=True, root="/r"),
                         [["bash", "/r/macos-xfce/install.sh", "--restore", "--dry-run"]])
        self.assertEqual(core.restore_commands(packages=True, root="/r")[0][-1], "--packages")

    def test_a_preview_never_confirms_and_never_changes_anything(self):
        cmd = core.restore_commands(dry_run=True, packages=True, root="/r")[0]
        self.assertNotIn("--yes", cmd)

    def test_the_installer_can_be_replaced_for_tests(self):
        os.environ["LU_SETUP_INSTALLER"] = "/fake"
        try:
            self.assertEqual(core.install_commands(root="/r")[1], ["bash", "/fake"])
        finally:
            del os.environ["LU_SETUP_INSTALLER"]

    def test_sudo_uses_the_graphical_prompt(self):
        self.assertEqual(core.child_env("/x/askpass")["SUDO_ASKPASS"], "/x/askpass")


class Output(unittest.TestCase):
    def test_ansi_codes_are_stripped(self):
        self.assertEqual(core.strip_ansi("\x1b[1;32m[OK]\x1b[0m   done\n"), "[OK]   done\n")

    def test_extras_listed_only_when_present(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "extras", "net-badge"))
            open(os.path.join(d, "extras", "net-badge", "install.sh"), "w").close()
            os.makedirs(os.path.join(d, "extras", "vpntray"))      # no install.sh
            self.assertEqual([n for n, _ in core.available_extras(d)], ["net-badge"])


if __name__ == "__main__":
    unittest.main()
