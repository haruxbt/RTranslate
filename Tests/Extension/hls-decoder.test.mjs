import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs/promises';

for (const lookahead of [0,25]) test(
  lookahead ? 'HLS can release bounded audio in advance while paused and stop immediately on seek'
    : 'HLS keeps pace when the browser coalesces the capture timer into one-second callbacks',
  async () => {
  let milliseconds = 0;
  let pump;
  let decoderOutput;
  let capturedFrames = 0;
  let accepting = true, failure, firstStart;
  const callbacks = new Map();
  const media = {
    currentSrc: 'https://example.test/audio.m3u8', currentTime: 0,
    paused: lookahead>0, ended: false, playbackRate: 1,
    addEventListener: (name, callback) => callbacks.set(name, callback),
    removeEventListener: name => callbacks.delete(name)
  };
  const file = {
    stop() {}, start() {}, setExtractionOptions() {},
    getTrackById: () => ({mdia:{minf:{stbl:{stsd:{entries:[{
      esds:{esd:{findDescriptor:() => ({findDescriptor:() => ({data:new Uint8Array([1])})})}}
    }]}}}}})
  };
  class Hls {
    static isSupported() { return true; }
    static Events = {BUFFER_APPENDING: 1, LEVEL_LOADED: 2, ERROR: 3};
    on() {}
    loadSource() {}
    attachMedia() {}
    stopLoad() {}
    startLoad() {}
    destroy() {}
  }
  const context = vm.createContext({
    performance: {now: () => milliseconds},
    setInterval: callback => { pump = callback; },
    clearInterval() {}, setTimeout() {}, clearTimeout() {},
    document: {
      createElement: () => ({style:{}, attachShadow:() => ({append(){}}), async play(){}, pause(){}, remove(){}}),
      documentElement: {append(){}}
    },
    AudioDecoder: class {
      constructor({output}) { decoderOutput = output; }
      configure() {}
      close() {}
    }
  });
  const mp4 = new vm.SyntheticModule(['createFile'], function () {
    this.setExport('createFile', () => file);
  }, {context});
  const source = await fs.readFile(new URL('../../SafariExtension/Resources/hls-decoder.mjs', import.meta.url), 'utf8');
  const decoder = new vm.SourceTextModule(source, {context});
  await decoder.link(() => mp4);
  await decoder.evaluate();
  const session = decoder.namespace.createHLSCapture({
    media, url: media.currentSrc, Hls, lookahead, canAcceptAudio: () => accepting,
    onBlock: (samples, _rate, start) => { firstStart ??= start; capturedFrames += samples.length; },
    onError: message => { failure = message; }
  });
  file.onReady({audioTracks:[{id:1,codec:'mp4a.40.2',audio:{sample_rate:16000,channel_count:1}}]});
  for (let second = 0; second < 35; second++) {
    decoderOutput({timestamp:second * 1e6, sampleRate:16000, numberOfFrames:16000, numberOfChannels:1,
                   copyTo: samples => samples.fill(0.25), close(){}});
  }
  const control = await session;
  if (lookahead) {
    accepting = false;
    milliseconds = 1000; pump();
    assert.equal(capturedFrames, 0);
    accepting = true;
    for (let second = 2; second <= 16; second++) {
      milliseconds = second * 1000;
      pump();
    }
    assert.equal(firstStart, 0);
    assert.equal(media.currentTime, 0);
    assert.equal(capturedFrames, 400000);
    callbacks.get('seeking')();
    assert.match(failure, /再生位置が変わりました/);
    milliseconds=17000; pump();
    assert.equal(capturedFrames,400000);
    assert.equal(callbacks.has('timeupdate'), false);
    return;
  }
  for (let second = 1; second <= 10; second++) {
    milliseconds = second * 1000;
    media.currentTime = second;
    pump();
  }
  assert.equal(capturedFrames, 160000);
  milliseconds = 11000;
  media.currentTime = 11;
  callbacks.get('timeupdate')();
  assert.equal(capturedFrames, 176000);
  control.stop();
  assert.equal(callbacks.has('timeupdate'), false);
});
