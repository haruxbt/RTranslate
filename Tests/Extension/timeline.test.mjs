import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs/promises';
const source=await fs.readFile(new URL('../../SafariExtension/Resources/timeline.js',import.meta.url),'utf8');
async function fixture(){
 class Element{
  constructor(tag){this.tag=tag;this.children=[];this.attributes={};this.handlers={};this.clientHeight=600;this.scrollHeight=1200;this.offsetTop=0;this.scrollTop=0;}
  get isConnected(){return this.root || Boolean(this.parent?.isConnected);}
  append(...children){for(const child of children){child.remove?.();this.children.push(child);child.parent=this;}}
  remove(){if(this.parent)this.parent.children=this.parent.children.filter(x=>x!==this);this.parent=null;}
  attachShadow(){const shadow=new Element('shadow');this.append(shadow);return shadow;}
  setAttribute(k,v){this.attributes[k]=v;}removeAttribute(k){delete this.attributes[k];}
  addEventListener(k,v){this.handlers[k]=v;}
 }
 const root=new Element('html');root.root=true;let listener,tick;const calls=[];let response={ok:true,rows:[{id:'a',japanese:'同じ訳を二重に表示しません。',receivedAt:1794567800}],cursor:1,historySession:'s',speakingID:'a',pending:true};
 const document={documentElement:root,createElement:tag=>new Element(tag),getElementById:id=>walk(root).find(x=>x.id===id)};
 const context=vm.createContext({document,console,Date,addEventListener(){},setTimeout(fn){tick=fn;return 1;},clearTimeout(){},browser:{runtime:{getURL:p=>p,onMessage:{addListener:fn=>listener=fn},sendMessage:async r=>{calls.push(r);return response;}}}});
 vm.runInContext(source,context);return {root,calls,next:async value=>{response=value;await tick();},send:r=>listener(r),inject:()=>vm.runInContext(source,context)};
}
function walk(node){return [node,...node.children.flatMap(walk)];}
test('closing timeline reports OFF, retains history, and leaves translation untouched',async()=>{
 const f=await fixture();assert.equal((await f.send({type:'timelineVisibility'})).visible,false);
 await f.send({type:'timelineVisibility',visible:true});await new Promise(resolve=>setImmediate(resolve));
 assert.equal((await f.send({type:'timelineVisibility'})).visible,true);
 const close=walk(f.root).find(e=>e.attributes['aria-label']==='タイムラインを閉じる');close.onclick();
 assert.equal((await f.send({type:'timelineVisibility'})).visible,false);
 assert.ok(f.calls.every(r=>r.type==='timelineData'));
 f.inject();assert.equal((await f.send({type:'timelineVisibility'})).visible,false);
 await f.send({type:'timelineVisibility',visible:true});await new Promise(resolve=>setImmediate(resolve));
 assert.equal(walk(f.root).filter(e=>e.tag==='article').length,1);
 assert.equal(walk(f.root).filter(e=>e.attributes['aria-current']==='true').length,1);
 assert.equal(walk(f.root).filter(e=>e.className==='current').length,0);
});

test('idle gaps and queued translations preserve the last spoken anchor',async()=>{
 const f=await fixture();await f.send({type:'timelineVisibility',visible:true});await new Promise(resolve=>setImmediate(resolve));
 const history=walk(f.root).find(e=>e.className==='history'),a=walk(f.root).find(e=>e.tag==='article');a.offsetTop=600;
 await f.next({ok:true,rows:[],speakingID:'a'});assert.equal(history.scrollTop,270);
 await f.next({ok:true,rows:[{id:'b',japanese:'次の訳です。'}],speakingID:'',pending:false});
 const b=walk(f.root).filter(e=>e.tag==='article')[1];b.offsetTop=900;
 assert.equal(history.scrollTop,270);assert.equal(a.attributes['aria-current'],undefined);
 await f.next({ok:true,rows:[],speakingID:''});assert.equal(history.scrollTop,270);
 await f.next({ok:true,rows:[],speakingID:'b'});assert.equal(history.scrollTop,570);assert.equal(b.offsetTop-history.scrollTop,330);
});

test('a new capture session replaces displayed rows without deleting saved history',async()=>{
 const f=await fixture();await f.send({type:'timelineVisibility',visible:true});await new Promise(resolve=>setImmediate(resolve));
 await f.next({ok:true,rows:[{id:'new',japanese:'別のページの訳'}],historySession:'new-session',cursor:1,speakingID:''});
 const articles=walk(f.root).filter(e=>e.tag==='article');assert.equal(articles.length,1);
 assert.ok(walk(articles[0]).some(e=>e.textContent==='別のページの訳'));assert.equal(walk(f.root).find(e=>e.className==='history').scrollTop,0);
 assert.ok(f.calls.every(r=>r.type==='timelineData'));
});
