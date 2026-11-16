import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs/promises';
const source=await fs.readFile(new URL('../../SafariExtension/Resources/capture.js',import.meta.url),'utf8');
const discoverySource=await fs.readFile(new URL('../../SafariExtension/Resources/media-discovery.js',import.meta.url),'utf8');
const workletSource=await fs.readFile(new URL('../../SafariExtension/Resources/audio-worklet.js',import.meta.url),'utf8');
function fixture(src='https://example.test/video.mp4',failModule=false,needsGesture=false,options={}){
 const listeners=[],contexts=[],packets=[],modules=new Map(),timers=new Set();const events=new Map(),fetches=[];let cors=null;
 const media={currentSrc:src,currentTime:17,paused:true,loadCount:0,mediaKeys:options.protected?{}:null,
  getAttribute:()=>cors,setAttribute:(_key,value)=>{cors=value;},removeAttribute:()=>{cors=null;},
  addEventListener:(name,listener)=>{if(!events.has(name))events.set(name,new Set());events.get(name).add(listener);},
  removeEventListener:(name,listener)=>events.get(name)?.delete(listener),
  load(){this.loadCount++;this.currentTime=0;const name=this.loadCount===options.failLoad?'error':'loadedmetadata';queueMicrotask(()=>{for(const fn of [...(events.get(name)||[])])fn();});},
  async play(){this.paused=false;}
 };Object.defineProperty(media,'crossOrigin',{get:()=>cors,set:value=>{cors=value;}});let Processor,workletScope,trusted=false,activationButton,hlsStops=0;
 function element(){return {style:{},isConnected:true,attachShadow(){return {append:button=>{activationButton=button;}};},remove(){this.isConnected=false;}};}
 class ModuleBlob {constructor(parts){this.code=parts.join('');}}
 class ModuleURL extends URL {static createObjectURL(blob){modules.set('blob:test',blob.code);return 'blob:test';}static revokeObjectURL(url){modules.delete(url);}}
 class AudioContext{
  constructor(){this.state='suspended';this.sampleRate=48000;this.currentTime=0;this.destination={};this.connections=[];contexts.push(this);
   this.audioWorklet={addModule:async url=>{
    if(failModule)throw Error('module blocked');
    workletScope=vm.createContext({AudioWorkletProcessor:class{constructor(){this.port={onmessage:null,postMessage:value=>{this.output?.(value);}};}},Float32Array,currentFrame:0,registerProcessor:(_name,constructor)=>{Processor=constructor;}});
    assert.equal(url,'safari-web-extension://test/audio-worklet.js');vm.runInContext(workletSource,workletScope);
   }};
  }
  createMediaElementSource(){const graph=this;return {connect(destination){graph.connections.push(destination);},disconnect(destination){graph.connections=graph.connections.filter(d=>d!==destination);}};}
  async resume(){if(needsGesture&&!trusted)return new Promise(()=>{});this.state='running';}async close(){this.state='closed';}
 }
 class AudioWorkletNode {
  constructor(context){this.worker=new Processor();this.port={onmessage:null,postMessage:value=>this.worker.port.onmessage({data:value}),close(){}};this.worker.output=value=>this.port.onmessage?.({data:value});context.processor=this;this.context=context;this.onprocessorerror=null;}
  connect(){} disconnect(){}
  render(channels){workletScope.currentFrame=Math.round(this.context.currentTime*this.context.sampleRate);const active=this.worker.process([channels],[[new Float32Array(channels[0].length)]]);this.context.currentTime+=channels[0].length/this.context.sampleRate;return active;}
 }
 const shadow={querySelectorAll:selector=>selector==='video,audio'?[media]:[]};
 const context=vm.createContext({AudioContext,AudioWorkletNode,URL:ModuleURL,Blob:ModuleBlob,location:{href:'https://example.test/',origin:'https://example.test'},document:{querySelectorAll:selector=>options.shadow?(selector==='video,audio'?[]:[{shadowRoot:shadow}]):(selector==='video,audio'?[media]:[]),createElement:element,documentElement:{append(){}}},
  browser:{runtime:{getURL:path=>'safari-web-extension://test/'+path,onMessage:{addListener:fn=>listeners.push(fn)},sendMessage:async packet=>{packets.push(packet);return {ok:true};}}},
  setTimeout,clearTimeout,setInterval:fn=>{timers.add(fn);return fn;},clearInterval:fn=>timers.delete(fn),AbortController,fetch:async(url,request)=>{fetches.push(request);if(!options.corsAllowed)throw Error('CORS denied');return {ok:true,type:'cors'};},addEventListener(){},btoa:value=>Buffer.from(value,'binary').toString('base64'),Float32Array,Uint8Array,DataView,console});
 vm.runInContext(discoverySource,context);
 vm.runInContext(source,context,{importModuleDynamically:async specifier=>{
  assert.equal(specifier,'safari-web-extension://test/hls-decoder.mjs');
  const module=new vm.SyntheticModule(['createHLSCapture'],function(){this.setExport('createHLSCapture',async options=>{
    assert.equal(options.media,media);options.onBlock(new Float32Array(24000).fill(.25),48000);
    return {stop:()=>{hlsStops++;},sampleRate:48000};
  });},{context});await module.link(()=>{});await module.evaluate();return module;
 }});return {get hlsStops(){return hlsStops;},rawSend:request=>listeners[0](request),send:async request=>{
  const result=await listeners[0](request);
  if(request.type!=='captureStart')return result;
  const deadline=Date.now()+3000;
  while(Date.now()<deadline){
   const done=packets.find(p=>p.type==='captureReady'||p.type==='captureError');
   if(done)return {ok:done.type==='captureReady',error:done.error};
   await new Promise(resolve=>setTimeout(resolve,5));
  }
  throw Error('capture completion timeout');
 },contexts,packets,media,modules,fetches,tick:async()=>{for(const fn of timers)await fn();},emit:async name=>{for(const fn of events.get(name)||[])await fn();},activate:()=>{trusted=true;activationButton.onclick({isTrusted:true});},untrusted:()=>activationButton.onclick({isTrusted:false})};
}
test('actual worklet and capture send bounded PCM and stop without silencing original',async()=>{
 const f=fixture();assert.equal((await f.send({type:'captureStart',index:0,session:'s'})).ok,true);
 const context=f.contexts[0];
 for(let i=0;i<192;i++)context.processor.render([new Float32Array(128).fill(.5),new Float32Array(128)]);
 await new Promise(resolve=>setImmediate(resolve));
 const pcm=f.packets.filter(p=>p.type==='pcm');assert.equal(pcm.length,1);assert.equal(pcm[0].sequence,0);
 const data=Buffer.from(pcm[0].pcm,'base64');assert.equal(data.length,16000);assert.ok(Math.abs(data.readInt16LE(0)-8192)<=1);
 assert.equal(f.modules.size,0);
 await f.send({type:'captureStop',session:'s'});
 assert.equal(context.processor.port.onmessage,null);assert.equal(context.state,'running');assert.ok(context.connections.includes(context.destination));
 assert.equal(context.processor.render([new Float32Array(128)]),false);
});
test('cross-origin video without CORS is rejected before touching its audio route',async()=>{
 const f=fixture('https://other.test/video.mp4');const result=await f.send({type:'captureStart',index:0,session:'s'});
 assert.equal(result.ok,false);assert.equal(f.contexts.length,0);
});
test('missing worklet blocks are surfaced instead of silently losing speech',async()=>{
 const f=fixture();await f.send({type:'captureStart',index:0,session:'s'});
 const processor=f.contexts[0].processor;
 processor.port.onmessage({data:{sequence:1,samples:new Float32Array(4096),frameEnd:4096}});
 await new Promise(resolve=>setImmediate(resolve));
 assert.ok(f.packets.some(p=>p.type==='captureError'));
 assert.equal(processor.port.onmessage,null);
});
test('worklet loading failure leaves the media route untouched',async()=>{
 const f=fixture(undefined,true);assert.equal((await f.send({type:'captureStart',index:0,session:'s'})).ok,false);
 assert.equal(f.contexts[0].connections.length,0);assert.equal(f.contexts[0].state,'closed');assert.equal(f.modules.size,0);
});
test('delivery delay up to two seconds is tolerated; greater delay stops explicitly',async()=>{
 const f=fixture();await f.send({type:'captureStart',index:0,session:'s'});
 const context=f.contexts[0],processor=context.processor;context.currentTime=1.5;
 processor.port.onmessage({data:{sequence:0,samples:new Float32Array(4096),frameEnd:4096}});
 assert.notEqual(processor.port.onmessage,null);context.currentTime=3;
 processor.port.onmessage({data:{sequence:1,samples:new Float32Array(4096),frameEnd:8192}});
 await new Promise(resolve=>setImmediate(resolve));assert.ok(f.packets.some(p=>p.type==='captureError'&&p.error.includes('2秒')));
});

