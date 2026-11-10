import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCards, serializeCards, diff, Session, REQUEUE_GAP, meanings, typingTarget, fillSeparators } from '../docs/core.js';

test('parses the supported separators', () => {
  const cards = parseCards('a = 1\nb\t2\n# comment\n\nc: 3\nd=4\nno separator\ne = x = y\nf : git log --oneline');
  assert.deepEqual(cards, [['a', '1'], ['b', '2'], ['c', '3'], ['d', '4'], ['e', 'x = y'], ['f', 'git log --oneline']]);
});

test('serialize round-trips', () => {
  const cards = [['200', 'OK'], ['a=b', 'c'], ['소 잃고', '외양간 고친다']];
  assert.deepEqual(parseCards(serializeCards(cards)), cards);
});

test('diff marks ok, bad, composing, todo and extra characters', () => {
  assert.deepEqual(diff('서울', '서우', true).map((d) => d.state), ['ok', 'comp']);
  assert.deepEqual(diff('서울', '서우', false).map((d) => d.state), ['ok', 'bad']);
  assert.deepEqual(diff('OK', 'O', false).map((d) => d.state), ['ok', 'todo']);
  assert.deepEqual(diff('OK', 'OKK', false).map((d) => d.state), ['ok', 'ok', 'extra']);
});

test('completing the answer advances immediately, even while an IME is composing', () => {
  const s = new Session([['대한민국', '서울'], ['일본', '도쿄']], { shuffle: false });
  assert.equal(s.input('서', true, 0), 'none');
  assert.equal(s.input('서우', true, 10), 'none');
  assert.equal(s.hadError, false, 'a syllable still being composed is not an error');
  assert.equal(s.input('서울', true, 20), 'advance');
  assert.equal(s.current.q, '일본');
  assert.equal(s.typed, '');
  assert.equal(s.streak, 1);
});

test('a wrong character makes the card come back later', () => {
  const cards = Array.from({ length: 10 }, (_, i) => [`k${i}`, `v${i}`]);
  const s = new Session(cards, { shuffle: false });
  s.input('x', false, 0);
  assert.equal(s.hadError, true);
  assert.equal(s.input('v0', false, 100), 'advance');
  assert.equal(s.queue.length, 11);
  assert.equal(s.queue[1 + REQUEUE_GAP], 0);
  assert.equal(s.streak, 0);
  assert.equal(s.missed.length, 1);
});

test('enter reveals, tab skips and both count as a miss', () => {
  const s = new Session([['a', '1'], ['b', '2']], { shuffle: false });
  assert.equal(s.submit(), 'reveal');
  assert.equal(s.submit(), 'shake');
  assert.equal(s.input('1', false, 5), 'advance');
  assert.equal(s.skip(10), 'advance');
  assert.equal(s.accuracy, 0);
  // both cards were re-queued at the end because the deck is short
  assert.deepEqual(s.queue, [0, 1, 0, 1]);
  s.input('1', false, 20);
  s.input('2', false, 30);
  assert.equal(s.finished, true);
  assert.equal(s.accuracy, 0, 'accuracy only counts the first attempt');
});

test('reverse mode swaps question and answer; NFD input still matches', () => {
  const s = new Session([['서울', '수도']], { shuffle: false, reverse: true });
  assert.equal(s.current.q, '수도');
  assert.equal(s.input('서울'.normalize('NFD'), false, 0), 'advance');
  assert.equal(s.finished, true);
});

test('keystrokes per minute uses active typing time', () => {
  const s = new Session([['a', 'abc']], { shuffle: false });
  s.keystroke(0); s.keystroke(500); s.keystroke(1000);
  s.input('abc', false, 3000);
  assert.equal(Math.round(s.kpm), 60);
  assert.equal(s.accuracy, 1);
});

test('text that runs past the answer carries over to the next cards', () => {
  const s = new Session([['a', 'OK'], ['b', 'Found'], ['c', 'Gone']], { shuffle: false });
  assert.deepEqual(s.feed('OKFoundGo', false, 0), { advanced: 2, rest: 'Go' });
  assert.equal(s.current.a, 'Gone');
  assert.equal(s.typed, 'Go');
  assert.equal(s.streak, 2);
  assert.deepEqual(s.feed('Gone', false, 10), { advanced: 1, rest: '' });
  assert.equal(s.finished, true);
});

test('feed does not carry over while an IME is still composing', () => {
  const s = new Session([['a', '서울'], ['b', '도쿄']], { shuffle: false });
  assert.deepEqual(s.feed('서울도', true, 0), { advanced: 0, rest: '서울도' });
  assert.equal(s.current.a, '서울');
});

import { InputTracker, absorbedJamo } from '../docs/core.js';

