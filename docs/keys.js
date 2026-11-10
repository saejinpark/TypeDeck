// Enter in text fields, including an Enter pressed to finish a Hangul syllable.

const GRACE_MS = 60;

/**
 * Wraps an Enter handler. Chrome on macOS reports an Enter that finishes a Hangul syllable only
 * as part of the composition and sends no second Enter, so a plain "ignore while composing"
 * check makes people press Enter twice. This runs `handler` once the composition has ended;
 * when a browser does send a second, ordinary Enter (Safari), that one runs and the delayed one
 * is dropped. Returns a keydown listener that reports whether the key was Enter.
 */
export function enterHandler(handler) {
  let timer = null;
  return (e) => {
    if (e.key !== 'Enter') return false;
    clearTimeout(timer);
    timer = null;
    if (e.isComposing || e.keyCode === 229) {
      // Leave this event alone: it is what commits the syllable.
      const later = { target: e.target, metaKey: e.metaKey, ctrlKey: e.ctrlKey, shiftKey: e.shiftKey, preventDefault() {} };
      timer = setTimeout(() => {
        timer = null;
        const stillThere = typeof document === 'undefined' || document.activeElement === later.target;
        if (stillThere) handler(later);
      }, GRACE_MS);
      return true;
    }
    handler(e);
    return true;
  };
}
