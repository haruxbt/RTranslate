import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs/promises';import {webcrypto} from 'node:crypto';
async function fixture(nativeStatus={},restoreNeverFinishes=false){
 const calls=[],listeners={},store={};let onMessage,timelineVisible=false;
 const event=name=>({addListener:fn=>listeners[name]=fn});
 const api={storage:{local:{get:async()=>restoreNeverFinishes?await new Promise(()=>{}):store,set:async value=>Object.assign(store,value)}},runtime:{onMessage:{addListener:fn=>onMessage=fn},sendNativeMessage:async(app,request)=>{
  calls.push(request);if(request.command==='status')return {ok:true,running:true,voiceEnabled:true,...nativeStatus};
  if(request.command==='timelineForPage')return {ok:true,rows:[{id:'owned',japanese:'表示経路の試験'}],cursor:1,historySession:'native-session'};
  if(request.command==='timeline')return {ok:true,rows:[],cursor:0};return {ok:true};
 }},tabs:{get:async id=>({id,url:'https://example.test/webinar'}),query:async()=>[{id:7,url:'https://example.test/webinar',title:'Synthetic webinar'}],sendMessage:async(_id,r)=>{if(r.type==='timelineVisibility'){if(typeof r.visible==='boolean')timelineVisible=r.visible;return {ok:true,visible:timelineVisible};}return {ok:true};},onRemoved:event('removed'),onUpdated:event('updated'),onActivated:event('activated')},scripting:{executeScript:async request=>request.func?[{frameId:0,result:[{index:0,playing:true,area:100}]}]:[]}};
 const context=vm.createContext({browser:api,URL,crypto:webcrypto,setTimeout,console});
 const protocol=new vm.SourceTextModule(await fs.readFile(new URL('../../SafariExtension/Resources/protocol.mjs',import.meta.url),'utf8'),{context});await protocol.link(()=>{});await protocol.evaluate();
 const background=new vm.SourceTextModule(await fs.readFile(new URL('../../SafariExtension/Resources/background.js',import.meta.url),'utf8'),{context});await background.link(()=>protocol);await background.evaluate();
 return {send:(r,s={})=>onMessage(r,s),calls,listeners};
}
test('start binds current tab and enables native speech; foreign frames cannot send PCM',async()=>{
 const f=await fixture();assert.equal((await f.send({type:'start'})).ok,true);
 await new Promise(resolve=>setImmediate(resolve));
 const start=f.calls.find(c=>c.command==='start');assert.equal(start.url,'https://example.test/webinar');
 const bad=await f.send({type:'pcm',session:start.session,sequence:0,pcm:'bad'},{tab:{id:7},frameId:2});assert.equal(bad.ok,false);
 assert.equal(f.calls.filter(c=>c.command==='pcm').length,0);
 assert.equal((await f.send({type:'stop'})).ok,true);
 assert.ok(f.calls.some(c=>c.command==='stop'));
 assert.equal((await f.send({type:'timelineData',cursor:0},{tab:{id:7},frameId:0})).ok,true);
});
test('content scripts cannot invoke user controls; changing tabs stops the old session',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 assert.equal((await f.send({type:'voice'},{tab:{id:7},frameId:0})).ok,false);
 f.listeners.activated({tabId:8});await new Promise(resolve=>setImmediate(resolve));
 assert.ok(f.calls.some(c=>c.command==='stop'));
});

test('native no-audio status is visible instead of a stale translating message',async()=>{
 const f=await fixture({message:'取得中・15秒以上音声未検出：対象を確認'});await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 const start=f.calls.find(c=>c.command==='start');
 assert.equal((await f.send({type:'captureReady',session:start.session},{tab:{id:7},frameId:0})).ok,true);
 assert.equal((await f.send({type:'status'})).message,'動画の音声が届いていません。');
 await f.send({type:'stop'});
});

test('pause heartbeats are session and frame bound, and paused status is visible',async()=>{
 const f=await fixture({paused:true});await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 const session=f.calls.find(c=>c.command==='start').session;
 for(const [key,frame,paused] of [[session,2,true],['old',0,true],[session,0,'true']]){
  assert.equal((await f.send({type:'captureHeartbeat',session:key,paused},{tab:{id:7},frameId:frame})).ok,false);
 }
 assert.equal(f.calls.filter(c=>c.command==='heartbeat').length,0);
 assert.equal((await f.send({type:'captureHeartbeat',session,paused:true},{tab:{id:7},frameId:0})).ok,true);
 assert.equal((await f.send({type:'status'})).message,'動画の再生を待っています');
 await f.send({type:'stop'});
});

