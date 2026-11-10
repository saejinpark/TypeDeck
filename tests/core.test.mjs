import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCards, serializeCards, diff, Session, REQUEUE_GAP } from '../docs/core.js';

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
