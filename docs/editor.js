import { parseCards, parseCardsDetailed, serializeCards } from './core.js';

/*
 * Deck editor: a two-column list of key/value fields.
 * Enter moves key -> value -> next card, the last row always stays empty so typing there adds a
 * card, multi-line paste becomes many cards, and a text view keeps the old "key = value" format.
 */

const $ = (sel) => document.querySelector(sel);

let rows = []; // [{ q, a }], the last one is always the empty "new card" row
let view = 'rows';
let onSave = null;
let onDelete = null;
let dirty = false;
let warnedIncomplete = false;

const isBlank = (r) => !r.q.trim() && !r.a.trim();
const isComplete = (r) => r.q.trim() && r.a.trim();
const isIncomplete = (r) => !isBlank(r) && !isComplete(r);
const composingKey = (e) => e.isComposing || e.keyCode === 229;

/* ---------- key/value column divider ---------- */

const RATIO_KEY = 'typedeck.editorKeyRatio';
const DEFAULT_RATIO = 0.4;
const clampRatio = (r) => Math.min(0.8, Math.max(0.15, r));
let keyRatio = DEFAULT_RATIO;
try { keyRatio = clampRatio(Number(localStorage.getItem(RATIO_KEY)) || DEFAULT_RATIO); } catch { /* storage blocked */ }

/** Applies the ratio to both columns and puts the divider in the gap between them. */
function applyRatio() {
  const box = $('#editorRows');
  box.style.setProperty('--key-fr', `${keyRatio}fr`);
  box.style.setProperty('--value-fr', `${1 - keyRatio}fr`);
  // Measured on a card row, not the header: the rows share their width with a scrollbar.
  const [, keyCell] = columnCells();
  const left = keyCell.getBoundingClientRect().right - box.getBoundingClientRect().left;
  const gap = parseFloat(getComputedStyle(keyCell.parentElement).columnGap) || 0;
  $('#colDivider').style.left = `${left + gap / 2}px`;
}

function columnCells() {
  const row = $('#rowsBody .card-row') ?? $('#editorRows .card-rows-header');
  return row.children;
}

function setRatio(r, persist = true) {
  keyRatio = clampRatio(r);
  applyRatio();
  if (persist) try { localStorage.setItem(RATIO_KEY, String(keyRatio)); } catch { /* storage blocked */ }
}

function setupDivider() {
  const handle = $('#colDivider');
  const box = $('#editorRows');
  handle.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    try { handle.setPointerCapture(e.pointerId); } catch { /* synthetic pointer */ }
    handle.classList.add('dragging');
    const [, keyCell, valueCell] = columnCells();
    const start = keyCell.getBoundingClientRect().left;
    const width = keyCell.getBoundingClientRect().width + valueCell.getBoundingClientRect().width;
    const move = (ev) => setRatio((ev.clientX - start) / width, false);
    const up = () => {
      handle.classList.remove('dragging');
      handle.removeEventListener('pointermove', move);
      setRatio(keyRatio);
    };
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', up, { once: true });
    handle.addEventListener('pointercancel', up, { once: true });
  });
  handle.addEventListener('dblclick', () => setRatio(DEFAULT_RATIO));
  handle.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      e.preventDefault();
      setRatio(keyRatio + (e.key === 'ArrowLeft' ? -0.03 : 0.03));
    }
  });
  new ResizeObserver(() => { if (!box.hidden) applyRatio(); }).observe(box);
}

export function setupEditor() {
  setupDivider();
  const body = $('#rowsBody');
  body.addEventListener('input', onRowInput);
  body.addEventListener('keydown', onRowKeyDown);
  body.addEventListener('paste', onRowPaste);
  body.addEventListener('click', (e) => {
    const del = e.target.closest('.row-del');
    if (del) removeRow(rowIndex(del), 'k');
  });

  $('#editorName').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !composingKey(e)) {
      e.preventDefault();
      if (e.metaKey || e.ctrlKey) return save();
      focusCell(0, 'k');
    }
  });
  $('#editorName').addEventListener('input', () => { dirty = true; });
  $('#editorCategory').addEventListener('input', () => { dirty = true; });
  $('#editorCategory').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !composingKey(e)) {
      e.preventDefault();
      if (e.metaKey || e.ctrlKey) return save();
      $('#editorName').focus();
    }
  });
  $('#editorCards').addEventListener('input', () => { dirty = true; updateCount(); });
  $('#editorCards').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); save(); }
  });

  for (const b of document.querySelectorAll('#editorView button')) {
    b.addEventListener('click', () => setView(b.dataset.view));
  }
  $('#editorSave').addEventListener('click', save);
  $('#editorCancel').addEventListener('click', () => requestClose());
  $('#editorDelete').addEventListener('click', () => onDelete?.());
  $('#editor').addEventListener('cancel', (e) => {
    e.preventDefault();
    requestClose();
  });
}

