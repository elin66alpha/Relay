---
title: Notifications
category: Usage and notifications
order: 830
summary: Task completion and quota reset alerts, and whether each platform gets them in the background or when closed.
keywords: notification, push, fcm, web push, alert, task finished
---

## Two alerts

Turn each on or off in **Settings → Notifications**:

| Switch | Alerts when |
|---|---|
| Task completion alerts | a turn finishes while **no device** is viewing that workspace; it shows the reply's first line |
| Quota reset alerts | a quota window resets |

## Platforms

| Platform | What works |
|---|---|
| Android, iOS, macOS, Windows | local notifications while the app is receiving live events |
| Web | browser notifications; with Web Push configured by the deployment, even after the tab closes |
| Android | with FCM configured by the deployment, even after the app is killed |
| Linux desktop | an in-app message only |

A fully closed iOS app has no offline push channel yet.

## Deployment setup

- Web Push: set `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT` in `server/.env`.
- FCM: set `FCM_SERVICE_ACCOUNT_FILE` and use an Android build configured with Firebase.

The service-account file and push tokens are deployment secrets; never commit them.
