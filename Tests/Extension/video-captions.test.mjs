import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../../SafariExtension/Resources/video-captions.js', import.meta.url), 'utf8');

test('Japanese cues are ready before playback and removed when the capture ends', async () => {
  const cues = [];
  const calls = [];
  const track = {
    mode: 'disabled',
    addCue(cue) { cues.push(cue); },
    removeCue(cue) { cues.splice(cues.indexOf(cue), 1); }
  };
  const root = {adoptedStyleSheets:[]};
  const selectedVideo = {
    getRootNode: () => root,
    tagName: 'VIDEO', currentTime: 5,
    addTextTrack(kind, label, language) {
      assert.equal(kind, 'subtitles');
      assert.equal(language, 'ja');
      return track;
    }
  };
  let poll;
  let resolveReply;
  const context = {
    CSSStyleSheet: class {
      replaceSync(text) { this.text = text; }
    },
    VTTCue: class {
      constructor(startTime, endTime, text) { Object.assign(this, {startTime, endTime, text}); }
    },
    browser: {runtime: {sendMessage(request) {
      calls.push(request);
      return new Promise(resolve => { resolveReply = resolve; });
    }}},
    setTimeout(callback) { poll = callback; return 1; },
    clearTimeout() {}
  };
  vm.runInNewContext(source, context);

  const stop = context.__rTranslateVideoCaptions(selectedVideo, 'capture');
  assert.equal(track.mode, 'showing');
  assert.match(root.adoptedStyleSheets[0].text, /video::cue\(#rtranslate-caption\) \{ line-height: 0\.95; \}/);
  assert.match(root.adoptedStyleSheets[0].text, /video::cue\(\.rtranslate-caption\) \{ font-size: 0\.6em; \}/);
  resolveReply({ok:true, historySession:'live', cursor:2, rows:[
    {mediaStart:12, mediaEnd:12.5, japanese:'最初の字幕 <A>'},
    {mediaStart:13, mediaEnd:15, japanese:'次の字幕'}
  ]});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(selectedVideo.currentTime, 5);
  assert.ok(cues.every(cue => cue.id === 'rtranslate-caption'));
  assert.deepEqual(cues.map(cue => [cue.startTime, cue.endTime, cue.text]), [
    [12, 13, '<c.rtranslate-caption>最初の字幕 &lt;A&gt;</c>'], [13, 15, '<c.rtranslate-caption>次の字幕</c>']
  ]);
  const pending = poll();
  assert.equal(calls[1].cursor, 2);
  assert.equal(calls[1].historySession, 'live');
  stop();
  resolveReply({ok:true, historySession:'live', cursor:3, rows:[{mediaStart:16,mediaEnd:18,japanese:'停止後'}]});
  await pending;
  assert.equal(track.mode, 'disabled');
  assert.deepEqual(cues, []);
});
