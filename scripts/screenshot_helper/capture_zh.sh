#!/bin/bash
# 1. Credentials
adb shell input tap 456 654
sleep 1.5
adb shell screencap -p /sdcard/setup.png
adb pull /sdcard/setup.png docs/assets/screenshots/relay-mobile-setup-zh.png
adb shell input keyevent 4
sleep 1

# Open drawer
adb shell input tap 84 201
sleep 1

# 2. 定时消息
adb shell input tap 456 990
sleep 1.5
adb shell screencap -p /sdcard/quota.png
adb pull /sdcard/quota.png docs/assets/screenshots/relay-mobile-quota-zh.png
adb shell input keyevent 4
sleep 1

# Open drawer
adb shell input tap 84 201
sleep 1

# 3. 文件系统
adb shell input tap 456 2004
sleep 1.5
adb shell screencap -p /sdcard/fs.png
adb pull /sdcard/fs.png docs/assets/screenshots/relay-mobile-fs-zh.png
adb shell input keyevent 4
sleep 1

# Open drawer
adb shell input tap 84 201
sleep 1

# 4. 卡片模式
adb shell input tap 456 1903
sleep 1.5
adb shell screencap -p /sdcard/cards.png
adb pull /sdcard/cards.png docs/assets/screenshots/relay-mobile-cards-zh.png
adb shell input keyevent 4
sleep 1

# 5. 主聊天底部界面
adb shell input tap 978 2138
sleep 1.5
adb shell screencap -p /sdcard/bottom.png
adb pull /sdcard/bottom.png docs/assets/screenshots/relay-mobile-bottom-zh.png
adb shell input keyevent 4
sleep 1

