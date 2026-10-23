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
const project={id:'p',name:'report',path:'workspace/report',commit:'a'.repeat(40),test:false,ledger_intact:true,tasks:[
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
(async()=>{
  await settle();
  assert.equal(node('tasks').children.length,2);
  const card=node('tasks').children.find(c=>c.dataset.task==='scout-01');card.onclick();
  assert.equal(node('detail-summary').textContent,'원문 5편의 근거를 추출했습니다.');
  assert.equal(node('detail').open,true);assert.equal(node('report-detail').open,false);
  node('close').onclick();assert.equal(node('detail').open,false);
  assert.equal(node('timeline').children.length,1);assert.equal(node('timeline').children[0].open,false);
  assert.ok(node('outputs').children.every(x=>x.tagName==='details'));
  node('role').value='research-scout';node('role').onchange();await settle();
  assert.ok(requests.some(r=>r.url.includes('role=research-scout')));
  await node('older').onclick();await settle();
  assert.match(node('event-count').textContent,/3건/);assert.equal(node('older').hidden,true);
  node('task-role').value='research-lead';node('task-role').onchange();assert.equal(node('tasks').children.length,1);assert.equal(node('tasks').children[0].dataset.kind,'coordination');
  node('file-search').value='result.docx';node('file-search').oninput();assert.match(node('document-count').textContent,/1개/);
  assert.ok(requests.every(r=>r.options.credentials==='same-origin'));
  const sequence=vm.runInContext("groups([{role:'research-scout'},{role:'research-scout'},{role:'research-reviewer'},{role:'research-scout'}]).map(g=>g.rows.length)",context);
  assert.deepEqual(Array.from(sequence),[2,1,1]);
  node('task-role').value='';
  context.sortFixture=[
    {id:'old-failure',kind:'coordination',assignee:'research-lead',status:'failed',updated:'2026-10-21T12:00:00Z'},
    {id:'latest-result',kind:'coordination',assignee:'research-lead',status:'done',updated:'2026-10-22T12:00:00Z'},
    {id:'unresolved-task',kind:'task',assignee:'research-worker',status:'failed',updated:'2026-10-21T10:00:00Z'},
    {id:'active',kind:'task',assignee:'research-scout',status:'running',updated:'2026-10-21T09:00:00Z'}
  ];
  vm.runInContext('renderTasks({tasks:sortFixture})',context);
  assert.deepEqual(node('tasks').children.map(c=>c.dataset.task),['active','unresolved-task','latest-result','old-failure']);
  assert.ok(!source.includes('innerHTML'));assert.ok(!source.includes('eval('));
  console.log('PASS compact cards, top summary, actual lead distinction, folders, role-first HTTP pagination, older history, consecutive groups and authenticated text-only requests');
})().catch(e=>{console.error(e);process.exitCode=1;});