/** deck: { name, category, cards } or null for a new deck. */
export function openEditor(deck, handlers) {
  $('#categoryList').replaceChildren(...(handlers.categories ?? []).map((c) => {
    const o = document.createElement('option');
    o.value = c;
    return o;
  }));
  $('#editorCategory').value = deck ? deck.category ?? '' : handlers.defaultCategory ?? '';
  onSave = handlers.onSave;
  onDelete = handlers.onDelete;
  dirty = false;
  warnedIncomplete = false;
  $('#editorTitle').textContent = deck ? '덱 편집' : '새 덱';
  $('#editorName').value = deck ? deck.name : '';
  $('#editorDelete').hidden = !deck;
  rows = (deck?.cards ?? []).map(([q, a]) => ({ q, a }));
  ensureTrailingBlank();
  note('');
  view = 'rows';
  syncViewButtons();
  $('#editorRows').hidden = false;
  $('#editorCards').hidden = true;
  renderRows();
  $('#editor').showModal();
  applyRatio();
  if (deck) focusCell(rows.length - 1, 'k');
  else $('#editorName').focus();
}

export function closeEditor() {
  $('#editor').close();
}

function requestClose() {
  if (dirty && !confirm('저장하지 않은 변경이 있어요. 닫을까요?')) return;
  closeEditor();
}

/* ---------- rows ---------- */

function ensureTrailingBlank() {
  while (rows.length > 1 && isBlank(rows[rows.length - 1]) && isBlank(rows[rows.length - 2])) rows.pop();
  if (!rows.length || !isBlank(rows[rows.length - 1])) rows.push({ q: '', a: '' });
}

function rowEl(row, i) {
  const el = document.createElement('div');
  el.className = 'card-row';
  el.innerHTML = `
    <span class="row-num"></span>
    <input class="row-k" autocomplete="off" spellcheck="false" aria-label="키">
    <input class="row-v" autocomplete="off" spellcheck="false" aria-label="값">
    <button type="button" class="row-del" tabindex="-1" aria-label="카드 삭제" title="카드 삭제">×</button>`;
  el.querySelector('.row-k').value = row.q;
  el.querySelector('.row-v').value = row.a;
  decorate(el, row, i);
  return el;
}

function decorate(el, row, i) {
  const last = i === rows.length - 1;
  el.querySelector('.row-num').textContent = last ? '+' : String(i + 1);
  el.querySelector('.row-k').placeholder = last ? (i === 0 ? '키 (예: 대한민국)' : '새 카드 키') : '키';
  el.querySelector('.row-v').placeholder = last ? (i === 0 ? '값 (여러 개면 쉼표로: 지원하다, 신청하다)' : '값 (쉼표로 여러 개)') : '값';
  el.classList.toggle('is-new', last);
  el.classList.toggle('incomplete', isIncomplete(row));
}

function renderRows() {
  const body = $('#rowsBody');
  body.replaceChildren(...rows.map(rowEl));
  updateCount();
}

function rowIndex(node) {
  const el = node.closest('.card-row');
  return [...$('#rowsBody').children].indexOf(el);
}

function focusCell(i, col, caret = 'end') {
  const el = $('#rowsBody').children[i];
  const input = el?.querySelector(col === 'k' ? '.row-k' : '.row-v');
  if (!input) return;
  input.focus();
  const pos = caret === 'start' ? 0 : input.value.length;
  input.setSelectionRange(pos, pos);
  el.scrollIntoView({ block: 'nearest' });
}

function onRowInput(e) {
  const i = rowIndex(e.target);
  if (i < 0) return;
  const field = e.target.classList.contains('row-k') ? 'q' : 'a';
  rows[i][field] = e.target.value;
  dirty = true;
  const body = $('#rowsBody');
  if (i === rows.length - 1 && !isBlank(rows[i])) {
    // Typing in the empty last row turns it into a card and adds a new empty row.
    rows.push({ q: '', a: '' });
    body.append(rowEl(rows[rows.length - 1], rows.length - 1));
  }
  decorate(body.children[i], rows[i], i);
  updateCount();
}

