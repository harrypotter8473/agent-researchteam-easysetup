"""Create explicitly labelled offline UI fixtures; never calls an agent or model."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import datetime as dt

SHARED = Path(__file__).resolve().parents[1] / 'team/shared'
sys.path.insert(0, str(SHARED))
from research_activity import Journal

parser = argparse.ArgumentParser()
parser.add_argument('root')
args = parser.parse_args()
root = Path(args.root).resolve()
home, ws = root / 'runtime', root / 'workspace'
home.mkdir(parents=True, exist_ok=True); ws.mkdir(exist_ok=True)
project = ws / '화면검증용-모의-연구'; project.mkdir(exist_ok=True)
def git(*args): subprocess.run(['git','-C',str(project),*args], check=True, capture_output=True)
if not (project / '.git').exists():
    git('init','-q','-b','main');git('config','user.email','fixture@localhost');git('config','user.name','모의 화면 검증')
    (project / '.tasks').mkdir(); (project / 'reports').mkdir(); (project / 'notes').mkdir()
    (project / 'reports/중간결과.md').write_text('# 화면 검증용 모의 문서\n실제 연구 또는 S1 통과 결과가 아닙니다.\n',encoding='utf-8')
    fixtures=[('r1-literature','research-scout','done','notes/추출표.md'),('a1-analysis','research-worker','running','reports/중간결과.md'),('v1-audit','research-reviewer','ready','reviews/판정.json'),('q1-scope','research-scout','blocked','notes/추가자료.md')]
    for tid,role,status,output in fixtures:
        (project / '.tasks' / (tid+'.md')).write_text(f'---\nid: {tid}\nassignee: {role}\nstatus: {status}\nexpects: {output}\nstop_reason: '+('연구 범위를 확인해야 합니다（모의 요청）' if status=='blocked' else '')+'\n---\n화면 검증용 모의 작업. 실제 에이전트 실행이 아닙니다.\n',encoding='utf-8')
    git('add','.');git('commit','-qm','offline UI fixture, NOT live validation')
    journal=Journal(home,project.name,'r1-literature','research-scout')
    for action,result in [('검색','공개 원저 후보 확보（모의）'),('원문 읽기','원문 근거 저장（모의）'),('문서 작성·수정','추출표 작성（모의）')]:journal.emit(action,result,'done')
    Journal(home,project.name,'a1-analysis','research-worker').emit('자료 읽기','비교·분석 중（모의）','running',detail='reports/중간결과.md')
# Refresh only this script's explicitly named mock question; never an agent project.
question = project / '.tasks/q1-scope.md'
if question.is_file():
    text = question.read_text(encoding='utf-8')
    if 'gate: human' not in text:
        question.write_text(text.replace('status: blocked', 'status: blocked\ngate: human'), encoding='utf-8')
        git('add','.tasks/q1-scope.md');git('commit','-qm','explicit mock user question')
print(json.dumps({'home':str(home),'workspace':str(ws),'mock':True},ensure_ascii=False))