test('Safari gesture gate waits for a trusted page click without touching original audio',async()=>{
 const f=fixture(undefined,false,true);const starting=f.send({type:'captureStart',index:0,session:'s'});
 await new Promise(resolve=>setTimeout(resolve,550));
 assert.equal(f.contexts[0].connections.length,0);assert.ok(f.packets.some(p=>p.type==='captureAwaitGesture'));
 f.untrusted();assert.equal(f.contexts[0].state,'suspended');
 f.activate();assert.equal((await starting).ok,true);assert.equal(f.contexts[0].state,'running');
 await f.send({type:'captureStop',session:'s'});
});
test('stopping while waiting for a page click cancels preparation without changing audio route',async()=>{
 const f=fixture(undefined,false,true);const starting=f.send({type:'captureStart',index:0,session:'s'});
 await new Promise(resolve=>setTimeout(resolve,550));await f.send({type:'captureStop',session:'s'});
 assert.equal((await starting).ok,false);assert.equal(f.contexts[0].connections.length,0);assert.equal(f.contexts[0].state,'closed');
});

test('server-authorized cross-origin media reloads only on page click and preserves position',async()=>{
 const f=fixture('https://cdn.test/video.mp4',false,false,{corsAllowed:true});
 const starting=f.send({type:'captureStart',index:0,session:'s'});await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.media.loadCount,0);assert.equal(f.fetches[0].method,'HEAD');assert.equal(f.fetches[0].credentials,'omit');assert.equal(f.fetches[0].mode,'cors');
 f.activate();assert.equal((await starting).ok,true);assert.equal(f.media.currentTime,17);assert.equal(f.media.paused,true);assert.equal(f.media.crossOrigin,'anonymous');
 await f.send({type:'captureStop',session:'s'});
});
test('failed CORS reload restores original media settings before refusing capture',async()=>{
 const f=fixture('https://cdn.test/video.mp4',false,false,{corsAllowed:true,failLoad:1});
 const starting=f.send({type:'captureStart',index:0,session:'s'});await new Promise(resolve=>setImmediate(resolve));f.activate();
 assert.equal((await starting).ok,false);assert.equal(f.media.loadCount,2);assert.equal(f.media.crossOrigin,null);assert.equal(f.media.currentTime,17);assert.equal(f.contexts[0].connections.length,0);
});
test('encrypted media is refused without probing or changing its route',async()=>{
 const f=fixture('https://cdn.test/video.m3u8',false,false,{corsAllowed:true,protected:true});
 assert.equal((await f.send({type:'captureStart',index:0,session:'s'})).ok,false);assert.equal(f.fetches.length,0);assert.equal(f.media.loadCount,0);assert.equal(f.contexts.length,0);
});

