import {VOICES, settings} from './protocol.mjs';
const api=globalThis.browser || globalThis.chrome, $=id=>document.getElementById(id);
let userInteracted=false;
globalThis.addEventListener?.('keydown',()=>{userInteracted=true;},{capture:true,once:true});
globalThis.addEventListener?.('pointerdown',()=>{userInteracted=true;},{capture:true,once:true});
const speeds=[.75,1,1.25,1.5,1.75,2];let state={},busy=false;
for(const [id,name] of VOICES){const opt=document.createElement('option');opt.value=id;opt.textContent=name+' / ノーマル';$('speaker').append(opt);}
function display(value){
 state=value;const running=Boolean(value.running||value.preparing);
 $('translate').disabled=busy||(!running&&value.assetReady===false);
 document.body.dataset.running=String(running);document.body.dataset.error=String(Boolean(value.error));
 $('site').textContent=value.host || '現在のタブ';
 $('status').textContent=value.error || value.message || (running?'翻訳中':'開始できます');
 $('translate-label').textContent=running?'翻訳停止':'翻訳開始';$('translate-symbol').className=running?'pause':'play';
 $('translate').setAttribute('aria-label',running?'翻訳停止':'翻訳開始');
 $('voice').disabled=!running;$('voice').setAttribute('aria-checked',String(running&&Boolean(value.voiceEnabled)));
 $('timeline').setAttribute('aria-checked',String(Boolean(value.timelineVisible)));
}
async function send(type,extra={}){const result=await api.runtime.sendMessage({type,...extra});if(!result?.ok)throw Error(result?.error || '拡張との接続を確認してください。');return result;}
async function action(type,extra={}){
 if(busy)return;busy=true;$('translate').disabled=true;
 try{display(await send(type,extra));}catch(error){display({...state,error:error.message});}
 finally{busy=false;$('translate').disabled=!state.running&&!state.preparing&&state.assetReady===false;}
}
$('translate').onclick=()=>action(state.running||state.preparing?'stop':'start');
$('voice').onclick=()=>action('voice',{enabled:!state.voiceEnabled});
$('timeline').onclick=()=>action('timeline',{visible:!state.timelineVisible});
function updateInputs(){
 $('volume-number').value=$('volume').value;$('speed-value').textContent=speeds[Number($('speed').value)].toFixed(2)+'×';
 $('credit').textContent='VOICEVOX:'+VOICES.find(([id])=>id===Number($('speaker').value))[1];
}
async function saveSettings(){
 const value=settings({volume:$('volume').value,speed:speeds[Number($('speed').value)],speaker:$('speaker').value,autoSpeed:$('autoSpeed').checked});
 try{await send('settings',{value});await refresh();}catch(error){$('preview-status').textContent=error.message;}
}
$('volume').oninput=updateInputs;$('speed').oninput=updateInputs;
$('volume-number').oninput=()=>{$('volume').value=Math.max(0,Math.min(100,Number($('volume-number').value)||0));};
$('volume-number').onchange=()=>{updateInputs();saveSettings();};
for(const name of ['volume','speed','speaker','autoSpeed'])$(name).onchange=()=>{updateInputs();saveSettings();};
$('preview').onclick=async()=>{
 $('preview').disabled=true;$('preview-status').textContent='試聴用の音声を準備しています…';
 try{await saveSettings();const result=await send('preview');$('preview-status').textContent=result.message || '試聴しています';}
 catch(error){$('preview-status').textContent=error.message;}finally{$('preview').disabled=false;}
};
const stored=await api.storage.local.get('settings'),initial=settings(stored.settings || {volume:60,speed:1.25,speaker:2});
$('speaker').value=initial.speaker;$('volume').value=initial.volume;$('speed').value=speeds.indexOf(initial.speed);$('autoSpeed').checked=initial.autoSpeed;updateInputs();
async function refresh(){if(busy)return;try{display(await send('status'));}catch(error){display({...state,error:error.message});}}
await refresh();setInterval(refresh,1200);

