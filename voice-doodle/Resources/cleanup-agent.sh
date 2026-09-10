#!/bin/bash
# 卸载数据清理守护（方案 2026-09-10 用户批准）。
# 由 launchd WatchPaths 监听 ~/Library/Applications 唤醒；bundle 持续消失
# ≥ THRESHOLD 秒判定为卸载 → 清用户数据 + TCC + agent 自删。
# 安全核心：先查 bundle 存在性——存在（更新流中重现）无条件放行。
set -u

APP="$HOME/Library/Applications/Voice Doodle.app"
DATA="$HOME/Library/Application Support/Voice Doodle"
PLIST="$HOME/Library/Preferences/com.xiabingquan.voice-doodle.plist"
LEGACY="$HOME/Library/Containers/com.xiabingquan.voice-doodle"
AGENT_LABEL="com.xiabingquan.voice-doodle.cleanup-agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
STATE="$DATA/.agent-uninstall-since"
THRESHOLD=60

LOG() { /usr/bin/logger -t vd-cleanup-agent "$*"; }

if [ -e "$APP" ]; then
  rm -f "$STATE"
  exit 0
fi

now=$(date +%s)
if [ ! -f "$STATE" ]; then
  mkdir -p "$DATA"
  echo "$now" > "$STATE"
  LOG "app bundle missing; uninstall timer started"
  exit 0
fi

since=$(cat "$STATE" 2>/dev/null || echo "$now")
if [ $((now - since)) -lt "$THRESHOLD" ]; then
  exit 0
fi

LOG "uninstall confirmed (missing >= ${THRESHOLD}s); purging user data"
rm -rf "$DATA" "$PLIST" "$LEGACY"
/usr/bin/tccutil reset All com.xiabingquan.voice-doodle >/dev/null 2>&1
/bin/launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1
rm -f "$AGENT_PLIST"
rm -f -- "$0"
LOG "cleanup complete; agent removed"
