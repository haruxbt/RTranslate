import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs/promises';
async function fixture(options={}){
 class Element{constructor(){this.value='';this.checked=false;this.disabled=false;this.attributes={};this.children=[];this.textContent='';}focus(){this.focused=true;}append(...x){this.children.push(...x);}replaceChildren(){this.children=[];}setAttribute(k,v){this.attributes[k]=v;}}
 const html=await fs.readFile(new URL('../../SafariExtension/Resources/popup.html',import.meta.url),'utf8'),ids=new Set([...html.matchAll(/id="([^"]+)"/g)].map(x=>x[1]));
 const elements=new Map(),calls=[];const get=id=>{assert.ok(ids.has(id),'Missing popup element: '+id);if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
 let model={running:false,voiceEnabled:false,timelineVisible:false,host:'example.test',effectiveSpeed:1.75};
 const context=vm.createContext({document:{getElementById:get,createElement:()=>new Element(),body:{dataset:{}}},setInterval(){},console,browser:{storage:{local:{get:async()=>{if(options.storageFails)throw Error('invalid schema version');return {settings:{speaker:14,volume:80,speed:1.2,autoSpeed:false}};}}},runtime:{sendMessage:async request=>{
  calls.push(request);if(request.type==='start')Object.assign(model,{running:true,voiceEnabled:true,timelineVisible:true});
  if(request.type==='stop')Object.assign(model,{running:false,voiceEnabled:false});
  if(request.type==='voice')model.voiceEnabled=request.enabled;if(request.type==='timeline')model.timelineVisible=request.visible;
  if(request.type==='pageStart')return {ok:true,reading:true};
  if(request.type==='pageStop')return {ok:true,reading:false};
  if(request.type==='preview')return {ok:true,message:'試聴しています'};
  return {ok:true,...model};
 }}}});
 const protocol=new vm.SourceTextModule(await fs.readFile(new URL('../../SafariExtension/Resources/protocol.mjs',import.meta.url),'utf8'),{context});await protocol.link(()=>{});await protocol.evaluate();
 const popup=new vm.SourceTextModule(await fs.readFile(new URL('../../SafariExtension/Resources/popup.js',import.meta.url),'utf8'),{context});await popup.link(()=>protocol);await popup.evaluate();return {get,calls};
}
test('popup restores settings and one start enables speech and timeline independently',async()=>{
 const f=await fixture(),g=f.get;assert.equal(Number(g('speaker').value),14);assert.equal(g('speed-value').textContent,'1.2×');assert.equal(g('voice').disabled,true);
 await g('translate').onclick();assert.equal(g('voice').attributes['aria-checked'],'true');assert.equal(g('timeline').attributes['aria-checked'],'true');
 await g('voice').onclick();await g('timeline').onclick();assert.equal(g('voice').attributes['aria-checked'],'false');assert.equal(g('timeline').attributes['aria-checked'],'false');assert.equal(g('translate-label').textContent,'翻訳停止');
 await g('translate').onclick();assert.equal(g('translate-label').textContent,'翻訳開始');
});
test('volume numeric entry and preset speed reach settings; preview uses the current choice',async()=>{
 const f=await fixture(),g=f.get;g('volume-number').value='25';g('volume-number').oninput();assert.equal(Number(g('volume').value),25);
 g('speed').value='4';g('speaker').value='52';g('speed').onchange();await new Promise(resolve=>setImmediate(resolve));
 const last=f.calls.filter(x=>x.type==='settings').at(-1);assert.equal(last.value.volume,25);assert.equal(last.value.speed,1.4);assert.equal(last.value.speaker,52);assert.equal(last.value.autoSpeed,false);
 await g('preview').onclick();assert.equal(g('preview-status').textContent,'試聴しています');assert.ok(f.calls.some(x=>x.type==='preview'));
});

test('dictionary and slide buttons open the matching native settings page',async()=>{
 const f=await fixture(),g=f.get;
 await g('settings-dictionary').onclick();await g('settings-slides').onclick();
 assert.deepEqual(f.calls.filter(x=>x.type==='openAppSettings').map(x=>x.page),['dictionary','slides']);
 assert.equal(f.calls.filter(x=>x.type==='dictionarySave').length,0);
});
test('gear opens separate settings and back restores the popup',async()=>{
 const f=await fixture(),g=f.get;g('open-settings').onclick();assert.equal(g('main-page').hidden,true);assert.equal(g('settings-page').hidden,false);
 await new Promise(resolve=>setImmediate(resolve));assert.ok(f.calls.some(x=>x.type==='playbackGet'));
 g('close-settings').onclick();assert.equal(g('settings-page').hidden,true);assert.equal(g('main-page').hidden,false);
 assert.equal(f.calls.filter(x=>x.type==='uninstall').length,0);
});

test('opening the popup uses a neutral root instead of focusing details',async()=>{
 const f=await fixture();assert.equal(f.get('popup-root').focused,true);assert.notEqual(f.get('backend').focused,true);
});

test('engine and smoothing choices are saved and cannot switch during capture',async()=>{
 const f=await fixture(),g=f.get;g('backend').value='Apple';g('speech-engine').value='Apple';g('smooth').checked=false;g('backend').onchange();await new Promise(resolve=>setImmediate(resolve));
 const value=f.calls.filter(x=>x.type==='settings').at(-1).value;assert.equal(value.backend,'Apple');assert.equal(value.speechEngine,'Apple');assert.equal(value.smooth,false);
 await g('translate').onclick();assert.equal(g('backend').disabled,true);assert.equal(g('speech-engine').disabled,true);
});

test('popup initializes controls even when Safari storage is unavailable',async()=>{
 const f=await fixture({storageFails:true});assert.equal(f.get('translate-label').textContent,'翻訳開始');
 assert.ok(f.calls.some(x=>x.type==='playbackGet'));await f.get('translate').onclick();assert.equal(f.get('translate-label').textContent,'翻訳停止');
});

test('page mode defaults to Japanese translation and can still read original text',async()=>{
 const f=await fixture(),g=f.get;
 g('page-tab').onclick();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(g('page-panel').hidden,false);
 assert.equal(g('video-panel').hidden,true);
 assert.equal(g('page-mode').value,'translate');
 await g('page-read').onclick();
 assert.equal(f.calls.find(x=>x.type==='pageStart').mode,'translate');
 assert.equal(g('page-read-label').textContent,'読み上げ停止');
 await g('page-read').onclick();
 assert.equal(g('page-read-label').textContent,'読み上げ開始');
 g('page-mode').value='original';
 await g('page-read').onclick();
 assert.equal(f.calls.filter(x=>x.type==='pageStart').at(-1).mode,'original');
});
