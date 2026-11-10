import { Session, InputTracker, diff, chars, migrateDecks, groupDecks, collapsedExcept, seedCategories, addSeedDecks, syncCategories, renameCategory, cleanCategory, SEED_VERSION, UNCATEGORIZED } from './core.js';
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
let store = { decks: [], categories: [], seedVersion: SEED_VERSION, settings: { deckId: null, mode: 'copy', reverse: false, shuffle: true, collapsed: [] } };
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
  if (store.decks.length) {
    card.append(el('p', '', '이 덱에는 카드가 없어요.'));
    const btn = el('button', 'primary-btn', '카드 추가하기');
    btn.type = 'button';
    btn.addEventListener('click', () => openEditor(store.settings.deckId));
    card.append(btn);
    return card;
  }
  card.append(el('p', '', '아직 덱이 없어요. 공부할 주제마다 카테고리를 만들고, 외울 것을 덱으로 정리해 보세요.'));
  const buttons = el('div', 'empty-actions');
  const cat = el('button', 'primary-btn', '＋ 새 카테고리');
  cat.type = 'button';
  cat.addEventListener('click', startNewCategory);
  const deck = el('button', 'ghost-btn', '＋ 새 덱');
  deck.type = 'button';
  deck.addEventListener('click', () => openEditor(null));
  buttons.append(cat, deck);
  card.append(buttons);
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
  const groups = groupDecks(store.decks, store.categories);
  for (const group of groups) {
    const key = group.category;
    const label = key || UNCATEGORIZED;
    const isOpen = !collapsed.has(key);
    const section = el('div', 'deck-group');
    if (catEdit?.mode === 'rename' && catEdit.key === key) {
      section.append(categoryInput(key));
      list.append(section);
      continue;
    }
    const head = el('button', 'group-head keep-focus');
    head.type = 'button';
    head.setAttribute('aria-expanded', String(isOpen));
    head.title = isOpen ? '접기' : '펼치기';
    head.classList.toggle('has-current', group.decks.some((d) => d.id === store.settings.deckId));
    head.append(el('span', 'chev', '›'), el('span', 'group-name', label), el('span', 'count', `${group.decks.length}개`));
    head.addEventListener('click', () => toggleGroup(key));
    head.addEventListener('dblclick', () => startRename(key));
    const headRow = el('div', 'group-row');
    headRow.append(head, rowActions([
      [PLUS, `'${label}'에 새 덱 만들기`, () => openEditor(null, key)],
      [PENCIL, `'${label}' 이름 바꾸기`, () => startRename(key)],
      [TRASH, `'${label}' 카테고리 삭제`, () => deleteCategory(key)],
    ]));
    section.append(headRow);
    if (isOpen && !group.decks.length) {
      const empty = el('button', 'group-empty keep-focus');
      empty.type = 'button';
      empty.append(el('span', '', '덱이 없어요'), el('b', '', '＋ 덱 만들기'));
      empty.addEventListener('click', () => openEditor(null, key));
      section.append(empty);
    }
    if (isOpen) {
      for (const deck of group.decks) {
        const b = el('button', 'deck-item keep-focus');
        b.type = 'button';
        b.setAttribute('aria-current', String(deck.id === store.settings.deckId));
        b.append(el('span', '', deck.name), el('span', 'count', String(deck.cards.length)));
        b.addEventListener('click', () => selectDeck(deck.id));
        const row = el('div', 'deck-row');
        row.append(b, rowActions([[TRASH, `'${deck.name}' 덱 삭제`, () => deleteDeck(deck.id)]]));
        section.append(row);
      }
    }
    list.append(section);
  }
  if (catEdit?.mode === 'new') list.append(categoryInput(''));
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

const PLUS = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" d="M8 3v10M3 8h10"/></svg>';
const PENCIL = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" d="M10.5 2.5l3 3L6 13H3v-3z"/></svg>';

/** Small buttons that show at the end of a sidebar row while it is hovered. */
function rowActions(actions) {
  const box = el('div', 'row-actions');
  for (const [icon, label, onClick] of actions) {
    const b = el('button', 'row-action keep-focus');
    b.type = 'button';
    b.title = label;
    b.setAttribute('aria-label', label);
    b.innerHTML = icon;
    b.addEventListener('click', (e) => { e.stopPropagation(); onClick(); });
    box.append(b);
  }
  return box;
}

/* ---------- the + menu at the top of the sidebar ---------- */