test('one start opens the timeline; hiding it never stops native translation and next start reopens it',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 assert.equal((await f.send({type:'status'})).timelineVisible,true);
 assert.equal((await f.send({type:'timeline',visible:false})).timelineVisible,false);
 assert.equal(f.calls.filter(c=>c.command==='stop').length,0);
 await f.send({type:'stop'});await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 assert.equal((await f.send({type:'status'})).timelineVisible,true);await f.send({type:'stop'});
});
test('voice switch sends an explicit state, and preview is unavailable to page content',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 await f.send({type:'voice',enabled:false});assert.equal(f.calls.find(c=>c.command==='voice').enabled,false);
 assert.equal((await f.send({type:'preview'},{tab:{id:7},frameId:0})).ok,false);
 assert.equal(f.calls.filter(c=>c.command==='preview').length,0);
 await f.send({type:'stop'});assert.equal((await f.send({type:'preview'})).ok,true);
 const preview=f.calls.find(c=>c.command==='preview');assert.equal(preview.settings.speaker,2);assert.equal(preview.session,undefined);
});

test('page content cannot read or overwrite dictionaries',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 for(const type of ['dictionaryGet','dictionarySave'])assert.equal((await f.send({type},{tab:{id:7},frameId:0})).ok,false);
 assert.equal(f.calls.filter(c=>c.command.startsWith('dictionary')).length,0);assert.equal((await f.send({type:'dictionaryGet'})).ok,true);await f.send({type:'stop'});
});
test('webpage cannot invoke asset management or uninstall',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 for(const type of ['assetsStatus','assetsPrepare','uninstallReview','uninstall'])assert.equal((await f.send({type,selection:{models:true}},{tab:{id:7},frameId:0})).ok,false);
 assert.equal(f.calls.filter(x=>x.command.startsWith('uninstall')).length,0);await f.send({type:'stop'});
});

test('timeline uses the actual sender page even without background capture state',async()=>{
 const f=await fixture();
 const result=await f.send({type:'timelineData',url:'https://attacker.invalid/',cursor:0},{tab:{id:7,url:'https://example.test/webinar'},frameId:0});
 assert.equal(result.rows[0].japanese,'表示経路の試験');
 const call=f.calls.find(c=>c.command==='timelineForPage');assert.equal(call.url,'https://example.test/webinar');
 assert.equal(f.calls.filter(c=>c.command==='start'||c.command==='pcm').length,0);
 assert.equal((await f.send({type:'timelineData'},{tab:{id:7,url:'https://example.test/webinar'},frameId:2})).ok,false);
});
test('Safari missing frame ID requires a matching sender URL for a read-only timeline',async()=>{
 const f=await fixture();
 assert.equal((await f.send({type:'timelineData'},{tab:{id:7,url:'https://example.test/webinar'},url:'https://example.test/webinar'})).ok,true);
 assert.equal((await f.send({type:'timelineData'},{tab:{id:7,url:'https://example.test/webinar'},url:'https://other.invalid/'})).ok,false);
});

test('timeline lookup does not wait for capture storage restoration',async()=>{
 const f=await fixture({},true);
 const result=await Promise.race([f.send({type:'timelineData'},{tab:{id:7,url:'https://example.test/webinar'},frameId:0}),new Promise((_,reject)=>setTimeout(()=>reject(Error('timeline blocked by capture restoration')),100))]);
 assert.equal(result.rows[0].id,'owned');
});

test('native settings links and shared playback writes are restricted to extension controls',async()=>{
 const f=await fixture();
 assert.equal((await f.send({type:'openAppSettings',page:'dictionary'})).ok,true);
 assert.equal(f.calls.find(c=>c.command==='openSettings').page,'dictionary');
 assert.equal((await f.send({type:'openAppSettings',page:'unknown'})).ok,false);
 assert.equal((await f.send({type:'openAppSettings',page:'support'},{tab:{id:7,url:'https://example.test/webinar'},frameId:0})).ok,false);
 await f.send({type:'settings',value:{backend:'Apple',speechEngine:'Apple',smooth:false,volume:40,speed:1.5,speaker:2}});
 const saved=f.calls.find(c=>c.command==='playbackSave');assert.equal(saved.settings.backend,'Apple');assert.equal(saved.settings.speechEngine,'Apple');assert.equal(saved.settings.smooth,false);
 assert.equal(f.calls.filter(c=>c.command==='start').length,0);
});
