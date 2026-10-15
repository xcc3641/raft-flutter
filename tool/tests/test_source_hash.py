"""Verification policy changes must invalidate the gate's source receipt."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SourceHashTests(unittest.TestCase):
    def test_structure_policy_is_hashed_but_documentation_is_not(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'tool').mkdir()
            shutil.copy2(ROOT / 'tool/source-hash', root / 'tool/source-hash')
            def stamp():
                return subprocess.check_output([sys.executable, str(root / 'tool/source-hash')], text=True)
            previous = stamp()
            for name in ['tool/structure-audit', 'tool/structure-audit-baseline.json']:
                path = root / name
                path.write_text('initial')
                current = stamp()
                self.assertNotEqual(previous, current)
                path.write_text('changed')
                changed = stamp()
                self.assertNotEqual(current, changed)
                previous = changed
            (root / 'docs').mkdir()
            (root / 'docs/readme.md').write_text('explanatory text')
            self.assertEqual(previous, stamp())


if __name__ == '__main__':
    unittest.main()