test('absorbedJamo finds the consonant the IME attached to the previous syllable', () => {
  assert.equal(absorbedJamo('다', '닥'), 'ㄱ');
  assert.equal(absorbedJamo('울', '욹'), 'ㄱ');
  assert.equal(absorbedJamo('다', '도'), null);
  assert.equal(absorbedJamo('다', '다'), null);
  assert.equal(absorbedJamo('a', 'b'), null);
});

test('tracker: card finished mid-composition, next card typed into the same input', () => {
  const t = new InputTracker();
  // "곱다" finished while 다 is still composing
  t.consume('곱다', '다');
  assert.equal(t.segment('곱다'), '');
  assert.equal(t.segment('곱닥'), 'ㄱ', 'the next consonant shows on the new card');
  assert.equal(t.segment('곱다가'), '가', 'the IME split the syllable');
  assert.equal(t.segment('곱다각'), '각');
});

test('tracker: typo on the new card can be deleted down to nothing', () => {
  const t = new InputTracker();
  t.consume('서울', '울');
  assert.equal(t.segment('서욹'), 'ㄱ');    // typo absorbed into 울
  assert.equal(t.segment('서울'), '');      // Backspace removes it
  assert.equal(t.segment('서우'), '');      // extra Backspace eats the old syllable, still nothing new
  assert.equal(t.segment('서'), '');
  assert.equal(t.segment(''), '');
  assert.equal(t.segment('ㄷ'), 'ㄷ');
});

test('tracker: typo after the carry has settled', () => {
  const t = new InputTracker();
  t.consume('서울', '울');
  assert.equal(t.segment('서울도'), '도');
  assert.equal(t.segment('서울도ㅋ'), '도ㅋ');
  assert.equal(t.segment('서울도'), '도');
  assert.equal(t.segment('서울ㄷ'), 'ㄷ');
  assert.equal(t.segment('서울'), '');
  assert.equal(t.segment('서우'), '', 'deleting into the old card shows nothing');
});

test('tracker: committed overflow and plain resets', () => {
  const t = new InputTracker();
  t.consume('OKFo', '', 'Fo');
  assert.equal(t.segment('OKFo'), 'Fo');
  assert.equal(t.segment('OKF'), 'F');
  t.reset();
  assert.equal(t.segment('abc'), 'abc');
});

import { parseCardsDetailed } from '../docs/core.js';

test('parseCardsDetailed counts lines it could not use', () => {
  const r = parseCardsDetailed('a = 1\nno separator\n\n# note\nb =\nc\t3');
  assert.deepEqual(r.cards, [['a', '1'], ['c', '3']]);
  assert.equal(r.skipped, 2);
});

import { migrateDecks, groupDecks, compactDecks, collapsedExcept, seedCategories, addSeedDecks, syncCategories, renameCategory, parseImport, SEED_VERSION } from '../docs/core.js';


test('migrateDecks adds built-in decks newer than the stored data, once', () => {
  const seed = [
    { id: 'toeic-basic-01', name: 'T', category: '토익', since: 3, cards: [['a', '1']] },
    { id: 'en-sent-01', name: 'S', category: '영어 문장', since: 5, cards: [['ko', 'en.', '메모']] },
  ];
  const mine = { id: 'mine', name: 'M', cards: [] };
  // Data from before the sentence decks gets them, with their 메모.
  const next = migrateDecks([mine], 4, seed);
  assert.deepEqual(next.map((d) => d.id), ['en-sent-01', 'mine']);
  assert.deepEqual(next[0].cards[0], ['ko', 'en.', '메모']);
  // A TOEIC deck the user deleted at version 4 does not come back.
  assert.ok(!next.some((d) => d.id === 'toeic-basic-01'));
  // Up-to-date data is left alone.
  assert.equal(migrateDecks(next, SEED_VERSION, seed), next);
});

test('groupDecks keeps first-seen order and puts uncategorized last', () => {
  const g = groupDecks([{ id: 1, category: '토플' }, { id: 2 }, { id: 3, category: '토익' }, { id: 4, category: '토플' }]);
  assert.deepEqual(g.map((x) => [x.category, x.decks.map((d) => d.id)]), [['토플', [1, 4]], ['토익', [3]], ['', [2]]]);
});

test('meanings split on commas but keep numbers like 1,000', () => {
  assert.deepEqual(meanings('지원하다, 신청하다'), ['지원하다', '신청하다']);
  assert.deepEqual(meanings('지원하다,신청하다 ,'), ['지원하다', '신청하다']);
  assert.deepEqual(meanings('1,000'), ['1,000']);
  assert.deepEqual(meanings('apply'), ['apply']);
  assert.equal(typingTarget('지원하다,신청하다').text, '지원하다, 신청하다');
});

