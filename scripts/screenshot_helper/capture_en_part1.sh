#!/bin/bash
# Switch to English
adb shell input tap 217 933
sleep 1
# Back to main
adb shell input keyevent 4
sleep 1
# Open drawer
adb shell input tap 84 201
sleep 1
# Select Codex (it's in the list, even if scrolled it should be visible since it was at 1401 when scrolled, and 1506 before. Let's just click 456 1506 assuming it's un-scrolled? Wait, no, drawer state might persist. Let's scroll up to top first)
adb shell input swipe 456 500 456 1500
sleep 1
adb shell input swipe 456 500 456 1500
sleep 1
# Now it's at the top.
# Codex should be at 456 1590 (from first dump [0,1506][912,1674])
adb shell input tap 456 1590
sleep 2

# Capture Codex Chat
adb shell screencap -p /sdcard/chat_en.png
adb pull /sdcard/chat_en.png docs/assets/screenshots/relay-mobile-chat-en.png
rm docs/assets/screenshots/relay-mobile-en.png

# Capture Bottom sheet
adb shell input tap 978 2138
sleep 1.5
adb shell screencap -p /sdcard/bottom_en.png
adb pull /sdcard/bottom_en.png docs/assets/screenshots/relay-mobile-bottom-en.png
adb shell input keyevent 4
sleep 1

# Open drawer
adb shell input tap 84 201
sleep 1

# Capture drawer
adb shell screencap -p /sdcard/drawer_en.png
adb pull /sdcard/drawer_en.png docs/assets/screenshots/relay-mobile-drawer-en.png

# Dump drawer UI to safely find English buttons
adb shell uiautomator dump /sdcard/drawer_en_dump.xml
adb pull /sdcard/drawer_en_dump.xml drawer_en_dump.xml
