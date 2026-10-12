# Yuyin iOS / macOS 中文转写客户端 — 设计文档

**日期：** 2026-10-11  
**状态：** 已对齐（路线 1；场景 C；模式用户可选；分发先自用再上架）

---

## 1. 目标与约束

### 1.1 产品目标

做一款 **iOS + macOS** 原生客户端：麦克风/文件 → **实时字幕上屏** → **句末（或整段）高精度纠错** → 导出笔记。

用户可在设置中选择：

| 模式 | Streaming（实时） | Corrector（纠错） |
|------|-------------------|-------------------|
| 纯离线 | 本机流式 | 本机离线模型 |
| 混合 | 本机流式 | 优先云端高精度；无网降级本机 |
| 纯云端 | 云 WebSocket 流式 | 云二遍 / 文件识别 |

### 1.2 分发策略

1. **一期：** 自用 / TestFlight / 直接安装；允许较大模型按需下载  
2. **二期：** 收敛体积、隐私文案、按需下载，准备 App Store  

### 1.3 非目标（YAGNI）

- 不做多人说话人分离（diarization）一期  
- 不做实时翻译  
- 不做 Android / Web  
- 一期不上 FireRed 级大模型（留 Mac 二期可选）

---

## 2. 架构总览（路线 1）

原生 **SwiftUI 双端 + 引擎插件**：

```
Apps/Yuyin (SwiftUI iOS+macOS)
        │
        ▼
 Packages/YuyinCore
   Capture · Session · 2-pass Orchestrator · Export
        │
   ┌────┴────┐
   ▼         ▼
YuyinLocal  YuyinCloud
 sherpa-onnx  FunASR / Doubao Providers
```

### 2.1 模块职责

1. **Capture** — 麦克风 / 导入文件；输出 16 kHz mono PCM  
2. **StreamingASR** — 低延迟 partial  
3. **Endpointing** — VAD / 静音判句  
4. **CorrectorASR** — 句级或段级高精度 final  
5. **SessionStore** — 时间轴与持久化  
6. **Providers** — `LocalSherpa` / `CloudFunASR` / `CloudDoubao`  
7. **Export** — txt / SRT / 带时间戳 Markdown  

### 2.2 为何不选其他路线

- **Mac 本地 FunASR 服务 + iOS 连接：** iPhone 离线弱，分发像挂服务器  
- **云端为主 + 系统 Speech：** 离线差，中文准度弱于国产引擎  

---

## 3. 技术栈

| 层 | 选型 |
|----|------|
| UI | SwiftUI，iOS 17+ / macOS 14+ |
| 语言 | Swift 5.10+ |
| 共享 | Swift Package `YuyinCore` |
| 音频 | `AVAudioEngine`；文件 `AVAssetReader` / `ExtAudioFile` |
| 本地 ASR | **sherpa-onnx** XCFramework |
| 云端 | URLSession WebSocket；Provider 插件 |
| 存储 | GRDB (SQLite) |
| 密钥 | Keychain |
| 模型文件 | Application Support，按需下载 + checksum |

### 3.1 一期模型

| 角色 | 模型 | 量级 | 用途 |
|------|------|------|------|
| 流式 | Streaming Paraformer zh-en (sherpa-onnx) | ~200MB | partial |
| 纠错 | SenseVoice-Small 或 Paraformer-offline | ~250–500MB | final |
| VAD | silero / fsmn（随 sherpa） | 小 | 判句 |

### 3.2 二期增强（Mac）

- 可选下载 **FireRedASR2-AED** 作为 Corrector「最高精度」档  
- iPhone 仍以 SenseVoice / Paraformer 为主（体积与算力）

### 3.3 云 Provider（一期至少接 1 家完整）

- 优先：**阿里 Fun-ASR-Realtime**（流式）+ 对应文件/句级纠错 API  
- 备选骨架：**火山豆包**（双向流式 + `enable_nonstream` 二遍）  
- 抽象接口统一，避免 UI 绑死某一家协议  

---

## 4. 仓库结构

```
yuyin/
  Apps/Yuyin/                 # SwiftUI App（iOS + macOS targets）
  Packages/YuyinCore/         # Capture, Orchestrator, Session, Export
  Packages/YuyinLocal/        # sherpa-onnx 封装
  Packages/YuyinCloud/        # FunASR / Doubao Provider
  Models/                     # 下载脚本与 checksum（模型不进 git）
  docs/plans/                 # 设计与实现计划
```

---

## 5. 2-pass 数据流与状态机

### 5.1 实时主链路

```
Mic/File PCM 16k
  → AudioTap（环形缓冲）
  → StreamingASR.partial     → UI 灰字字幕
  → VAD / 静音超时（600–800ms）判句结束
  → 取出该句 PCM + partial
  → CorrectorASR.final       → UI 黑字最终句
  → SessionStore.append(Utterance)
```