test('every meaning is typed; the ", " between them fills in by itself', () => {
  const target = typingTarget('줄, 노선, 제품군');
  assert.deepEqual(fillSeparators(target, '줄', false).shown, '줄, ');
  assert.deepEqual(fillSeparators(target, '줄', true).shown, '줄', 'not while the syllable is still being composed');
  assert.deepEqual(fillSeparators(target, '줄노선', false).shown, '줄, 노선, ');
  assert.deepEqual(fillSeparators(target, '줄, 노선', false).shown, '줄, 노선, ', 'typing the comma yourself also works');
  assert.deepEqual(fillSeparators(target, '줄,노선', false).shown, '줄, 노선, ');
  const s = new Session([['line', '줄, 노선, 제품군'], ['hire', '고용하다']], { shuffle: false });
  assert.equal(s.input('줄', false, 0), 'none', 'the first meaning alone is not enough');
  assert.equal(s.input('줄노선', false, 1), 'none');
  assert.equal(s.hadError, false);
  assert.equal(s.input('줄노선제품군', false, 2), 'advance');
  assert.equal(s.current.q, 'hire');
  assert.equal(s.streak, 1);
});

test('a wrong meaning is an error at its own place', () => {
  const s = new Session([['line', '줄, 노선']], { shuffle: false });
  s.input('줄노산', false, 0);
  assert.equal(s.shown, '줄, 노산');
  assert.equal(s.hadError, true);
  assert.deepEqual(diff(s.current.a, s.shown, false).map((d) => d.state), ['ok', 'ok', 'ok', 'ok', 'bad']);
});

test('reverse shows all meanings and asks for the word', () => {
  const s = new Session([['apply', '지원하다, 신청하다']], { shuffle: false, reverse: true });
  assert.equal(s.current.q, '지원하다, 신청하다');
  assert.equal(s.input('apply', false, 0), 'advance');
});

test('pasted text carries over to the next cards', () => {
  const s = new Session([['a', '가, 나'], ['b', '다'], ['c', '라']], { shuffle: false });
  assert.deepEqual(s.feed('가나다라', false, 0), { advanced: 3, rest: '' });
  assert.equal(s.finished, true);
});

test('collapsedExcept leaves only the current deck category open', () => {
  const decks = [{ id: 'a', category: '토익 기초' }, { id: 'b', category: '토익 기초' }, { id: 'c', category: '토플' }, { id: 'd' }];
  assert.deepEqual(collapsedExcept(decks, 'c'), ['토익 기초', '']);
  assert.deepEqual(collapsedExcept(decks, 'missing'), ['토익 기초', '토플']);
});

test('seedCategories counts cards and addSeedDecks keeps seed order first', () => {
  const seed = [
    { id: 'b1', category: '기초', cards: [['a', '1'], ['b', '2']] },
    { id: 'b2', category: '기초', cards: [['c', '3']] },
    { id: 'm1', category: '중급', cards: [['d', '4']] },
  ];
  const mine = { id: 'mine', category: '', cards: [] };
  assert.deepEqual(seedCategories(seed).map((c) => [c.category, c.decks.length, c.cardCount]), [['기초', 2, 3], ['중급', 1, 1]]);
  const next = addSeedDecks([mine, seed[2]], seed, [seed[0], seed[2]]);
  assert.deepEqual(next.map((d) => d.id), ['b1', 'm1', 'mine']);
  assert.deepEqual(addSeedDecks([], seed, []), []);
});

test('empty categories from the list are kept, in order, before uncategorized decks', () => {
  const decks = [{ id: 1, category: '토익' }, { id: 2 }, { id: 3, category: ' 정보처리기사 ' }];
  const g = groupDecks(decks, ['정보처리기사', '한국사']);
  assert.deepEqual(g.map((x) => [x.category, x.decks.map((d) => d.id)]), [['정보처리기사', [3]], ['한국사', []], ['토익', [1]], ['', [2]]]);
  assert.deepEqual(syncCategories(['한국사'], decks), ['한국사', '토익', '정보처리기사']);
});

test('renameCategory moves decks and merges into an existing category', () => {
  const decks = [{ id: 1, category: 'A' }, { id: 2, category: 'B' }];
  const r = renameCategory(decks, ['A', 'B', 'C'], 'A', '  새 이름 ');
  assert.deepEqual(r.order, ['새 이름', 'B', 'C']);
  assert.equal(r.decks[0].category, '새 이름');
  const m = renameCategory(decks, ['A', 'B', 'C'], 'A', 'C');
  assert.deepEqual(m.order, ['B', 'C']);
  assert.equal(m.decks[0].category, 'C');
});

