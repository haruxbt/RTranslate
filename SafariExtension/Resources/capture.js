(() => {
  if (globalThis.__webinarCaptureInstalled) return;
  globalThis.__webinarCaptureInstalled=true;
  const api=globalThis.browser || globalThis.chrome;
  const graphs=new WeakMap(); let current=null, pendingActivation=null, pendingSession=null, preparingSession=null, generation=0;
  function stop() {
    generation++;
    preparingSession=null;
    pendingActivation?.();
    if (!current) return;
    current.stopped=true;
    current.stopHeartbeat?.();
    current.capture?.stop();
    if(current.processor){
      current.processor.port.postMessage({stop:true});
      current.processor.port.onmessage=null;current.processor.port.close();current.processor.onprocessorerror=null;
      current.graph.source.disconnect(current.processor);current.processor.disconnect();
    }
    current=null;
    // Keep original playback connected. Never close its audio context on stop.
  }
  async function resumeContext(context,session,reload=null) {
    if(context.state==='running'&&!reload)return;
    let timer;
    if(!reload) {
      try { await Promise.race([context.resume(),new Promise(resolve=>{timer=setTimeout(resolve,500);})]); }
      catch {} finally { clearTimeout(timer); }
      if(context.state==='running')return;
    }
    await new Promise((resolve,reject)=>{
      const host=document.createElement('div'),shadow=host.attachShadow({mode:'closed'});
      host.style.cssText='position:fixed;top:18px;left:50%;transform:translateX(-50%);z-index:2147483647';
      const button=document.createElement('button');
      button.textContent=reload?'音声を接続（動画を再読み込み）':'音声を接続して翻訳する';
      button.style.cssText='font:16px system-ui;padding:14px 20px;background:#2458ce;color:white;border:2px solid white;border-radius:12px;box-shadow:0 4px 20px #0005;cursor:pointer';
      shadow.append(button);document.documentElement.append(host);
      let settled=false;
      const finish=error=>{if(settled)return;settled=true;clearTimeout(timer);host.remove();pendingActivation=null;pendingSession=null;error?reject(error):resolve();};
      pendingSession=session;
      pendingActivation=()=>finish(new Error('音声接続を取り消しました'));
      timer=setTimeout(()=>finish(new Error('ページの「音声を接続して翻訳する」を押してから再試行してください')),45000);
      button.onclick=event=>{
        if(!event.isTrusted)return;
        // Call synchronously in the page's trusted click, before any await.
        const resumed=context.resume();
        Promise.all([resumed,reload?reload():Promise.resolve()]).then(()=>{if(context.state==='running')finish();else finish(new Error('Safariが音声接続を許可しませんでした'));},finish);
      };
      api.runtime.sendMessage({type:'captureAwaitGesture',session,reload:Boolean(reload)}).catch(()=>{});
    });
  }
  async function needsCORSReload(media) {
    if(media.mediaKeys)throw new Error('保護された動画は、この方式で音声取得できません。');
    const url=media.currentSrc?new URL(media.currentSrc,location.href):null;
    if(!url || !['http:','https:'].includes(url.protocol) || url.origin===location.origin || media.crossOrigin)return false;
    // The browser must accept the server's CORS policy. Never proxy media or
    // disable origin checks. HEAD reads no media body and sends no credentials.
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),6000);
    try {
      const response=await fetch(url.href,{method:'HEAD',mode:'cors',credentials:'omit',cache:'no-store',signal:controller.signal});
      if(!response.ok || !['cors','basic'].includes(response.type))throw new Error('cors');
      return true;
    }catch {
      throw new Error('配信元の音声アクセス許可を確認できませんでした。この動画は現在のSafari拡張方式では取得できません。');
    }finally{clearTimeout(timer);}
  }
  async function reloadWithCORS(media,active) {
    const original=media.getAttribute('crossorigin'),time=media.currentTime,playing=!media.paused;
    async function load() {
      const loaded=new Promise((resolve,reject)=>{
        let timer;
        const cleanup=()=>{clearTimeout(timer);media.removeEventListener('loadedmetadata',done);media.removeEventListener('error',error);};
        const done=()=>{cleanup();resolve();},error=()=>{cleanup();reject(new Error('動画を読み込めません'));};
        media.addEventListener('loadedmetadata',done);media.addEventListener('error',error);
        timer=setTimeout(error,8000);
      });
      media.load();
      // Request play while still inside the trusted click; metadata is awaited
      // afterwards. Paused media stays paused.
      const played=playing?media.play().then(()=>null,error=>error):Promise.resolve(null);
      await loaded;
      if(Number.isFinite(time))media.currentTime=time;
      const error=await played;if(error)throw error;
    }
    try {
      if(!active())throw new Error('音声接続を取り消しました');
      media.crossOrigin='anonymous';await load();
      if(!active())throw new Error('音声接続を取り消しました');
    }catch(error){
      if(original===null)media.removeAttribute('crossorigin');else media.setAttribute('crossorigin',original);
      try{await load();}catch{}
      throw new Error('音声用の読み込みに失敗したため元の設定へ戻しました。必要なら動画を再生し直してください。');
    }
  }
  function resampler(rate) {
    let samples=[], position=0; const ticks=Math.round(rate);
    return input=>{
      samples.push(...input); const out=[];
      while(position+ticks<=samples.length*16000){
        const begin=position/16000, end=(position+ticks)/16000; let total=0;
        for(let i=Math.floor(begin);i<Math.ceil(end);i++)total+=samples[i]*Math.max(0,Math.min(i+1,end)-Math.max(i,begin));
        out.push(total*16000/ticks); position+=ticks;
      }
      const used=Math.floor(position/16000);samples.splice(0,used);position-=used*16000;return out;
    };
  }
  function makePCMRun(session) {
    const run={session,stopped:false,queue:[],buffer:[],sequence:0,sending:false,sourceSequence:0};current=run;
    let convert,rate;
    async function fail(error){
      if(run.stopped)return;stop();
      try{await api.runtime.sendMessage({type:'captureError',session:run.session,error});}catch{}
    }
    async function drain(){
      if(run.sending)return;run.sending=true;
      try{
        while(run.queue.length&&!run.stopped){
          const packet=run.queue[0];let response;
          for(let attempt=0;attempt<2;attempt++){
            try{response=await api.runtime.sendMessage({type:'pcm',session:run.session,...packet});if(response?.ok)break;}catch{}
          }
          if(!response?.ok)throw new Error(response?.error || '音声をMacへ送れませんでした。');
          run.queue.shift();
        }
      }catch(error){await fail(error.message);}finally{run.sending=false;}
    }
    run.fail=fail;
    run.pushPCM=(mono,sampleRate)=>{
      if(run.stopped)return;
      if(rate&&rate!==sampleRate){fail('音声形式が変わりました。翻訳を再開してください。');return;}
      if(!convert){rate=sampleRate;convert=resampler(rate);}
      run.buffer.push(...convert(mono));
      while(run.buffer.length>=8000){
        const chunk=run.buffer.splice(0,8000), bytes=new Uint8Array(16000), view=new DataView(bytes.buffer);
        chunk.forEach((sample,i)=>{const v=Math.max(-1,Math.min(1,sample));view.setInt16(i*2,Math.round(v*(v<0?32768:32767)),true);});
        let binary='';for(const byte of bytes)binary+=String.fromCharCode(byte);
        run.queue.push({sequence:run.sequence++,pcm:btoa(binary)});
      }
      if(run.queue.length>4){fail('音声の転送が追いつかないため停止しました。');return;}
      drain();
    };
    return run;
  }
  function monitorPlayback(run,media) {
    let sending=false;
    async function beat(){
      if(sending||run.stopped)return;sending=true;
      try{
        const reply=await api.runtime.sendMessage({type:'captureHeartbeat',session:run.session,paused:Boolean(media.paused||media.ended)});
        if(!reply?.ok&&!run.stopped)run.fail(reply?.error || 'タブとの接続を確認できませんでした。');
      }catch{if(!run.stopped)run.fail('タブとの接続が切れました。');}finally{sending=false;}
    }
    const events=['play','pause','ended'];for(const name of events)media.addEventListener(name,beat);
    const timer=setInterval(beat,2000);
    run.stopHeartbeat=()=>{clearInterval(timer);for(const name of events)media.removeEventListener(name,beat);};
    beat();
  }
  async function start(request) {
    stop(); const token=generation;preparingSession=request.session;
    const media=[...document.querySelectorAll('video,audio')][request.index];
    if(!media)throw new Error('対象の動画が変わりました。もう一度開始してください。');
    const sourceURL=media.currentSrc?new URL(media.currentSrc,location.href):null;
    if(sourceURL&&/\.m3u8$/i.test(sourceURL.pathname)){
      if(media.mediaKeys)throw new Error('保護された動画は取得できません。');
      const run=makePCMRun(request.session);
      monitorPlayback(run,media);
      const {createHLSCapture}=await import(api.runtime.getURL('hls-decoder.mjs'));
      if(token!==generation)throw new Error('音声取得を取り消しました');
      const capture=await createHLSCapture({media,url:sourceURL.href,Hls:globalThis.Hls,onBlock:run.pushPCM,onError:run.fail,isActive:()=>token===generation&&!run.stopped});
      if(token!==generation){capture.stop();throw new Error('音声取得を取り消しました');}
      run.capture=capture;return {ok:true};
    }

    let graph=graphs.get(media);
    if(!graph){
      const reload=await needsCORSReload(media);
      if(token!==generation)throw new Error('音声接続を取り消しました');
      const context=new AudioContext();
      let stage='再生の開始';
      try {
        // Resume before changing the media route: a denied autoplay request must
        // never leave the original video connected to a suspended context.
        await resumeContext(context,request.session,reload?()=>reloadWithCORS(media,()=>token===generation):null);
        if(token!==generation)throw new Error('音声接続を取り消しました');
        stage='音声処理の読み込み';
        if(!context.audioWorklet || typeof AudioWorkletNode==='undefined')throw new Error('AudioWorklet is unavailable');
        // Load a declared extension resource; blob origins in an isolated content
        // world need not match the AudioContext's document origin in Safari.
        await context.audioWorklet.addModule(api.runtime.getURL('audio-worklet.js'));
        if(token!==generation)throw new Error('音声接続を取り消しました');
        stage='動画との接続';
        const source=context.createMediaElementSource(media); source.connect(context.destination);
        graph={context,source}; graphs.set(media,graph);
      }catch(error){await context.close();throw new Error('音声処理を準備できません（'+stage+' / '+String(error?.name || 'Error')+': '+String(error?.message || error).slice(0,180)+'）。');}
    }
    await resumeContext(graph.context,request.session);
    if(token!==generation)throw new Error('音声接続を取り消しました');
    if(graph.context.state!=='running')throw new Error('動画を再生してから、もう一度翻訳開始を押してください。');
    const processor=new AudioWorkletNode(graph.context,'webinar-pcm-collector',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1]});
    const run=makePCMRun(request.session);run.graph=graph;run.processor=processor;
    monitorPlayback(run,media);
    processor.onprocessorerror=()=>run.fail('タブの音声処理でエラーが発生したため停止しました。');
    processor.port.onmessage=event=>{
      if(run.stopped)return;
      const block=event.data;
      if(block.sequence!==run.sourceSequence++ || !(block.samples instanceof Float32Array) || block.samples.length!==4096) {
        run.fail('タブの音声データに欠落を検出したため停止しました。'); return;
      }
      if(graph.context.currentTime-block.frameEnd/graph.context.sampleRate>2) {
        run.fail('タブの音声処理が2秒以上遅れたため停止しました。'); return;
      }
      run.pushPCM(block.samples,graph.context.sampleRate);
    };
    graph.source.connect(processor);processor.connect(graph.context.destination);
    return {ok:true};
  }
  api.runtime.onMessage.addListener(request=>{
    if(request.type==='captureStart') {
      // Do not hold a Safari message reply open across a page click or media
      // reload. Completion is a separate, session-bound notification.
      start(request).then(()=>{if(preparingSession===request.session)preparingSession=null;return api.runtime.sendMessage({type:'captureReady',session:request.session});},
        error=>{if(current?.session===request.session||preparingSession===request.session)stop();return api.runtime.sendMessage({type:'captureError',session:request.session,error:error.message});}).catch(()=>{});
      return Promise.resolve({ok:true,preparing:true});
    }
    if(request.type==='captureStop'){if(current?.session===request.session || pendingSession===request.session || preparingSession===request.session)stop();return Promise.resolve({ok:true});}
  });
  addEventListener('pagehide',stop);
})();
