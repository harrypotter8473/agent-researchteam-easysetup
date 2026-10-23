'use strict';
const $ = id => document.getElementById(id);
const api = path => new URL(path.replace(/^\/+/, ''), new URL('.', location.href)).href;
const request = url => fetch(url,{credentials:'same-origin'});
const roles = {'research-lead':'총괄','research-scout':'조사','research-worker':'분석','research-reviewer':'감사'};
const states = {ready:'대기',running:'진행 중',done:'완료',failed:'실패',partial:'부분 완료',blocked:'후속 판단 필요'};
const route = new URLSearchParams(location.search);
let view = route.get('view') === 'checks' ? 'checks' : 'research';
let requested = route.get('project'), data = {projects:[]}, selected = null, events = [], busy = false, lastSnapshot = 0;
let eventScope = '', nextCursor = null, moreEvents = false, olderBusy = false;
let activityLoadedScope = '';
const openedGroups = new Set(), openedFolders = new Set();
function el(tag,text,className){const x=document.createElement(tag);if(text!==undefined)x.textContent=text;if(className)x.className=className;return x;}
function current(){return data.projects.find(p=>p.id===selected);}
function summary(task){
  const text=task.summary||(task.status==='done'?'저장된 결과를 확인하세요.':'작업이 진행되면 결과를 표시합니다.');
  if(task.kind!=='coordination')return text;
  const parts=text.split(' · ').map(s=>s.replace(/^[-*]\s*/,''));
  const useful=parts.filter(s=>!/^요청\s+[A-Za-z0-9_-]+|^작업\s*[A-Za-z0-9_-]+\s*[:/]|^상태:/.test(s));
  return useful.slice(0,2).join(' · ')||text;
}
function taskTitle(task){
  const title=task.title || ({'research-scout':'자료 조사','research-worker':'분석·보고서','research-reviewer':'감사','research-lead':'조치'}[task.assignee] || '작업');
  if(task.kind==='coordination')return title.startsWith('총괄')?title:'총괄 '+title;
  if(task.assignee==='research-reviewer')return task.audit_scope==='final'||title==='최종 검토'?'최종 감사':'중간 감사';
  return title;
}
function followedUp(p,t){
  // Presentation only: preserve the original failure/verdict and every card.
  if(t.kind==='coordination')return Boolean(t.origin_task&&t.status==='failed'&&p.tasks.some(o=>o!==t&&o.kind==='coordination'&&o.origin_task===t.origin_task&&o.status==='done'&&(o.updated||'')>(t.updated||'')));
  return Boolean(t.assignee==='research-reviewer'&&t.audit_of?.length&&p.tasks.some(o=>o!==t&&o.assignee==='research-reviewer'&&o.status==='done'&&o.verdict==='pass'&&String(o.audit).includes('현재 버전')&&o.audit_scope===t.audit_scope&&t.audit_of.every(id=>o.audit_of?.includes(id))&&(o.updated||'')>(t.updated||'')));
}
function taskBucket(p,t){
  if(t.approval)return 'attention';
  if(followedUp(p,t))return 'done';
  if(['failed','blocked','partial'].includes(t.status)||(t.status==='done'&&t.assignee==='research-reviewer'&&(t.verdict!=='pass'||!String(t.audit).includes('현재 버전'))))return 'attention';
  return t.status==='done'?'done':'active';
}
function taskBadge(p,t){
  if(t.approval)return '내 확인 필요';
  if(followedUp(p,t))return t.kind==='coordination'?'이전 오류 기록':'이전 감사 기록';
  if(t.assignee==='research-reviewer'&&t.status==='done')return ({pass:String(t.audit).includes('현재 버전')?'감사 통과':'재검토 필요',reject:'감사 반려',unverifiable:'검증 불가'}[t.verdict]||'판정 확인');
  return states[t.status]||t.status;
}
function query(project,path,preview=false){const q=new URLSearchParams({project:project.id,commit:project.commit,path});if(preview)q.set('preview','1');return api('api/output?'+q);}
function outputRow(project,item,short=false){
  const row=el('div',undefined,'output');row.append(el('span',short?item.path.split('/').pop():item.path));
  if(!item.available){row.append(el('small','저장 대기'));return row;}
  const a=el('a','받기');a.href=query(project,item.path);a.download='';row.append(a);
  if(/\.(md|txt|json|jsonl|csv|py|html|log|tex)$/i.test(item.path)){
    const b=el('button','보기');b.onclick=async()=>{try{
      const response=await request(query(project,item.path,true));if(!response.ok)throw Error('버전이 바뀌었습니다. 새로 고침하세요.');
      const text=await response.text();
      if(!$('detail').open){$('detail-title').textContent=item.path.split('/').pop();$('summary-label').textContent='파일 미리보기';$('detail-summary').textContent='저장된 파일의 내용입니다. 실행되지 않는 텍스트 미리보기입니다.';$('detail-meta').textContent=item.path+' · 버전 '+project.commit.slice(0,12);$('report').textContent='';$('detail-outputs').replaceChildren();$('detail').showModal();}
      $('preview').textContent=text;$('preview').hidden=false;
    }catch(e){$('error').textContent=e.message;}};row.append(b);
  }return row;
}
function detail(project,task){
  $('summary-label').textContent=task.kind==='coordination'?'조치 당시 요약':'제출 당시 요약';
  $('detail-title').textContent=taskTitle(task);$('detail-summary').textContent=summary(task);
  $('detail-meta').textContent=`현재 기록: ${roles[task.assignee]||task.assignee} · ${states[task.status]||task.status} · ${task.kind==='coordination'?'실제 총괄 실행 기록 · 감사 승인과 별개':'감사: '+task.audit} · ${task.id}`;
  $('report').textContent=task.report||'';$('report-detail').open=false;
  $('detail-outputs').replaceChildren(...(task.outputs||[]).map(o=>outputRow(project,o)));
  if(!task.outputs?.length)$('detail-outputs').append(el('p',task.kind==='coordination'?'총괄의 판단·배정 기록입니다. 문서 산출물 및 감사 결과는 해당 실무 카드에서 확인하세요.':'아직 저장된 결과 파일이 없습니다.','muted'));
  $('preview').hidden=true;$('detail').showModal();
}
function renderTasks(p){
  const items=p.tasks.filter(t=>!$('task-role').value||t.assignee===$('task-role').value).slice().sort((a,b)=>{
    const priority=t=>t.status==='running'?0:t.status==='ready'?1:2;
    return priority(a)-priority(b)||(b.updated||'').localeCompare(a.updated||'');
  });
  $('tasks').replaceChildren(...[['active','진행 중'],['attention','확인 필요'],['done','작업 완료']].map(([key,label])=>{
    const lane=el('section',undefined,'task-lane '+key);lane.dataset.bucket=key;
    const rows=items.filter(t=>taskBucket(p,t)===key),head=el('div',undefined,'lane-heading');
    head.append(el('h4',label),el('span',String(rows.length),'lane-count'));lane.append(head);
    const cards=el('div',undefined,'lane-cards');cards.append(...rows.map(t=>{
    const card=el('button',undefined,'card');card.dataset.kind=t.kind||'task';card.dataset.task=t.id;
    card.setAttribute('aria-label',taskTitle(t)+' · '+taskBadge(p,t)+' · 상세 보기');
    card.append(el('span',roles[t.assignee]||'작업','role-tag '+t.assignee));
    const text=el('div',undefined,'card-title');text.append(el('strong',taskTitle(t)),el('span',taskBadge(p,t),'task-state'));card.append(text);
    card.onclick=()=>detail(p,t);return card;
    }));if(!rows.length)cards.append(el('p','해당 작업 없음','lane-empty'));lane.append(cards);return lane;
  }));
}
function renderDocuments(p){
  const filter=$('file-search').value.trim().toLocaleLowerCase();
  const all=new Map((p.documents||[]).map(o=>[o.path,o]));for(const t of p.tasks)for(const o of t.outputs||[])all.set(o.path,o);
  const items=[...all.values()].filter(o=>!filter||o.path.toLocaleLowerCase().includes(filter)).sort((a,b)=>a.path.localeCompare(b.path));
  $('document-count').textContent=`파일 ${items.length}개 · 폴더를 펼쳐 확인하세요.`;
  const root={folders:new Map(),files:[]};
  for(const item of items){const parts=item.path.split('/');let node=root;for(const part of parts.slice(0,-1)){if(!node.folders.has(part))node.folders.set(part,{folders:new Map(),files:[]});node=node.folders.get(part);}node.files.push(item);}
  function tree(node,prefix=''){
    const children=[];for(const [name,sub] of node.folders){const path=prefix+name+'/',d=el('details',undefined,'folder');d.open=Boolean(filter)||openedFolders.has(p.id+':'+path);d.append(el('summary','▣ '+name));const body=el('div',undefined,'folder-body');body.append(...tree(sub,path));d.append(body);d.ontoggle=()=>{if(d.open)openedFolders.add(p.id+':'+path);else openedFolders.delete(p.id+':'+path);};children.push(d);}
    for(const item of node.files)children.push(outputRow(p,item,true));return children;
  }
  $('outputs').replaceChildren(...tree(root));if(!items.length)$('outputs').append(el('p',filter?'일치하는 파일이 없습니다.':'결과가 저장되면 파일이 나타납니다.','muted'));
}
function render(){
  const visible=data.projects.filter(p=>Boolean(p.test)===(view==='checks'));
  if(requested)selected=visible.find(p=>p.name===requested)?.id||null;else if(!visible.some(p=>p.id===selected))selected=visible[0]?.id||null;
  $('research-view').setAttribute('aria-pressed',String(view==='research'));$('checks-view').setAttribute('aria-pressed',String(view==='checks'));
  $('projects').replaceChildren(...visible.map(p=>{const b=el('button',p.display_name||p.name);b.setAttribute('aria-current',String(p.id===selected));b.append(el('small',`${p.project_label||(p.test?'설치 검증':'연구 프로젝트')} · ${p.tasks.filter(t=>t.kind!=='coordination').length}개 과제`));b.onclick=()=>{selected=p.id;requested=null;history.replaceState(null,'','?'+new URLSearchParams({view,project:p.name}));render();poll(true);};return b;}));
  $('workspace').textContent=data.workspace||'';const p=current();$('name').textContent=p?.display_name||p?.name||(view==='checks'?'설치 검증 기록이 없습니다':'연구 프로젝트가 없습니다');$('project-label').textContent=p?.project_label||(view==='checks'?'설치 검증':'연구 프로젝트');$('source').textContent=p?`${p.name} · ${p.path||''} · ${(p.commit||'').slice(0,12)} · ${p.source||''}`:'';$('error').textContent=p?.error||'';
  for(const id of ['tasks','approvals','outputs','metrics'])$(id).replaceChildren();$('approval-panel').hidden=true;
  if(!p){events=[];renderEvents();return;}
  const work=p.tasks.filter(t=>t.kind!=='coordination'),lead=p.tasks.filter(t=>t.kind==='coordination');
  for(const [label,count] of [['실무 과제',work.length],['총괄 조치',lead.length],['진행 중',p.tasks.filter(t=>t.status==='running').length],['내 확인',p.tasks.filter(t=>t.approval).length]])$('metrics').append(el('span',`${label} ${count}`,'metric'));
  renderTasks(p);renderDocuments(p);
  for(const t of p.tasks.filter(t=>t.approval)){const n=el('div',undefined,'notice');n.append(el('strong',taskTitle(t)),el('p',t.stop_reason||summary(t)));const b=el('button','요청 확인');b.onclick=()=>detail(p,t);n.append(b);$('approvals').append(n);$('approval-panel').hidden=false;}
  if(p.ledger_intact===false)$('error').textContent='작업 원장의 해시 체인이 일치하지 않습니다. 완료로 취급하지 말고 점검하세요.';
  $('export').href=api('api/log?'+new URLSearchParams({project:p.name,role:$('role').value,limit:'500'}));renderEvents();
}
function groups(rows){
  const result=[];for(const e of rows){let g=result.at(-1);if(!g||g.role!==e.role){g={role:e.role,rows:[]};result.push(g);}g.rows.push(e);}return result;
}
function renderEvents(){
  const p=current(),rows=p?events.filter(e=>e.project===p.name&&(!$('role').value||e.role===$('role').value)):[];
  const loading=Boolean(p&&activityLoadedScope!==p.id+':'+$('role').value);
  $('timeline').replaceChildren(...groups(rows).reverse().map(g=>{
    const first=g.rows[0],last=g.rows.at(-1),key=first.id,d=el('details',undefined,'activity-group');d.open=openedGroups.has(key);
    const failed=g.rows.filter(e=>e.state==='failed').length,s=el('summary');
    const stateLabel={done:'완료',running:'실행 중',waiting:'대기',failed:'실패',info:'기록'}[last.state]||'기록';
    s.append(el('strong',roles[g.role]||g.role),el('span',`${g.rows.length}건`,'badge'),el('span',failed?`${last.action} · 실패 ${failed}건`:last.action+' · '+stateLabel,'group-result'),el('time',new Date(first.time).toLocaleTimeString('ko-KR')+'–'+new Date(last.time).toLocaleTimeString('ko-KR'),'group-time'));d.append(s);
    const body=el('div',undefined,'group-events');for(const e of [...g.rows].reverse()){const row=el('div',undefined,'event '+e.state),time=el('time',new Date(e.time).toLocaleTimeString('ko-KR'));time.dateTime=e.time;const desc=el('div',(e.detail?e.detail+' — ':'')+e.result);desc.append(el('div',e.task+(e.tool?' · '+e.tool:''),'sub'));row.append(time,el('strong',e.action),desc);body.append(row);}d.append(body);d.ontoggle=()=>{if(d.open)openedGroups.add(key);else openedGroups.delete(key);};return d;
  }));if(!rows.length)$('timeline').append(el('p',loading?'담당별 기록을 조회 중입니다.':'이 담당의 기록이 아직 없습니다. 다른 담당을 선택하거나 새로 고침하세요.','muted'));
  $('event-count').textContent=loading?'기록 조회 중':`불러온 활동 ${rows.length}건 · ${moreEvents?'이전 기록 있음':'현재 조회 범위의 시작'}`;$('older').hidden=!moreEvents||loading;$('older').disabled=olderBusy;
}
function mergeEvents(rows){const all=new Map(events.map(e=>[e.id,e]));for(const e of rows)all.set(e.id,e);events=[...all.values()].sort((a,b)=>(a.time||'').localeCompare(b.time||'')||(a.id||'').localeCompare(b.id||''));}
async function loadActivity(older=false){
  const p=current();if(!p)return;const scope=p.id+':'+$('role').value;
  if(scope!==eventScope){eventScope=scope;events=[];nextCursor=null;moreEvents=false;}
  const q=new URLSearchParams({project:p.name,role:$('role').value,limit:'100'});if(older&&nextCursor)q.set('before',nextCursor);
  const response=await request(api('api/activity?'+q));if(!response.ok)throw Error('활동 기록을 불러오지 못했습니다.');const page=await response.json();if(scope!==eventScope)return;
  activityLoadedScope=scope;const wasEmpty=!events.length;mergeEvents(page.events||[]);if(older||wasEmpty){nextCursor=page.next_cursor;moreEvents=page.has_more===true;}renderEvents();
}
async function poll(force=false){
  if(busy)return;busy=true;try{
    if(force||Date.now()-lastSnapshot>5000){const r=await request(api('api/projects'));if(!r.ok)throw Error('작업 보드 응답 오류');data=await r.json();lastSnapshot=Date.now();render();const updated=Date.parse(data.service?.updated||'');const healthy=!data.service?.stopped&&Number.isFinite(updated)&&Date.now()-updated<30000&&data.service?.children?.length&&data.service.children.every(c=>c.state==='running');$('health').textContent=healthy?'연구팀 연결됨':'서비스 상태 확인 필요 · 저장 기록 표시';$('validation').textContent=data.validation?.passed?'설치 검증: 실제 S1·S2·S3 통과 기록 있음':'설치 검증: 현재 코드 기준 검증 미완료';}
    await loadActivity();$('updated').textContent='마지막 확인 '+new Date().toLocaleTimeString('ko-KR')+' · 읽기 전용 · 활동 2초 / 저장 결과 5초마다 확인';
  }catch(e){$('health').textContent='연결 끊김 · 마지막 표시';$('error').textContent=e.message;}finally{busy=false;}
}
function switchView(next){view=next;selected=null;requested=null;eventScope='';activityLoadedScope='';events=[];history.replaceState(null,'','?'+new URLSearchParams({view}));render();poll(true);}
$('research-view').onclick=()=>switchView('research');$('checks-view').onclick=()=>switchView('checks');$('refresh').onclick=()=>poll(true);$('close').onclick=()=>$('detail').close();
$('task-role').onchange=()=>{if(current())renderTasks(current());};$('file-search').oninput=()=>{if(current())renderDocuments(current());};
$('role').onchange=()=>{eventScope='';activityLoadedScope='';events=[];render();poll(true);};$('older').onclick=async()=>{if(olderBusy||!nextCursor)return;olderBusy=true;renderEvents();try{await loadActivity(true);}catch(e){$('error').textContent=e.message;}finally{olderBusy=false;renderEvents();}};
setInterval(()=>poll(),2000);poll(true);
