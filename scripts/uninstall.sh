#!/bin/bash
# Voice Doodle explicit uninstall: removes the app bundle, all local user
# data, system TCC permission records, and the cleanup launch agent in one
# pass. Run by double-click or from a terminal.
set -u

BUNDLE_ID="com.xiabingquan.voice-doodle"
APP="$HOME/Library/Applications/voice-doodle.app"
DATA="$HOME/Library/Application Support/Voice Doodle"
PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
LEGACY="$HOME/Library/Containers/$BUNDLE_ID"
AGENT_LABEL="$BUNDLE_ID.cleanup-agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_SCRIPT_DIR="$HOME/Library/Application Scripts/$BUNDLE_ID"

echo "==> 退出 Voice Doodle…"
osascript -e 'tell application "voice-doodle" to quit' 2>/dev/null
sleep 2

echo "==> 清除系统权限记录（麦克风/辅助功能等）…"
/usr/bin/tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1

echo "==> 卸载清理守护 agent…"
/bin/launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1
rm -rf "$AGENT_PLIST" "$AGENT_SCRIPT_DIR"

echo "==> 删除 app 与全部本地数据…"
rm -rf "$APP" "$DATA" "$PREFS" "$LEGACY"

echo "卸载完成：app、用户数据、权限记录与守护 agent 均已删除。"
