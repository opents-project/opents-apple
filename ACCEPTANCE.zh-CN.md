# OpenTS 功能验收

2026-11-24。Apple 构建覆盖 Apple Silicon macOS 和 arm64 iOS 模拟器。构建成功、客户端自身测试、与官方 TS3 客户端互通分别记录。缺少双端观察或涉及真实音频设备时，保留待验状态。

| 功能 | 实现 | Apple 构建 | 已完成的测试 | 与官方 TS3 客户端对照或互通 |
| --- | --- | --- | --- | --- |
| 域名和服务器昵称 | 已实现 | 通过 | 两种入口均连接同一服务器 UID | 官方客户端事件栏显示测试身份进入和退出 |
| 频道树、详情、成员 | 已实现 | 通过 | Mac 原生窗口选择频道并读取成员及属性 | 与官方客户端截图中的顺序、编码、频道类型和人数对照通过 |
| 频道列表人数 | 每行显示该频道可见人数，未订阅用横线表示未知 | 通过 | rbq 独立身份在另一频道读到 📦 有 1 人，另有 29 个已订阅空频道 | 远端移动后的实时对照待验 |
| 加入频道 | 已实现 | 通过 | rbq 拒绝测试身份加入训练房并返回权限编号 139，确认仍在原频道；重启后用户截图确认中文弹窗保留编号 | 成功移动及密码频道待验 |
| Opus Voice 收发 | 已接入 | 通过 | 本机 48 kHz 单声道测试信号经 Opus 编码、语音包封装、接收端解码和双声道混音，输出频率与能量通过断言 | 同频道双向听音待验 |
| Voice → Music → Voice | 按确认的频道用单声道 Opus Voice 或立体声 Opus Music 编码；单声道输入在 Music 中复制到左右声道 | 通过 | 左 500 Hz、右 1500 Hz 的合成 PCM 编码后解码，验证声道数与频率分离。模拟两种确认顺序、权限拒绝、超时、迟到回执及旧帧丢弃；Swift 测试验证半帧与阈值尾音隔离 | 官方客户端双向通话、真实立体声输入及 iOS 真机待验 |
| 按键说话 | 已实现窗口内按住发送、释放停止 | 通过 | 麦克风关闭时按住不会进入讲话状态 | 真实麦克风、首尾音节、远端发言指示待验；远端实际收到后台快捷键发言待验 |
| macOS 全局按键说话 | 可在音频菜单启用 ⌥⇧空格 | 通过 | 后台测试进程收到系统按下和释放；验证冲突、注销、过期事件丢弃和重新注册 | 实际通话待验 |
| 本地书签 | 添加、修改、删除及回填连接表单 | 通过 | 独立偏好域跨三个进程验证多条书签写入、修改和读取；窗口自动化超时 | Mac 和 iOS 交互待验 |
| 阈值语音激活 | 可调阈值、实时电平、240 ms 尾音 | 通过 | 合成 PCM 实测低于阈值不发送、超阈值发送、尾音后关闭、调节及静音 | 真实人声和官方客户端双向听音待验 |
| 输出与静音 | 已接入 AVAudioEngine | 通过 | Mac 默认输出引擎启动、静音、恢复通过；硬件可用和用户静音独立上报；解码队列静音后输出为零 | 菜单操作、官方客户端静音标记待验 |
| 逐用户播放控制 | 展开其他成员，可调音量 0–200%、左右声像、本地静音与复位；默认 100% 居中 | 通过 | 合成双声道 PCM 验证居中不变、左右和增益；两路合成 Opus 验证静音不改变另一人的样本、限幅、重连/切服后旧音频与设置隔离 | 真实多人通话、耳机听感、界面操作和 iOS 真机待验 |
| 回声消除和降噪 | 优先启用 Apple Voice Processing，失败时重试普通输入，再失败时恢复播放 | 通过 | Mac 界面实测回退后出现按住说话控件 | 外放回声、双讲和环境噪声对照待验 |
| macOS 语音设备选择 | 输入和输出分别跟随系统或保存指定设备 UID；菜单并列显示首选项和引擎实际设备；设备不可用时用默认路由，重插可恢复。iOS 使用系统路由 | 通过 | 模拟设备覆盖独立选择、偏好恢复、设备编号变化、拔插、默认设备变化、枚举失败、绑定或启动失败及实际设备不匹配；采集关闭时只绑定输出 | 真机插拔、蓝牙双工、语音处理回退、提示音输出与官方客户端双向听音待验 |
| 临时断线及反馈 | 连接超时、重连状态、服务器拒绝及设备错误已接入 | 通过 | 虚拟时钟验证 35 秒恢复期限及主动断开优先；独立音频句柄测试验证旧队列和延迟采集无法跨连接发送；频道权限拒绝已验。真实断网后重连待验 | 待验 |
| 本机身份持久化 | 钥匙串保存 TS3 私钥并显示公开 UID | 通过 | 两个独立进程通过 rbq 重连，复用同一测试条目，UID 相同 | 管理员组跨重启待验 |
| 当前频道定位 | 服务器确认后展开祖先、选中并滚动到频道 | 通过 | macOS 连接后实际选中接客厅；三级频道路径通过本地断言 | 真实服务器移动到折叠子频道待验 |
| 频道提示音 | 连接、断开、切换频道、同频道成员进入和离开 | 通过 | 五段音效在 Mac 播放时间均前进；两个测试客户端在 rbq 进出同频道，观察端正确识别进入和离开 | iOS 设备播放待验 |
| 简体中文和英语 | 界面、菜单、应用错误、麦克风用途描述 | 通过 | 两个平台构建产物中的中英文资源逐条核对；macOS 中文界面实测 | iOS 界面待验 |
| 频道与服务器文字聊天 | 会话内收发，按服务器或当前频道 ID 隔离，确认后显示己方消息；失败保留草稿 | 通过 | Rust 模拟消息覆盖目标范围、切换频道、回显去重和拒绝；Swift 离线状态测试覆盖范围过滤、错误显示状态和草稿保留 | 官方客户端、真实收发、窗口和手机交互待验 |
| 群组列表与有效权限（离线预览） | 服务器组与频道组分别列出；按客户端数据库 ID、频道 ID 展示有效值和五类赋值来源 | 通过 | 同 ID 不同类群组、已知/未知有效值、负值、skip/negate、空响应、权限不足、读取失败分别验证 | 使用模拟数据；真实读取、权限解析规则及界面交互待验 |
| 服务器日志（Debug 离线预览） | 模拟数据分批加载、显示空结果、拒绝和失败，可重试；切换模拟服务器或断开时清空 | 通过 | Swift 离线断言覆盖 3/3/1 分页、末页、连续点击、重复回包、重叠记录、游标停滞、同游标重试和旧连接回包 | 管理日志协议尚未接入；真实服务器、日志轮转和设备界面待验 |
| 文件浏览和传输状态（Debug 离线预览） | 合成目录，模拟上传、下载、进度、取消、拒绝及失败 | 通过 | 离线测试覆盖路径规范化、拒绝含上级跳转的路径、根目录边界、空目录、禁止和失败状态、终态后回调、重连及切服清理 | 真实目录访问权限、服务器配额、字节收发、断点续传和内容完整性待验 |
| 私聊、群组权限编辑和服务器管理 | 见实施计划 | 待实现 | 待验 | 待验 |

