import { Session, InputTracker, diff, parseCards, serializeCards, chars } from './core.js';

const STORE_KEY = 'typedeck.v1';
const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};

let seed = [];
let store = { decks: [], settings: { deckId: null, mode: 'copy', reverse: false, shuffle: true } };
let session = null;
let sessionCards = [];
let sink = null;
const tracker = new InputTracker();
let composing = false;
let compositionText = '';
let editingId = null;

/* ---------- storage ---------- */

function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(store)); } catch { /* private mode */ }
}
function loadSaved() {
  try { return JSON.parse(localStorage.getItem(STORE_KEY) ?? 'null'); } catch { return null; }
}
const cloneDeck = (d) => ({ id: d.id, name: d.name, cards: d.cards.map((c) => [c[0], c[1]]) });
const currentDeck = () => store.decks.find((d) => d.id === store.settings.deckId) ?? null;

/* ---------- input sink ----------
   One hidden input keeps focus the whole time. While an IME is composing we never change its
   value or focus (Chrome on macOS re-inserts the syllable and swallows the next Backspace if we
   do); the tracker remembers where the current card's text starts instead. */

function setupSink() {
  sink = $('#sink');
  sink.addEventListener('keydown', onSinkKeyDown);
  sink.addEventListener('input', onSinkInput);
  sink.addEventListener('compositionstart', () => { composing = true; compositionText = ''; });
  sink.addEventListener('compositionupdate', (e) => { compositionText = e.data ?? ''; });
  sink.addEventListener('compositionend', (e) => {
    composing = false;
    compositionText = '';
    onSinkInput(e);
  });
  sink.addEventListener('focus', () => $('#arena').classList.add('focused'));
  sink.addEventListener('blur', () => $('#arena').classList.remove('focused'));
}

function focusSink() {
  if (!$('#editor').open && document.activeElement !== sink) sink.focus({ preventScroll: true });
}

/** Starts the next card's text from scratch. Safe to call at any time. */
function clearInput() {
  if (composing) {
    const carry = compositionText || chars(sink.value).slice(-1).join('');
    tracker.consume(sink.value, carry);
  } else {
    sink.value = '';
    tracker.reset();
  }
}

/** Drops text that belongs to finished cards, but only when no composition is in progress. */
function compactInput(e) {
  if (e.type !== 'input' || e.isComposing || composing || tracker.carry || tracker.base === 0) return;
  sink.value = tracker.segment(sink.value);
  tracker.reset();
}

function onSinkInput(e) {
  if (!session || session.finished) {
    if (!composing && e.type === 'input') { sink.value = ''; tracker.reset(); }
    return;
  }
  const isComposing = e.type === 'compositionend' ? false : Boolean(e.isComposing || composing);
  const text = tracker.segment(sink.value);
  const { advanced, rest } = session.feed(text, isComposing, performance.now());
  if (advanced) {
    if (isComposing) {
      tracker.consume(sink.value, compositionText || chars(sink.value).slice(-1).join(''));
    } else {
      tracker.consume(sink.value, '', rest);
    }
    compactInput(e);
    showNext();
  } else {
    compactInput(e);
    renderAnswer();
  }
}

function onSinkKeyDown(e) {
  if (e.metaKey || e.ctrlKey) return;
  if (handleCommandKey(e)) return;
  if (session?.finished) {
    if (e.key.length === 1) e.preventDefault();
    return;
  }
  if (e.key.length === 1 || e.key === 'Process' || e.keyCode === 229) {
    session?.keystroke(performance.now());
  }
}

/** Enter / Tab / Escape. Returns true when the key was handled. */
function handleCommandKey(e) {
  const { key } = e;
  if (key !== 'Enter' && key !== 'Tab' && key !== 'Escape') return false;
  if (key === 'Enter' && (e.isComposing || e.keyCode === 229)) return true;
  e.preventDefault();
  if (!session) return true;
  const now = performance.now();
  if (session.finished) {
    if (key === 'Enter') startSession();
    if (key === 'Tab' && session.missed.length) startSession(true);
    return true;
  }
  if (key === 'Enter') {
    const r = session.submit();
    if (r === 'reveal') renderFront();
    else if (r === 'shake') shake();
  } else if (key === 'Tab') {
    session.skip(now);
    clearInput();
    showNext();
  } else {
    clearInput();
    session.input('', false, now);
    renderAnswer();
  }
  return true;
}

