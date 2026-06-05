#!/bin/bash
# 1. Credentials
adb shell input tap 456 654
sleep 1.5
adb shell screencap -p /sdcard/setup_en.png
adb pull /sdcard/setup_en.png docs/assets/screenshots/relay-mobile-setup-en.png
adb shell input keyevent 4
sleep 1

# Open drawer
adb shell input tap 84 201
sleep 1

# 2. Scheduled messages (Quota/Timer)
adb shell input tap 456 990
sleep 1.5
adb shell screencap -p /sdcard/quota_en.png
adb pull /sdcard/quota_en.png docs/assets/screenshots/relay-mobile-quota-en.png
adb shell input keyevent 4
sleep 1

# Open drawer
adb shell input tap 84 201
sleep 1

# 3. File System
adb shell input tap 456 2004
sleep 1.5
adb shell screencap -p /sdcard/fs_en.png
adb pull /sdcard/fs_en.png docs/assets/screenshots/relay-mobile-fs-en.png
adb shell input keyevent 4
sleep 1

# Open drawer
adb shell input tap 84 201
sleep 1

# 4. Card mode
adb shell input tap 456 1903
sleep 1.5
adb shell screencap -p /sdcard/cards_en.png
adb pull /sdcard/cards_en.png docs/assets/screenshots/relay-mobile-cards-en.png
adb shell input keyevent 4
sleep 1

