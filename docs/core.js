// TypeDeck core: pure logic shared by the UI and the tests. No DOM access here.

export const normalize = (s) => (s ?? '').normalize('NFC');
export const chars = (s) => Array.from(s);

const SEPARATORS = ['\t', ' = ', ' : ', '=', ':'];

/**
 * Parses "key = value" lines (tab, " = ", " : ", "=", ":" in that order of preference). Lines
 * starting with ">" right after a card are that card's note (메모); cards with a note come back
 * as [key, value, note].
 */
export function parseCards(text) {
  return parseCardsDetailed(text).cards;
}

/** Like parseCards, but also counts the non-empty lines that had no separator. */
export function parseCardsDetailed(text) {
  const cards = [];
  let skipped = 0;
  let last = null; // the card that note lines attach to
  for (const raw of (text ?? '').split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('>')) {
      if (!last) { skipped++; continue; }
      const noteLine = line.slice(1).replace(/^ /, '');
      last[2] = last[2] === undefined ? noteLine : `${last[2]}\n${noteLine}`;
      continue;
    }
    if (!line || line.startsWith('#')) { if (!line) last = null; continue; }
    const sep = SEPARATORS.find((s) => line.includes(s));
    const i = sep ? line.indexOf(sep) : -1;
    const q = sep ? line.slice(0, i).trim() : '';
    const a = sep ? line.slice(i + sep.length).trim() : '';
    if (q && a) { last = [q, a]; cards.push(last); }
    else { skipped++; last = null; }
  }
  for (const c of cards) if (c[2] !== undefined && !(c[2] = c[2].trim())) c.length = 2;
  return { cards, skipped };
}