文件转写：跳过 Streaming（或显示假进度），直接 Corrector 整段/分片。

### 5.2 逻辑模型

```text
Utterance {
  id, startMs, endMs,
  partial, final,
  status: partial | pendingCorrection | final | failed,
  provider
}
```

UI：`pendingCorrection` 显示 partial；`final` 覆盖；`failed` 保留 partial 并标记「未纠错」。

### 5.3 会话状态机

```text
idle → preparing → listening ⇄ pausing → stopping → idle
```

- 纠错在 `listening` 内异步执行，不阻塞采集  
- `CorrectionQueue` **串行**（一次一句），避免 NPU/GPU 抢占  

### 5.4 线程模型

| 线程 | 职责 |
|------|------|
| Audio realtime | 只推 PCM |
| ASR worker | sherpa streaming accept/decode |
| Correction queue | 离线/云纠错 |
| Main/UI | 订阅 `AsyncStream<TranscriptEvent>` |

### 5.5 模式切换与降级

- 切换 Provider：当前句结束后再生效  
- **混合**无网：Corrector 降级本地，横幅提示一次  
- **云端**断线：暂停 Streaming 并提示重连；已 final 不回滚  

### 5.6 延迟目标（一期）

- 首字 partial：&lt; 300–500ms（本机流式）  
- 句末 final：静音后 + 纠错（本机目标 &lt; 1–2s/句）  

---

## 6. 错误处理

| 场景 | 行为 |
|------|------|
| 麦克风拒绝 | 引导系统设置；会话不进入 listening |
| 模型未下载 / 损坏 | preparing 失败；引导重新下载；校验 checksum |
| 本机 OOM / 推理失败 | 该句 `failed`，保留 partial；可「重试纠错」 |
| 云 401/403 | 提示检查 API Key；不自动清空已写文本 |
| 云超时 | 重试 1 次 → 混合模式降级本地；纯云端标 failed |
| 音频中断（来电等） | 自动 pause；恢复后询问继续/结束 |
| 磁盘满 | 停止写入录音缓冲；提示清理 |

日志：本地 os_log + 可选导出诊断包（不含云密钥）。

---

## 7. 权限与平台差异

### 7.1 共用

- `NSMicrophoneUsageDescription`  
- 网络（云模式）：ATS 仅访问配置的 API 域名  

### 7.2 iOS

- 后台：一期 **前台会话为主**；若需锁屏续录，再申请 audio background mode（上架需说清用途）  
- 耳机 / 蓝牙路由变更时重建 AVAudioSession  

### 7.3 macOS

- 麦克风权限同系统 TCC  
- 系统音频内录（如黑胶/会议对面声音）**不做一期**；二期再评估 ScreenCaptureKit  

---

## 8. 测试策略

| 层级 | 内容 |
|------|------|
| 单元 | VAD 判句边界、Utterance 状态迁移、模式降级逻辑 |
| 契约 | Provider mock：partial/final 事件顺序 |
| 集成 | 固定 wav 金标集 → micro-CER（中文 normalize 后） |
| 手工 | 三种模式切换、断网、来电中断、长会话 30min+ |

金标集建议自备：安静朗读、会议噪声、中英混、专有名词各 3–5 分钟。

---

## 9. 上架收敛（M4 清单）

- 模型默认不打进 ipa；首次按需下载 + 可删  
- 隐私清单：麦克风、网络、用户音频是否出设备（按模式动态说明）  
- 无「隐藏」云上传；混合/云端明确开关与状态条  
- 体积：主包 &lt; App Store 合理范围；大模型外置  
- 审核备注：说明本地推理与可选云 Provider  

---

## 10. 分期里程碑

| 里程碑 | 交付 |
|--------|------|
| **M1** | Mac：本机流式字幕 + 句末本机纠错 + 导出 txt |
| **M2** | 三模式切换 + 一家云 Provider + Keychain |
| **M3** | iOS 同构 + 模型按需下载 UI + 中断/降级打磨 |
| **M4** | Mac 可选 FireRed 纠错；上架清单收敛 |

---

## 11. 已确认决策摘要

1. 场景：**实时 + 句末高精度纠错（2-pass）**  
2. 网络策略：**用户可选** 离线 / 混合 / 云端  
3. 分发：**先自用可用，再收敛上架**  
4. 实现路线：**Swift 双端 + sherpa-onnx 本地 + 云 Provider 插件**  

---

## 12. 下一步

设计已对齐。后续可写实现计划（`writing-plans`）并按 M1 开工：Xcode 工程骨架 → sherpa 流式 → VAD 判句 → 离线纠错 → 导出。
