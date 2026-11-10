import { Session, InputTracker, diff, chars, migrateDecks, groupDecks, collapsedExcept, seedCategories, addSeedDecks, SEED_VERSION, UNCATEGORIZED } from './core.js';
import { setupEditor, openEditor as openDeckEditor, closeEditor } from './editor.js';

const STORE_KEY = 'typedeck.v1';
const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};

let seed = [];
let store = { decks: [], seedVersion: SEED_VERSION, settings: { deckId: null, mode: 'copy', reverse: false, shuffle: true, collapsed: [] } };
const CHOICES = 5;
const isChoice = () => store.settings.mode === 'choice';
let session = null;
let sessionCards = [];
let sink = null;
const tracker = new InputTracker();
let composing = false;
let compositionText = '';

/* ---------- storage ---------- */

function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(store)); } catch { /* private mode */ }
}
function loadSaved() {
  try { return JSON.parse(localStorage.getItem(STORE_KEY) ?? 'null'); } catch { return null; }
}
const cloneDeck = (d) => ({ id: d.id, name: d.name, category: d.category ?? '', cards: d.cards.map((c) => [c[0], c[1]]) });
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

const modalOpen = () => $('#editor').open || $('#picker').open;

function focusSink() {
  if (!modalOpen() && document.activeElement !== sink) sink.focus({ preventScroll: true });
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
  if (!session || session.finished || isChoice()) {
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
  if (isChoice()) {
    const m = /^(?:Digit|Numpad)([1-9])$/.exec(e.code);
    if (m || e.key.length === 1) e.preventDefault();
    if (m) pick(Number(m[1]) - 1);
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
    const r = session.submit(now);
    if (r === 'advance') { clearInput(); showNext(); }
    else if (r === 'reveal') renderFront();
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

function pick(i) {
  if (!session || session.finished) return;
  const r = session.choose(i, performance.now());
  if (r === 'advance') showNext();
  else if (r === 'wrong') { renderFront(); shake(); }
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
  const choices = isChoice() ? CHOICES : 0;
  session = sessionCards.length ? new Session(sessionCards, { shuffle, reverse, choices }) : null;
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
  const label = isChoice() ? '문제' : store.settings.reverse ? '값' : '키';
  meta.append(el('span', 'pill', label), el('span', 'card-count'));
  const q = el('div', 'q', session.current.q);
  if (isChoice()) {
    card.classList.add('choice-card');
    const list = el('div', 'choices');
    session.choices.forEach((text, i) => {
      const b = el('button', 'choice keep-focus');
      b.type = 'button';
      b.append(el('kbd', '', String(i + 1)), el('span', '', text));
      b.addEventListener('click', () => pick(i));
      list.append(b);
    });
    card.append(meta, q, list);
  } else {
    const wrap = el('div', 'answer-wrap');
    wrap.append(el('div', 'answer'));
    card.append(meta, q, wrap);
  }
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
  if (isChoice()) {
    const showRight = session.revealed || session.wrongPicks.size > 0;
    card.querySelectorAll('.choice').forEach((b, i) => {
      b.classList.toggle('wrong', session.wrongPicks.has(i));
      b.classList.toggle('right', showRight && i === session.answerIndex);
    });
    return;
  }
  renderAnswer(card);
}

function renderAnswer(card = stackEl().querySelector('.card.front')) {
  if (!card || !session?.current || isChoice()) return;
  const answer = card.querySelector('.answer');
  const { alts } = session.current;
  const target = session.target;
  const typed = session.typed;
  const showAnswer = store.settings.mode === 'copy' || session.revealed;
  const frag = document.createDocumentFragment();
  let hasError = false;

  if (showAnswer) {
    // Every accepted answer is shown; the one being typed gets the character-by-character view.
    alts.forEach((alt, k) => {
      if (k > 0) frag.append(el('span', 'alt', ', '));
      if (alt !== target) { frag.append(el('span', 'alt', alt)); return; }
      const parts = diff(alt, typed, session.composing);
      const caretAt = chars(typed).length;
      parts.forEach((p, i) => {
        if (i === caretAt) frag.append(el('span', 'caret'));
        const shown = p.state === 'extra' || p.state === 'comp' ? p.typed ?? p.ch : p.ch;
        frag.append(el('span', p.state, shown));
        if (p.state === 'bad' || p.state === 'extra') hasError = true;
      });
      if (caretAt >= parts.length) frag.append(el('span', 'caret'));
    });
  } else {
    if (typed) frag.append(el('span', 'typed', typed));
    frag.append(el('span', 'caret'));
    if (!typed) frag.append(el('span', 'recall-hint', '기억나는 대로 입력'));
  }
  if (session.awaitingEnter) frag.append(el('span', 'recall-hint enter-hint', 'Enter ↵ 로 넘기기'));
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
  if (!store.decks.length && seed.length) {
    const add = el('button', 'ghost-btn', '토익 단어 덱 넣기');
    add.type = 'button';
    add.addEventListener('click', () => openPicker(false));
    card.append(add);
  }
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
    isChoice() ? ['남음', String(session.remaining)] : ['타/분', num(session.kpm)],
    ['연속', String(session.streak)],
  ]) {
    const cell = el('div');
    cell.append(el('dt', '', k), el('dd', '', v));
    stats.append(cell);
  }
  $('#hints').innerHTML = session.finished
    ? `<kbd>Enter</kbd>다시 하기${session.missed.length ? ' &nbsp; <kbd>Tab</kbd>틀린 카드만' : ''}`
    : isChoice()
      ? `<kbd>1</kbd>–<kbd>${session.choices.length}</kbd>고르기 &nbsp; <kbd>Enter</kbd>정답 보기 &nbsp; <kbd>Tab</kbd>건너뛰기`
      : '<kbd>Enter</kbd>정답 보기 &nbsp; <kbd>Tab</kbd>건너뛰기 &nbsp; <kbd>Esc</kbd>지우기';
}

function renderDeckList() {
  const list = $('#deckList');
  list.replaceChildren();
  const collapsed = new Set(store.settings.collapsed ?? []);
  const groups = groupDecks(store.decks);
  for (const group of groups) {
    const key = group.category;
    const isOpen = !collapsed.has(key);
    const section = el('div', 'deck-group');
    const head = el('button', 'group-head keep-focus');
    head.type = 'button';
    head.setAttribute('aria-expanded', String(isOpen));
    head.title = isOpen ? '접기' : '펼치기';
    head.classList.toggle('has-current', group.decks.some((d) => d.id === store.settings.deckId));
    head.append(el('span', 'chev', '›'), el('span', 'group-name', key || UNCATEGORIZED), el('span', 'count', `${group.decks.length}개`));
    head.addEventListener('click', () => toggleGroup(key));
    const headRow = el('div', 'group-row');
    headRow.append(head, rowAction(`'${key || UNCATEGORIZED}' 카테고리 삭제`, () => deleteCategory(key)));
    section.append(headRow);
    if (isOpen) {
      for (const deck of group.decks) {
        const b = el('button', 'deck-item keep-focus');
        b.type = 'button';
        b.setAttribute('aria-current', String(deck.id === store.settings.deckId));
        b.append(el('span', '', deck.name), el('span', 'count', String(deck.cards.length)));
        b.addEventListener('click', () => selectDeck(deck.id));
        const row = el('div', 'deck-row');
        row.append(b, rowAction(`'${deck.name}' 덱 삭제`, () => deleteDeck(deck.id)));
        section.append(row);
      }
    }
    list.append(section);
  }
  const allClosed = groups.every((g) => collapsed.has(g.category));
  const toggle = $('#toggleGroups');
  toggle.textContent = allClosed ? '모두 펼치기' : '모두 접기';
  toggle.hidden = groups.length < 2;
  const deck = currentDeck();
  $('#deckName').textContent = deck ? deck.name : 'TypeDeck';
  $('#editDeck').hidden = !deck;
  document.title = deck ? `${deck.name} · TypeDeck` : 'TypeDeck';
}

const TRASH = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" d="M2.5 4h11M6 4V2.75h4V4M4 4l.7 9.25h6.6L12 4M6.75 6.75v4M9.25 6.75v4"/></svg>';

/** The small trash button that shows when a sidebar row is hovered. */
function rowAction(label, onClick) {
  const b = el('button', 'row-action keep-focus');
  b.type = 'button';
  b.title = label;
  b.setAttribute('aria-label', label);
  b.innerHTML = TRASH;
  b.addEventListener('click', (e) => { e.stopPropagation(); onClick(); });
  return b;
}

const isBuiltIn = (deck) => seed.some((s) => s.id === deck.id);
const comeBackNote = '기본 덱이라 사이드바 아래 \'기본 덱 추가\'에서 다시 넣을 수 있어요.';

/** Removes decks and keeps the selection and the collapsed list consistent. */
function removeDecks(ids) {
  store.decks = store.decks.filter((d) => !ids.has(d.id));
  if (!currentDeck()) store.settings.deckId = store.decks[0]?.id ?? null;
  const cats = new Set(store.decks.map((d) => (d.category ?? '').trim()));
  store.settings.collapsed = (store.settings.collapsed ?? []).filter((c) => cats.has(c));
  revealDeck(store.settings.deckId);
  save();
  if ($('#editor').open) closeEditor();
  renderDeckList();
  startSession();
}

function deleteCategory(key) {
  const list = store.decks.filter((d) => (d.category ?? '').trim() === key);
  if (!list.length) return;
  const tail = list.every(isBuiltIn) ? comeBackNote : '되돌릴 수 없어요.';
  if (!confirm(`'${key || UNCATEGORIZED}' 카테고리의 덱 ${list.length}개를 모두 삭제할까요?\n${tail}`)) return;
  removeDecks(new Set(list.map((d) => d.id)));
  note(`덱 ${list.length}개를 삭제했어요`);
}

function toggleAllGroups() {
  const keys = groupDecks(store.decks).map((g) => g.category);
  const collapsed = new Set(store.settings.collapsed ?? []);
  store.settings.collapsed = keys.every((k) => collapsed.has(k)) ? [] : keys;
  save();
  renderDeckList();
}

/** Opens the category of `deckId` so the selected deck is visible. */
function revealDeck(deckId) {
  const cat = (store.decks.find((d) => d.id === deckId)?.category ?? '').trim();
  store.settings.collapsed = (store.settings.collapsed ?? []).filter((c) => c !== cat);
}

function toggleGroup(key) {
  const set = new Set(store.settings.collapsed ?? []);
  if (set.has(key)) set.delete(key); else set.add(key);
  store.settings.collapsed = [...set];
  save();
  renderDeckList();
}

function renderControls() {
  for (const b of document.querySelectorAll('.segmented button')) {
    b.setAttribute('aria-checked', String(b.dataset.mode === store.settings.mode));
  }
  $('#reverseBtn').setAttribute('aria-pressed', String(store.settings.reverse && !isChoice()));
  $('#reverseBtn').disabled = isChoice();
  $('#arena').classList.toggle('choice-mode', isChoice());
  $('#reverseBtn').title = isChoice() ? '5지선다에서는 방향을 바꾸지 않아요' : '키와 값의 방향을 바꿉니다';
  $('#shuffleBtn').setAttribute('aria-pressed', String(store.settings.shuffle));
}

function selectDeck(id) {
  store.settings.deckId = id;
  revealDeck(id);
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
  const deck = id ? store.decks.find((d) => d.id === id) : null;
  const categories = groupDecks(store.decks).map((g) => g.category).filter(Boolean);
  const defaultCategory = deck ? deck.category ?? '' : currentDeck()?.category ?? '';
  openDeckEditor(deck, {
    categories,
    defaultCategory,
    onSave: ({ name, category, cards }) => saveDeck(id, name, category, cards),
    onDelete: () => deleteDeck(id),
  });
}

function saveDeck(id, name, category, cards) {
  const deck = id ? store.decks.find((d) => d.id === id) : null;
  if (deck) {
    deck.name = name || deck.name;
    deck.category = category;
    deck.cards = cards;
  } else {
    const newId = `d${Date.now().toString(36)}`;
    store.decks.push({ id: newId, name: name || '새 덱', category, cards });
    store.settings.deckId = newId;
  }
  // A deck that was just saved (possibly into another category) stays in view.
  revealDeck(id ?? store.settings.deckId);
  save();
  renderDeckList();
  startSession();
}

function deleteDeck(id) {
  const deck = store.decks.find((d) => d.id === id);
  if (!deck) return;
  const tail = isBuiltIn(deck) ? comeBackNote : '되돌릴 수 없어요.';
  if (!confirm(`'${deck.name}' 덱을 삭제할까요?\n${tail}`)) return;
  removeDecks(new Set([id]));
}

/* ---------- built-in deck picker (first run and "기본 덱 추가") ---------- */

function openPicker(firstRun) {
  const dlg = $('#picker');
  const cats = seedCategories(seed, store.decks);
  $('#pickerTitle').textContent = firstRun ? 'TypeDeck에 오신 걸 환영해요' : '기본 덱 추가';
  $('#pickerLead').textContent = firstRun
    ? '카드에 나온 단어의 뜻을 치면 바로 다음 카드로 넘어가요. 토익 영단어 덱을 넣어 드릴까요? 나중에 사이드바 아래 \'기본 덱 추가\'에서 언제든 넣을 수 있어요.'
    : '넣을 토익 덱을 고르세요. 이미 있는 덱은 그대로 두고 빠진 덱만 넣어요.';
  const list = $('#pickerList');
  list.replaceChildren();
  for (const c of cats) {
    const row = el('label', 'picker-row');
    const box = el('input');
    box.type = 'checkbox';
    box.value = c.category;
    box.checked = c.missing.length > 0;
    box.disabled = c.missing.length === 0;
    const text = el('span', 'picker-text');
    text.append(el('b', '', c.category || UNCATEGORIZED),
      el('small', '', `덱 ${c.decks.length}개 · ${c.words.toLocaleString('ko-KR')}단어`));
    const state = c.missing.length === 0 ? '모두 있음' : c.missing.length < c.decks.length ? `${c.missing.length}개 빠짐` : '';
    row.append(box, text, el('span', 'picker-state', state));
    box.addEventListener('change', update);
    list.append(row);
  }
  const ok = $('#pickerOk');
  const skip = $('#pickerSkip');
  skip.textContent = firstRun ? '빈 상태로 시작' : '취소';
  function update() {
    const n = list.querySelectorAll('input:checked').length;
    ok.textContent = firstRun ? (n ? '선택한 덱으로 시작' : '빈 상태로 시작') : '추가';
    ok.disabled = !firstRun && n === 0;
  }
  update();
  ok.onclick = () => {
    const chosen = new Set([...list.querySelectorAll('input:checked')].map((b) => b.value));
    const add = cats.filter((c) => chosen.has(c.category)).flatMap((c) => c.missing).map(cloneDeck);
    dlg.close();
    applyPicked(add, firstRun);
  };
  skip.onclick = () => { dlg.close(); if (firstRun) applyPicked([], true); };
  // The first run has to end with a choice; Esc does not just dismiss it.
  dlg.oncancel = (e) => { if (firstRun) e.preventDefault(); };
  dlg.showModal();
  ok.focus();
}

function applyPicked(add, firstRun) {
  store.decks = addSeedDecks(store.decks, seed, add);
  if (firstRun) {
    store.seedVersion = SEED_VERSION;
    store.settings.deckId = store.decks[0]?.id ?? null;
    store.settings.collapsed = collapsedExcept(store.decks, store.settings.deckId);
  } else {
    if (!currentDeck()) store.settings.deckId = add[0]?.id ?? store.decks[0]?.id ?? null;
    const added = new Set(add.map((d) => (d.category ?? '').trim()));
    store.settings.collapsed = (store.settings.collapsed ?? []).filter((c) => !added.has(c) || c === '');
    if (add.length) note(`덱 ${add.length}개를 넣었어요`);
  }
  save();
  renderDeckList();
  startSession();
  focusSink();
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
    if (modalOpen() || document.activeElement === sink) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const tag = document.activeElement?.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (handleCommandKey(e)) { focusSink(); return; }
    focusSink();
  }, true);

  for (const b of document.querySelectorAll('.segmented button')) {
    b.addEventListener('click', () => {
      const before = store.settings.mode;
      store.settings.mode = b.dataset.mode;
      save();
      renderControls();
      if (before === 'choice' || store.settings.mode === 'choice') startSession();
      else renderFront();
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
  $('#toggleGroups').addEventListener('click', toggleAllGroups);
  $('#editDeck').addEventListener('click', () => openEditor(store.settings.deckId));
  $('#restoreDecks').addEventListener('click', () => openPicker(false));
  $('#picker').addEventListener('close', () => setTimeout(focusSink, 0));

  setupEditor();
  $('#editor').addEventListener('close', () => setTimeout(focusSink, 0));
}

async function boot() {
  try {
    const res = await fetch('decks.json', { cache: 'no-cache' });
    seed = (await res.json()).decks ?? [];
  } catch { seed = []; }
  const saved = loadSaved();
  // Before seed 3 there were only a few decks; now only the current deck's category starts open.
  const firstRun = !(saved && Array.isArray(saved.decks));
  const startCollapsed = firstRun || (saved.seedVersion ?? 1) < 3;
  if (!firstRun) {
    store = {
      decks: migrateDecks(saved.decks, saved.seedVersion, seed),
      seedVersion: SEED_VERSION,
      settings: { ...store.settings, ...saved.settings },
    };
  } else {
    // First run: nothing is stored until the welcome dialog is answered.
    store.decks = [];
  }
  if (!currentDeck()) store.settings.deckId = store.decks[0]?.id ?? null;
  if (startCollapsed) store.settings.collapsed = collapsedExcept(store.decks, store.settings.deckId);
  revealDeck(store.settings.deckId);
  if (!firstRun) save();
  setupSink();
  bindUI();
  renderDeckList();
  renderControls();
  startSession();
  if (firstRun) openPicker(true);
  else focusSink();
}

// Read-only handle for debugging in the console.
Object.defineProperty(window, 'typedeck', { get: () => ({ session, store }) });

boot();
