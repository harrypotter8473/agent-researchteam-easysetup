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
  assert.equal(node('tasks').children.length,3);
  assert.deepEqual(node('tasks').children.map(c=>c.dataset.bucket),['active','attention','done']);
  assert.equal(cards().length,2);
  assert.equal(node('name').textContent,'논문 비교 보고서');
  assert.equal(node('projects').children[0].textContent,'논문 비교 보고서');
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
  assert.equal(cards()[0].children[1].children.length,2); // name + status only, no report/summary inventory
  assert.equal(cards()[0].children[1].children[0].textContent,'총괄 후속 판단');
  node('file-search').value='result.docx';node('file-search').oninput();assert.match(node('document-count').textContent,/1개/);
  assert.ok(requests.every(r=>r.options.credentials==='same-origin'));
  const sequence=vm.runInContext("groups([{role:'research-scout'},{role:'research-scout'},{role:'research-reviewer'},{role:'research-scout'}]).map(g=>g.rows.length)",context);
  assert.deepEqual(Array.from(sequence),[2,1,1]);
  node('task-role').value='';
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
  console.log('PASS readable project names, three status lanes, title-only cards, full opened summaries, strict historical audit distinction, folders and authenticated history pagination');
})().catch(e=>{console.error(e);process.exitCode=1;});
