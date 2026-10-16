# Yuyin Scribe（余音）隐私政策

**生效日期：** 2026 年 10 月 16 日

Yuyin Scribe（以下称「本应用」）是在 iPhone、iPad 和 Mac 上运行的语音转写工具。我们的原则是：**录音和文字留在你自己的设备上**。

## 我们不收集任何个人信息

- 开发者不运营任何服务器，不收集、不接收、不出售、不分享你的录音、转写、翻译或其他个人信息。
- 本应用没有账号，没有广告，没有统计分析或第三方跟踪 SDK。

## 在你设备上处理和保存的数据

录音、转写文字、翻译、说话人名字与声纹、热词和设置，都只保存在本应用在你设备上的存储空间里。语音识别、纠错、翻译、润色和说话人识别默认都在本机完成。删除一条记录即删除其录音和文字；删除本应用即删除全部数据。

## 本应用使用的权限

- **麦克风**：录音和实时转写。
- **语音识别**：使用系统的语音识别时，本应用要求只在设备上识别，不发送到苹果服务器。
- **本地网络**：仅在你选择「同一 Wi-Fi」时，用于把 iPhone 的录音直接交给你自己的 Mac 转写。
- **系统声音录制（Mac）**：仅在你选择录制系统声音、会议或指定应用时，用于转写其中的声音。

## 只有在你主动开启时，数据才会离开设备

1. **经 iCloud 交给 Mac 转写**：录音和转写先在设备上用每条录音单独的随机密钥加密，再存入**你自己的** iCloud 私有数据库；密钥保存在 CloudKit 的端到端加密字段中，开发者和苹果都无法读取内容。Mac 转写完成、手机取回结果后，iCloud 上的副本会被删除。
2. **同一 Wi-Fi 交给 Mac 转写**：录音在你配对过的设备之间直接加密传输，不经过任何服务器。
3. **云端识别与翻译**：只有当你自行填写阿里云百炼 API Key，并选择「混合」「纯云端」模式或云端翻译时，相应的音频片段或文字才会发送到阿里云百炼（DashScope）处理，并适用阿里云的隐私政策。不填写 API Key 时不会发生。

## 下载模型时的网络连接

首次使用或你手动下载识别模型时，本应用会从 Hugging Face（huggingface.co）、其镜像（hf-mirror.com）或 GitHub 下载模型文件。这些请求只用于下载文件，不包含你的录音或文字，但这些服务可能按其政策记录 IP 地址等访问日志。

## 儿童

本应用不面向 13 岁以下儿童，也不会有意收集儿童的信息。

## 变更与联系

本政策如有变更，会更新本页面并修改生效日期。如有疑问，请联系：newsmy7000@gmail.com

---

## Privacy Policy (English summary)

Yuyin Scribe transcribes speech on your own devices. The developer runs no servers and collects, receives, sells or shares no personal data; there are no accounts, ads, analytics or third-party trackers. Recordings, transcripts, translations, speaker names and voiceprints stay in the app's storage on your device, and deleting the app deletes them.

Data leaves your device only when you turn it on: (1) handing a recording to your Mac through **your own** iCloud private database, encrypted on the device with a per-recording key kept in CloudKit's end-to-end encrypted fields, and deleted from iCloud once the transcript is back; (2) handing it directly to your paired Mac on the local network, encrypted; (3) cloud recognition or translation through Alibaba Cloud Model Studio (DashScope), only after you enter your own API key and choose a cloud mode. Downloading speech models contacts Hugging Face, its mirror hf-mirror.com or GitHub for the model files only. The app is not directed at children under 13. Contact: newsmy7000@gmail.com
