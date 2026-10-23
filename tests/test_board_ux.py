"""Offline regression for compact cards, actual lead observations and full history."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SHARED = Path(__file__).resolve().parents[1] / 'team/shared'
sys.path.insert(0, str(SHARED))
import research_activity as activity
import research_dashboard as dashboard
import research_board as rb


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def records(self, name, count, role='research-worker', start=0):
        folder = self.home / 'activity'; folder.mkdir(exist_ok=True)
        rows = [{'schema': 1, 'id': f'{name}:{n}', 'time': f'2026-10-22T12:{(n+start)//60:02}:{(n+start)%60:02}.000Z',
                 'project': 'p', 'task': 't', 'role': role, 'action': '자료 읽기', 'result': '완료', 'state': 'done'}
                for n in range(count)]
        (folder / (name + '.jsonl')).write_text(''.join(json.dumps(r) + '\n' for r in rows), encoding='utf-8')
        return rows

    def test_role_is_filtered_before_recent_page_selection(self):
        self.records('scout', 155, 'research-scout')
        self.records('worker', 900, start=200)
        first = activity.read_page(self.home, 'p', 'research-scout')
        self.assertEqual(len(first['events']), 100)
        self.assertTrue(first['has_more'])
        second = activity.read_page(self.home, 'p', 'research-scout', before=first['next_cursor'])
        self.assertEqual(len(second['events']), 55)
        self.assertFalse(second['has_more'])
        self.assertEqual(len({r['id'] for r in first['events'] + second['events']}), 155)

    def test_history_does_not_drop_old_files_or_large_file_prefix(self):
        self.records('old-scout', 1, 'research-scout')
        for n in range(103): self.records(f'new-{n}', 1)
        self.assertEqual(len(activity.read_page(self.home, 'p', 'research-scout')['events']), 1)
        path = self.home / 'activity/large.jsonl'
        with path.open('w', encoding='utf-8') as f:
            f.write(json.dumps({'schema':1,'id':'old','time':'2026-01-01','project':'p','task':'rare',
                                'role':'research-scout','state':'done'}) + '\n')
            f.write((' ' * 10000 + '\n') * 30)
        self.assertEqual(activity.read_page(self.home, 'p', task='rare')['events'][0]['id'], 'old')

    def test_cursor_order_handles_identical_times_without_loss(self):
        rows = self.records('a', 230)
        for row in rows: row['time'] = '2026-10-22T12:00:00Z'
        (self.home / 'activity/a.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
        ids, cursor = set(), None
        while True:
            page = activity.read_page(self.home, 'p', before=cursor, limit=35)
            new = {r['id'] for r in page['events']}
            self.assertFalse(ids & new); ids.update(new)
            if not page['has_more']: break
            cursor = page['next_cursor']
        self.assertEqual(len(ids), 230)

    def test_invalid_page_requests_are_rejected(self):
        for limit in (0, -1, 501, '100'):
            with self.assertRaises(ValueError): activity.read_page(self.home, limit=limit)
        for cursor in ('../secret', '!', 'e30', 'x' * 1025):
            with self.assertRaises(ValueError): activity.read_page(self.home, before=cursor)
        (self.home / 'activity').mkdir()
        with self.assertRaises(ValueError): activity.read_page(self.home, role='administrator')

    def test_metadata_is_sanitized_even_in_modified_journals(self):
        self.records('a', 1)
        p = self.home / 'activity/a.jsonl'
        row = json.loads(p.read_text()); row['result'] = 'token=private-value'
        row['api_key'] = 'hidden'; p.write_text(json.dumps(row) + '\n')
        result = json.dumps(activity.read_page(self.home))
        self.assertNotIn('private-value', result); self.assertNotIn('api_key', result)

    def test_lead_cards_are_persisted_observations_not_audit_approval(self):
        journal = activity.Journal(self.home, 'p', 'worker-1', 'research-lead')
        journal.emit('후속 계획 판단', '자료 검토·후속 배정', 'running')
        before = activity.management_cards(self.home, 'p')
        self.assertEqual(before[0]['status'], 'running')
        journal.emit('후속 계획 판단', '독립 최종 감사를 배정했습니다.', 'done')
        after = activity.management_cards(self.home, 'p')
        self.assertEqual(after[0]['id'], before[0]['id'])
        self.assertEqual(after[0]['status'], 'done')
        self.assertEqual(after[0]['kind'], 'coordination')
        self.assertEqual(after[0]['approval'], '')
        self.assertIn('감사 승인과 별개', after[0]['audit'])
        self.assertFalse((self.home / '.tasks/ledger.jsonl').exists())

    def test_nested_lead_commands_join_one_card(self):
        parent = activity.Journal(self.home, 'p', 't', 'research-lead')
        parent.emit('후속 계획 판단', '판단 중', 'running')
        with patch.dict(os.environ, {'RESEARCH_LEAD_CARD_ID': parent.card}):
            child = activity.Journal(self.home, 'p', 'audit-next', 'research-lead')
            child.emit('작업 배정', '감사 배정', 'done')
        cards = activity.management_cards(self.home, 'p')
        self.assertEqual(len(cards), 1)
        self.assertEqual(cards[0]['status'], 'running')
        parent.emit('후속 계획 판단', '배정을 마쳤습니다.', 'done')
        self.assertEqual(activity.management_cards(self.home, 'p')[0]['status'], 'done')

    def test_lead_command_success_failure_and_system_exit_are_recorded(self):
        with patch.object(rb, 'TEAM_HOME', self.home), patch.object(rb, 'activity_project', return_value='p'):
            def action(a): return 'ok'
            args = argparse.Namespace(cmd='edit', paper=str(self.home), id='t', fn=action)
            self.assertEqual(rb.tracked_lead_command(args), 'ok')
            self.assertEqual(activity.management_cards(self.home, 'p')[0]['status'], 'done')
            def fail(a): raise RuntimeError('404 not found')
            args.fn = fail
            with self.assertRaises(RuntimeError): rb.tracked_lead_command(args)
            self.assertTrue(any(c['status'] == 'failed' for c in activity.management_cards(self.home, 'p')))
            def exit_ok(a): raise SystemExit(0)
            args.fn = exit_ok
            with self.assertRaises(SystemExit): rb.tracked_lead_command(args)
            self.assertEqual(len(activity.management_cards(self.home, 'p')), 3)

    def test_summary_uses_result_not_original_instructions(self):
        text = '# Request\nFind some papers.\n\n## Result — now\nSTATUS: done\n\n### 결과\n- 원문 5편의 근거를 추출했습니다.\n'
        result = dashboard.result_summary(text, 'fallback')
        self.assertIn('원문 5편', result)
        self.assertNotIn('Find some papers', result)

    def test_summary_prefers_outcome_to_saved_file_inventory(self):
        text = ('## Result — now\n작업 rag-scout-01의 검색·추출을 수행했습니다.\n'
                '산출물 v1:\n산출물\n- C:\\Users\\user\\notes\\search-log.md\n'
                '- sources/rag/manifest.json\n원문·근거 보존:\n'
                '- 같은 sources\\rag\\ 아래 원본 PDF.\n'
                '- bibliography.md: 전체 저자·판본.\n확인 결과:\n'
                '- 핵심 14편의 PDF를 확보하고 근거를 추출했습니다.\n'
                '- 독립 감사는 아직 통과하지 않았습니다.\nSTATUS: done\n')
        result = dashboard.result_summary(text, 'fallback')
        self.assertIn('핵심 14편', result)
        self.assertIn('아직 통과하지 않았습니다', result)
        self.assertNotIn('C:', result)
        self.assertNotIn('manifest.json', result)

    def test_summary_preserves_meaningful_leading_numbers(self):
        result = dashboard.result_summary('## Result — now\n1차 논문 1편에서 근거를 추출했습니다.\n2026년 후보도 구분했습니다.\n', 'fallback')
        self.assertIn('1차 논문 1편', result)
        self.assertIn('2026년 후보', result)
        numbered = dashboard.result_summary('## Result — now\n1. 원문 5편을 읽었습니다.\n', 'fallback')
        self.assertTrue(numbered.startswith('원문 5편'))

    def test_bridge_allows_only_read_pagination_fields(self):
        spec = importlib.util.spec_from_file_location('ux_bridge', SHARED.parents[1] / 'plugins/research-board/bridge.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        module.validate_query('/api/activity', 'project=p&role=research-scout&limit=100')
        for query in ('role=admin', 'limit=0', 'limit=501', 'before=..%2Fsecret', 'role=research-scout&role=research-worker', 'command=run'):
            with self.assertRaises(ValueError): module.validate_query('/api/activity', query)


if __name__ == '__main__': unittest.main()
