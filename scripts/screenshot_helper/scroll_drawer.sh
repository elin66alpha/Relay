#!/bin/bash
adb shell input tap 84 201
sleep 1
adb shell input swipe 456 1500 456 500
sleep 1
adb shell uiautomator dump /sdcard/drawer2_dump.xml
adb pull /sdcard/drawer2_dump.xml drawer2_dump.xml
