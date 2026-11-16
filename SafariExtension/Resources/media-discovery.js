// Runs in the extension's isolated world in each permitted frame. Do not enter
// frames here: Safari supplies frame IDs and enforces origin permissions.
(() => {
  if (globalThis.__rTranslateMedia) return;
  globalThis.__rTranslateMedia = (root = document) => {
    const media = [];
    function visit(scope) {
      media.push(...scope.querySelectorAll('video,audio'));
      for (const element of scope.querySelectorAll('*')) {
        if (element.shadowRoot) visit(element.shadowRoot);
      }
    }
    visit(root);
    return media;
  };
})();
