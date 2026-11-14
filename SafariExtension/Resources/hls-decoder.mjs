import {createFile} from './mp4box.all.mjs';

// All stream requests remain browser CORS requests. No URL or encoded media is
// sent to the native app. Only bounded mono PCM is emitted on the video clock.
export async function createHLSCapture({media,url,Hls,onBlock,onError,isActive=()=>true}) {
  if(typeof AudioDecoder==='undefined'||!Hls?.isSupported())throw new Error('このSafariではHLS音声の独立デコードを利用できません。');
  if(media.mediaKeys)throw new Error('保護された動画は取得できません。');
  const requestedStart=media.currentTime;
  let lastSampleEnd=-Infinity;
  let active=true,offset=0,trackID,decoder,anchor=null,fragmentStart=0,queue=[],queuedFrames=0,rate=0,ready=false,stalled=false;
  let resolveReady,rejectReady;
  const readiness=new Promise((resolve,reject)=>{resolveReady=resolve;rejectReady=reject;});
  const clone=document.createElement('video');clone.muted=true;clone.playsInline=true;clone.preload='auto';
  clone.style.cssText='position:fixed;left:0;top:0;width:1px;height:1px;opacity:.001;pointer-events:none';
  const host=document.createElement('div');host.attachShadow({mode:'closed'}).append(clone);document.documentElement.append(host);
  const file=createFile(true);
  const hls=new Hls({preferManagedMediaSource:false,enableWorker:false,startLevel:0,autoLevelCapping:0,
    startPosition:requestedStart,maxBufferLength:10,maxMaxBufferLength:20,maxBufferSize:10*1024*1024,backBufferLength:0,debug:false});
  hls.autoLevelCapping=0;
  let timer,timeout;
  function stop() {
    if(!active)return;active=false;clearInterval(timer);clearTimeout(timeout);
    media.removeEventListener('seeking',seek);media.removeEventListener('play',play);media.removeEventListener('pause',pause);media.removeEventListener('ratechange',speed);
    clone.pause();hls.destroy();file.stop();if(decoder&&decoder.state!=='closed')decoder.close();
    host.remove();queue=[];queuedFrames=0;
  }
  function fail(message) {
    if(!active)return;const wasReady=ready;stop();
    const error=new Error(message);rejectReady(error);if(wasReady)onError(message);
  }
  function seek(){fail('再生位置が変わりました。新しい位置で翻訳開始を押してください。');}
  function play(){if(active)clone.play().catch(()=>fail('音声用の読み込みを再開できませんでした。'));}
  function pause(){clone.pause();hls.stopLoad();stalled=true;}
  function speed(){clone.playbackRate=media.playbackRate;}
  file.onError=()=>fail('HLS音声データを解析できませんでした。');
  file.onReady=info=>{
    const track=info.audioTracks[0];if(!track){fail('HLSの音声トラックが見つかりません。');return;}trackID=track.id;
    if(!track.codec.startsWith('mp4a.')){fail('このHLS音声形式は現在未対応です。');return;}
    const entry=file.getTrackById(trackID).mdia.minf.stbl.stsd.entries[0];
    const esds=entry.esds || entry.wave?.esds;
    const description=esds?.esd?.findDescriptor(4)?.findDescriptor(5)?.data;
    if(!description){fail('HLS音声の設定情報を取得できませんでした。');return;}
    decoder=new AudioDecoder({output:data=>{
      try {
        if(!active)return;
        if(rate&&rate!==data.sampleRate){fail('音声形式が変わりました。翻訳を再開してください。');return;}
        rate=data.sampleRate;
        const start=data.timestamp/1e6-anchor;
        const trim=Math.max(0,Math.ceil((requestedStart-start)*rate));
        if(trim>=data.numberOfFrames)return;
        const samples=new Float32Array(data.numberOfFrames-trim);
        for(let c=0;c<data.numberOfChannels;c++){
          const plane=new Float32Array(data.numberOfFrames);data.copyTo(plane,{planeIndex:c,format:'f32-planar'});
          for(let i=0;i<samples.length;i++)samples[i]+=plane[i+trim]/data.numberOfChannels;
        }
        queue.push({start:start+trim/rate,samples,used:0});queuedFrames+=samples.length;
        if(queuedFrames>rate*60){fail('音声の先読みが上限に達したため停止しました。');return;}
        if(!ready){ready=true;clearTimeout(timeout);resolveReady({stop,sampleRate:rate});}
      }catch{fail('HLS音声をPCMへ変換できませんでした。');}finally{data.close();}
    },error:()=>fail('Safariの音声デコーダでエラーが発生しました。')});
    try{decoder.configure({codec:track.codec,sampleRate:track.audio.sample_rate,numberOfChannels:track.audio.channel_count,description});}
    catch{fail('このSafariではHLSの音声形式をデコードできません。');return;}
    file.setExtractionOptions(trackID,null,{nbSamples:1,rapAlignement:false});file.start();
  };
  file.onSamples=(_id,_user,samples)=>{
    if(!active||!decoder||decoder.state!=='configured')return;
    for(const sample of samples){
      const end=(sample.cts+sample.duration)/sample.timescale;
      if(end<=lastSampleEnd+.000001)continue; // retransmitted fragment, not new speech
      lastSampleEnd=end;
      if(anchor===null)anchor=sample.cts/sample.timescale-fragmentStart;
      if(decoder.decodeQueueSize>2500){fail('音声のデコード待ちが上限に達しました。');return;}
      try{decoder.decode(new EncodedAudioChunk({type:'key',timestamp:Math.round(sample.cts*1e6/sample.timescale),duration:Math.round(sample.duration*1e6/sample.timescale),data:sample.data}));}
      catch{fail('HLS音声のデコードを開始できませんでした。');return;}
    }
    if(samples.length)file.releaseUsedSamples(trackID,samples.at(-1).number+1);
  };
  hls.on(Hls.Events.BUFFER_APPENDING,(_event,data)=>{
    if(!active||!['audio','audiovideo'].includes(data.type))return;
    if(data.frag)fragmentStart=data.frag.start;
    try{const buffer=data.data.slice().buffer;buffer.fileStart=offset;offset+=buffer.byteLength;file.appendBuffer(buffer);}
    catch{fail('HLS音声の読み込みに失敗しました。');}
  });
  hls.on(Hls.Events.LEVEL_LOADED,(_event,data)=>{if(data.details.live)fail('ライブHLSの音声取得は現在未対応です。');});
  hls.on(Hls.Events.ERROR,(_event,data)=>{if(data.fatal)fail('HLS音声を取得できません。配信元のアクセス許可または音声形式を確認してください。');});
  media.addEventListener('seeking',seek);media.addEventListener('play',play);media.addEventListener('pause',pause);media.addEventListener('ratechange',speed);
  speed();hls.loadSource(url);hls.attachMedia(clone);clone.play().catch(()=>fail('音声用の読み込みを開始できませんでした。'));
  timeout=setTimeout(()=>fail('HLS音声を準備できませんでした。'),25000);
  let previousEnd=null;
  timer=setInterval(()=>{
    if(!active)return;
    if(!isActive()){fail('音声取得を取り消しました。');return;}
    if(media.currentSrc!==url){fail('対象動画が切り替わりました。翻訳を再開してください。');return;}
    if(!rate)return;
    if(media.paused&&!clone.paused)clone.pause();
    const ahead=queuedFrames/rate;
    if((ahead>15||media.paused)&&!stalled){hls.stopLoad();stalled=true;}
    else if(ahead<6&&!media.paused&&stalled){hls.startLoad(-1);clone.play().catch(()=>{});stalled=false;}
    // At most 2x realtime; native messages must not receive a burst on startup.
    let budget=Math.ceil(rate*.2);
    while(active&&queue.length&&budget>0){
      const block=queue[0],start=block.start+block.used/rate;
      const available=Math.min(block.samples.length-block.used,Math.floor((media.currentTime-start)*rate),budget);
      if(available<=0)break;
      if(previousEnd!==null&&Math.abs(start-previousEnd)>.12){fail('HLS音声の区間が連続していないため停止しました。');return;}
      onBlock(block.samples.subarray(block.used,block.used+available),rate);
      block.used+=available;queuedFrames-=available;budget-=available;previousEnd=start+available/rate;
      if(block.used===block.samples.length)queue.shift();
    }
  },100);
  return readiness;
}
