import { decodeText, parseCards, parseCardsDetailed, parseImport, serializeCards } from './core.js';
import { enterHandler } from './keys.js';

/*
 * Deck editor: a two-column list of key/value fields.
 * Enter moves key -> value -> next card, the last row always stays empty so typing there adds a
 * card, multi-line paste becomes many cards, and a text view keeps the old "key = value" format.
 */

const $ = (sel) => document.querySelector(sel);

let rows = []; // [{ q, a, n, open }], n is the 메모; the last row is always the empty "new card" row
let view = 'rows';
let onSave = null;
let onDelete = null;
let onClearRecord = null;
let dirty = false;
let warnedIncomplete = false;

const isBlank = (r) => !r.q.trim() && !r.a.trim();
const toRow = ([q, a, n]) => ({ q, a, n: n ?? '', open: false });
const toCard = (r) => (r.n.trim() ? [r.q.trim(), r.a.trim(), r.n.trim()] : [r.q.trim(), r.a.trim()]);
const blankRow = () => ({ q: '', a: '', n: '', open: false });
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
    const noteBtn = e.target.closest('.row-note-btn');
    if (noteBtn) toggleNote(rowIndex(noteBtn));
  });

  // Enter after the name goes to the empty row at the end, where new cards are typed.
  $('#editorName').addEventListener('keydown', enterHandler((e) => {
    e.preventDefault();
    if (e.metaKey || e.ctrlKey) return save();
    focusCell(rows.length - 1, 'k');
  }));
  $('#editorImport').addEventListener('click', () => $('#editorFile').click());
  $('#editorFile').addEventListener('change', async (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (file) importFile(file.name, decodeText(await file.arrayBuffer()));
  });
  $('#editorName').addEventListener('input', () => { dirty = true; });
  $('#editorCategory').addEventListener('input', () => { dirty = true; });
  $('#editorCategory').addEventListener('keydown', enterHandler((e) => {
    e.preventDefault();
    if (e.metaKey || e.ctrlKey) return save();
    $('#editorName').focus();
  }));
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
  $('#editorClearRecord').addEventListener('click', () => {
    if (onClearRecord?.()) $('#editorClearRecord').hidden = true;
  });
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
  onClearRecord = handlers.onClearRecord;
  $('#editorClearRecord').hidden = !deck || !handlers.hasRecord;
  dirty = false;
  warnedIncomplete = false;
  $('#editorTitle').textContent = deck ? '덱 편집' : '새 덱';
  $('#editorName').value = deck ? deck.name : '';
  $('#editorDelete').hidden = !deck;
  rows = (deck?.cards ?? []).map(toRow);
  ensureTrailingBlank();
  showMessage('');
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
  if (!rows.length || !isBlank(rows[rows.length - 1])) rows.push(blankRow());
}

const rowTemplate = document.createElement('template');
rowTemplate.innerHTML = `<div class="card-row">
    <span class="row-num"></span>
    <input class="row-k" autocomplete="off" spellcheck="false" aria-label="키">
    <input class="row-v" autocomplete="off" spellcheck="false" aria-label="값">
    <button type="button" class="row-note-btn" tabindex="-1" aria-label="메모" title="메모 쓰기 · 보기"><svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" d="M3 4h10M3 8h10M3 12h6"/></svg></button>
    <button type="button" class="row-del" tabindex="-1" aria-label="카드 삭제" title="카드 삭제">×</button></div>`;

function rowEl(row, i) {
  const el = rowTemplate.content.firstElementChild.cloneNode(true);
  el.querySelector('.row-k').value = row.q;
  el.querySelector('.row-v').value = row.a;
  if (row.open) {
    const area = document.createElement('textarea');
    area.className = 'row-note';
    area.rows = 3;
    area.placeholder = '메모 (뜻풀이, 예문, 외우는 요령, 문법 설명…) · 연습할 때 카드 아래에 나와요';
    area.value = row.n;
    el.append(area);
    requestAnimationFrame(() => fitNote(area));
  }
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
  el.classList.toggle('has-note', Boolean(row.n.trim()));
  el.classList.toggle('note-open', row.open);
}

function fitNote(area) {
  area.style.height = 'auto';
  area.style.height = `${Math.min(area.scrollHeight + 2, 320)}px`;
}

/** Opens or closes the 메모 field under row `i`. */
function toggleNote(i) {
  const row = rows[i];
  if (!row || i === rows.length - 1) return;
  row.open = !row.open;
  const body = $('#rowsBody');
  const el = rowEl(row, i);
  body.replaceChild(el, body.children[i]);
  if (row.open) el.querySelector('.row-note').focus();
  else focusCell(i, 'v');
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
  const field = e.target.classList.contains('row-k') ? 'q' : e.target.classList.contains('row-note') ? 'n' : 'a';
  rows[i][field] = e.target.value;
  if (field === 'n') fitNote(e.target);
  dirty = true;
  const body = $('#rowsBody');
  if (i === rows.length - 1 && !isBlank(rows[i])) {
    // Typing in the empty last row turns it into a card and adds a new empty row.
    rows.push(blankRow());
    body.append(rowEl(rows[rows.length - 1], rows.length - 1));
  }
  decorate(body.children[i], rows[i], i);
  updateCount();
}

