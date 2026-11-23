# OpenTS 原生客户端实施计划

## 基线与架构

以 TeamSpeak 3 桌面客户端 3.6.2 的用户可见功能为覆盖目标，以原版自建服务器和官方客户端为互通基准。目标平台为 macOS、iOS 和 Android，首期优先开发 Apple 两端。macOS 与 iOS 共用一个仓库，分别提供原生 SwiftUI 应用。参照 Scrctl 的 Rust → UniFFI → XCFramework → Swift 会话适配层。Rust 持有协议连接、身份、编解码、每个发言者的语音流和管理命令。Swift 共享会话模型、频道树和 Apple 音频引擎，各平台管理自己的输入设备、系统中断、后台生命周期和界面。高频 PCM 通过缓冲区与音频线程交接，控制事件走 UniFFI。

Android 客户端规划独立仓库，使用 Kotlin 和 Jetpack Compose。将共享 Rust 核心作为可独立版本化的 Cargo 包，Apple 和 Android 工程固定引用其版本或提交，通过 UniFFI 分别生成 Swift 和 Kotlin 接口。麦克风采集、播放、音频路由和系统语音处理由各平台接入。

## 调查记录

2026-11-24 检查 tsclientlib ee3bc6f 和该版本锁定的 tsdeclarations 83cb8a9。上游 audio 示例实现麦克风发送和频道语音播放，包含固定的示例身份，产品需为用户生成或导入独立身份。

| 用户操作 | 上游源码证据 | 首轮验证 |
| --- | --- | --- |
| 编辑服务器组及成员 | ServerGroupAdd、ServerGroupCopy、ServerGroupAddClient 和对应查询消息 | 建临时组、复制、改名、增删成员、重连后复查、清理 |
| 编辑服务器组和频道组权限 | ServerGroupAddPerm 含 value、negated、skip，ChannelGroupAddPerm 单独建模 | 两种组分别写入、读回、删除；对照官方客户端；验证无授权身份收到拒绝 |
| 查询有效权限 | PermOverviewRequest、PermOverview、PermList | 对照指定用户在指定频道上的权限来源和结果，覆盖 grant、skip、negate |
| 查看服务器日志 | LogView 请求和 ServerLog 回包，BookToMessages 映射行数、顺序、实例标志和偏移；响应含 last_pos、file_size、log | 普通客户端会话读取虚拟服务器日志，翻页、刷新、空结果、权限不足及日志轮转；单独核实实例日志权限 |

当前建议采用 tsclientlib 作为共享协议核心的基础。已确认的兼容缺口是内置音频接收队列只接受 Opus Voice 和 Opus Music，Speex 和 CELT 在此路径返回 UnsupportedCodec。若要覆盖使用旧编码的频道，需要补相应的编解码并与官方客户端验证。上游另有连接超时后重连逻辑和文件上传下载入口。

以上为源码覆盖证据。每项另行登记共享核心的真实服务器往返结果，以及 macOS、iOS、Android 各自的构建和用户界面验收结果。

## 实施顺序及交付条件

1. 建立 3.6.2 功能清单。按主菜单、右键菜单、设置、快捷键以及连接前后界面逐项记录。用管理员和普通成员身份补齐权限相关入口。覆盖身份和书签迁移、多服务器、频道、聊天、离线消息、联系人、语音激活、按键说话、密语、3D 音频、录音、文件、群组权限、封禁、投诉、权限密钥、服务器设置及日志。对插件、ClientQuery、覆盖层、主题和 myTeamSpeak 服务逐项调查依赖及三个平台的可实现程度。每项记录上游支持层级、缺口和验收操作。
2. 建 Apple 双目标最小项目，锁定 Rust 依赖，编译 macOS、iOS 模拟器和 iPhone 真机目标。连接个人测试服务器，与官方客户端同频道双向通话。同时做群组权限修改读回和服务器日志分页原型。若高层接口不足，先使用类型化协议消息，随后按实际缺口补库。
3. 集成 AVAudioEngine Voice Processing，将远端解码音频接入同一引擎供回声抵消使用。iOS 配置 AVAudioSession 的 playAndRecord 和 voiceChat，macOS 接入输入输出设备选择。对比处理开关，分别测扬声器回声、键盘风扇噪声、其他应用外放、人声保真、双讲和端到端延迟。测试蓝牙切换、静音、按键说话首音节、锁屏、系统中断恢复。分开记录其他应用内录音轨与扬声器被麦克风拾取的情况。
4. 完成日常客户端，交付身份和书签、频道树、跨频道移动、多服务器、聊天、密语、音频配置和重连；在 macOS 和 iOS 各完成一次实际通话流程。
5. 完成管理和文件功能。覆盖五类权限作用域、成员管理、服务器与频道设置、日志、封禁、投诉、权限密钥以及上传下载。用两种授权级别与官方客户端交叉验证。
6. 在 Apple 首轮互通验证完成后启动 Android 分仓开发，可与 Apple 后续功能并行。先在 Android 真机上完成与官方客户端的双向语音、群组权限修改读回和日志分页，再按同一份功能清单补齐日常操作、管理及文件功能。单独验证蓝牙切换、音频焦点、后台通话和麦克风恢复。
7. 收尾高级功能与平台差异。为录音、3D 音频、扩展、同步服务及步骤 1 发现的其他条目补实现和验收。按平台发布兼容性清单，注明验证过的服务器版本、设备及尚缺项目。

## 调查依据

- [tsclientlib 音频示例](https://github.com/ReSpeak/tsclientlib/blob/ee3bc6f/tsclientlib/examples/audio.rs)
- [锁定版本的协议消息声明](https://github.com/ReSpeak/tsdeclarations/blob/83cb8a9/Messages.toml)
- [服务器日志请求映射](https://github.com/ReSpeak/tsdeclarations/blob/83cb8a9/BookToMessages.toml#L352)
- [TeamSpeak 官方插件 API](https://github.com/teamspeak/ts3client-pluginsdk/blob/master/include/ts3_functions.h)
- [Apple 双向语音会话](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat)
- [Apple Voice I/O](https://developer.apple.com/documentation/AudioToolbox/audio-unit-voice-i-o)
