// Firebase web config for the push service worker (stream N loads it with
// importScripts('firebase-config.js')). Overwritten at release build time by
// .github/scripts/firebase-config.sh with
//   self.JAY_FIREBASE_CONFIG = {apiKey, authDomain, projectId, storageBucket,
//                               messagingSenderId, appId};
// (keys exactly as the Firebase JS SDK expects them).
// null = this build has no Firebase project; the service worker must no-op.
self.JAY_FIREBASE_CONFIG = null;
