import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'team/shared'))
import research_board as board

class PlanWatch(unittest.TestCase):
    def fixture(self):
        root=Path('fixture');task=root/'.tasks/p.md'
        return {'p':(task,{'status':'done','assignee':'research-worker'},''),
                'repair':(root/'.tasks/repair.md',{'status':'ready','assignee':'research-worker','after':'p'},'')}
    def check(self,items):
        with patch.object(board,'tasks',return_value=items),patch.object(board.audit_gate,'approved',return_value=False):
            return board.blocked_plan_event(Path('fixture'))
    def test_unapproved_repair_dependency_is_diagnosed_without_task_mutation(self):
        items=self.fixture();before=repr(items)
        event=self.check(items)
        self.assertEqual(event['observed_status'],'ready')
        self.assertEqual(event['waiting'],{'repair':['p:audit']})
        self.assertEqual(repr(items),before)
    def test_runnable_reviewer_prevents_false_deadlock(self):
        items=self.fixture();items['audit']=(Path('a'),{'status':'ready','assignee':'research-reviewer','after':'p'},'')
        self.assertIsNone(self.check(items))
    def test_running_task_prevents_replanning(self):
        items=self.fixture();items['p'][1]['status']='running'
        self.assertIsNone(self.check(items))
    def test_explicit_human_gate_is_respected(self):
        items=self.fixture();items['p'][1]['gate']='human'
        self.assertIsNone(self.check(items))
    def test_explicit_blocked_input_request_does_not_trigger_background_replan(self):
        items=self.fixture();items['p'][1].update(status='blocked',gate='human')
        self.assertIsNone(self.check(items))
    def test_timestamps_do_not_create_repeated_diagnostics(self):
        items=self.fixture();first=self.check(items)
        items['repair'][1]['updated']='later'
        self.assertEqual(self.check(items),first)

if __name__=='__main__':unittest.main(verbosity=2)
