// Jay push service worker (notifications spec 2026-11-06, section 2, web).
//
// Registered by the app (lib/features/notifications/web_platform_web.dart)
// with the NARROW scope "/push/": Flutter's own flutter_service_worker.js owns
// "/" and a scope holds one worker. This worker controls no page and has no
// fetch handler, so it can never affect the app or /admin/.
//
// It does two things:
// - "push": shows the server's generic notification (contract 1.3). Browsers
//   require a visible notification for every push (userVisibleOnly).
// - "notificationclick": focuses an open Jay tab and tells it which
//   conversation to open, or opens a new tab at that route.
//
// The routing below mirrors NotificationTarget in notification_content.dart;
// test/web/push_sw.test.mjs covers it.

/* eslint-env serviceworker */

const ID = /^[A-Za-z0-9-]{1,64}$/;
const TYPES = ['message', 'group_message', 'incoming_call', 'channel_post'];

/** App route for push data, "/chats" when the data is unusable. */
function routeFor(data) {
  if (!data || !TYPES.includes(data.type) || typeof data.conversationId !== 'string' || !ID.test(data.conversationId)) {
    return '/chats';
  }
  return data.type === 'channel_post'
    ? '/channels/feed/' + data.conversationId
    : '/chats/' + data.conversationId;
}

/** Only the three contract keys travel on: nothing else is trusted. */
function pickData(data) {
  const out = {};
  if (data && typeof data === 'object') {
    for (const key of ['type', 'conversationId', 'v']) {
      if (typeof data[key] === 'string') out[key] = data[key];
    }
  }
  return out;
}

/** Where the app lives: the directory of this script (the site root). */
function appRoot() {
  return new URL('./', self.location.href).href;
}

function onPush(event) {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = {};
  }
  const title = typeof payload.title === 'string' && payload.title ? payload.title : 'Jay';
  const body = typeof payload.body === 'string' ? payload.body : '';
  const data = pickData(payload);
  const tag = typeof payload.tag === 'string' && payload.tag ? payload.tag : data.conversationId;
  const options = { body: body, data: data, icon: appRoot() + 'icons/Icon-192.png' };
  // Same tag per conversation: a newer push replaces the older one (N4).
  if (tag) options.tag = tag;
  event.waitUntil(self.registration.showNotification(title, options));
}

async function openOrFocus(data) {
  const root = appRoot();
  const route = routeFor(data);
  const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  // An app tab: same origin, not the operator console under /admin/.
  const tabs = windows.filter((c) => c.url.startsWith(root) && !c.url.startsWith(root + 'admin'));
  const tab = tabs.find((c) => c.focused) || tabs.find((c) => c.visibilityState === 'visible') || tabs[0];
  if (tab) {
    // The tab routes itself (keeps its state, no reload).
    tab.postMessage({ jay: 'notification-click', data: data });
    if ('focus' in tab) await tab.focus();
    return;
  }
  // Hash routing: the Flutter app reads the route after "#".
  await self.clients.openWindow(root + '#' + route);
}

function onNotificationClick(event) {
  event.notification.close();
  event.waitUntil(openOrFocus(pickData(event.notification.data)));
}

// A new version replaces the old one at once: it holds no state or cache.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('push', onPush);
self.addEventListener('notificationclick', onNotificationClick);
// "pushsubscriptionchange" is deliberately not handled: re-registering needs
// the device's API token, which only the app has. The app re-subscribes and
// re-registers on every start and reconnect.

// Exposed for the Node unit test only (no effect in a browser).
if (typeof module !== 'undefined') {
  module.exports = { routeFor, pickData, onPush, onNotificationClick, openOrFocus };
}