function setupAddMenu() {
  const btn = $('#addMenuBtn');
  const menu = $('#addMenu');
  const close = () => { menu.hidden = true; btn.setAttribute('aria-expanded', 'false'); };
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    const open = menu.hidden;
    menu.hidden = !open;
    btn.setAttribute('aria-expanded', String(open));
  });
  menu.addEventListener('click', (e) => {
    const action = e.target.closest('[data-action]')?.dataset.action;
    if (!action) return;
    close();
    if (action === 'deck') openEditor(null);
    if (action === 'category') startNewCategory();
    if (action === 'file') { openEditor(null); $('#editorFile').click(); }
  });
  document.addEventListener('click', (e) => { if (!menu.hidden && !e.target.closest('.add-menu')) close(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !menu.hidden) { close(); e.stopPropagation(); } }, true);
}

/* ---------- creating and renaming categories ---------- */

let catEdit = null; // { mode: 'new' } or { mode: 'rename', key }

function startNewCategory() {
  catEdit = { mode: 'new' };
  renderDeckList();
}

function startRename(key) {
  catEdit = { mode: 'rename', key };
  renderDeckList();
}

/** The inline name field used to create or rename a category. */
function categoryInput(key) {
  const row = el('div', 'cat-input-row');
  const input = el('input', 'cat-input');
  input.maxLength = 40;
  input.autocomplete = 'off';
  input.placeholder = '카테고리 이름 (예: 정보처리기사)';
  input.value = key;
  input.setAttribute('aria-label', key ? `'${key || UNCATEGORIZED}' 새 이름` : '새 카테고리 이름');
  let done = false;
  const finish = (commit) => {
    if (done) return;
    if (commit && !commitCategory(input.value)) { input.focus(); return; }
    done = true;
    catEdit = null;
    renderDeckList();
    focusSink();
  };
  input.addEventListener('keydown', (e) => {
    if (e.isComposing || e.keyCode === 229) return;
    if (e.key === 'Enter') { e.preventDefault(); finish(true); }
    if (e.key === 'Escape') { e.preventDefault(); finish(false); }
  });
  // Clicking elsewhere keeps a typed name; a confirm() that hands focus back does not.
  input.addEventListener('blur', () => setTimeout(() => {
    if (document.activeElement !== input) finish(Boolean(cleanCategory(input.value)));
  }, 0));
  row.append(input);
  requestAnimationFrame(() => { input.focus(); input.select(); input.scrollIntoView({ block: 'nearest' }); });
  return row;
}

/** Applies the name typed into the category field. Returns false to keep editing. */
function commitCategory(value) {
  const name = cleanCategory(value);
  const existing = syncCategories(store.categories, store.decks);
  if (!name) return true;
  if (name === UNCATEGORIZED) { note(`'${UNCATEGORIZED}'는 쓸 수 없는 이름이에요`); return false; }
  if (catEdit?.mode === 'new') {
    if (existing.includes(name)) { note('이미 있는 카테고리예요'); return false; }
    store.categories = [...existing, name];
    store.settings.collapsed = (store.settings.collapsed ?? []).filter((c) => c !== name);
    save();
    note(`'${name}' 카테고리를 만들었어요`);
    return true;
  }
  const from = catEdit.key;
  if (name === from) return true;
  if (existing.includes(name) && !confirm(`'${name}' 카테고리가 이미 있어요. 두 카테고리를 합칠까요?`)) return false;
  const r = renameCategory(store.decks, store.categories, from, name);
  store.decks = r.decks;
  store.categories = r.order;
  store.settings.collapsed = (store.settings.collapsed ?? []).map((c) => (c === from ? name : c));
  save();
  return true;
}

/** Removes decks and keeps the selection and the collapsed list consistent. */
function removeDecks(ids, dropCategory = null) {
  store.decks = store.decks.filter((d) => !ids.has(d.id));
  if (dropCategory !== null) store.categories = (store.categories ?? []).filter((c) => c !== dropCategory);
  store.categories = syncCategories(store.categories, store.decks);
  if (!currentDeck()) store.settings.deckId = store.decks[0]?.id ?? null;
  const cats = new Set(store.categories);
  store.settings.collapsed = (store.settings.collapsed ?? []).filter((c) => cats.has(c));
  revealDeck(store.settings.deckId);
  save();
  if ($('#editor').open) closeEditor();
  renderDeckList();
  startSession();
}

function deleteCategory(key) {
  const list = store.decks.filter((d) => cleanCategory(d.category) === key);
  const label = key || UNCATEGORIZED;
  if (!list.length) {
    if (!confirm(`빈 카테고리 '${label}'를 삭제할까요?`)) return;
    removeDecks(new Set(), key);
    return;
  }
  if (!confirm(`'${label}' 카테고리와 그 안의 덱 ${list.length}개를 모두 삭제할까요?\n되돌릴 수 없어요.`)) return;
  removeDecks(new Set(list.map((d) => d.id)), key);
  note(`덱 ${list.length}개를 삭제했어요`);
}

