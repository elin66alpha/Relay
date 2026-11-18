---
title: Wallpaper
category: App settings
order: 920
summary: Set one device-local wallpaper for chat and adjust its opacity, acrylic blur and tint.
keywords: wallpaper, background, acrylic, blur, opacity, tint
---

**Settings → Wallpaper** sets one background image for every solo chat, Swarm and the home page. It is stored only on this device, independent of machine, workspace and session.

## Editing

| Setting | Range | Default |
|---|---|---|
| Image opacity | saved separately for the current theme | 80% light, 20% dark |
| Acrylic blur | 0–30, shared by both themes | 6 |
| Acrylic tint | 0–100%, shared by both themes | 55% |

The preview updates as you drag or type and stays pinned at the top, so it remains visible with the keyboard open. Nothing applies until you select **Save**; leaving without saving keeps the old settings. **Remove wallpaper** then Save restores solid surfaces.

## Supported images

JPG, PNG and WebP.

- Android, iOS and desktop keep the original, with no size limit, and decode only the pixels the screen needs.
- The Web accepts up to 20 MB / 40 MP and stores a JPEG copy with a long edge of at most 1920 pixels and at most 256 KiB in the browser; clearing site data removes it.

The image is never uploaded to the backend.

## How it looks

On Home, solo chat and Swarms, headers, the drawer, the composer and message bubbles become translucent acrylic; other pages, such as the file browser, Quota usage and Settings, show the wallpaper blurred. Text and controls follow your theme.