/** Enter in a card row: key → value → the next row's key. */
const rowEnter = enterHandler((e) => {
  const input = e.target;
  const i = rowIndex(input);
  if (i < 0) return;
  e.preventDefault();
  if (e.metaKey || e.ctrlKey) return save();
  if (input.classList.contains('row-k')) return focusCell(i, 'v');
  // Enter on the last row stays there until it has content.
  if (i === rows.length - 1) return focusCell(i, 'k');
  return focusCell(i + 1, 'k');
});

function onRowKeyDown(e) {
  const input = e.target;
  if (input.classList.contains('row-note')) {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && !composingKey(e)) { e.preventDefault(); save(); }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); toggleNote(rowIndex(input)); }
    return;
  }
  if (!(input instanceof HTMLInputElement)) return;
  if (rowEnter(e)) return;
  const i = rowIndex(input);
  const col = input.classList.contains('row-k') ? 'k' : 'v';
  if (composingKey(e)) return;

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
  if (i === rows.length - 1) { rows[i] = blankRow(); }
  else rows.splice(i, 1);
  dirty = true;
  ensureTrailingBlank();
  renderRows();
  if (then === 'v-prev') focusCell(Math.max(0, i - 1), 'v');
  else focusCell(Math.min(i, rows.length - 1), 'k');
}

/** Adds the cards of an imported file after the existing ones. */
function importFile(fileName, text) {
  if (text === null) return showMessage(`'${fileName}'은(는) 텍스트 파일이 아니에요. 텍스트, CSV, TSV 파일을 골라 주세요.`);
  if (!text.trim()) return showMessage(`'${fileName}'은(는) 비어 있어요.`);
  const { cards, skipped } = parseImport(text, fileName);
  if (!cards.length) {
    showMessage(`'${fileName}'에서 카드를 찾지 못했어요. 한 줄에 "키 = 값"이나 탭, CSV 두 열로 적힌 파일을 써 주세요.`);
    return;
  }
  if (view === 'text') setView('rows');
  rows = rows.filter((r) => !isBlank(r)).concat(cards.map(toRow));
  ensureTrailingBlank();
  renderRows();
  if (!$('#editorName').value.trim()) $('#editorName').value = fileName.replace(/\.[^.]+$/, '');
  dirty = true;
  updateCount();
  focusCell(rows.length - 1, 'k');
  showMessage(`'${fileName}'에서 ${cards.length}장을 불러왔어요.` + (skipped ? ` 나눌 수 없는 ${skipped}줄은 건너뛰었어요.` : ''));
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
    showMessage(skipped ? `"키 = 값"이나 탭으로 나뉜 줄을 찾지 못했어요.` : '');
    return;
  }
  let i = rowIndex(input);
  // Fill the current row if it is empty, then insert the rest after it.
  const insertAt = isBlank(rows[i]) ? i : i + 1;
  if (isBlank(rows[i])) rows.splice(i, 1);
  rows.splice(insertAt, 0, ...cards.map(toRow));
  dirty = true;
  ensureTrailingBlank();
  renderRows();
  focusCell(insertAt + cards.length, 'k');
  showMessage(`${cards.length}장을 붙여 넣었어요.` + (skipped ? ` 나눌 수 없는 ${skipped}줄은 건너뛰었어요.` : ''));
}

/* ---------- views, count, save ---------- */

function currentCards() {
  if (view === 'text') return parseCards($('#editorCards').value);
  return rows.filter(isComplete).map(toCard);
}

function updateCount() {
  const n = currentCards().length;
  const incomplete = view === 'rows' ? rows.filter(isIncomplete).length : 0;
  $('#editorCount').textContent = `${n}장` + (incomplete ? ` · 미완성 ${incomplete}` : '');
}

function setView(next) {
  if (next === view) return;
  if (next === 'text') {
    $('#editorCards').value = serializeCards(rows.filter(isComplete).map(toCard));
  } else {
    rows = parseCards($('#editorCards').value).map(toRow);
    ensureTrailingBlank();
    renderRows();
  }
  view = next;
  syncViewButtons();
  $('#editorRows').hidden = view !== 'rows';
  if (view === 'rows') applyRatio();
  $('#editorCards').hidden = view !== 'text';
  showMessage('');
  updateCount();
  if (view === 'text') $('#editorCards').focus();
  else focusCell(rows.length - 1, 'k');
}

function syncViewButtons() {
  for (const b of document.querySelectorAll('#editorView button')) {
    b.setAttribute('aria-checked', String(b.dataset.view === view));
  }
}

function showMessage(text) {
  $('#editorMessage').textContent = text;
}

function save() {
  if (view === 'rows') {
    const firstIncomplete = rows.findIndex(isIncomplete);
    if (firstIncomplete >= 0 && !warnedIncomplete) {
      warnedIncomplete = true;
      showMessage('키나 값이 빈 카드는 저장되지 않아요. 한 번 더 저장하면 빼고 저장합니다.');
      focusCell(firstIncomplete, rows[firstIncomplete].q.trim() ? 'v' : 'k');
      return;
    }
  }
  onSave?.({ name: $('#editorName').value.trim(), category: $('#editorCategory').value.trim(), cards: currentCards() });
  dirty = false;
  closeEditor();
}
