import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
const source=await fs.readFile(new URL('../../SafariExtension/Resources/media-discovery.js',import.meta.url),'utf8');
function scope(media=[],elements=[]){return {querySelectorAll:selector=>selector==='video,audio'?media:elements};}
test('discovers an ISC2-style video behind three open shadow roots with stable index',()=>{
 const video={id:'owned-video'},plain={id:'plain-audio'};
 const deep=scope([video]),mid=scope([],[{shadowRoot:deep}]),outer=scope([],[{shadowRoot:mid}]);
 const document=scope([plain],[{shadowRoot:outer}]),context=vm.createContext({document});
 assert.equal(document.querySelectorAll('video,audio').length,1);
 vm.runInContext(source,context);const result=context.__rTranslateMedia();
 assert.equal(result.length,2);assert.equal(result[0],plain);assert.equal(result[1],video);
 vm.runInContext(source,context);assert.equal(context.__rTranslateMedia()[1],video);
});
test('discovery stays within the granted frame and respects inaccessible shadow roots',()=>{
 const inaccessible={tagName:'IFRAME',get contentDocument(){throw Error('must not inspect another frame');}},closed={shadowRoot:null};
 const context=vm.createContext({document:scope([],[inaccessible,closed])});vm.runInContext(source,context);
 assert.equal(context.__rTranslateMedia().length,0);
});