test('capture acknowledges immediately while gesture is pending and confirms completion separately',async()=>{
 const f=fixture(undefined,false,true);const ack=await f.rawSend({type:'captureStart',index:0,session:'s'});
 assert.equal(ack.ok,true);assert.equal(ack.preparing,true);assert.ok(!f.packets.some(p=>p.type==='captureReady'));
 await new Promise(resolve=>setTimeout(resolve,550));f.activate();
 await new Promise(resolve=>setTimeout(resolve,10));assert.ok(f.packets.some(p=>p.type==='captureReady'&&p.session==='s'));
 await f.send({type:'captureStop',session:'s'});
});

test('HLS uses independent PCM input, leaves original media untouched, and closes its decoder on stop',async()=>{
 const f=fixture('https://cdn.test/video.m3u8');assert.equal((await f.send({type:'captureStart',index:0,session:'s'})).ok,true);
 assert.equal(f.contexts.length,0);assert.equal(f.media.loadCount,0);assert.equal(f.media.crossOrigin,null);assert.equal(f.media.currentTime,17);
 const pcm=f.packets.filter(p=>p.type==='pcm');assert.equal(pcm.length,1);assert.equal(Buffer.from(pcm[0].pcm,'base64').length,16000);
 await f.send({type:'captureStop',session:'s'});assert.equal(f.hlsStops,1);
});

test('paused HLS stays connected without synthetic PCM and cancels heartbeats on stop',async()=>{
 const f=fixture('https://cdn.test/video.m3u8');await f.send({type:'captureStart',index:0,session:'s'});
 const pcmCount=f.packets.filter(p=>p.type==='pcm').length;
 for(let i=0;i<50;i++)await f.tick();
 assert.equal(f.packets.filter(p=>p.type==='pcm').length,pcmCount);
 assert.equal(f.packets.at(-1).paused,true);
 f.media.paused=false;await f.emit('play');assert.equal(f.packets.at(-1).paused,false);
 f.media.paused=true;await f.emit('pause');assert.equal(f.packets.at(-1).paused,true);
 await f.send({type:'captureStop',session:'s'});const count=f.packets.length;
 await f.tick();await f.emit('play');assert.equal(f.packets.length,count);
});

test('the capture route resolves the same discovered shadow video and sends PCM',async()=>{
 const f=fixture(undefined,false,false,{shadow:true});assert.equal((await f.send({type:'captureStart',index:0,session:'shadow'})).ok,true);
 const context=f.contexts[0];for(let i=0;i<192;i++)context.processor.render([new Float32Array(128).fill(.25)]);
 await new Promise(resolve=>setImmediate(resolve));assert.equal(f.packets.filter(p=>p.type==='pcm').length,1);
 await f.send({type:'captureStop',session:'shadow'});
});
