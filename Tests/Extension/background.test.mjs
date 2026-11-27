import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs/promises';import {webcrypto} from 'node:crypto';
async function fixture(nativeStatus={},restoreNeverFinishes=false,options={}){
 const calls=[],controls=[],listeners={},store={};let onMessage,timelineVisible=false,timelineReady=false,pageReading=false;
 const event=name=>({addListener:fn=>listeners[name]=fn});
 const api={storage:{local:{get:async()=>{if(options.storageFails)throw Error('invalid schema version');return restoreNeverFinishes?await new Promise(()=>{}):store;},set:async value=>{if(options.storageFails)throw Error('invalid schema version');return Object.assign(store,value);}}},runtime:{onMessage:{addListener:fn=>onMessage=fn},sendNativeMessage:async(app,request)=>{
  calls.push(request);
  if(request.command==='pageStart')return {ok:true,reading:pageReading=true};
  if(request.command==='pageStop')return {ok:true,reading:pageReading=false};
  if(request.command==='pageStatus')return {ok:true,reading:pageReading};
  if(request.command==='status')return {ok:true,running:true,voiceEnabled:true,...nativeStatus};
  if(request.command==='timelineForPage')return {ok:true,rows:[{id:'owned',japanese:'表示経路の試験'}],cursor:1,historySession:'native-session'};
  if(request.command==='timeline')return {ok:true,rows:[],cursor:0};return {ok:true};
 }},tabs:{get:async id=>({id,url:'https://example.test/webinar'}),query:async()=>[{id:7,url:'https://example.test/webinar',title:'Synthetic webinar'}],sendMessage:async()=>{throw Error('No message receiver');},onRemoved:event('removed'),onUpdated:event('updated'),onActivated:event('activated')},scripting:{executeScript:async request=>{if(options.scriptError)throw Error(options.scriptError);const control=request.args?.[0];
 if(control?.type==='captureStart' || control?.type==='captureStop'){
  const [frameId]=request.target.frameIds;
  controls.push({...control,frameId,tabId:request.target.tabId});
  return [{frameId,result:options.noController?undefined:{ok:true}}];
 }
 if(request.files?.includes('timeline.js')){
  if(options.timelineUnavailable)throw Error('No permission');
  timelineReady=true;
  return [];
 }
 if(request.func?.toString().includes('__rTranslateTimelineV2')){
  assert.deepEqual(Array.from(request.target.frameIds),[0]);
  if(timelineReady && typeof control==='boolean')timelineVisible=control;
  return [{frameId:0,result:{ready:timelineReady,visible:timelineVisible,fullscreen:options.fullscreen===true}}];
 }
 if(request.args)return [{frameId:0,result:{url:'https://example.test/webinar',text:'The system uses OAuth.'}}];return request.func?[{frameId:options.mediaFrame ?? 0,result:options.noMedia?[]:[{index:0,playing:true,area:100}]}]:[];}}};
 const context=vm.createContext({browser:api,URL,crypto:webcrypto,TextEncoder,setTimeout,clearTimeout,console});
 const protocol=new vm.SourceTextModule(await fs.readFile(new URL('../../SafariExtension/Resources/protocol.mjs',import.meta.url),'utf8'),{context});await protocol.link(()=>{});await protocol.evaluate();
 const background=new vm.SourceTextModule(await fs.readFile(new URL('../../SafariExtension/Resources/background.js',import.meta.url),'utf8'),{context});await background.link(()=>protocol);await background.evaluate();
 return {send:(r,s={})=>onMessage(r,s),calls,controls,listeners};
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
test('changing tabs keeps the original capture bound until that tab closes',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 assert.equal((await f.send({type:'voice'},{tab:{id:7},frameId:0})).ok,false);
 f.listeners.activated?.({tabId:8});await new Promise(resolve=>setImmediate(resolve));
 const session=f.calls.find(c=>c.command==='start').session;
 assert.equal(f.calls.some(c=>c.command==='stop'),false);
 assert.equal((await f.send({type:'pcm',session,sequence:1,pcm:'data'},{tab:{id:7},frameId:0})).ok,true);
 assert.equal((await f.send({type:'pcm',session,sequence:1,pcm:'data'},{tab:{id:8},frameId:0})).ok,false);
 f.listeners.removed(7);await new Promise(resolve=>setImmediate(resolve));
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
test('a blocked timeline reports its own failure and preserves active capture',async()=>{
 const options={timelineUnavailable:true};
 const f=await fixture({},false,options);
 const started=await f.send({type:'start',lookahead:true});
 assert.equal(started.ok,true);
 assert.equal(started.timelineVisible,false);
 assert.match(started.error,/タイムラインを表示できませんでした/);
 assert.equal((await f.send({type:'status'})).running,true);
 assert.equal(f.calls.some(c=>c.command==='stop'),false);
 options.timelineUnavailable=false;
 const retry=await f.send({type:'timeline',visible:true});
 assert.equal(retry.timelineVisible,true);
 assert.equal((await f.send({type:'status'})).error,undefined);
 await f.send({type:'stop'});
});

test('the sidebar reports that video fullscreen obscures it',async()=>{
 const f=await fixture({},false,{fullscreen:true});
 assert.equal((await f.send({type:'timeline',visible:true})).timelineFullscreen,true);
 assert.equal((await f.send({type:'status'})).timelineFullscreen,true);
 assert.equal((await f.send({type:'timeline',visible:false})).timelineFullscreen,false);
});

test('voice switch sends an explicit state, and preview is unavailable to page content',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 await f.send({type:'voice',enabled:false});assert.equal(f.calls.find(c=>c.command==='voice').enabled,false);
 assert.equal((await f.send({type:'preview'},{tab:{id:7},frameId:0})).ok,false);
 assert.equal(f.calls.filter(c=>c.command==='preview').length,0);
 await f.send({type:'stop'});assert.equal((await f.send({type:'preview'})).ok,true);
 const preview=f.calls.find(c=>c.command==='preview');assert.equal(preview.settings.speaker,2);assert.equal(preview.session,undefined);
});

test('legacy dictionary messages cannot read or overwrite pronunciation preferences',async()=>{
 const f=await fixture();await f.send({type:'start'});await new Promise(resolve=>setImmediate(resolve));
 for(const type of ['dictionaryGet','dictionarySave'])assert.equal((await f.send({type},{tab:{id:7},frameId:0})).ok,false);
 assert.equal(f.calls.filter(c=>c.command.startsWith('dictionary')).length,0);assert.equal((await f.send({type:'dictionaryGet'})).ok,false);await f.send({type:'stop'});
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

test('failed start remains visible through status refreshes until explicit retry',async()=>{
 const f=await fixture({},false,{noMedia:true});
 const failed=await f.send({type:'start'});assert.equal(failed.ok,false);
 for(let i=0;i<3;i++)assert.equal((await f.send({type:'status'})).error,failed.error);
 assert.equal(f.calls.filter(x=>x.command==='start').length,0);
 await f.send({type:'stop'});assert.equal((await f.send({type:'status'})).error,undefined);
});
test('Safari storage schema failures do not block native start, settings or stop',async()=>{
 const f=await fixture({},false,{storageFails:true});
 assert.equal((await f.send({type:'start'})).ok,true);await new Promise(resolve=>setImmediate(resolve));
 const state=await f.send({type:'status'});assert.equal(state.running,true);assert.match(state.storageNotice,/Safari/);
 assert.equal((await f.send({type:'settings',value:{speed:1.5}})).ok,true);
 assert.equal((await f.send({type:'stop'})).ok,true);assert.ok(f.calls.some(x=>x.command==='stop'));
});

test('page translation does not start capture and stops when its source tab navigates',async()=>{
 const f=await fixture();
 assert.equal((await f.send({type:'pageStart',mode:'translate'},{tab:{id:7},frameId:0})).ok,false);
 assert.equal((await f.send({type:'pageStart',mode:'translate'})).reading,true);
 const request=f.calls.find(x=>x.command==='pageStart');
 assert.equal(request.text,'The system uses OAuth.');
 assert.equal(request.mode,'translate');
 assert.equal(f.calls.some(x=>x.command==='pcm'||x.command==='start'),false);
 assert.equal((await f.send({type:'start'})).ok,false);
 f.listeners.updated(7,{status:'loading'});
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.calls.find(x=>x.command==='pageStop').session,request.session);
});

test('capture starts and stops in the detected video frame without a tab-message receiver',async()=>{
 const f=await fixture({},false,{mediaFrame:4});
 assert.equal((await f.send({type:'start'})).ok,true);
 await new Promise(resolve=>setImmediate(resolve));
 const session=f.calls.find(c=>c.command==='start').session;
 assert.deepEqual(f.controls[0],{type:'captureStart',session,index:0,frameId:4,tabId:7});
 assert.equal((await f.send({type:'captureReady',session},{tab:{id:7},frameId:4})).ok,true);
 await f.send({type:'stop'});
 assert.deepEqual(f.controls[1],{type:'captureStop',session,index:0,frameId:4,tabId:7});
});
test('a missing capture controller stops the native session and explains how to retry',async()=>{
 const f=await fixture({},false,{noController:true});
 await f.send({type:'start'});
 await new Promise(resolve=>setImmediate(resolve));
 const state=await f.send({type:'status'});
 assert.equal(state.running,false);
 assert.match(state.error,/動画フレームで音声取得を開始できませんでした.*再読み込み/);
 assert.equal(f.calls.filter(c=>c.command==='stop').length,1);
});

test('the lookahead clock and PCM origin travel only from the selected frame',async()=>{
 const f=await fixture({},false,{mediaFrame:4});
 assert.equal((await f.send({type:'start',lookahead:true,captions:true})).ok,true);
 await new Promise(resolve=>setImmediate(resolve));
 const start=f.calls.find(c=>c.command==='start');
 assert.equal(start.lookahead,true);
 assert.equal(f.controls[0].lookahead,true);
 assert.equal(f.controls[0].captions,true);
 const captions={type:'captureCaptions',session:start.session,cursor:2,historySession:'live'};
 assert.equal((await f.send(captions,{tab:{id:7},frameId:0})).ok,false);
 await f.send(captions,{tab:{id:7},frameId:4});
 assert.equal(f.calls.find(c=>c.command==='timeline').cursor,2);
 const beat={type:'captureHeartbeat',session:start.session,paused:true,clock:{position:45,serial:0}};
 assert.equal((await f.send(beat,{tab:{id:7},frameId:0})).ok,false);
 await f.send(beat,{tab:{id:7},frameId:4});
 await f.send({type:'pcm',session:start.session,mediaStart:45.002,sequence:0,pcm:'data'},{tab:{id:7},frameId:4});
 assert.equal(f.calls.find(c=>c.command==='heartbeat').clock.position,45);
 assert.equal(f.calls.find(c=>c.command==='pcm').mediaStart,45.002);
 await f.send({type:'stop'});
});