语音回环可在 core 目录执行 `cargo test --locked --lib`。测试把客户端语音负载装进本地模拟的服务端转发包，不读取麦克风。另行验证实际通话时，应分别记录发送端、接收端、系统、设备、频道编码，以及两个方向的结果。

桌面基线及各项缺口见 [TS3 客户端差异表](TS3-GAPS.zh-CN.md)。

文字聊天离线检查：在 core 目录运行 `cargo test --locked --lib`。生成 Apple 绑定后，在仓库根目录运行 `swiftc -I build/headers -L core/target/debug -lopents_core Apple/Generated/opents_core.swift Apple/ChatState.swift tests/ChatStateCheck.swift -o /tmp/opents-chat-check && /tmp/opents-chat-check`。

离线权限检查：生成 Apple 绑定后运行 `swiftc -D DEBUG -I build/headers -L core/target/debug -lopents_core Apple/Generated/opents_core.swift Apple/PermissionsState.swift tests/PermissionsStateCheck.swift -o /tmp/opents-permissions-check && /tmp/opents-permissions-check`。Debug 连接页的「离线权限预览」只展示模拟响应。

日志离线检查：在仓库根目录运行 `swiftc -D DEBUG Apple/ServerLog.swift tests/ServerLogCheck.swift -o /tmp/opents-serverlog-check && /tmp/opents-serverlog-check`。该检查只使用进程内的模拟响应。

文件离线检查：运行 `swiftc -D DEBUG Apple/OfflineFiles.swift tests/OfflineFilesCheck.swift -o /tmp/opents-files-check && /tmp/opents-files-check`。模拟路径以频道根目录为起点，目录项、进度与错误均来自内存。

Apple 采集切换离线检查可在生成绑定后运行 `swiftc -I build/headers -L core/target/debug -lopents_core Apple/Generated/opents_core.swift Apple/TalkHotKey.swift Apple/MacAudioDevices.swift Apple/VoiceAudio.swift tests/ChannelCaptureCheck.swift -o /tmp/opents-channel-capture-check && /tmp/opents-channel-capture-check`。

macOS 设备选择离线检查可运行 `swiftc Apple/MacAudioDevices.swift tests/MacAudioDevicesCheck.swift -o /tmp/opents-device-selection && /tmp/opents-device-selection`。该检查使用合成设备和独立的临时偏好域。
