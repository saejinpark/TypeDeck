import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCards, serializeCards, diff, Session, REQUEUE_GAP, alternatives, pickTarget } from '../docs/core.js';

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
  assert.equal(s.submit(0), 'reveal');
  assert.equal(s.submit(0), 'shake');
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

import { migrateDecks, groupDecks, collapsedExcept, SEED_VERSION } from '../docs/core.js';


test('multiple choice offers the answer and distinct distractors', () => {
  const cards = Array.from({ length: 8 }, (_, i) => [`w${i}`, `m${i}`]);
  const s = new Session(cards, { shuffle: false, choices: 5, reverse: true });
  assert.equal(s.current.q, 'w0', 'reverse is ignored in multiple choice');
  assert.equal(s.choices.length, 5);
  assert.equal(new Set(s.choices).size, 5);
  assert.ok(s.choices.includes('m0'));
  const wrong = s.choices.findIndex((c) => c !== 'm0');
  assert.equal(s.choose(wrong, 0), 'wrong');
  assert.ok(s.wrongPicks.has(wrong));
  assert.equal(s.choose(s.answerIndex, 1), 'advance');
  assert.equal(s.current.q, 'w1');
  assert.equal(s.choices.length, 5);
  assert.equal(s.missed.length, 1, 'a wrong pick counts as a miss');
  assert.equal(s.queue.length, 9, 'and the card comes back');
});

test('multiple choice with a small deck uses what it has', () => {
  const s = new Session([['a', '1'], ['b', '2'], ['c', '2']], { shuffle: false, choices: 5 });
  assert.deepEqual([...s.choices].sort(), ['1', '2']);
  assert.equal(s.choose(9, 0), 'none');
});

test('migrateDecks replaces retired built-in decks once', () => {
  const seed = [{ id: 'toeic-basic-01', name: 'T', category: '토익', cards: [['a', '1']] }, { id: 'toefl-1', name: 'F', cards: [['b', '2']] }];
  const old = [{ id: 'proverbs', name: 'P', cards: [] }, { id: 'mine', name: 'M', cards: [['x', 'y']] }];
  const next = migrateDecks(old, 1, seed);
  assert.deepEqual(next.map((d) => d.id), ['toeic-basic-01', 'toefl-1', 'mine']);
  assert.equal(migrateDecks(next, SEED_VERSION, seed), next);
  // Version 2 had three small TOEIC decks; they give way to the day decks, TOEFL is kept as is.
  const v2 = [{ id: 'toeic-1', name: 'old', cards: [] }, { id: 'toefl-1', name: 'edited', cards: [] }, { id: 'mine', name: 'M', cards: [] }];
  assert.deepEqual(migrateDecks(v2, 2, seed).map((d) => [d.id, d.name]), [['toeic-basic-01', 'T'], ['toefl-1', 'edited'], ['mine', 'M']]);
});

test('groupDecks keeps first-seen order and puts uncategorized last', () => {
  const g = groupDecks([{ id: 1, category: '토플' }, { id: 2 }, { id: 3, category: '토익' }, { id: 4, category: '토플' }]);
  assert.deepEqual(g.map((x) => [x.category, x.decks.map((d) => d.id)]), [['토플', [1, 4]], ['토익', [3]], ['', [2]]]);
});

test('alternatives split on commas but keep numbers like 1,000', () => {
  assert.deepEqual(alternatives('지원하다, 신청하다'), ['지원하다', '신청하다']);
  assert.deepEqual(alternatives('지원하다,신청하다 ,'), ['지원하다', '신청하다']);
  assert.deepEqual(alternatives('1,000'), ['1,000']);
  assert.deepEqual(alternatives('apply'), ['apply']);
  assert.equal(pickTarget(['지원하다', '신청하다'], '신'), '신청하다');
  assert.equal(pickTarget(['지원하다', '신청하다'], ''), '지원하다');
});

test('any one of several meanings completes the card', () => {
  const s = new Session([['apply', '지원하다, 신청하다'], ['hire', '고용하다']], { shuffle: false });
  assert.equal(s.input('신청', false, 0), 'none');
  assert.equal(s.target, '신청하다');
  assert.equal(s.hadError, false, 'heading for the second meaning is not an error');
  assert.equal(s.input('신청하다', false, 10), 'advance');
  assert.equal(s.current.q, 'hire');
  assert.equal(s.streak, 1);
});

test('a meaning that starts a longer one waits for Enter', () => {
  const s = new Session([['a', '지원, 지원하다'], ['b', 'x']], { shuffle: false });
  assert.equal(s.input('지원', false, 0), 'none');
  assert.equal(s.submit(5), 'advance');
  assert.equal(s.current.q, 'b');
  assert.equal(s.streak, 1, 'accepting with Enter is still a clean answer');
  const t = new Session([['a', '지원, 지원하다'], ['b', 'x']], { shuffle: false });
  assert.equal(t.input('지원하다', false, 0), 'advance');
});

test('reverse shows all meanings and asks for the word', () => {
  const s = new Session([['apply', '지원하다, 신청하다']], { shuffle: false, reverse: true });
  assert.equal(s.current.q, '지원하다, 신청하다');
  assert.equal(s.input('apply', false, 0), 'advance');
});

test('pasted text carries over past a short meaning', () => {
  const s = new Session([['a', '가, 나'], ['b', '다'], ['c', '라']], { shuffle: false });
  assert.deepEqual(s.feed('나다라', false, 0), { advanced: 3, rest: '' });
  assert.equal(s.finished, true);
});

test('multiple choice leaves out options that share a meaning with the answer', () => {
  const cards = [['apply', '지원하다, 신청하다'], ['register', '등록하다, 신청하다'], ['hire', '고용하다'], ['fire', '해고하다']];
  for (let seed = 0; seed < 20; seed++) {
    let x = seed + 1;
    const rng = () => ((x = (x * 16807) % 2147483647) / 2147483647);
    const s = new Session(cards, { shuffle: false, choices: 5, rng });
    assert.equal(s.current.q, 'apply');
    assert.ok(!s.choices.includes('등록하다, 신청하다'));
    assert.equal(s.choices.length, 3);
  }
});

test('collapsedExcept leaves only the current deck category open', () => {
  const decks = [{ id: 'a', category: '토익 기초' }, { id: 'b', category: '토익 기초' }, { id: 'c', category: '토플' }, { id: 'd' }];
  assert.deepEqual(collapsedExcept(decks, 'c'), ['토익 기초', '']);
  assert.deepEqual(collapsedExcept(decks, 'missing'), ['토익 기초', '토플']);
});
