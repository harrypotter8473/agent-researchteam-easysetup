import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'team/shared'))
import research_board as board

class ProfileRoot(unittest.TestCase):
    def test_root_and_active_profile_resolve_to_same_data_root(self):
        root=Path.cwd()/'isolated-home'
        with patch.dict(os.environ,{'HERMES_HOME':str(root)}):self.assertEqual(board.hermes_root(),root)
        for role in ('research-lead','research-worker','default'):
            with patch.dict(os.environ,{'HERMES_HOME':str(root/'profiles'/role)}):
                self.assertEqual(board.hermes_root(),root)
    def test_root_fallback(self):
        root=Path.cwd()/'isolated-fallback'
        with patch.dict(os.environ,{'HERMES_ROOT':str(root)},clear=True):self.assertEqual(board.hermes_root(),root)

if __name__=='__main__':unittest.main(verbosity=2)
