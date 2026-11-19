import {VOICES,settings} from './protocol.mjs';
const api=globalThis.browser || globalThis.chrome,$=id=>document.getElementById(id);
let interacted=false;globalThis.addEventListener?.('keydown',()=>interacted=true,{capture:true,once:true});globalThis.addEventListener?.('pointerdown',()=>interacted=true,{capture:true,once:true});
const speeds=[.75,1,1.25,1.5,1.75,2];let state={},busy=false;
let tabMode='video',pageState={},pageBusy=false,pageError='';
$('page-word-list').hidden=true;
const playbackDetails=$('playback-details');
function showTab(mode) {
  tabMode=mode;
  for(const name of ['video','page']) {
    $(name+'-tab').setAttribute('aria-pressed',String(name===mode));
    $(name+'-panel').hidden=name!==mode;
  }
  playbackDetails.hidden=mode==='page';
  if(mode==='page')void refreshPage();
  api.storage.local.set?.({popupTab:mode})?.catch?.(()=>{});
}
function displayPage(value) {
  pageState=value;
  $('page-status').textContent=pageError||value.message||'読み上げを開始できます';
  $('page-status-line').dataset ? $('page-status-line').dataset.error=String(Boolean(pageError)) : $('page-status-line').setAttribute('data-error',String(Boolean(pageError)));
  $('page-mode').disabled=pageBusy||Boolean(value.reading);
  $('page-read').disabled=pageBusy;
  $('page-read-label').textContent=value.reading?'読み上げ停止':'読み上げ開始';
  $('page-read-symbol').className=value.reading?'pause':'play';
  if(value.host)$('site').textContent=value.host;
}
async function refreshPage() {
  if(pageBusy)return;
  try { displayPage(await send('pageStatus')); }
  catch(error) { pageError=error.message; displayPage(pageState); }
}
$('video-tab').onclick=()=>{showTab('video');void refresh();};
$('page-tab').onclick=()=>showTab('page');
$('page-read').onclick=async()=>{
  if(pageBusy)return;
  pageBusy=true;pageError='';
  displayPage({...pageState,message:pageState.reading?'停止しています…':'本文を準備しています…'});
  let started=false;
  try {
    pageState=await send(pageState.reading?'pageStop':'pageStart',{mode:$('page-mode').value});
    started=Boolean(pageState.reading);
  }catch(error){pageError=error.message;}
  finally{pageBusy=false;displayPage(pageState);}
  if(started)globalThis.close?.();
};
async function addWord(word='') {
  try { await send('openAppSettings',{page:'dictionary',word}); }
  catch(error) {
    if(tabMode==='page') { pageError=error.message;displayPage(pageState); }
    else display({...state,error:error.message});
  }
}
$('video-add-word').onclick=()=>addWord();
$('page-add-word').onclick=()=>addWord();
$('page-words').onclick=async()=>{
  const list=$('page-word-list');
  list.hidden=!list.hidden;
  if(list.hidden)return;
  list.textContent='候補を確認しています…';
  try {
    const {words}=await send('pageWords');
    list.replaceChildren();
    if(!words.length)list.textContent='候補はありません。';
    for(const word of words) {
      const button=document.createElement('button');
      button.textContent=word;button.onclick=()=>addWord(word);list.append(button);
    }
  }catch(error){list.textContent=error.message;}
};
for(const [id,name] of VOICES){const option=document.createElement('option');option.value=id;option.textContent=name+' / ノーマル';$('speaker').append(option);}
async function send(type,extra={}){const r=await api.runtime.sendMessage({type,...extra});if(!r?.ok)throw Error(r?.error || '拡張との接続を確認してください。');return r;}
function display(value){state=value;const running=Boolean(value.running||value.preparing);document.body.dataset.running=String(running);document.body.dataset.error=String(Boolean(value.error));$('site').textContent=value.host||'現在のタブ';$('storage-notice').textContent=value.storageNotice||'';$('status').textContent=value.error||value.message||(running?'翻訳中':'開始できます');$('translate').disabled=busy||(!running&&value.assetReady===false);$('translate-label').textContent=running?'翻訳停止':'翻訳開始';$('translate-symbol').className=running?'pause':'play';$('translate').setAttribute('aria-label',running?'翻訳停止':'翻訳開始');$('voice').disabled=!running;$('voice').setAttribute('aria-checked',String(running&&Boolean(value.voiceEnabled)));$('timeline').setAttribute('aria-checked',String(Boolean(value.timelineVisible)));$('backend').disabled=running;$('speech-engine').disabled=running;}
async function refresh(){if(tabMode==='page'){await refreshPage();return;}if(busy)return;try{display(await send('status'));}catch(e){display({...state,error:e.message});}}
async function action(type,extra={}){if(busy)return;busy=true;$('translate').disabled=true;try{display(await send(type,extra));}catch(e){display({...state,error:e.message});}finally{busy=false;$('translate').disabled=!state.running&&!state.preparing&&state.assetReady===false;}}
$('translate').onclick=()=>action(state.running||state.preparing?'stop':'start');$('voice').onclick=()=>action('voice',{enabled:!state.voiceEnabled});$('timeline').onclick=()=>action('timeline',{visible:!state.timelineVisible});
function updateInputs(){$('volume-number').value=$('volume').value;$('speed-value').textContent=speeds[Number($('speed').value)].toFixed(2)+'×';$('voice-row').hidden=$('speech-engine').value!=='VOICEVOX';$('prepare-apple').hidden=$('backend').value!=='Apple';}
function restore(value){const v=settings(value);$('backend').value=v.backend;$('speech-engine').value=v.speechEngine;$('speaker').value=v.speaker;$('volume').value=v.volume;$('speed').value=speeds.indexOf(v.speed);$('autoSpeed').checked=v.autoSpeed;$('smooth').checked=v.smooth;updateInputs();}
async function saveSettings(){const value=settings({volume:$('volume').value,speed:speeds[Number($('speed').value)],speaker:$('speaker').value,autoSpeed:$('autoSpeed').checked,backend:$('backend').value,speechEngine:$('speech-engine').value,smooth:$('smooth').checked});try{await send('settings',{value});await refresh();}catch(e){$('preview-status').textContent=e.message;}}
$('volume').oninput=updateInputs;$('speed').oninput=updateInputs;$('volume-number').oninput=()=>{$('volume').value=Math.max(0,Math.min(100,Number($('volume-number').value)||0));};$('volume-number').onchange=()=>{updateInputs();saveSettings();};for(const id of ['volume','speed','speaker','autoSpeed','backend','speech-engine','smooth'])$(id).onchange=()=>{updateInputs();saveSettings();};
$('preview').onclick=async()=>{$('preview').disabled=true;$('preview-status').textContent='試聴用の音声を準備しています…';try{await saveSettings();const r=await send('preview');$('preview-status').textContent=r.message||'試聴しています';}catch(e){$('preview-status').textContent=e.message;}finally{$('preview').disabled=false;}};
$('open-settings').onclick=()=>{$('main-page').hidden=true;$('settings-page').hidden=false;};
$('close-settings').onclick=()=>{
  $('settings-page').hidden=true;$('main-page').hidden=false;
  $('main-page').append(playbackDetails);playbackDetails.hidden=tabMode==='page';
};
$('settings-playback').onclick=()=>{
  $('settings-page').append(playbackDetails);playbackDetails.hidden=false;playbackDetails.open=true;
};
async function openSettings(page){try{await send('openAppSettings',{page});$('settings-status').textContent='アプリの設定を開きました';}catch(e){$('settings-status').textContent=e.message;}}
for(const page of ['overview','dictionary','slides','models','history','support'])$('settings-'+page).onclick=()=>openSettings(page);$('prepare-apple').onclick=()=>openSettings('models');
let stored={};try{stored=await api.storage.local.get(['settings','popupTab']);}catch{}let initial=stored.settings||{volume:60,speed:1.25,speaker:2};try{initial=(await send('playbackGet')).settings||initial;}catch{}restore(initial);$('page-mode').value='original';if(stored.popupTab==='page')showTab('page');await refresh();setInterval(refresh,1200);
function neutralFocus(){if(!interacted)$('popup-root')?.focus?.({preventScroll:true});}neutralFocus();globalThis.requestAnimationFrame?.(neutralFocus);
