// Bridges the browser Web Push API to the Flutter app. The fiddly bits
// (service-worker registration, base64url VAPID key decoding, PushManager
// subscribe) live here in plain JS; Dart calls these via js_interop and only
// passes the resulting subscription JSON to the backend.
(function () {
  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const raw = atob(base64);
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }

  function supported() {
    return (
      'serviceWorker' in navigator &&
      'PushManager' in window &&
      'Notification' in window
    );
  }

  async function getRegistration() {
    if (!('serviceWorker' in navigator)) return null;
    let reg = await navigator.serviceWorker.getRegistration();
    const url = reg && reg.active ? reg.active.scriptURL : '';
    if (!reg || !url.endsWith('/push_sw.js')) {
      reg = await navigator.serviceWorker.register('push_sw.js');
    }
    await navigator.serviceWorker.ready;
    return reg;
  }

  async function requestPermission() {
    try {
      return await Notification.requestPermission();
    } catch (_e) {
      return 'denied';
    }
  }

  window.agentdeckPush = {
    supported: supported,
    permission: function () {
      try {
        return Notification.permission;
      } catch (_e) {
        return 'denied';
      }
    },
    // Returns the subscription JSON string, or null when unsupported / denied.
    subscribe: async function (vapidKey) {
      try {
        if (!supported() || !vapidKey) return null;
        const perm = await requestPermission();
        if (perm !== 'granted') return null;
        const reg = await getRegistration();
        if (!reg) return null;
        let sub = await reg.pushManager.getSubscription();
        if (!sub) {
          sub = await reg.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: urlBase64ToUint8Array(vapidKey),
          });
        }
        return JSON.stringify(sub.toJSON());
      } catch (_e) {
        return null;
      }
    },
    // Returns the removed endpoint, or null when there was none.
    unsubscribe: async function () {
      try {
        const reg = await getRegistration();
        if (!reg) return null;
        const sub = await reg.pushManager.getSubscription();
        if (!sub) return null;
        const endpoint = sub.endpoint;
        await sub.unsubscribe();
        return endpoint;
      } catch (_e) {
        return null;
      }
    },
  };
})();