let dictionary=null,dictBusy=false;
function dictEntries(text){return String(text || '').split('\n').filter(x=>x.trim()).map(x=>{const i=x.indexOf('=');return {source:x.slice(0,i).trim(),target:x.slice(i+1).trim()};});}
function renderDictionary(){
 const kind=$('dict-kind').value || 'glossary',entries=dictEntries(dictionary?.[kind]);$('dict-list').replaceChildren();
 $('dict-target-title').textContent=kind==='readings'?'読み':kind==='displayTerms'?'表示する表記':'訳語';
 $('dict-source').placeholder=kind==='readings'?'Square':kind==='displayTerms'?'担当の方':'SOC';
 $('dict-target').placeholder=kind==='readings'?'スクエア':kind==='displayTerms'?'担当のかた':'SOC';
 for(const entry of entries){
  const row=document.createElement('div');row.className='dict-entry';const words=document.createElement('div'),source=document.createElement('strong'),target=document.createElement('small');source.textContent=entry.source;target.textContent=entry.target;words.append(source,target);
  const remove=document.createElement('button');remove.textContent='×';remove.setAttribute('aria-label',entry.source+'を辞書から削除');remove.onclick=()=>changeDictionary(entries.filter(x=>x.source!==entry.source));row.append(words,remove);$('dict-list').append(row);
 }
}
async function loadDictionary(){
 if(dictionary||dictBusy)return;dictBusy=true;$('dict-status').textContent='読み込み中…';
 try{dictionary=(await send('dictionaryGet')).dictionary;renderDictionary();$('dict-status').textContent='';}catch(error){$('dict-status').textContent=error.message;}finally{dictBusy=false;}
}
async function changeDictionary(entries){
 if(!dictionary||dictBusy)return;dictBusy=true;const kind=$('dict-kind').value,next={...dictionary,[kind]:entries.map(x=>x.source+' = '+x.target).join('\n')};
 try{await send('dictionarySave',{dictionary:next});dictionary=next;renderDictionary();$('dict-status').textContent='保存しました';}catch(error){$('dict-status').textContent=error.message;}finally{dictBusy=false;}
}
$('dictionary-panel').ontoggle=()=>{if($('dictionary-panel').open)loadDictionary();};
$('dict-kind').onchange=()=>{renderDictionary();$('dict-status').textContent='';};
$('dict-add').onclick=async()=>{
 await loadDictionary();if(!dictionary)return;
 const source=$('dict-source').value.trim(),target=$('dict-target').value.trim();
 if(!source||!target||/[=\r\n]/.test(source)||/[\r\n]/.test(target)){$('dict-status').textContent='用語と変換先を入力してください';return;}
 const entries=dictEntries(dictionary[$('dict-kind').value]).filter(x=>x.source.toLowerCase()!==source.toLowerCase());entries.push({source,target});
 await changeDictionary(entries);
};

$('open-settings').onclick=()=>{$('main-page').hidden=true;$('settings-page').hidden=false;refreshAssets();};
$('close-settings').onclick=()=>{$('settings-page').hidden=true;$('main-page').hidden=false;};
async function refreshAssets(){try{const result=await send('assetsStatus');$('assets-status').textContent=result.message;}catch(e){$('assets-status').textContent=e.message;}}
$('prepare-assets').onclick=async()=>{try{await send('assetsPrepare');await refreshAssets();}catch(e){$('assets-status').textContent=e.message;}};
let removalToken='';
function removal(){return {models:$('remove-models').checked,history:$('remove-history').checked,app:$('remove-app').checked};}
$('review-uninstall').onclick=async()=>{try{const r=await send('uninstallReview',{selection:removal()});removalToken=r.token;$('uninstall-summary').textContent=r.message;$('uninstall-review').hidden=false;}catch(e){$('uninstall-status').textContent=e.message;}};
$('cancel-uninstall').onclick=()=>{$('uninstall-review').hidden=true;};
$('confirm-uninstall').onclick=async()=>{try{const r=await send('uninstall',{selection:removal(),token:removalToken});$('uninstall-status').textContent=r.message;$('uninstall-review').hidden=true;}catch(e){$('uninstall-status').textContent=e.message;}};

setInterval(()=>{if(!$('settings-page').hidden)refreshAssets();},1500);

// Neutral initial focus; keyboard navigation still keeps visible focus rings.
function neutralInitialFocus(){if(!userInteracted)$('popup-root')?.focus?.({preventScroll:true});}
neutralInitialFocus();globalThis.requestAnimationFrame?.(neutralInitialFocus);
