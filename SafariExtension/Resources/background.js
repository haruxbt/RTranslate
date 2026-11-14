import {NATIVE_APP, webURL, settings} from './protocol.mjs';
const api = globalThis.browser || globalThis.chrome;
let active = null, lastTarget = null, message = '', starting = false;
const restored = api.storage.local.get(['activeSession','lastTarget','settings','pacePolicy']).then(async data => {
  active=data.activeSession || null;lastTarget=data.lastTarget || null;
  if(data.pacePolicy!==2)await api.storage.local.set({pacePolicy:2,settings:settings({...data.settings,volume:data.settings?.volume ?? 60,speaker:data.settings?.speaker ?? 2,speed:1.25})});
});
async function save() { await api.storage.local.set({activeSession:active,lastTarget}); }
async function native(command, payload = {}) {
  let result;
  try { result = await api.runtime.sendNativeMessage(NATIVE_APP, {command, ...payload, client:"safari-extension"}); }
  catch { throw new Error('Mac側のR翻訳と拡張の連携を確認してください。'); }
  if (!result?.ok) throw new Error(result?.error || 'Macとの接続に失敗しました。');
  return result;
}
async function currentTab() {
  const [tab] = await api.tabs.query({active:true,currentWindow:true});
  if (!tab || !webURL(tab.url)) throw new Error('ウェビナーのタブを開いてください。');
  return tab;
}
let profileCache={tabID:null,at:0,value:null};
async function mediaProfile() {
  const tab=await currentTab();
  if(profileCache.tabID===tab.id && Date.now()-profileCache.at<5000)return profileCache.value;
  const frames=await api.scripting.executeScript({target:{tabId:tab.id,allFrames:true},func:()=>[...document.querySelectorAll('video,audio')].map(media=>{
    let url;try{url=new URL(media.currentSrc,location.href);}catch{}
    const path=url?.pathname || '';
    return {playing:!media.paused,area:media.getBoundingClientRect().width*media.getBoundingClientRect().height,
      kind:/\.m3u8$/i.test(path)?'HLS':/\.mp4$/i.test(path)?'MP4':url?.protocol==='blob:'?'MediaSource':media.tagName==='AUDIO'?'音声':'不明',
      crossOrigin:Boolean(url&&url.origin!==location.origin),cors:media.crossOrigin || 'unset',protected:Boolean(media.mediaKeys)};
  })});
  const candidates=frames.flatMap(frame=>frame.result || []).sort((a,b)=>Number(b.playing)-Number(a.playing)||b.area-a.area);
  const picked=candidates[0];
  const value=picked?{kind:picked.kind,crossOrigin:picked.crossOrigin,cors:picked.cors,protected:picked.protected}:null;
  profileCache={tabID:tab.id,at:Date.now(),value};return value;
}
async function status() {
  await restored;
  let host='',timelineVisible=false;
  try{const tab=await currentTab();host=new URL(tab.url).hostname;timelineVisible=Boolean((await api.tabs.sendMessage(tab.id,{type:'timelineVisibility'},{frameId:0}))?.visible);}catch{}
  if (!active) {
    let profile=null;try{profile=await mediaProfile();}catch{}
    let assets;try{assets=await native('assetsStatus');}catch(error){assets={ready:false,message:error.message};}
    return {ok:true,running:false,message:assets.ready===false?assets.message:message,assetReady:assets.ready,profile,host,timelineVisible};
  }
  try {
    const value = await native('status',{session:active.session});
    if (!value.running && !value.preparing) { message=value.message; await stop(false); }
    const noAudio=!starting && value.running && value.message?.includes('音声未検出');
    return {...value,ok:true,host,timelineVisible,message:value.running&&value.paused?'動画の再生を待っています':noAudio?'動画の音声が届いていません。':message || value.message};
  } catch (error) { return {ok:true,running:false,message:error.message}; }
}
async function setTimeline(tabID,visible){
  await api.scripting.executeScript({target:{tabId:tabID,frameIds:[0]},files:['timeline.js']});
  return api.tabs.sendMessage(tabID,{type:'timelineVisibility',visible},{frameId:0});
}
async function stop(notify = true) {
  const previous=active; if(previous)lastTarget=previous; active=null; starting=false; await save();
  if (previous) {
    try { await api.tabs.sendMessage(previous.tabID,{type:'captureStop',session:previous.session},{frameId:previous.frameID}); } catch {}
    if (notify) { try { await native('stop',{session:previous.session}); } catch {} }
  }
  const value=await status();return {...value,running:false,preparing:false,voiceEnabled:false};
}
async function start() {
  await restored;
  if (active) return status();
  const tab=await currentTab();
  const candidates=await api.scripting.executeScript({target:{tabId:tab.id,allFrames:true},func:() => {
    const media=[...document.querySelectorAll('video,audio')];
    return media.map((m,index)=>({index,playing:!m.paused&&!m.ended,area:m.getBoundingClientRect().width*m.getBoundingClientRect().height}));
  }});
  const list=candidates.flatMap(frame => (frame.result || []).map(media=>({...media,frameID:frame.frameId})));
  list.sort((a,b)=>Number(b.playing)-Number(a.playing)||b.area-a.area);
  if (!list.length) throw new Error('このタブで動画を見つけられません。埋め込み元へのアクセス許可が必要な場合があります。');
  const picked=list[0], session=crypto.randomUUID();
  active={tabID:tab.id,frameID:picked.frameID,index:picked.index,session,url:tab.url}; await save();
  starting=true; message='音声認識と日本語音声を準備しています…';
  try {
    const stored=await api.storage.local.get('settings');
    const current=await native('playbackGet');
    await native('start',{session,url:tab.url,title:tab.title || '',settings:settings(current.settings || stored.settings || {volume:60,speed:1.25,speaker:2})});
    // Keep this asynchronous task separate from the popup, which may close immediately.
    prepareCapture(active).catch(async error => { message=error.message; await stop(); });
    await setTimeline(tab.id,true);
    return {ok:true,preparing:true,voiceEnabled:true,timelineVisible:true,host:new URL(tab.url).hostname,message};
  } catch(error) { await stop(); throw error; }
}
async function prepareCapture(target) {
  const deadline=Date.now()+180000;
  while (active?.session===target.session) {
    const state=await native('status',{session:target.session});
    if (state.running) break;
    if (!state.preparing) throw new Error(state.message || '準備を完了できませんでした。');
    if (Date.now()>deadline) throw new Error('準備に時間がかかっています。Macアプリの表示を確認してください。');
    await new Promise(resolve=>setTimeout(resolve,700));
  }
  if (active?.session!==target.session) return;
  await api.scripting.executeScript({target:{tabId:target.tabID,frameIds:[target.frameID]},files:['hls.min.js','capture.js']});
  const result=await api.tabs.sendMessage(target.tabID,{type:'captureStart',session:target.session,index:target.index},{frameId:target.frameID});
  if (!result?.ok) throw new Error(result?.error || 'この動画の音声を取得できませんでした。');
  // captureReady will confirm the audio route after any required page click.
}
api.runtime.onMessage.addListener((request,sender) => (async()=>{
  // Read-only timeline lookup is independent of capture-state restoration.
  if(request.type!=='timelineData')await restored;
  try {
    if (sender.tab) {
      const target=active || lastTarget;
      if(request.type==='timelineData') {
        const tab=sender.tab.url?sender.tab:await api.tabs.get(sender.tab.id);
        const url=webURL(tab.url);
        const top=sender.frameId===0 || (sender.frameId==null && url && webURL(sender.url)===url);
        if(!top || !url)throw new Error('タイムラインは翻訳ページの最上位フレームで表示してください。');
        const payload={url,cursor:Math.max(0,Number(request.cursor)||0),historySession:request.historySession || ''};
        try{return await native('timelineForPage',payload);}
        catch(error){
          // Compatibility with an app older than this extension; keep session checks.
          if(target && sender.tab.id===target.tabID)return await native('timeline',{session:target.session,cursor:payload.cursor,historySession:payload.historySession});
          throw new Error('R翻訳アプリとSafari拡張を同じ最新版に更新して、翻訳を開始し直してください。');
        }
      }
      if (!target || sender.tab.id!==target.tabID) throw new Error('対象外のタブです。');
      if (request.type==='pcm') {
        if (!active || sender.frameId!==active.frameID || request.session!==active.session) throw new Error('対象外の動画です。');
        return await native('pcm',{session:active.session,sequence:request.sequence,pcm:request.pcm});
      }
      if (request.type==='captureHeartbeat') {
        if (!active || sender.frameId!==active.frameID || request.session!==active.session || typeof request.paused!=='boolean') throw new Error('対象外の動画です。');
        return await native('heartbeat',{session:active.session,paused:request.paused});
      }
      if (request.type==='captureReady') {
        if (!active || sender.frameId!==active.frameID || request.session!==active.session) throw new Error('対象外の動画です。');
        starting=false; message='このタブを翻訳しています'; return {ok:true};
      }
      if (request.type==='captureAwaitGesture') {
        if (!active || sender.frameId!==active.frameID || request.session!==active.session) throw new Error('対象外の動画です。');
        message=request.reload?'ページの「音声を接続（動画を再読み込み）」を押してください':'ページの「音声を接続して翻訳する」を押してください'; return {ok:true};
      }
      if (request.type==='captureError') {
        if (!active || sender.frameId!==active.frameID || request.session!==active.session) throw new Error('対象外の動画です。');
        message=String(request.error || '音声取得を停止しました。').slice(0,240); await stop(); return {ok:true};
      }
      throw new Error('許可されていない操作です。');
    }
    switch(request.type) {
      case 'status': return status();
      case 'start': return start();
      case 'stop': message='停止しました'; return stop();
      case 'voice':
        if (!active) throw new Error('先に翻訳を開始してください。');
        await native('voice',{session:active.session,...(typeof request.enabled==='boolean'?{enabled:request.enabled}:{})});
        return status();
      case 'openAppSettings': {
        if(!['overview','dictionary','slides','models','history','support'].includes(request.page))throw new Error('設定項目を確認してください。');
        return native('openSettings',{page:request.page});
      }
      case 'playbackGet': return native('playbackGet');
      case 'assetsStatus': return native('assetsStatus');
      case 'assetsPrepare': return native('assetsPrepare');
      case 'uninstallReview': return native('uninstallReview',{selection:request.selection});
      case 'uninstall': {
        const result=await native('uninstall',{selection:request.selection,token:request.token});
        if(request.selection?.history){active=null;lastTarget=null;message='';starting=false;await api.storage.local.remove(['settings','pacePolicy','activeSession','lastTarget']);}
        return result;
      }
      case 'dictionaryGet': return native('dictionaryGet');
      case 'dictionarySave': return native('dictionarySave',{dictionary:request.dictionary});
      case 'preview': {
        const stored=await api.storage.local.get('settings');
        return native('preview',{settings:settings(stored.settings || {volume:60,speed:1.25,speaker:2})});
      }
      case 'settings': {
        const value=settings(request.value); await native('playbackSave',{settings:value});
        await api.storage.local.set({settings:value});
        return {ok:true};
      }
      case 'timeline': {
        const tab=await currentTab();
        if (active && tab.id!==active.tabID) throw new Error('翻訳しているタブを開いてください。');
        let visible=request.visible;
        if(typeof visible!=='boolean')visible=!Boolean((await api.tabs.sendMessage(tab.id,{type:'timelineVisibility'},{frameId:0}).catch(()=>null))?.visible);
        await setTimeline(tab.id,visible);
        return status();
      }
      default: throw new Error('不明な操作です。');
    }
  } catch(error) { return {ok:false,error:error.message}; }
})());
api.tabs.onRemoved.addListener(id=>{ if(active?.tabID===id) { message='対象タブが閉じられたため停止しました'; stop(); } });
api.tabs.onUpdated.addListener((id,change)=>{ if(active?.tabID===id && change.status==='loading') { message='ページが移動したため停止しました'; stop(); } });
api.tabs.onActivated.addListener(info=>{ if(active && active.tabID!==info.tabId) { message='対象タブが変わったため停止しました'; stop(); } });
