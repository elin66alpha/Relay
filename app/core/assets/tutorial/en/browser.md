---
title: Browser
category: Machine and tools
order: 740
summary: View and operate pages on the backend machine's localhost from anywhere, with no port forwarding.
keywords: browser, localhost, 127.0.0.1, chrome, port, preview, dashboard, web page
---

**Browser**, at the bottom of the drawer, opens pages served on **the backend machine's own localhost**, such as a dashboard an agent is building, even from outside the backend's LAN or Tailscale network.

## How it works

The backend renders the page in a headless Chrome, Chromium or Edge and streams it to the app as JPEG frames; your taps, drags, sliders, scrolling and typing go back as input. Nothing is port forwarded, so the page's absolute paths, API calls and hot reload behave exactly as on the host.

## The address bar

Enter `3000`, `3000/admin`, `localhost:5173`, `127.0.0.1:8080`, or a full `http(s)://` URL. Only loopback hosts are allowed (`localhost`, `*.localhost`, `127.0.0.0/8`, `[::1]`). Links and redirects inside the page are not restricted, so third-party sign-in and CDN assets still load.

## Fits the device

The page is the size of the picture in the app. Android and iOS (including mobile Web) get the page's mobile layout and touch events; desktops and desktop Web get the desktop layout and mouse events. A horizontal drag never navigates back; use the back button.

## Typing on a phone

The keyboard button opens an input bar: text typed there (with any input method) is inserted into the focused field on the page, and its buttons send Backspace and Enter.

## Dialogs

A page's `alert`, `confirm` or `prompt` is accepted at once and its text shown in the app, because an unanswered dialog would freeze the page.

## Sessions

- One browser with one tab per device token.
- Leaving keeps it for 10 minutes, so coming back shows the same page; opening it on another device takes it over.
- Each browser uses a fresh temporary profile deleted when it closes, so sign-ins inside the page do not persist.
- No sound, no file upload or download, no clipboard.

## Links that open a new tab

New tabs pointing to localhost or another loopback address open in the streamed tab on the backend. For other HTTP or HTTPS addresses, Relay shows the full URL and asks before opening it in your device’s browser.

## Info button

The **i** button at the top right summarizes what this browser can and cannot do.

## No browser found

The backend looks for Chrome, Chromium or Edge in their standard locations (on Linux, also on PATH and `/snap/bin/chromium`). Set `RELAY_BROWSER` in `server/.env` to an executable path to choose one.

Setup checks for one after installing the server dependencies (step 1). If none is found it shows how to install one and carries on, since everything else works without it. A browser installed later is found without restarting Relay.