/* ---------- session ---------- */

function startSession(onlyMissed = false) {
  const deck = currentDeck();
  if (onlyMissed && session) {
    sessionCards = session.missed.map((it) => sessionCards[it.id]);
  } else {
    sessionCards = deck ? deck.cards : [];
  }
  const { shuffle, reverse } = store.settings;
  session = sessionCards.length ? new Session(sessionCards, { shuffle, reverse }) : null;
  clearInput();
  focusSink();
  renderStack();
}

/* ---------- rendering ---------- */

const stackEl = () => $('#stack');

function renderStack() {
  const stack = stackEl();
  for (const child of [...stack.children]) if (!child.classList.contains('out')) child.remove();
  if (!session) { stack.append(emptyCard()); renderStatus(); return; }
  if (session.finished) { stack.append(summaryCard()); renderStatus(); return; }
  const depth = Math.min(2, session.remaining - 1);
  for (let d = depth; d >= 1; d--) {
    const back = el('div', 'card back');
    back.dataset.depth = String(d);
    stack.append(back);
  }
  stack.append(frontCard());
  renderStatus();
}

function frontCard() {
  const card = el('article', 'card front');
  const meta = el('div', 'card-meta');
  meta.append(el('span', 'pill', store.settings.reverse ? '값' : '키'), el('span', 'card-count'));
  const q = el('div', 'q', session.current.q);
  const wrap = el('div', 'answer-wrap');
  wrap.append(el('div', 'answer'));
  card.append(meta, q, wrap);
  fillFront(card);
  return card;
}

function renderFront() {
  const card = stackEl().querySelector('.card.front');
  if (card) fillFront(card);
}

function fillFront(card) {
  const pill = card.querySelector('.pill');
  if (session.revealed) { pill.textContent = '정답 공개'; pill.classList.add('reveal'); }
  card.querySelector('.card-count').textContent = `남은 카드 ${session.remaining}`;
  renderAnswer(card);
}

function renderAnswer(card = stackEl().querySelector('.card.front')) {
  if (!card || !session?.current) return;
  const answer = card.querySelector('.answer');
  const { a } = session.current;
  const typed = session.typed;
  const showAnswer = store.settings.mode === 'copy' || session.revealed;
  const frag = document.createDocumentFragment();
  let hasError = false;

  if (showAnswer) {
    const parts = diff(a, typed, session.composing);
    const caretAt = chars(typed).length;
    parts.forEach((p, i) => {
      if (i === caretAt) frag.append(el('span', 'caret'));
      const shown = p.state === 'extra' || p.state === 'comp' ? p.typed ?? p.ch : p.ch;
      frag.append(el('span', p.state, shown));
      if (p.state === 'bad' || p.state === 'extra') hasError = true;
    });
    if (caretAt >= parts.length) frag.append(el('span', 'caret'));
  } else {
    if (typed) frag.append(el('span', 'typed', typed));
    frag.append(el('span', 'caret'));
    if (!typed) frag.append(el('span', 'recall-hint', '기억나는 대로 입력'));
  }
  answer.replaceChildren(frag);
  card.classList.toggle('has-error', hasError);
}

function showNext() {
  const old = stackEl().querySelector('.card.front');
  if (old) {
    old.classList.remove('front', 'shake');
    old.classList.add('out');
    old.addEventListener('animationend', () => old.remove(), { once: true });
    setTimeout(() => old.remove(), 400);
  }
  renderStack();
}

function shake() {
  const card = stackEl().querySelector('.card.front');
  if (!card) return;
  card.classList.remove('shake');
  void card.offsetWidth;
  card.classList.add('shake');
}

