// Unit test of web/push-sw.js (notifications spec section 3: "SW click
// handler logic covered by a small JS test"). Runs the worker in a Node VM
// with a fake ServiceWorkerGlobalScope. Run: node --test test/web/push_sw.test.mjs
// (test/web/push_sw_test.dart runs it from `flutter test` when node exists).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const source = readFileSync(
  fileURLToPath(new URL('../../web/push-sw.js', import.meta.url)),
  'utf8',
);

function load({ windows = [] } = {}) {
  const listeners = {};
  const shown = [];
  const opened = [];
  const self = {
    location: { href: 'https://jay.example/push-sw.js' },
    addEventListener: (type, fn) => { listeners[type] = fn; },
    skipWaiting: () => {},
    registration: {
      showNotification: async (title, options) => { shown.push({ title, options }); },
    },
    clients: {
      matchAll: async () => windows,
      openWindow: async (url) => { opened.push(url); },
    },
  };
  const module = { exports: {} };
  vm.runInNewContext(source, { self, module, URL });
  return { api: module.exports, listeners, shown, opened };
}

function tab(url, extra = {}) {
  const t = { url, focused: false, visibilityState: 'hidden', messages: [], focusCalls: 0, ...extra };
  t.postMessage = (m) => t.messages.push(m);
  t.focus = async () => { t.focusCalls++; };
  return t;
}

async function click(listeners, data) {
  let waited;
  let closed = false;
  listeners.notificationclick({
    notification: { data, close: () => { closed = true; } },
    waitUntil: (p) => { waited = p; },
  });
  await waited;
  return closed;
}

test('routeFor maps every contract type and rejects unsafe ids', () => {
  const { api } = load();
  assert.equal(api.routeFor({ type: 'message', conversationId: 'abc-1' }), '/chats/abc-1');
  assert.equal(api.routeFor({ type: 'group_message', conversationId: 'g1' }), '/chats/g1');
  assert.equal(api.routeFor({ type: 'incoming_call', conversationId: 'p1' }), '/chats/p1');
  assert.equal(api.routeFor({ type: 'channel_post', conversationId: 'c1' }), '/channels/feed/c1');
  assert.equal(api.routeFor({ type: 'message', conversationId: '../settings' }), '/chats');
  assert.equal(api.routeFor({ type: 'other', conversationId: 'x' }), '/chats');
  assert.equal(api.routeFor(undefined), '/chats');
});

test('push shows the server text with the conversation as tag', async () => {
  const { listeners, shown } = load();
  let waited;
  listeners.push({
    data: { json: () => ({ title: 'Jay', body: 'New message', type: 'message', conversationId: 'abc', v: '1', tag: 'abc', extra: 'dropped' }) },
    waitUntil: (p) => { waited = p; },
  });
  await waited;
  assert.equal(shown.length, 1);
  assert.equal(shown[0].title, 'Jay');
  assert.equal(shown[0].options.body, 'New message');
  assert.equal(shown[0].options.tag, 'abc');
  assert.deepEqual({ ...shown[0].options.data }, { type: 'message', conversationId: 'abc', v: '1' });
});

test('a push without a readable payload still shows a notification', async () => {
  const { listeners, shown } = load();
  let waited;
  listeners.push({ data: { json: () => { throw new Error('not json'); } }, waitUntil: (p) => { waited = p; } });
  await waited;
  assert.equal(shown.length, 1);
  assert.equal(shown[0].title, 'Jay');
});

test('click focuses an open app tab and posts the target to it', async () => {
  const app = tab('https://jay.example/#/chats', { visibilityState: 'visible' });
  const admin = tab('https://jay.example/admin/', { focused: true });
  const { listeners, opened } = load({ windows: [admin, app] });
  const closed = await click(listeners, { type: 'channel_post', conversationId: 'c1', v: '1' });
  assert.equal(closed, true);
  assert.equal(opened.length, 0);
  assert.equal(admin.messages.length, 0, 'the operator console is never used');
  assert.equal(app.focusCalls, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(app.messages)), [
    { jay: 'notification-click', data: { type: 'channel_post', conversationId: 'c1', v: '1' } },
  ]);
});

test('click without an app tab opens the conversation route', async () => {
  const { listeners, opened } = load({ windows: [tab('https://other.example/')] });
  await click(listeners, { type: 'group_message', conversationId: 'g-9', v: '1' });
  assert.deepEqual(opened, ['https://jay.example/#/chats/g-9']);
});