function onRowKeyDown(e) {
  const input = e.target;
  if (!(input instanceof HTMLInputElement)) return;
  const i = rowIndex(input);
  const col = input.classList.contains('row-k') ? 'k' : 'v';
  if (composingKey(e)) return;

  if (e.key === 'Enter') {
    e.preventDefault();
    if (e.metaKey || e.ctrlKey) return save();
    if (col === 'k') return focusCell(i, 'v');
    if (i === rows.length - 1) {
      // Enter on the last row does nothing until it has content.
      return focusCell(i, 'k');
    }
    return focusCell(i + 1, 'k');
  }
  if (e.key === 'ArrowDown' && i < rows.length - 1) { e.preventDefault(); return focusCell(i + 1, col); }
  if (e.key === 'ArrowUp' && i > 0) { e.preventDefault(); return focusCell(i - 1, col); }
  if (e.key === 'Backspace' && input.selectionStart === 0 && input.selectionEnd === 0) {
    if (col === 'v') { e.preventDefault(); return focusCell(i, 'k'); }
    if (isBlank(rows[i]) && i > 0) {
      e.preventDefault();
      if (i === rows.length - 1) return focusCell(i - 1, 'v');
      return removeRow(i, 'v-prev');
    }
  }
}

function removeRow(i, then) {
  if (i < 0 || i >= rows.length) return;
  if (i === rows.length - 1) { rows[i] = { q: '', a: '' }; }
  else rows.splice(i, 1);
  dirty = true;
  ensureTrailingBlank();
  renderRows();
  if (then === 'v-prev') focusCell(Math.max(0, i - 1), 'v');
  else focusCell(Math.min(i, rows.length - 1), 'k');
}

function onRowPaste(e) {
  const text = e.clipboardData?.getData('text/plain') ?? '';
  const input = e.target;
  const multi = /[\r\n\t]/.test(text);
  const looksLikePair = input.classList.contains('row-k') && !input.value && / = /.test(text);
  if (!multi && !looksLikePair) return;
  e.preventDefault();
  const { cards, skipped } = parseCardsDetailed(text);
  if (!cards.length) {
    note(skipped ? `"키 = 값"이나 탭으로 나뉜 줄을 찾지 못했어요.` : '');
    return;
  }
  let i = rowIndex(input);
  // Fill the current row if it is empty, then insert the rest after it.
  const insertAt = isBlank(rows[i]) ? i : i + 1;
  if (isBlank(rows[i])) rows.splice(i, 1);
  rows.splice(insertAt, 0, ...cards.map(([q, a]) => ({ q, a })));
  dirty = true;
  ensureTrailingBlank();
  renderRows();
  focusCell(insertAt + cards.length, 'k');
  note(`${cards.length}장을 붙여 넣었어요.` + (skipped ? ` 나눌 수 없는 ${skipped}줄은 건너뛰었어요.` : ''));
}

/* ---------- views, count, save ---------- */

function currentCards() {
  if (view === 'text') return parseCards($('#editorCards').value);
  return rows.filter(isComplete).map((r) => [r.q.trim(), r.a.trim()]);
}

function updateCount() {
  const n = currentCards().length;
  const incomplete = view === 'rows' ? rows.filter(isIncomplete).length : 0;
  $('#editorCount').textContent = `${n}장` + (incomplete ? ` · 미완성 ${incomplete}` : '');
}

function setView(next) {
  if (next === view) return;
  if (next === 'text') {
    $('#editorCards').value = serializeCards(rows.filter(isComplete).map((r) => [r.q.trim(), r.a.trim()]));
  } else {
    rows = parseCards($('#editorCards').value).map(([q, a]) => ({ q, a }));
    ensureTrailingBlank();
    renderRows();
  }
  view = next;
  syncViewButtons();
  $('#editorRows').hidden = view !== 'rows';
  if (view === 'rows') applyRatio();
  $('#editorCards').hidden = view !== 'text';
  note('');
  updateCount();
  if (view === 'text') $('#editorCards').focus();
  else focusCell(rows.length - 1, 'k');
}

function syncViewButtons() {
  for (const b of document.querySelectorAll('#editorView button')) {
    b.setAttribute('aria-checked', String(b.dataset.view === view));
  }
}

function note(text) {
  $('#editorNote').textContent = text;
}

function save() {
  if (view === 'rows') {
    const firstIncomplete = rows.findIndex(isIncomplete);
    if (firstIncomplete >= 0 && !warnedIncomplete) {
      warnedIncomplete = true;
      note('키나 값이 빈 카드는 저장되지 않아요. 한 번 더 저장하면 빼고 저장합니다.');
      focusCell(firstIncomplete, rows[firstIncomplete].q.trim() ? 'v' : 'k');
      return;
    }
  }
  onSave?.({ name: $('#editorName').value.trim(), category: $('#editorCategory').value.trim(), cards: currentCards() });
  dirty = false;
  closeEditor();
}
