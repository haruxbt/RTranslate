(() => {
 const api=globalThis.browser || globalThis.chrome,id='webinar-nihongo-timeline';
 if(globalThis.__rTranslateTimelineV2)return;
 // Replace a panel from the previous extension build without reloading video.
 document.getElementById(id)?.remove();
 let host=null,history,empty,pending,follow,latest,timer,cursor=0,historySession='',following=true,polling=false,lastSpeaking='',anchorID='',expectedScroll=null;
 const rows=new Map();
 function scrollToPosition(){
  if(!following||!history)return;
  const active=rows.get(anchorID)?.element;
  // Pin the spoken paragraph to one reading position; appending new paragraphs
  // must not push the listener's current text up and down.
  const top=active?active.offsetTop-history.clientHeight*.55:0;
  expectedScroll=Math.min(Math.max(0,top),Math.max(0,history.scrollHeight-history.clientHeight));history.scrollTop=expectedScroll;
 }
 function setFollowing(value){following=value;follow.setAttribute('aria-checked',String(value));latest.hidden=value;if(value)scrollToPosition();}
 function mount(){
  if(host){document.documentElement.append(host);poll();return;}
  host=document.createElement('div');host.id=id;const shadow=host.attachShadow({mode:'closed'});
  const style=document.createElement('link');style.rel='stylesheet';style.href=api.runtime.getURL('timeline.css');shadow.append(style);style.onload=scrollToPosition;
  const aside=document.createElement('aside');aside.setAttribute('role','complementary');aside.setAttribute('aria-label','翻訳タイムライン');
  const header=document.createElement('header'),title=document.createElement('h2');title.textContent='翻訳タイムライン';
  const close=document.createElement('button');close.className='close';close.textContent='×';close.setAttribute('aria-label','タイムラインを閉じる');close.onclick=()=>setVisible(false);header.append(title,close);
  const toolbar=document.createElement('div');toolbar.className='toolbar';const label=document.createElement('span');label.id='r-follow-label';label.textContent='自動スクロール';
  follow=document.createElement('button');follow.className='switch';follow.setAttribute('role','switch');follow.setAttribute('aria-label','自動スクロール');follow.setAttribute('aria-checked','true');follow.append(document.createElement('span'));follow.onclick=()=>setFollowing(!following);toolbar.append(label,follow);
  history=document.createElement('div');history.className='history';history.tabIndex=0;history.setAttribute('aria-label','翻訳履歴');
  empty=document.createElement('p');empty.className='empty';empty.textContent='翻訳の接続を確認しています…';history.append(empty);
  history.addEventListener('wheel',event=>{if(event.deltaY<0)setFollowing(false);},{passive:true});
  history.addEventListener('touchstart',()=>setFollowing(false),{passive:true});
  history.addEventListener('keydown',event=>{if(['ArrowUp','PageUp','Home'].includes(event.key))setFollowing(false);});
  history.addEventListener('scroll',()=>{if(following&&expectedScroll!==null&&history.scrollTop<expectedScroll-3)setFollowing(false);});
  const footer=document.createElement('footer');pending=document.createElement('p');pending.className='pending';pending.setAttribute('role','status');
  latest=document.createElement('button');latest.className='latest';latest.textContent='最新へ';latest.hidden=true;latest.onclick=()=>setFollowing(true);footer.append(pending,latest);
  aside.append(header,toolbar,history,footer);shadow.append(aside);document.documentElement.append(host);poll();
 }
 function setVisible(value){clearTimeout(timer);if(value){if(!host?.isConnected)mount();else void poll();}else host?.remove();return {ok:true,visible:Boolean(host?.isConnected)};}
 async function poll(){
  if(!host?.isConnected||polling)return;polling=true;
  try{
   const result=await api.runtime.sendMessage({type:'timelineData',cursor,historySession});
   if(!result?.ok){const error=result?.error || '接続を確認してください';pending.textContent=error;if(!rows.size)empty.textContent=error;return;}
   empty.textContent=result.emptyMessage || '音声を認識・翻訳しています…';
   if(typeof result.historySession==='string' && result.historySession!==historySession){
    for(const item of rows.values())item.element.remove();
    rows.clear();cursor=0;lastSpeaking='';anchorID='';expectedScroll=null;
    following=true;follow.setAttribute('aria-checked','true');latest.hidden=true;
    history.append(empty);history.scrollTop=0;
   }
   for(const row of result.rows || []){
    if(!row.japanese)continue;let item=rows.get(row.id);
    if(!item){
     const element=document.createElement('article');element.className='row';const meta=document.createElement('div');meta.className='meta';
     const time=document.createElement('time');
     if(Number.isFinite(row.mediaStart)&&row.mediaStart>=0){
      const seconds=Math.floor(row.mediaStart);
      time.title='動画内の発話時刻';time.textContent=`${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;
     }else if(row.receivedAt>0){
      const date=new Date(row.receivedAt*1000);time.title='訳文の記録時刻';time.dateTime=date.toISOString();
      time.textContent=date.toLocaleTimeString('ja-JP',{hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false});
     }
     const speaking=document.createElement('span');speaking.className='speaking-label';speaking.textContent='読み上げ中';speaking.hidden=true;const text=document.createElement('p');meta.append(time,speaking);element.append(meta,text);history.append(element);item={element,text,speaking};rows.set(row.id,item);
    }
    if(item.text.textContent!==row.japanese)item.text.textContent=row.japanese;
   }
   if(rows.size)empty.remove();cursor=result.cursor ?? cursor;historySession=typeof result.historySession==='string'?result.historySession:historySession;
   const speaking=result.speakingID || '';
   if(lastSpeaking!==speaking){const old=rows.get(lastSpeaking);if(old){old.element.removeAttribute('aria-current');old.speaking.hidden=true;}lastSpeaking=speaking;}
   if(speaking)anchorID=speaking;else if(!anchorID&&rows.size)anchorID=rows.keys().next().value;
   const active=rows.get(speaking);if(active){active.element.setAttribute('aria-current','true');active.speaking.hidden=false;}
   if(result.running&&result.lookahead){
    const parts=[`音声準備済み ${result.preparedSpeech ?? 0}件`];
    if(Number.isFinite(result.inputLead)){
     const lead=Math.round(result.inputLead);
     parts.unshift(lead>=0?`取得 ${lead}秒先`:`取得 ${-lead}秒遅れ`);
    }
    if(result.speechLag>=1)parts.push(`読み上げ待ち ${Math.round(result.speechLag)}秒`);
    pending.textContent=parts.join(' · ');
   }else pending.textContent=result.pending?'…':'';
   scrollToPosition();
  }catch{if(pending)pending.textContent='接続を確認してください';if(!rows.size&&empty)empty.textContent='R翻訳との接続を確認してください。拡張から翻訳を開始し直すと再接続します。';}
  finally{polling=false;if(host?.isConnected)timer=setTimeout(poll,900);}
 }
 globalThis.__rTranslateTimelineV2=value=>{
  if(typeof value==='boolean')setVisible(value);
  return {ready:true,visible:Boolean(host?.isConnected),
    fullscreen:Boolean(document.fullscreenElement || document.webkitFullscreenElement)};
 };
 addEventListener('pagehide',()=>{clearTimeout(timer);host?.remove();});
})();
