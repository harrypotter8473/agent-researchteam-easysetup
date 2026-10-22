"""Real two-clone Git regression, no model or existing environment changes."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE=Path(__file__).resolve().parents[1]/'team/shared'
import sys
sys.path.insert(0,str(SOURCE))
import research_board as board

class ParallelLedger(unittest.TestCase):
    def test_concurrent_completion_preserves_both_results_and_chain(self):
        with tempfile.TemporaryDirectory(prefix='parallel-ledger-') as temp:
            root=Path(temp);bare=root/'remote.git'
            def git(repo,*args):
                p=subprocess.run(['git','-C',str(repo),*args],capture_output=True,text=True,encoding='utf-8')
                self.assertEqual(p.returncode,0,p.stderr);return p.stdout
            subprocess.run(['git','init','--bare',str(bare)],check=True,capture_output=True)
            clones=[]
            for name in ('first','second'):
                clone=root/name
                subprocess.run(['git','clone','-c','core.autocrlf=false',str(bare),str(clone)],check=True,capture_output=True)
                git(clone,'config','user.name','isolated benchmark')
                git(clone,'config','user.email','benchmark@localhost')
                clones.append(clone)
            first,second=clones
            (first/'.tasks').mkdir();board.ledger_append(first,{'task':'seed','status':'done'})
            board.publish(first,['.tasks'],'seed')
            prefix=(first/'.tasks/ledger.jsonl').read_bytes()
            git(second,'pull','--rebase')
            for clone,name in ((first,'scout'),(second,'worker')):
                (clone/(name+'.md')).write_text(name,encoding='utf-8')
                board.ledger_append(clone,{'task':name,'status':'done'})
                board.stage(clone,['.tasks',name+'.md'])
            board.commit_push(first,'scout done')
            board.commit_push(second,'worker done')
            lines=board.ledger_lines(second)
            self.assertIsNone(board.ledger_check(lines))
            self.assertEqual([json.loads(x)['task'] for x in lines],['seed','scout','worker'])
            self.assertTrue((second/'.tasks/ledger.jsonl').read_bytes().startswith(prefix))
            self.assertEqual((second/'scout.md').read_text(),'scout')
            self.assertEqual((second/'worker.md').read_text(),'worker')
            (second/'pending.md').write_text('must survive')
            git(second,'add','pending.md');git(second,'commit','-m','unpublished real result')
            with self.assertRaisesRegex(RuntimeError,'preserved'):board.reset_to_remote(second)
            self.assertEqual((second/'pending.md').read_text(),'must survive')

if __name__=='__main__':unittest.main(verbosity=2)
