// TypeDeck core: pure logic shared by the UI and the tests. No DOM access here.

export const normalize = (s) => (s ?? '').normalize('NFC');
export const chars = (s) => Array.from(s);

const SEPARATORS = ['\t', ' = ', ' : ', '=', ':'];

/** Parses "key = value" lines (tab, " = ", " : ", "=", ":" in that order of preference). */
export function parseCards(text) {
  const cards = [];
  for (const raw of (text ?? '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const sep = SEPARATORS.find((s) => line.includes(s));
    if (!sep) continue;
    const i = line.indexOf(sep);
    const q = line.slice(0, i).trim();
    const a = line.slice(i + sep.length).trim();
    if (q && a) cards.push([q, a]);
  }
  return cards;
}

export function serializeCards(cards) {
  return cards.map(([q, a]) => (q.includes('=') || q.includes(':') ? `${q}\t${a}` : `${q} = ${a}`)).join('\n');
}

/**
 * Compares what was typed with the answer, character by character.
 * States: ok, bad, comp (still being composed by an IME), todo, extra.
 */
export function diff(answer, typed, composing) {
  const a = chars(answer);
  const t = chars(typed);
  const out = [];
  const n = Math.max(a.length, t.length);
  for (let i = 0; i < n; i++) {
    const isLastTyped = i === t.length - 1;
    if (i < t.length && i < a.length) {
      const state = composing && isLastTyped ? 'comp' : t[i] === a[i] ? 'ok' : 'bad';
      out.push({ ch: a[i], typed: t[i], state });
    } else if (i < a.length) {
      out.push({ ch: a[i], state: 'todo' });
    } else {
      out.push({ ch: t[i], state: composing && isLastTyped ? 'comp' : 'extra' });
    }
  }
  return out;
}

export function shuffled(list, rng = Math.random) {
  const a = list.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export const REQUEUE_GAP = 4;
export const MAX_REQUEUES = 3;

/** One round through a deck. Cards that were missed come back a few cards later. */
export class Session {
  constructor(cards, { shuffle = true, reverse = false, rng = Math.random } = {}) {
    this.items = cards.map(([q, a], id) => ({
      id,
      q: reverse ? a : q,
      a: normalize(reverse ? q : a),
    }));
    const order = this.items.map((it) => it.id);
    this.queue = shuffle ? shuffled(order, rng) : order;
    this.pos = 0;
    this.requeues = new Map();
    this.first = new Map(); // id -> clean on first attempt
    this.keystrokes = 0;
    this.activeMs = 0;
    this.streak = 0;
    this.bestStreak = 0;
    this.resetCard();
  }

  resetCard() {
    this.typed = '';
    this.composing = false;
    this.revealed = false;
    this.hadError = false;
    this.cardStart = null;
  }

  get finished() { return this.pos >= this.queue.length; }
  get current() { return this.finished ? null : this.items[this.queue[this.pos]]; }
  get remaining() { return this.queue.length - this.pos; }

  keystroke(now) {
    if (this.finished) return;
    this.keystrokes++;
    if (this.cardStart === null) this.cardStart = now;
  }

  /** Feed the full text of the input. Returns 'advance' when the answer was completed. */
  input(text, composing, now) {
    const card = this.current;
    if (!card) return 'none';
    this.typed = normalize(text);
    this.composing = composing;
    if (this.typed && this.cardStart === null) this.cardStart = now;
    if (this.typed === card.a) {
      this.complete(now);
      return 'advance';
    }
    if (diff(card.a, this.typed, composing).some((d) => d.state === 'bad' || d.state === 'extra')) {
      this.hadError = true;
    }
    return 'none';
  }

  /**
   * Like input(), but text that runs past the answer (a paste, or several characters arriving
   * in one event) completes the card and carries the rest over to the next one.
   */
  feed(text, composing, now) {
    let t = normalize(text);
    let advanced = 0;
    while (!this.finished && !composing && t.length > this.current.a.length && t.startsWith(this.current.a)) {
      const a = this.current.a;
      this.input(a, false, now);
      advanced++;
      t = t.slice(a.length);
    }
    if (this.finished) return { advanced, rest: '' };
    if (advanced && !t) return { advanced, rest: '' };
    if (this.input(t, composing, now) === 'advance') return { advanced: advanced + 1, rest: '' };
    return { advanced, rest: t };
  }

  /** Enter key. Reveals the answer the first time. */
  submit() {
    if (this.finished) return 'none';
    if (this.revealed) return 'shake';
    this.revealed = true;
    return 'reveal';
  }

  /** Tab key. Gives up on the card for now; it comes back later. */
  skip(now) {
    if (this.finished) return 'none';
    this.revealed = true;
    this.complete(now);
    return 'advance';
  }

  complete(now) {
    const card = this.current;
    const clean = !this.hadError && !this.revealed;
    if (!this.first.has(card.id)) this.first.set(card.id, clean);
    if (this.cardStart !== null) this.activeMs += Math.max(0, now - this.cardStart);
    if (clean) {
      this.streak++;
      this.bestStreak = Math.max(this.bestStreak, this.streak);
    } else {
      this.streak = 0;
      const n = this.requeues.get(card.id) ?? 0;
      if (n < MAX_REQUEUES) {
        this.requeues.set(card.id, n + 1);
        const at = Math.min(this.pos + 1 + REQUEUE_GAP, this.queue.length);
        this.queue.splice(at, 0, card.id);
      }
    }
    this.pos++;
    this.resetCard();
  }

  upcoming(n) {
    return this.queue.slice(this.pos + 1, this.pos + 1 + n).map((id) => this.items[id]);
  }

  get missed() {
    return [...this.first].filter(([, clean]) => !clean).map(([id]) => this.items[id]);
  }

  get accuracy() {
    if (this.first.size === 0) return null;
    const clean = [...this.first.values()].filter(Boolean).length;
    return clean / this.first.size;
  }

  /** Keystrokes per minute (Korean "타수"). */
  get kpm() {
    if (this.activeMs < 1000) return null;
    return (this.keystrokes / this.activeMs) * 60000;
  }
}

/* ---------- IME-safe input tracking ----------
   Chrome on macOS misbehaves when an input's value or focus changes while a Hangul syllable is
   still being composed: the syllable is re-inserted later and the first Backspace goes to that
   ghost composition. So the web app never touches the input during composition. Instead the
   input keeps everything typed, and this tracker remembers where the current card starts. */

const HANGUL_BASE = 0xac00;
const HANGUL_LAST = 0xd7a3;
// Final consonant index (1-27) -> compatibility jamo.
const FINALS = [null, ...'ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ'];
// Compound final -> [first, second] final indices.
const COMPOUND_FINALS = { 3: [1, 19], 5: [4, 22], 6: [4, 27], 9: [8, 1], 10: [8, 16], 11: [8, 17], 12: [8, 19], 13: [8, 25], 14: [8, 26], 15: [8, 27], 18: [17, 19] };

function syllable(ch) {
  const code = ch?.codePointAt(0);
  if (code === undefined || code < HANGUL_BASE || code > HANGUL_LAST) return null;
  const s = code - HANGUL_BASE;
  return { lv: Math.floor(s / 28), t: s % 28 };
}

/**
 * When the previous card ended on a syllable still being composed, the next consonant can be
 * absorbed into it as a final ("다" + ㄱ -> "닥"). Returns the absorbed jamo ("ㄱ"), or null when
 * `next` is not `prev` with one more consonant.
 */
export function absorbedJamo(prev, next) {
  const p = syllable(prev);
  const n = syllable(next);
  if (!p || !n || p.lv !== n.lv || p.t === n.t) return null;
  if (p.t === 0) return FINALS[n.t];
  const parts = COMPOUND_FINALS[n.t];
  return parts && parts[0] === p.t ? FINALS[parts[1]] : null;
}

export class InputTracker {
  constructor() { this.reset(); }

  reset() {
    this.base = 0; // index (in characters) where the current card's text starts
    this.carry = ''; // previous card's syllable that may still be under composition
  }

  /** The part of the input that belongs to the current card. */
  segment(value) {
    const chs = chars(normalize(value));
    if (chs.length <= this.base) {
      // Backspace reached text that belonged to an earlier card.
      this.base = chs.length;
      this.carry = '';
      return '';
    }
    let rest = chs.slice(this.base);
    if (this.carry) {
      const c = chars(this.carry);
      const startsWithCarry = c.every((ch, i) => rest[i] === ch);
      if (startsWithCarry) {
        if (rest.length === c.length) return '';
        // The composition moved past the carried syllable; it is settled now.
        this.base += c.length;
        this.carry = '';
        rest = rest.slice(c.length);
      } else if (c.length === 1) {
        const jamo = absorbedJamo(c[0], rest[0]);
        if (jamo) return jamo + rest.slice(1).join('');
        if (absorbedJamo(rest[0], c[0]) || rest.length === 1) {
          // Backspace is taking the carried syllable apart; it is not the new card's text.
          this.carry = rest[0];
          if (rest.length === 1) return '';
        }
        this.carry = '';
      } else {
        this.carry = '';
      }
    }
    return rest.join('');
  }

  /**
   * The current card is done. `carry` is the text still being composed (may be empty);
   * `rest` is overflow that already belongs to the next card.
   */
  consume(value, carry = '', rest = '') {
    const len = chars(normalize(value)).length;
    const carryLen = chars(normalize(carry)).length;
    this.base = Math.max(0, len - chars(rest).length - carryLen);
    this.carry = carryLen ? normalize(carry) : '';
  }
}