export function serializeCards(cards) {
  return cards.map(([q, a, note]) => {
    const line = q.includes('=') || q.includes(':') ? `${q}\t${a}` : `${q} = ${a}`;
    const noteLines = note ? note.split('\n').map((l) => (l ? `> ${l}` : '>')) : [];
    return [line, ...noteLines].join('\n');
  }).join('\n');
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

/**
 * The meanings of an answer like "지원하다, 신청하다". All of them are typed, in order. A sentence
 * (ending in . ? or !) is one meaning, and a comma between two digits ("1,000") does not split.
 */
export function meanings(answer) {
  const s = normalize(answer).trim();
  if (/[.?!][\s"')\]]*$/.test(s)) return [s];
  const parts = s.split(/(?<!\d),|,(?!\d)/).map((p) => p.trim()).filter(Boolean);
  return parts.length > 1 ? parts : [s];
}

/** What is typed for an answer: its meanings joined by ", ", and where those separators sit. */
export function typingTarget(answer) {
  const parts = meanings(answer);
  const auto = new Set();
  let at = 0;
  parts.forEach((p, k) => {
    at += chars(p).length;
    if (k < parts.length - 1) { auto.add(at); auto.add(at + 1); at += 2; }
  });
  return { text: parts.join(', '), auto };
}

/**
 * Lines the typed text up with the target and fills in the ", " between meanings, which the user
 * does not have to type (typing it is fine too). Returns the text as it reads on the card, and
 * how many typed characters spelled out the whole target (-1 until they do).
 */
export function fillSeparators(target, typed, composing) {
  const t = chars(target.text);
  const u = chars(typed);
  let shown = '';
  let i = 0;
  let used = -1;
  for (let j = 0; j < u.length; j++) {
    while (i < t.length && target.auto.has(i) && u[j] !== t[i]) shown += t[i++];
    shown += u[j];
    i++;
    if (used < 0 && i === t.length && shown === target.text) used = j + 1;
  }
  // A meaning that is finished moves the caret past the ", " right away.
  if (!composing) while (i < t.length && target.auto.has(i)) shown += t[i++];
  return { shown, used };
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
    this.items = cards.map(([q, a, note], id) => {
      const target = typingTarget(reverse ? q : a);
      return { id, q: reverse ? a : q, a: target.text, target, note: note ?? '' };
    });
    const order = this.items.map((it) => it.id);
    this.queue = shuffle ? shuffled(order, rng) : order;
    this.pos = 0;
    this.requeues = new Map();
    this.first = new Map(); // id -> clean on first attempt
    this.keystrokes = 0;
    this.activeMs = 0;
    this.streak = 0;
    this.bestStreak = 0;
    this.lastDone = null; // the card finished most recently, for showing its 메모
    this.resetCard();
  }

  resetCard() {
    this.typed = '';
    this.shown = ''; // typed text with the ", " between meanings filled in
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
    this.shown = fillSeparators(card.target, this.typed, composing).shown;
    if (this.typed && this.cardStart === null) this.cardStart = now;
    if (this.shown === card.a) {
      this.complete(now);
      return 'advance';
    }
    if (diff(card.a, this.shown, composing).some((d) => d.state === 'bad' || d.state === 'extra')) {
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
    while (!this.finished && !composing) {
      const { used } = fillSeparators(this.current.target, t, false);
      if (used < 0 || used >= chars(t).length) break;
      if (this.cardStart === null) this.cardStart = now;
      this.complete(now);
      advanced++;
      t = chars(t).slice(used).join('');
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
    this.lastDone = card;
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

/* ---------- decks ---------- */

export const SEED_VERSION = 5;
/**
 * Adds built-in decks that are newer than the stored data. A built-in deck's `since` is the seed
 * version that brought it, so a deck the user deleted never comes back on an update.
 */
export function migrateDecks(decks, seedVersion, seed) {
  const from = seedVersion ?? 0;
  if (from >= SEED_VERSION) return decks;
  const have = new Set(decks.map((d) => d.id));
  const added = seed.filter((s) => (s.since ?? 0) > from && !have.has(s.id));
  const clone = (d) => ({ id: d.id, name: d.name, category: d.category ?? '', cards: d.cards.map((c) => [...c]) });
  return [...added.map(clone), ...decks];
}

export const UNCATEGORIZED = '미분류';

/** Built-in decks grouped by category, with the number of cards in each category. */
export function seedCategories(seed) {
  return groupDecks(seed).map(({ category, decks }) => ({
    category,
    decks,
    cardCount: decks.reduce((n, d) => n + d.cards.length, 0),
  }));
}

/**
 * Adds the given built-in decks. Built-in decks keep the seed's order and come before the
 * user's own decks, which keep theirs.
 */
export function addSeedDecks(decks, seed, add) {
  const byId = new Map(decks.map((d) => [d.id, d]));
  for (const d of add) if (!byId.has(d.id)) byId.set(d.id, d);
  const seedIds = new Set(seed.map((d) => d.id));
  const builtIn = seed.filter((d) => byId.has(d.id)).map((d) => byId.get(d.id));
  return [...builtIn, ...decks.filter((d) => !seedIds.has(d.id))];
}

/** Every category except the one holding `deckId`: the sidebar starts with only that one open. */
export function collapsedExcept(decks, deckId) {
  const open = (decks.find((d) => d.id === deckId)?.category ?? '').trim();
  return [...new Set(decks.map((d) => (d.category ?? '').trim()))].filter((c) => c !== open);
}

/** Category names are trimmed and inner runs of spaces collapsed. */
export const cleanCategory = (name) => (name ?? '').trim().replace(/\s+/g, ' ');

/**
 * Groups decks by category. `order` is the user's category list, which may hold empty
 * categories; categories only found on decks follow it, and uncategorized decks go last.
 */
export function groupDecks(decks, order = []) {
  const groups = new Map();
  for (const name of order) {
    const n = cleanCategory(name);
    if (n && !groups.has(n)) groups.set(n, []);
  }
  for (const deck of decks) {
    const name = cleanCategory(deck.category);
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(deck);
  }
  const out = [...groups].filter(([name]) => name).map(([name, list]) => ({ category: name, decks: list }));
  if (groups.has('')) out.push({ category: '', decks: groups.get('') });
  return out;
}

/** The category list with every category used by a deck, keeping the existing order. */
export function syncCategories(order, decks) {
  return groupDecks(decks, order ?? []).map((g) => g.category).filter(Boolean);
}

/**
 * Renames a category on every deck and in the list. Renaming onto an existing category merges
 * the two, keeping the target's place.
 */
export function renameCategory(decks, order, from, to) {
  const target = cleanCategory(to);
  const nextDecks = decks.map((d) => (cleanCategory(d.category) === from ? { ...d, category: target } : d));
  const list = syncCategories(order, decks);
  const nextOrder = list.includes(target)
    ? list.filter((c) => c !== from)
    : list.map((c) => (c === from ? target : c));
  return { decks: nextDecks, order: syncCategories(nextOrder, nextDecks) };
}

/**
 * Splits CSV text into records of fields. Quotes may wrap a field, "" is a literal quote, and a
 * quoted field may span lines (a long 메모 with line breaks).
 */
function csvRecords(text, sep) {
  const records = [];
  let fields = [];
  let cur = '';
  let quoted = false;
  const endField = () => { fields.push(cur.trim()); cur = ''; };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { cur += '"'; i++; } else if (ch === '"') quoted = false; else cur += ch;
    } else if (ch === '"' && !cur.trim()) {
      quoted = true;
      cur = '';
    } else if (ch === sep) {
      endField();
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      endField();
      records.push(fields);
      fields = [];
    } else cur += ch;
  }
  if (cur || fields.length) { endField(); records.push(fields); }
  return records;
}

/**
 * Reads cards from an imported file. CSV and TSV columns are key, value and 메모 (a comma inside
 * quotes stays in the value, so "지원하다, 신청하다" keeps both meanings); anything else uses
 * the same separators as pasting, with "> " lines as 메모.
 */
export function parseImport(text, fileName = '') {
  const ext = (fileName.split('.').pop() ?? '').toLowerCase();
  if (ext !== 'csv' && ext !== 'tsv') return parseCardsDetailed(text);
  const sep = ext === 'tsv' ? '\t' : ',';
  const cards = [];
  let skipped = 0;
  for (const fields of csvRecords((text ?? '').replace(/^\uFEFF/, ''), sep)) {
    if (fields.every((f) => !f)) continue;
    const [q = '', a = '', ...rest] = fields;
    const note = rest.filter(Boolean).join('\n');
    if (q && a) cards.push(note ? [q, a, note] : [q, a]);
    else skipped++;
  }
  return { cards, skipped };
}