test('parseImport reads CSV with quotes, TSV and plain text', () => {
  const csv = '\uFEFFapply,"지원하다, 신청하다"\nhire,고용하다\n"say ""hi""",인사\nonly\n';
  assert.deepEqual(parseImport(csv, 'w.csv'), { cards: [['apply', '지원하다, 신청하다'], ['hire', '고용하다'], ['say "hi"', '인사']], skipped: 1 });
  assert.deepEqual(parseImport('a,b,"해설 첫 줄\n둘째 줄"\nc,d', 'x.csv').cards, [['a', 'b', '해설 첫 줄\n둘째 줄'], ['c', 'd']]);
  assert.deepEqual(parseImport('a\t1, 2', 'x.tsv').cards, [['a', '1, 2']]);
  assert.deepEqual(parseImport('OSI 7계층 = 물리, 데이터링크', 'notes.txt').cards, [['OSI 7계층', '물리, 데이터링크']]);
});

test('notes: "> " lines after a card, kept through serialize and the session', () => {
  const text = '나는 그를 안다. = I know him.\n> know는 상태동사라\n> 진행형으로 쓰지 않는다.\n\n고양이 = cat\n> 동물';
  const { cards, skipped } = parseCardsDetailed(text);
  assert.equal(skipped, 0);
  assert.deepEqual(cards, [['나는 그를 안다.', 'I know him.', 'know는 상태동사라\n진행형으로 쓰지 않는다.'], ['고양이', 'cat', '동물']]);
  assert.deepEqual(parseCardsDetailed(serializeCards(cards)).cards, cards);
  assert.equal(parseCardsDetailed('> orphan').skipped, 1);
  const s = new Session(cards, { shuffle: false });
  assert.equal(s.current.note, 'know는 상태동사라\n진행형으로 쓰지 않는다.');
  assert.equal(new Session([['a', 'b']], { shuffle: false }).current.note, '');
});

test('a sentence answer keeps its commas', () => {
  assert.deepEqual(meanings('If I had known, I would have come.'), ['If I had known, I would have come.']);
  assert.deepEqual(meanings('Yes, I do.'), ['Yes, I do.']);
  assert.deepEqual(meanings('"Wait," she said, "not yet!"'), ['"Wait," she said, "not yet!"']);
  const s = new Session([['내가 알았더라면, 왔을 텐데.', 'If I had known, I would have come.']], { shuffle: false });
  assert.equal(s.input('If I had known,', false, 0), 'none');
  assert.equal(s.shown, 'If I had known,', 'no automatic space inside a sentence');
  assert.equal(s.hadError, false);
  assert.equal(s.input('If I had known, I would have come.', false, 1), 'advance');
});

test('bundled sample decks: unique keys per category group and idioms added in v6', async () => {
  const { readFile } = await import('node:fs/promises');
  const { decks } = JSON.parse(await readFile(new URL('../docs/decks.json', import.meta.url), 'utf8'));
  const toeic = decks.filter((d) => d.id.startsWith('toeic-')).flatMap((d) => d.cards.map((c) => c[0].toLowerCase()));
  assert.equal(new Set(toeic).size, toeic.length, 'no TOEIC entry appears twice');
  const phrases = decks.filter((d) => d.category === '토익 숙어');
  assert.equal(phrases.length, 19);
  assert.ok(phrases.filter((d) => d.since === 6).every((d) => Number(d.id.slice(-2)) >= 5), 'old idiom decks keep since 3');
  assert.ok(decks.every((d) => Number.isInteger(d.since)));
});

test('compactDecks shows numbered decks as a grid under their shared name', () => {
  const d = (id, name) => ({ id, name, cards: [] });
  const r = compactDecks([d(1, '기초 Day 01'), d(2, '기초 Day 02'), d(3, '내 단어장'), d(4, '기초 Day 03')]);
  assert.equal(r.prefix, '기초 Day');
  assert.deepEqual(r.grid.map((g) => [g.deck.id, g.label]), [[1, '01'], [2, '02'], [4, '03']]);
  assert.deepEqual(r.rows.map((x) => x.id), [3]);
  // Names that do not share a part, or too few of them, stay as rows.
  assert.deepEqual(compactDecks([d(1, '01 시제와 완료'), d(2, '02 조동사와 가정법'), d(3, '03 관계사')]).grid, []);
  assert.deepEqual(compactDecks([d(1, 'Day 1'), d(2, 'Day 2')]).grid, []);
  assert.deepEqual(compactDecks([d(1, '단원 첫째이야기'), d(2, '단원 둘째이야기'), d(3, '단원 셋째이야기')]).grid, [], 'labels longer than 4 characters stay as rows');
});
