'use strict';
// Executes the real UI with a small DOM and HTTP fixtures. No models or servers.
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),assert=require('node:assert/strict');
class Element {
  constructor(tag='div'){this.tagName=tag;this.children=[];this.dataset={};this.attributes={};this.value='';this.hidden=false;this.open=false;this.textContent='';}
  append(...items){this.children.push(...items);}
  replaceChildren(...items){this.children=[...items];}
  setAttribute(k,v){this.attributes[k]=v;}
  showModal(){this.open=true;}
  close(){this.open=false;}
  get childElementCount(){return this.children.length;}
}
const nodes=new Map(),requests=[];
const node=id=>{if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id);};
const project={id:'p',name:'report',display_name:'논문 비교 보고서',project_label:'연구 프로젝트',path:'workspace/report',commit:'a'.repeat(40),test:false,ledger_intact:true,tasks:[
  {id:'scout-01',assignee:'research-scout',kind:'task',title:'자료 조사',status:'done',summary:'원문 5편의 근거를 추출했습니다.',report:'Full saved report',audit:'통과（현재 버전）',outputs:[{path:'sources/a.md',available:true}]},
  {id:'lead-1',assignee:'research-lead',kind:'coordination',title:'후속 판단',status:'done',summary:'독립 감사를 배정했습니다.',report:'Actual execution events',outputs:[]}
],documents:[{path:'reports/result.docx',available:true},{path:'sources/a.md',available:true}]};
const event=(id,role='research-scout')=>({id,time:'2026-10-22T12:00:00Z',project:'report',task:'scout-01',role,action:'검색',result:'완료',state:'done'});
const context=vm.createContext({URL,URLSearchParams,console,Date,Map,Set,Error,location:{href:'http://127.0.0.1:12345/',search:''},history:{replaceState(){}},setInterval(){},document:{getElementById:node,createElement:t=>new Element(t)},fetch:async(url,options)=>{
  requests.push({url,options});const u=new URL(url);let payload;
  if(u.pathname.endsWith('/api/projects'))payload={projects:[project],workspace:'workspace',service:{updated:new Date().toISOString(),children:[{state:'running'}]}};
  else if(u.pathname.endsWith('/api/activity'))payload=u.searchParams.has('before')?{events:[event('old')],has_more:false,next_cursor:null}:{events:[event('a'),event('b')],has_more:true,next_cursor:'cursor'};
  else return {ok:true,text:async()=>'saved text'};
  return {ok:true,json:async()=>JSON.parse(JSON.stringify(payload))};
}});
const source=fs.readFileSync(path.join(__dirname,'../team/shared/board-ui/app.js'),'utf8');
vm.runInContext(source,context);
const settle=async()=>{for(let n=0;n<5;n++)await new Promise(resolve=>setImmediate(resolve));};
const cards=()=>node('tasks').children.flatMap(lane=>lane.children[1].children).filter(c=>c.dataset.task);
(async()=>{
  await settle();
  assert.equal(node('tasks').children.length,4);
  assert.deepEqual(node('tasks').children.map(c=>c.dataset.bucket),['waiting','active','attention','done']);
  assert.equal(cards().length,2);
  assert.equal(node('name').textContent,'논문 비교 보고서');
  assert.equal(node('projects').children[0].textContent,'논문 비교 보고서');
  for(const [code,title] of [['s1','문헌검토 보고서'],['s2','자료 분석 보고서'],['s3','내부 웹 보고서']]){
    context.legacyProject={name:'da76809ff19d-'+code,test:true};
    assert.equal(vm.runInContext('projectTitle(legacyProject)',context),title);
    assert.equal(vm.runInContext('projectLabel(legacyProject)',context),'설치 검증 '+code.toUpperCase());
    assert.equal(context.legacyProject.name,'da76809ff19d-'+code);
  }
  assert.equal(vm.runInContext('projectTitle({name:"reports",test:false})',context),'연구 보고서');
  assert.equal(vm.runInContext('projectTitle({name:"actual-s1",test:false})',context),'actual-s1');
  assert.equal(vm.runInContext('projectTitle({name:"actual-s1",test:true,display_name:"사용자 지정 이름"})',context),'사용자 지정 이름');
  const card=cards().find(c=>c.dataset.task==='scout-01');card.onclick();
  assert.equal(node('detail-summary').textContent,'원문 5편의 근거를 추출했습니다.');
  assert.equal(node('detail').open,true);assert.equal(node('report-detail').open,false);
  node('close').onclick();assert.equal(node('detail').open,false);
  assert.equal(node('timeline').children.length,1);assert.equal(node('timeline').children[0].open,false);
  assert.ok(node('outputs').children.every(x=>x.tagName==='details'));
  node('role').value='research-scout';node('role').onchange();
  assert.equal(node('event-count').textContent,'기록 조회 중');
  await settle();
  assert.ok(requests.some(r=>r.url.includes('role=research-scout')));
  await node('older').onclick();await settle();
  assert.match(node('event-count').textContent,/3건/);assert.equal(node('older').hidden,true);
  node('task-role').value='research-lead';node('task-role').onchange();assert.equal(cards().length,1);assert.equal(cards()[0].dataset.kind,'coordination');
  assert.equal(cards()[0].children.length,1); // one visible title, all other text belongs in detail
  assert.equal(cards()[0].children[0].textContent,'총괄 후속 판단');
  node('file-search').value='result.docx';node('file-search').oninput();assert.match(node('document-count').textContent,/1개/);
  assert.ok(requests.every(r=>r.options.credentials==='same-origin'));
  const sequence=vm.runInContext("groups([{role:'research-scout'},{role:'research-scout'},{role:'research-reviewer'},{role:'research-scout'}]).map(g=>g.rows.length)",context);
  assert.deepEqual(Array.from(sequence),[2,1,1]);
  node('task-role').value='';
  const suppliedSummary='작성 산출물 v1을 관리자 검토용으로 반환합니다. 요청 전체 완료·전달 승인은 아닙니다. · 크기: 46,371 bytes';
  context.moveFixture={id:'move-project',tasks:[{id:'worker-01',assignee:'research-worker',kind:'task',title:'분석·보고서',status:'ready',summary:suppliedSummary,audit:'미통과',outputs:[]}]};
  const laneFor=id=>node('tasks').children.find(lane=>lane.children[1].children.some(c=>c.dataset.task===id))?.dataset.bucket;
  vm.runInContext('renderTasks(moveFixture)',context);
  const movingCard=cards()[0];
  assert.equal(movingCard.children.length,1);assert.equal(movingCard.children[0].textContent,'분석 보고서');
  assert.equal(laneFor('worker-01'),'waiting');
  for(const [status,lane] of [['running','active'],['blocked','attention'],['done','done']]){
    context.moveFixture.tasks[0].status=status;
    vm.runInContext('renderTasks(moveFixture)',context);
    assert.equal(laneFor('worker-01'),lane);assert.equal(cards().length,1);assert.equal(cards()[0],movingCard);
  }
  movingCard.onclick();
  assert.equal(node('detail-title').textContent,'분석 보고서');
  assert.equal(node('detail-summary').textContent,suppliedSummary);
  assert.match(node('detail-meta').textContent,/분석 · 완료 · 감사: 미통과/);
  assert.ok(!movingCard.children.some(c=>c.textContent.includes('46,371')));
  for(const [patch,lane] of [[{status:'ready',approval:true},'attention'],[{status:'failed',approval:false},'attention'],[{status:'partial'},'attention'],[{status:'unknown'},'attention'],[{status:'ready'},'waiting']]){
    Object.assign(context.moveFixture.tasks[0],patch);vm.runInContext('renderTasks(moveFixture)',context);
    assert.equal(laneFor('worker-01'),lane);assert.equal(cards()[0],movingCard);
  }
  context.moveFixture.tasks=[];vm.runInContext('renderTasks(moveFixture)',context);
  assert.equal(cards().length,0);assert.equal(vm.runInContext('taskCards.size',context),0);
  context.sortFixture=[
    {id:'old-failure',origin_task:'same-work',kind:'coordination',assignee:'research-lead',status:'failed',updated:'2026-10-21T12:00:00Z'},
    {id:'latest-result',origin_task:'same-work',kind:'coordination',assignee:'research-lead',status:'done',updated:'2026-10-22T12:00:00Z'},
    {id:'unresolved-task',kind:'task',assignee:'research-worker',status:'failed',updated:'2026-10-21T10:00:00Z'},
    {id:'active',kind:'task',assignee:'research-scout',status:'running',updated:'2026-10-21T09:00:00Z'}
  ];
  vm.runInContext('renderTasks({tasks:sortFixture})',context);
  assert.deepEqual(cards().map(c=>c.dataset.task),['active','unresolved-task','latest-result','old-failure']);
  context.reviewFixture={tasks:[
    {id:'middle-reject',assignee:'research-reviewer',status:'done',verdict:'reject',audit_scope:'intermediate',audit_of:['source'],updated:'2026-10-21'},
    {id:'final-pass',assignee:'research-reviewer',status:'done',verdict:'pass',audit:'통과（현재 버전）',audit_scope:'final',audit_of:['source'],updated:'2026-10-22'}
  ]};
  assert.equal(vm.runInContext('taskBucket(reviewFixture,reviewFixture.tasks[0])',context),'attention');
  context.reviewFixture.tasks.push({...context.reviewFixture.tasks[1],id:'middle-pass',audit_scope:'intermediate',updated:'2026-10-23'});
  assert.equal(vm.runInContext('taskBucket(reviewFixture,reviewFixture.tasks[0])',context),'done');
  assert.equal(context.reviewFixture.tasks[0].verdict,'reject');
  const longSummary='검증된 근거를 보존하고 비교한 내용입니다. '.repeat(25)+'마지막 주의사항도 그대로 표시합니다.';
  context.longSummary=longSummary;
  vm.runInContext('detail(current(),{assignee:"research-worker",status:"done",summary:longSummary,outputs:[]})',context);
  assert.equal(node('detail-summary').textContent,longSummary);
  assert.equal(node('summary-label').textContent,'제출 당시 요약');
  assert.match(node('detail-meta').textContent,/현재 기록:/);
  assert.ok(!source.includes('innerHTML'));assert.ok(!source.includes('eval('));
  for(const name of ['app.js','app.css','index.html'])assert.equal(fs.readFileSync(path.join(__dirname,'../plugins/research-board/server/board-ui',name),'utf8'),fs.readFileSync(path.join(__dirname,'../team/shared/board-ui',name),'utf8'),'Mattermost embedded UI drift: '+name);
  console.log('PASS compact title-only four-lane Kanban, queue/running separation, fail-closed states, same-card movement, full details, audit distinction and embedded UI parity');
})().catch(e=>{console.error(e);process.exitCode=1;});
