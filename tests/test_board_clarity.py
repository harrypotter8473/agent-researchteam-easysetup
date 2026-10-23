"""Read-only presentation regressions. No model calls or installed state changes."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'team/shared'))
import research_dashboard as dashboard
import research_activity as activity


class BoardClarityTests(unittest.TestCase):
    def test_structured_validation_marker_does_not_break_project_display(self):
        for invalid in ([], {}, 7, True):
            labels = dashboard.project_labels('my-project', {'validation': invalid}, '비교 보고서')
            self.assertEqual(labels['display_name'], '비교 보고서')

    def test_validation_names_are_human_labels_not_installation_hashes(self):
        for scenario, title in [('S1', '문헌검토 보고서'), ('S2', '자료 분석 보고서'), ('S3', '내부 웹 보고서')]:
            labels = dashboard.project_labels('78f7ba3129e2-' + scenario.lower(), {'validation': scenario}, '')
            self.assertEqual(labels['display_name'], title)
            self.assertEqual(labels['project_label'], '설치 검증 ' + scenario)

    def test_existing_request_or_explicit_title_without_changing_routing_name(self):
        labels = dashboard.project_labels('req_a01234', {}, '# Request\n\nreq_a01234\n논문 다섯 편의 비교 보고서를 작성해 줘.\n')
        self.assertEqual(labels['display_name'], '논문 다섯 편의 비교 보고서를 작성해 줘.')
        self.assertEqual(dashboard.project_labels('reports', {}, '')['display_name'], '연구 보고서')
        self.assertEqual(dashboard.project_labels('repo', {'title': '연구 계획 비교'}, 'Other text')['display_name'], '연구 계획 비교')

    def test_display_metadata_is_redacted_and_invalid_marker_is_ignored(self):
        labels = dashboard.project_labels('paper', {'title': 42}, 'token=do-not-publish 주제')
        self.assertNotIn('do-not-publish', labels['display_name'])
        self.assertEqual(dashboard.project_labels('reports', ['bad'], '')['display_name'], '연구 보고서')

    def test_legacy_validation_titles_require_a_validation_location(self):
        self.assertEqual(dashboard.project_labels('abcdef123456-s1', {}, '', is_validation=True)['display_name'], '문헌검토 보고서')
        self.assertNotEqual(dashboard.project_labels('my-paper-s1', {}, '')['display_name'], '문헌검토 보고서')

    def test_opened_summary_keeps_complete_saved_outcome_beyond_old_limit(self):
        sentence = '저장된 원문과 비교 조건을 확인하고 근거를 보존했습니다. ' * 15 + '확인하지 못한 항목도 마지막에 명시했습니다.'
        got = dashboard.result_summary('# Original request\nDo something\n## Result — now\n' + sentence, 'fallback')
        self.assertEqual(got, sentence)
        self.assertGreater(len(got), 220)
        self.assertNotIn('Do something', got)

    def test_only_sanitized_lead_completion_keeps_long_summary(self):
        with tempfile.TemporaryDirectory(prefix='nst clarity ') as folder:
            home = Path(folder)
            text = '저장된 근거와 검수 버전을 확인했습니다. ' * 22 + '마지막 조치까지 기록합니다. token=do-not-publish'
            lead = activity.Journal(home, 'p', 't', 'research-lead')
            lead.emit('후속 계획 판단', '검토 중', 'running')
            lead.emit('후속 계획 판단', text, 'done')
            card = activity.management_cards(home, 'p')[0]
            self.assertIn('마지막 조치까지 기록합니다.', card['summary'])
            self.assertNotIn('do-not-publish', card['summary'])
            self.assertEqual(card['approval'], '')
            scout = activity.Journal(home, 'p', 's', 'research-scout')
            row = scout.emit('도구 사용', text, 'done')
            self.assertEqual(len(row['result']), 240)


if __name__ == '__main__': unittest.main()
