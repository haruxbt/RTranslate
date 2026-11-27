(() => {
  if (globalThis.__rTranslateVideoCaptions) return;
  const api = globalThis.browser || globalThis.chrome;
  const tracks = new WeakMap();
  const styledRoots = new WeakSet();
  const cueStyle = 'video::cue(.rtranslate-caption) { font-size: 0.6em; }';

  function styleCaptions(media) {
    const root = media.getRootNode();
    if (styledRoots.has(root)) return;
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(cueStyle);
      root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
    } catch {
      const style = media.ownerDocument.createElement('style');
      style.textContent = cueStyle;
      (root.head ?? root).append(style);
    }
    styledRoots.add(root);
  }
  const escapeCueText = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  globalThis.__rTranslateVideoCaptions = (media, session) => {
    if (media.tagName !== 'VIDEO' || !media.addTextTrack || typeof VTTCue === 'undefined') return;
    let track;
    try {
      track = tracks.get(media) ?? media.addTextTrack('subtitles', 'R翻訳 日本語', 'ja');
      tracks.set(media, track);
      track.mode = 'showing';
    } catch { return; }
    try { styleCaptions(media); } catch { /* Keep the native track if styling is unavailable. */ }
    let stopped = false, timer, cursor = 0, historySession = '', lastCue;
    const cues = [];
    function clear() {
      for (const cue of cues) track.removeCue(cue);
      cues.length = 0;
      lastCue = undefined;
    }
    function append(row) {
      const start = row.mediaStart, end = row.mediaEnd;
      if (!Number.isFinite(start) || start < 0 || !Number.isFinite(end) || end <= start ||
          typeof row.japanese !== 'string' || !row.japanese.trim()) return;
      if (lastCue && start < lastCue.startTime) return;
      const text = `<c.rtranslate-caption>${escapeCueText(row.japanese)}</c>`;
      const until = Math.max(end, start + 1.5);
      if (lastCue && start === lastCue.startTime) {
        lastCue.text += '\n' + text;
        lastCue.endTime = Math.max(lastCue.endTime, until);
        return;
      }
      if (lastCue && lastCue.endTime > start) lastCue.endTime = start;
      const cue = new VTTCue(start, until, text);
      track.addCue(cue);
      cues.push(cue);
      lastCue = cue;
    }
    async function poll() {
      try {
        const reply = await api.runtime.sendMessage({type:'captureCaptions',session,cursor,historySession});
        if (stopped || !reply?.ok) return;
        if (reply.historySession !== historySession) {
          clear();
          historySession = reply.historySession;
        }
        for (const row of reply.rows ?? []) append(row);
        cursor = reply.cursor ?? cursor;
      } catch {
        // The caption track can outlive a transient connection failure.
      } finally {
        if (!stopped) timer = setTimeout(poll, 500);
      }
    }
    void poll();
    return () => {
      stopped = true;
      clearTimeout(timer);
      clear();
      track.mode = 'disabled';
    };
  };
})();