function toggleAllGroups() {
  const keys = groupDecks(store.decks, store.categories).map((g) => g.category);
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

/** Opens the editor for deck `id`, or for a new deck in `category` (default: the current one). */
function openEditor(id, category) {
  const deck = id ? store.decks.find((d) => d.id === id) : null;
  const categories = syncCategories(store.categories, store.decks);
  const defaultCategory = deck ? deck.category ?? '' : category ?? currentDeck()?.category ?? '';
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
  store.categories = syncCategories(store.categories, store.decks);
  // A deck that was just saved (possibly into another category) stays in view.
  revealDeck(id ?? store.settings.deckId);
  save();
  renderDeckList();
  startSession();
}

function deleteDeck(id) {
  const deck = store.decks.find((d) => d.id === id);
  if (!deck) return;
  if (!confirm(`'${deck.name}' 덱을 삭제할까요?\n되돌릴 수 없어요.`)) return;
  removeDecks(new Set([id]));
}

/* ---------- first run: optional TOEIC sample decks ---------- */

function openWelcome() {
  const dlg = $('#picker');
  const cats = seedCategories(seed, store.decks);
  $('#pickerTitle').textContent = 'TypeDeck에 오신 걸 환영해요';
  $('#pickerLead').textContent = '외울 것을 카드로 만들어 손으로 치면서 익혀요. 키를 보고 값을 치면 바로 다음 카드로 넘어가요. 자격증, 외국어, 용어처럼 공부할 주제마다 카테고리를 만들고 덱으로 정리하세요. 먼저 써 볼 수 있게 예시로 토익 영단어장을 넣어 둘까요?';
  const list = $('#pickerList');
  list.replaceChildren();
  for (const c of cats) {
    const row = el('label', 'picker-row');
    const box = el('input');
    box.type = 'checkbox';
    box.value = c.category;
    box.checked = true;
    const text = el('span', 'picker-text');
    text.append(el('b', '', c.category || UNCATEGORIZED),
      el('small', '', `덱 ${c.decks.length}개 · ${c.words.toLocaleString('ko-KR')}단어`));
    row.append(box, text);
    box.addEventListener('change', update);
    list.append(row);
  }
  const ok = $('#pickerOk');
  $('#pickerSkip').textContent = '빈 상태로 시작';
  function update() {
    ok.textContent = list.querySelector('input:checked') ? '예시 넣고 시작' : '빈 상태로 시작';
  }
  update();
  ok.onclick = () => {
    const chosen = new Set([...list.querySelectorAll('input:checked')].map((b) => b.value));
    dlg.close();
    finishWelcome(cats.filter((c) => chosen.has(c.category)).flatMap((c) => c.decks).map(cloneDeck));
  };
  $('#pickerSkip').onclick = () => { dlg.close(); finishWelcome([]); };
  // The first run has to end with a choice; Esc does not just dismiss it.
  dlg.oncancel = (e) => e.preventDefault();
  dlg.showModal();
  ok.focus();
}

function finishWelcome(add) {
  store.decks = addSeedDecks(store.decks, seed, add);
  store.categories = syncCategories(store.categories, store.decks);
  store.seedVersion = SEED_VERSION;
  store.settings.deckId = store.decks[0]?.id ?? null;
  store.settings.collapsed = collapsedExcept(store.decks, store.settings.deckId);
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
  setupAddMenu();
  $('#toggleGroups').addEventListener('click', toggleAllGroups);
  $('#editDeck').addEventListener('click', () => openEditor(store.settings.deckId));
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
      categories: saved.categories ?? [],
      seedVersion: SEED_VERSION,
      settings: { ...store.settings, ...saved.settings },
    };
  } else {
    // First run: nothing is stored until the welcome dialog is answered.
    store.decks = [];
  }
  store.categories = syncCategories(store.categories, store.decks);
  if (!currentDeck()) store.settings.deckId = store.decks[0]?.id ?? null;
  if (startCollapsed) store.settings.collapsed = collapsedExcept(store.decks, store.settings.deckId);
  revealDeck(store.settings.deckId);
  if (!firstRun) save();
  setupSink();
  bindUI();
  renderDeckList();
  renderControls();
  startSession();
  if (firstRun) openWelcome();
  else focusSink();
}

// Read-only handle for debugging in the console.
Object.defineProperty(window, 'typedeck', { get: () => ({ session, store }) });

boot();