function formatTime(ms) {
  const s = Math.round(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}
const pct = (v) => (v === null ? '—' : `${Math.round(v * 100)}%`);
const num = (v) => (v === null ? '—' : String(Math.round(v)));

function summaryCard() {
  const card = el('article', 'card front summary');
  card.append(el('span', 'pill', '라운드 완료'), el('h2', '', `정확도 ${pct(session.accuracy)}`));
  const grid = el('dl', 'summary-grid');
  for (const [k, v] of [
    ['카드', String(session.items.length)],
    ['타/분', num(session.kpm)],
    ['시간', formatTime(session.activeMs)],
    ['최고 연속', String(session.bestStreak)],
  ]) {
    const cell = el('div');
    cell.append(el('dt', '', k), el('dd', '', v));
    grid.append(cell);
  }
  card.append(grid);
  const missed = session.missed;
  if (missed.length) {
    const list = el('div', 'missed');
    for (const it of missed) {
      const chip = el('span');
      chip.append(el('b', '', it.q), document.createTextNode(` → ${it.a}`));
      list.append(chip);
    }
    card.append(list);
  }
  const actions = el('div', 'summary-actions');
  const again = el('button', 'primary-btn keep-focus');
  again.type = 'button';
  again.innerHTML = '<kbd>Enter</kbd>다시 하기';
  again.addEventListener('click', () => startSession());
  actions.append(again);
  if (missed.length) {
    const retry = el('button', 'ghost-btn keep-focus');
    retry.type = 'button';
    retry.innerHTML = `<kbd>Tab</kbd>틀린 ${missed.length}장만`;
    retry.addEventListener('click', () => startSession(true));
    actions.append(retry);
  }
  card.append(actions);
  return card;
}

function emptyCard() {
  const card = el('article', 'card front empty');
  card.append(el('p', '', store.decks.length ? '이 덱에는 카드가 없어요.' : '덱이 없어요.'));
  const btn = el('button', 'primary-btn', store.decks.length ? '카드 추가하기' : '새 덱 만들기');
  btn.type = 'button';
  btn.addEventListener('click', () => openEditor(store.decks.length ? store.settings.deckId : null));
  card.append(btn);
  return card;
}

function renderStatus() {
  const stats = $('#stats');
  stats.replaceChildren();
  const fill = $('#progressFill');
  if (!session) { fill.style.width = '0'; $('#hints').textContent = ''; return; }
  const total = session.queue.length;
  fill.style.width = `${(session.pos / total) * 100}%`;
  for (const [k, v] of [
    ['진행', `${Math.min(session.pos + 1, total)}/${total}`],
    ['정확도', pct(session.accuracy)],
    ['타/분', num(session.kpm)],
    ['연속', String(session.streak)],
  ]) {
    const cell = el('div');
    cell.append(el('dt', '', k), el('dd', '', v));
    stats.append(cell);
  }
  $('#hints').innerHTML = session.finished
    ? `<kbd>Enter</kbd>다시 하기${session.missed.length ? ' &nbsp; <kbd>Tab</kbd>틀린 카드만' : ''}`
    : '<kbd>Enter</kbd>정답 보기 &nbsp; <kbd>Tab</kbd>건너뛰기 &nbsp; <kbd>Esc</kbd>지우기';
}

function renderDeckList() {
  const list = $('#deckList');
  list.replaceChildren();
  for (const deck of store.decks) {
    const b = el('button', 'deck-item keep-focus');
    b.type = 'button';
    b.setAttribute('aria-current', String(deck.id === store.settings.deckId));
    b.append(el('span', '', deck.name), el('span', 'count', String(deck.cards.length)));
    b.addEventListener('click', () => selectDeck(deck.id));
    list.append(b);
  }
  const deck = currentDeck();
  $('#deckName').textContent = deck ? deck.name : 'TypeDeck';
  $('#editDeck').hidden = !deck;
  document.title = deck ? `${deck.name} · TypeDeck` : 'TypeDeck';
}

function renderControls() {
  for (const b of document.querySelectorAll('.segmented button')) {
    b.setAttribute('aria-checked', String(b.dataset.mode === store.settings.mode));
  }
  $('#reverseBtn').setAttribute('aria-pressed', String(store.settings.reverse));
  $('#shuffleBtn').setAttribute('aria-pressed', String(store.settings.shuffle));
}

function selectDeck(id) {
  store.settings.deckId = id;
  save();
  renderDeckList();
  startSession();
  const current = $('#deckList [aria-current="true"]');
  current?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}

function note(text) {
  const n = $('#sidebarNote');
  n.textContent = text;
  clearTimeout(note.t);
  note.t = setTimeout(() => { n.textContent = ''; }, 2500);
}

/* ---------- editor ---------- */

function openEditor(id) {
  editingId = id;
  const deck = id ? store.decks.find((d) => d.id === id) : null;
  $('#editorTitle').textContent = deck ? '덱 편집' : '새 덱';
  $('#editorName').value = deck ? deck.name : '';
  $('#editorCards').value = deck ? serializeCards(deck.cards) : '';
  $('#editorDelete').hidden = !deck;
  updateEditorCount();
  $('#editor').showModal();
  (deck ? $('#editorCards') : $('#editorName')).focus();
}

function updateEditorCount() {
  $('#editorCount').textContent = `${parseCards($('#editorCards').value).length}장`;
}

function saveEditor() {
  const name = $('#editorName').value.trim() || '새 덱';
  const cards = parseCards($('#editorCards').value);
  if (editingId) {
    const deck = store.decks.find((d) => d.id === editingId);
    deck.name = name;
    deck.cards = cards;
  } else {
    const id = `d${Date.now().toString(36)}`;
    store.decks.push({ id, name, cards });
    store.settings.deckId = id;
  }
  save();
  renderDeckList();
  startSession();
}

function deleteEditing() {
  const deck = store.decks.find((d) => d.id === editingId);
  if (!deck || !confirm(`'${deck.name}' 덱을 삭제할까요? 되돌릴 수 없어요.`)) return;
  store.decks = store.decks.filter((d) => d.id !== editingId);
  if (store.settings.deckId === editingId) store.settings.deckId = store.decks[0]?.id ?? null;
  save();
  $('#editor').close();
  renderDeckList();
  startSession();
}

/* ---------- wiring ---------- */

function bindUI() {
  // Controls never steal focus from the typing input.
  document.addEventListener('mousedown', (e) => {
    if (e.target.closest('.keep-focus')) e.preventDefault();
  });
  $('#arena').addEventListener('mousedown', (e) => {
    if (!e.target.closest('button')) { e.preventDefault(); focusSink(); }
  });
  window.addEventListener('focus', focusSink);

  // Typing anywhere goes to the card.
  document.addEventListener('keydown', (e) => {
    if ($('#editor').open || document.activeElement === sink) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const tag = document.activeElement?.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (handleCommandKey(e)) { focusSink(); return; }
    focusSink();
  }, true);

  for (const b of document.querySelectorAll('.segmented button')) {
    b.addEventListener('click', () => {
      store.settings.mode = b.dataset.mode;
      save();
      renderControls();
      renderFront();
    });
  }
  $('#reverseBtn').addEventListener('click', () => {
    store.settings.reverse = !store.settings.reverse;
    save(); renderControls(); startSession();
  });
  $('#shuffleBtn').addEventListener('click', () => {
    store.settings.shuffle = !store.settings.shuffle;
    save(); renderControls(); startSession();
  });
  $('#newDeck').addEventListener('click', () => openEditor(null));
  $('#editDeck').addEventListener('click', () => openEditor(store.settings.deckId));
  $('#restoreDecks').addEventListener('click', () => {
    const missing = seed.filter((d) => !store.decks.some((x) => x.id === d.id));
    if (!missing.length) { note('기본 덱이 모두 있어요'); return; }
    store.decks.push(...missing.map(cloneDeck));
    if (!currentDeck()) store.settings.deckId = store.decks[0].id;
    save(); renderDeckList(); if (!session) startSession();
    note(`${missing.length}개 덱을 되살렸어요`);
  });

  $('#editorCards').addEventListener('input', updateEditorCount);
  $('#editorForm').addEventListener('submit', () => saveEditor());
  $('#editorCancel').addEventListener('click', () => $('#editor').close());
  $('#editorDelete').addEventListener('click', deleteEditing);
  $('#editor').addEventListener('close', () => setTimeout(focusSink, 0));
}

async function boot() {
  try {
    const res = await fetch('decks.json', { cache: 'no-cache' });
    seed = (await res.json()).decks ?? [];
  } catch { seed = []; }
  const saved = loadSaved();
  if (saved && Array.isArray(saved.decks)) {
    store = { decks: saved.decks, settings: { ...store.settings, ...saved.settings } };
  } else {
    store.decks = seed.map(cloneDeck);
  }
  if (!currentDeck()) store.settings.deckId = store.decks[0]?.id ?? null;
  setupSink();
  bindUI();
  renderDeckList();
  renderControls();
  startSession();
  focusSink();
}

// Read-only handle for debugging in the console.
Object.defineProperty(window, 'typedeck', { get: () => ({ session, store }) });

boot();
