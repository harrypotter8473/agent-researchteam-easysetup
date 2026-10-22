'use strict';
const $ = id => document.getElementById(id);
const roles = {'research-lead':'총괄', 'research-scout':'조사', 'research-worker':'분석', 'research-reviewer':'감사'};
const states = {ready:'대기', running:'진행 중', done:'작업 완료', failed:'실패', partial:'부분 완료', blocked:'후속 판단 필요'};
const columns = [['ready','대기'], ['running','진행 중'], ['approval','사용자 확인 대기'], ['done','완료'], ['attention','확인 필요']];
const route = new URLSearchParams(location.search);
let view = route.get('view') === 'checks' ? 'checks' : 'research';
let requested = route.get('project'), data = {projects:[]}, selected = null, events = [], busy = false, lastSnapshot = 0;

function el(tag, text, className) {
  const x = document.createElement(tag);
  if (text !== undefined) x.textContent = text;
  if (className) x.className = className;
  return x;
}
function current() { return data.projects.find(p => p.id === selected); }
function query(project, path, preview=false) {
  const q = new URLSearchParams({project:project.id, commit:project.commit, path});
  if (preview) q.set('preview', '1');
  return '/api/output?' + q;
}
function outputRow(project, item) {
  const row = el('div', undefined, 'output');
  row.append(el('span', item.path));
  if (!item.available) { row.append(el('small', '아직 저장되지 않음')); return row; }
  const a = el('a', '다운로드'); a.href = query(project, item.path); a.download = ''; row.append(a);
  if (/\.(md|txt|json|jsonl|csv|py|html|log|tex)$/i.test(item.path)) {
    const b = el('button', '내용 보기');
    b.onclick = async () => {
      try {
        const response = await fetch(query(project, item.path, true));
        if (!response.ok) throw Error('버전이 바뀌었습니다. 새로 고침하세요.');
        $('preview').textContent = await response.text(); $('preview').hidden = false;
        if (!$('detail').open) {
          $('detail-title').textContent = item.path;
          $('report').textContent = '파일 내용은 아래에 표시됩니다.';
          $('detail-meta').textContent = '저장된 버전 ' + project.commit.slice(0,12);
          $('detail-outputs').replaceChildren(); $('detail').showModal();
        }
      } catch(e) { $('error').textContent = e.message; }
    };
    row.append(b);
  }
  return row;
}
function detail(project, task) {
  $('detail-title').textContent = task.id;
  $('detail-meta').textContent = `${roles[task.assignee] || task.assignee} · ${states[task.status] || task.status} · 감사 ${task.audit} · 시도 ${task.attempt}/${task.max_attempts || '설정값'}`;
  $('report').textContent = task.report;
  $('detail-outputs').replaceChildren(...task.outputs.map(o => outputRow(project,o)));
  $('preview').hidden = true; $('detail').showModal();
}
function render() {
  const visible = data.projects.filter(p => Boolean(p.test) === (view === 'checks'));
  if (requested) { selected = visible.find(p => p.name === requested)?.id || null; }
  else if (!visible.some(p => p.id === selected)) selected = visible[0]?.id || null;
  $('research-view').setAttribute('aria-pressed', String(view === 'research'));
  $('checks-view').setAttribute('aria-pressed', String(view === 'checks'));
  $('projects').replaceChildren(...visible.map(p => {
    const b = el('button', p.name);
    b.setAttribute('aria-current', String(p.id === selected));
    b.append(el('small', `${p.tasks.length}개 작업`));
    b.onclick = () => {
      selected = p.id; requested = null;
      history.replaceState(null, '', '?' + new URLSearchParams({view, project:p.name}));
      render(); poll(true);
    };
    return b;
  }));
  $('workspace').textContent = data.workspace || '';
  const p = current();
  $('name').textContent = p?.name || (view === 'checks' ? '설치 검증 기록이 없습니다' : '아직 연구 프로젝트가 없습니다');
  $('source').textContent = p ? `${p.source || ''} · ${p.path || ''} · ${(p.commit || '').slice(0,12)}` : '';
  $('error').textContent = p?.error || '';
  for (const id of ['tasks','approvals','outputs','metrics']) $(id).replaceChildren();
  if (!p) { renderEvents(); return; }
  for (const [label,count] of [['전체 작업',p.tasks.length], ['진행 중',p.tasks.filter(t=>t.status==='running').length], ['완료',p.tasks.filter(t=>t.status==='done').length], ['사용자 확인',p.tasks.filter(t=>t.approval).length]]) {
    $('metrics').append(el('span', `${label} ${count}`, 'metric'));
  }
  for (const [key,label] of columns) {
    const tasks = p.tasks.filter(t => t.approval ? key === 'approval' : key === 'attention' ? ['failed','blocked','partial','unknown'].includes(t.status) : t.status === key);
    const col = el('section', undefined, 'column'); col.dataset.status = key;
    const heading = el('h4', label); heading.append(el('span', tasks.length)); col.append(heading);
    for (const t of tasks) {
      const card = el('button', undefined, 'card');
      card.append(el('strong', t.id), el('p', roles[t.assignee] || t.assignee),
        el('p', '선행 작업: ' + (t.after.join(', ') || '없음')),
        el('span', `결과 ${t.outputs.filter(o=>o.available).length}개 · 시도 ${t.attempt}`, 'badge '+t.status), el('p','감사: '+t.audit));
      card.onclick = () => detail(p,t); col.append(card);
    }
    $('tasks').append(col);
  }
  for (const t of p.tasks.filter(t=>t.approval)) {
    const n = el('div',undefined,'notice');
    n.append(el('strong',t.id+' · '+t.approval), el('p',t.stop_reason || '문서를 검토한 뒤 Mattermost의 같은 스레드에서 총괄에게 결정·추가 자료를 전달하세요. 자동 감사 통과와 사용자 승인은 다릅니다.'));
    const b = el('button','문서·요청 확인'); b.onclick = () => detail(p,t); n.append(b); $('approvals').append(n);
  }
  if (!$('approvals').childElementCount) $('approvals').append(el('p','현재 사용자 결정·추가 정보 요청이 없습니다.','muted'));
  const unique = new Map(); for (const t of p.tasks) for (const o of t.outputs) unique.set(o.path,o);
  $('outputs').replaceChildren(...[...unique.values()].map(o=>outputRow(p,o)));
  if (!unique.size) $('outputs').append(el('p','작업 결과가 저장되면 파일과 다운로드가 여기에 나타납니다.','muted'));
  if (p.ledger_intact === false) $('error').textContent = '작업 원장의 해시 체인이 일치하지 않습니다. 완료로 취급하지 말고 점검하세요.';
  $('export').href = '/api/log?' + new URLSearchParams({project:p.name});
  renderEvents();
}
function renderEvents() {
  const p = current();
  const rows = p ? events.filter(e=>e.project === p.name && (!$('role').value || e.role === $('role').value)) : [];
  $('timeline').replaceChildren(...rows.slice(-200).reverse().map(e=>{
    const row=el('div',undefined,'event '+e.state);
    const time=el('time',new Date(e.time).toLocaleTimeString('ko-KR')); time.dateTime=e.time;
    row.append(time,el('strong',e.agent),el('div',e.action));
    const body=el('div',e.detail ? e.detail+' — '+e.result : e.result);
    body.append(el('div', e.task+(e.tool?' · '+e.tool:''), 'sub')); row.append(body); return row;
  }));
  if (!rows.length) $('timeline').append(el('p','아직 기록된 활동이 없습니다. 실제 실행이 시작되면 표시됩니다.','muted'));
}
async function poll(force=false) {
  if (busy) return; busy=true;
  try {
    if (force || Date.now()-lastSnapshot>5000) {
      const response=await fetch('/api/projects'); if(!response.ok)throw Error('작업 보드 응답 오류');
      data=await response.json(); lastSnapshot=Date.now(); render();
      const updated=Date.parse(data.service?.updated || '');
      const healthy=!data.service?.stopped && Number.isFinite(updated) && Date.now()-updated<30000 && data.service?.children?.length && data.service.children.every(c=>c.state==='running');
      $('health').textContent=healthy ? '연구팀 서비스 실행 중' : '서비스 중지·상태 지연 · 마지막 저장 기록 표시';
      $('validation').textContent=data.validation?.passed ? '설치 검증: 실제 S1·S2·S3 통과 기록 있음' : '설치 검증: 미완료（작업 완료 수와 별개）';
    }
    const r=await fetch('/api/activity?'+new URLSearchParams(current()?{project:current().name}:{}));
    if(!r.ok)throw Error('활동 기록 응답 오류'); events=(await r.json()).events; renderEvents();
    $('updated').textContent='마지막 확인 '+new Date().toLocaleTimeString('ko-KR')+' · 읽기 전용 · 활동 2초 / 저장 결과 5초마다 갱신';
  } catch(e) { $('health').textContent='연결 끊김 · 마지막 표시를 현재 상태로 보지 마세요'; $('error').textContent=e.message; }
  finally { busy=false; }
}
function switchView(next) {view=next; selected=null; requested=null; history.replaceState(null,'','?'+new URLSearchParams({view}));render();poll(true);}
$('research-view').onclick=()=>switchView('research'); $('checks-view').onclick=()=>switchView('checks');
$('refresh').onclick=()=>poll(true); $('role').onchange=renderEvents; $('close').onclick=()=>$('detail').close();
setInterval(()=>poll(),2000); poll(true);
