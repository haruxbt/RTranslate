import test from 'node:test';
import assert from 'node:assert/strict';
import {webURL,settings,Resampler,pcm16,mergeRows} from '../../SafariExtension/Resources/protocol.mjs';
test('only http(s) targets and normal preset voices',()=>{
 assert.equal(webURL('file:///Users/example/private.txt'),null);
 assert.equal(webURL('javascript:alert(1)'),null);
 assert.equal(webURL('https://www.brighttalk.com/webcast/1/2'),'https://www.brighttalk.com/webcast/1/2');
 assert.deepEqual(settings({volume:150,speed:8,speaker:0}),{volume:100,speed:1.25,speaker:2,autoSpeed:true});
 assert.equal(settings({volume:-5,speaker:52}).volume,0);
});
test('stream resampling preserves duration across arbitrary callback boundaries',()=>{
 for(const rate of [44100,48000]){
  const input=Float32Array.from({length:rate*2},(_,i)=>Math.sin(2*Math.PI*440*i/rate));
  const whole=new Resampler(rate).push(input), streaming=new Resampler(rate);let result=[];
  for(let i=0;i<input.length;i+=4096)result.push(...streaming.push(input.slice(i,i+4096)));
  assert.ok(Math.abs(result.length-32000)<=1);
  assert.equal(result.length,whole.length);
  assert.ok(Math.max(...result.map((x,i)=>Math.abs(x-whole[i])))<1e-8);
 }
});
test('signed little endian PCM clips without wrapping',()=>{
 const view=new DataView(pcm16([-2,-1,0,1,2]).buffer);
 assert.deepEqual([0,1,2,3,4].map(i=>view.getInt16(i*2,true)),[-32768,-32768,0,32767,32767]);
});
test('timeline retains repeated translations by audio identity and updates by ID',()=>{
 const rows=mergeRows([{id:'a',japanese:'変更しないでください。'}],[{id:'b',japanese:'変更しないでください。'},{id:'a',japanese:'24時間は変更しないでください。'}]);
 assert.equal(rows.length,2);assert.equal(rows[0].japanese,'24時間は変更しないでください。');
});
