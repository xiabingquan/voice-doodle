# Voice Doodle

🎙️ 极简的macOS 菜单栏语音输入工具。

## 功能特性

- 按住触发键说话，松开自动转写并插入到最前应用的光标处
- 双击触发并按住：本次识别完成后自动发送 Enter（用于终端等场景下快捷发送）
- 三家后端可切换：小米 MiMo ASR、火山引擎豆包 ASR、任意 OpenAI 兼容 网关 (e.g. OpenRouter)

## 系统要求

- macOS 13+ (Apple Silicon)
- 麦克风与辅助功能权限（首次启动向导内授权）
- 任一支持后端的 API Key

## 安装

从仓库 Release 页下载 **DMG**（如 `Voice-Doodle-v0.0.2.dmg`），打开后将 `Voice Doodle.app` 拖入旁边的 `Applications` 文件夹即可。

首次打开：右键点击 app → 「打开」→ 再点「打开」（macOS 对未公证应用的常规确认，仅需一次）。

## 快速开始

1. 启动后自动进入设置向导
2. 授权麦克风 + 辅助功能
3. 选择转录后端，填入 API Key（申请入口见下节）
4. 完成向导 → 菜单栏出现波形图标

## 基本用法

| 操作 | 效果 |
|---|---|
| 按住触发键（默认右 ⌥ Option） | 录音；松开后转写并插入光标处 |
| 双击触发并按住 | 识别完成后自动发送 Enter |

触发键可在仪表盘「触发键」区重新录制（单键或组合键）。

## API Key 申请

### 小米 MiMo ASR（推荐）

1. 打开 MiMo 开放平台控制台：<https://platform.xiaomimimo.com>
2. 登录后进入 控制台 → API Keys，创建 API Key
3. 接入文档：<https://mimo.mi.com/docs/zh-CN/quick-start/summary/first-api-call>
4. 将 Key 填入仪表盘（或 config.json 的 `asr.mimo.apiKey`）

### 火山引擎 · 豆包 ASR

1. 打开豆包语音控制台：<https://console.volcengine.com/speech/app>
2. 创建应用，开通大模型语音识别服务（本应用使用资源 ID `volc.seedasr.sauc.duration`）
3. 在 API Key 管理 中新建 API Key（新版控制台仅需 `X-Api-Key` 鉴权）
4. 官方文档：<https://www.volcengine.com/docs/6561/1816214>
5. 将 Key 填入仪表盘（或 config.json 的 `asr.doubao.apiKey`）

### OpenAI 兼容网关

任意提供 `/audio/transcriptions` 的服务（OpenAI、OpenRouter、Groq 等）：在 config.json 的 `asr.openaiCompatible` 中填写 `baseURL`、`apiKey`、`model`。

## License

本项目采用 **MIT License**（见 [LICENSE](LICENSE)）。

内置的 [TEN VAD](voice-doodle/Vendor/)（Agora/TEN Framework）依其自带许可分发：Apache-2.0 + 附加条款，详见 `voice-doodle/Vendor/TEN_VAD_LICENSE`。
