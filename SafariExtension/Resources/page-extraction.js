// Adapted from RSpeech (MIT).
globalThis.__rTranslatePageText = (respectSelection = true) => {
  const excluded = 'script,style,noscript,template,form,input,textarea,select,button,[contenteditable],nav,aside,header,footer,h1,[role="navigation"],[role="banner"],[role="dialog"],[aria-hidden="true"],.entry-title,.post-title,img,picture,svg,canvas,[role="img"],figcaption,.wp-caption-text,.wp-element-caption,.image-caption,.photo-caption,.figure-caption,.media-caption,.image-credit,.photo-credit,.caption-credit,.image-source,.photo-source,.copyright,[itemprop="caption"],[itemprop="creditText"],[itemprop="copyrightNotice"]';
  function visible(element) {
    const style = getComputedStyle(element);
    return !element.hidden && style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse';
  }
  const bodySelectors = '[itemprop="articleBody"],.znc,.markdown-body,.entry-content,.post-content,.article-body,.article-content';
  const specific = [...document.querySelectorAll(bodySelectors)]
    .filter(element => visible(element) && element.getBoundingClientRect().width > 0 && element.innerText.trim());
  const candidates = [...document.querySelectorAll('article,main,[role="main"]')]
    .filter(element => visible(element) && element.getBoundingClientRect().width > 0)
    .sort((a, b) => b.innerText.length - a.innerText.length);
  let root = specific.sort((a, b) => b.innerText.length - a.innerText.length)[0] || candidates[0] || document.body;
  const selected = respectSelection ? window.getSelection() : null;
  const selection = selected && selected.rangeCount && !selected.isCollapsed
    && document.body?.contains(selected.getRangeAt(0).startContainer) ? selected.getRangeAt(0) : null;
  let start = null;
  if (selection) {
    const element = selection.startContainer.nodeType === Node.ELEMENT_NODE ? selection.startContainer : selection.startContainer.parentElement;
    if (!root || !root.contains(selection.startContainer)) root = element?.closest(bodySelectors + ',article,main,[role="main"]') || document.body;
    start = selection.cloneRange(); start.collapse(true);
  }
  const relatedSections = '.related-posts,.related-articles,.relatedPosts,.relatedArticles,.jp-relatedposts,.yarpp-related,#related-posts,#related-articles,[aria-label="関連記事"],[data-component="RelatedArticles"]';
  function startsRelatedSection(node) {
    if (node.matches(relatedSections)) return true;
    // A standalone label/heading is a boundary; a mention inside a sentence is not.
    if (!node.matches('h2,h3,h4,h5,h6,[role="heading"],p,div')) return false;
    const label = node.textContent.replace(/[\s\u3000:：]+/g, '').toLowerCase();
    return ['関連記事', '関連する記事', 'relatedarticles', 'relatedposts'].includes(label);
  }
  function imageMetadata(node) {
    // Generic caption classes are used outside images too; limit them to image containers.
    if (node.matches('.caption,.credit,.credits') && (node.closest('figure,.wp-caption,.image,.photo,.picture,.image-container,.photo-container') || node.previousElementSibling?.matches('img,picture,svg,canvas'))) return true;
    if (!node.matches('p,div,span,small')) return false;
    if (node.querySelector('p,div,section,article,figure,ul,ol,table,h1,h2,h3,h4,h5,h6')) return false;
    const label = node.textContent.trim();
    // Standalone attribution labels, rather than ordinary prose mentioning a source.
    return label.length <= 512 && /^(?:(?:画像(?:の)?出典|写真(?:の)?出典|画像提供|写真提供|撮影|出典|image\s+credit|photo\s+credit|image\s+source|source)\s*[:：]|©|copyright\s*(?:©|\(c\)|[0-9]{4}))/i.test(label);
  }
  let ended = false;
  function content(node) {
    if (ended) return '';
    if (node.nodeType === Node.TEXT_NODE) {
      if (start && start.comparePoint(node, node.length) <= 0) return '';
      const text = start && node === start.startContainer ? node.nodeValue.slice(start.startOffset) : node.nodeValue;
      return text.replace(/\s+/g, ' ');
    }
    if (node.nodeType !== Node.ELEMENT_NODE || node.matches(excluded) || !visible(node) || imageMetadata(node)) return '';
    if (startsRelatedSection(node)) { ended = true; return ''; }
    if (node.tagName === 'BR') return '\n';
    const text = [...node.childNodes].map(content).join('');
    const block = /^(block|flex|grid|table|list-item)/.test(getComputedStyle(node).display);
    return block ? '\n' + text + '\n' : text;
  }
  const text = root ? content(root).split('\n').map(line => line.trim()).filter(Boolean).join('\n') : '';
  return {url: location.href, text};
};
