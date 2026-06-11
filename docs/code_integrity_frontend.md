# 前端代码审查记录 (Frontend Code Integrity)

> 本文档记录对 `lib/` Flutter 前端（约 11200 行 Dart）的一次完整人工审查发现的问题，
> 涵盖**全局卡死/卡顿、性能优化、安全、复用性/简洁性**四类。
> 每条标注了文件位置、问题描述与建议的修复方向，供后续逐条解决。
> 与后端审查记录 `code_integrity.md` 配套。
>
> 审查日期：2026-06-10 ·
> 状态图例：⬜ 待处理 / 🔧 进行中 / ✅ 已解决

---

## 优先级总览

| 优先级 | 事项 | 编号 | 状态 |
|---|---|---|---|
| 🔴 高 | PBKDF2 60 万次迭代在 UI isolate 上跑，导入凭据时全 app 冻结数秒至数十秒 | F-1 | ⬜ |
| 🔴 高 | 共享 SSE 事件流静默断链无检测，跨设备镜像与 quota 通知永久停摆 | F-2 | ⬜ |
| 🟠 中 | 流式 delta O(n²) 字符串拼接 + 每个 delta 全表扫描 | F-3 | ⬜ |
| 🟠 中 | 远端镜像轮询每 2s 在 UI isolate 全量解码会话 JSON | F-4 | ⬜ |
| 🟠 中 | 文件浏览器一次性构建目录全部条目，大目录秒级卡死 | F-5 | ⬜ |
| 🟠 中 | 每个 API 请求 3 次 secure-storage/prefs 读 + 凭据 JSON 全量解码 | P-1 | ⬜ |
| 🟠 中 | CardsService 复制 BackendClient 约 80 行连接管线 | R-1 | ⬜ |
| 🟡 低 | 其余性能/安全/复用项 | 见下 | ⬜ |

> 背景：Dart 与 Node 一样是单线程事件循环（UI isolate 还要每 16ms 出一帧）。
> 任何 CPU 密集或高频同步工作直接表现为掉帧；长同步计算 = 整个 app 冻结
> （触摸无响应、动画停住，Android 超过 5s 触发 ANR 弹窗）。

---

## 一、全局卡死 / 卡顿（F）

### F-1 ⬜ 凭据解密 PBKDF2 在 UI isolate 上跑（唯一会"整 app 冻结"的点）
- **位置**：`lib/core/credentials/credential_file_codec.dart:52-61`（`Pbkdf2.deriveKey`）；
  调用链 `machine_credentials_screen.dart:188-208 _finishImport` →
  `machine_credentials_controller.dart:60-68 decryptEncryptedBytes`
- **问题**：`pubspec.yaml` 只有 `cryptography`，没有注册 `cryptography_flutter`/平台后端，
  所以 native（Android/iOS/桌面）走**纯 Dart 实现**。后端已把迭代次数提到 600000
  （OWASP 标准，`server/lib/credential-file.js`），意味着导入凭据时 UI isolate 要同步算
  60 万轮 HMAC-SHA256 —— 中低端手机上数秒到数十秒整 app 冻结，输入密码后画面定格,
  Android 可能直接 ANR。屏幕上包的 `.timeout(15s)` **无法生效**：事件循环本身被占住，
  定时器根本没机会触发。同文件的 QR 图片解码已经正确用了 `compute()`
  （`machine_credentials_screen.dart:164`），偏偏更重的 PBKDF2 没有。
- **修复方向**：native 把整个 `decrypt(bytes, passphrase)` 放进 `compute()` / `Isolate.run`
  （顶层函数 + 可传参数，照抄 QR 解码的模式）；Web 保持现状（`cryptography` 在浏览器
  自动走 WebCrypto，异步且不占主线程，且 Web 没有 isolate）。修好后 15s 超时才真正有意义。

### F-2 ⬜ 共享 SSE 事件流静默断链后永远挂起
- **位置**：`lib/core/backend/backend_client.dart:1332-1349`（`streamEvents`，无任何超时）+
  `lib/features/chat/bot_chat_controller.dart:1047-1061`（`_connectEventsNow`）
- **问题**：`/api/events` 长连接没有 idle 超时。网络切换（WiFi→流量）、NAT/代理表项过期、
  隧道重启等场景经常**不发 FIN/RST**，socket 看起来还活着但再也收不到数据 ——
  `await for` 永远挂着，`onDone`/`onError` 都不会触发，重连逻辑永远不跑。
  后果：跨设备镜像、quota 提醒、scheduled-message 刷新全部静默停摆，
  直到用户把 app 切后台再切回（`didChangeAppLifecycleState` 里的 `reconnectEvents`）
  或重启。桌面/Web 常驻前台时没有 resume 事件，停摆是**永久的**。
  对比：聊天 POST 流有 65 分钟超时兜底，事件流什么都没有。
- **修复方向**：服务器本来就发心跳（`heartbeat` 事件）。客户端给事件流加空闲超时：
  `response.stream.timeout(Duration(seconds: 90))`（心跳间隔的 2-3 倍），超时抛错走
  现有 `onError` → `_scheduleEventReconnect` 路径。一行级改动，收益极大。

### F-3 ⬜ 流式 delta：O(n²) 拼接 + 每个 delta 全表扫描
- **位置**：`lib/features/chat/bot_chat_controller.dart:931-948`（`_appendDelta` 的
  `'${current.content}$text'`）、`:987-993`（`_assistantIndexForRequest` 用 `indexWhere` 从头扫）
- **问题**：每收到一个 delta 都把已累计的全部内容复制一遍再追加 —— 总成本 O(n²)。
  几百 KB 的长回复在流式后半段每个 delta 都要复制几十万字符，全部发生在 UI isolate，
  与 80ms 节流的 rebuild 叠加造成肉眼可见的掉帧。同时索引查找从消息列表头部线性扫描,
  而正在流式的气泡几乎总在尾部 —— 千条历史的会话里每个 delta 白扫一遍全表。
- **修复方向**：为活跃请求维护一个 `StringBuffer`（keyed by requestId），delta 只 append，
  在节流的 notify 时机才物化成 String 写回消息；索引查找改从尾部扫
  （倒序循环或 `lastIndexWhere`），命中通常 O(1)。

### F-4 ⬜ 远端镜像轮询每 2s 全量解码 + 全量重建消息列表
- **位置**：`lib/features/chat/bot_chat_controller.dart:659-709`
  （`_startHistoryPolling` 2s 周期 → `_refreshHistorySnapshot`）→
  `backend_client.dart:1067-1084 fetchHistory`（`jsonDecode` 整个会话 + 逐条 `ChatMessage.fromJson`）
- **问题**：另一台设备跑 turn 时，本机每 2 秒把**整个会话** JSON（最多 200 条消息，
  长代码回复可达数 MB）在 UI isolate 解码并重建所有 ChatMessage 对象，再整列表替换
  （`_applyHistorySnapshot` clear+addAll）。大会话 = 每 2 秒一次明显卡顿，持续整个远端 turn。
- **修复方向**：响应体超过阈值（如 256KB）时把 `jsonDecode`+`fromJson` 放进 `compute()`；
  顺手可做：快照与现有消息逐条比对，内容没变就不 `notifyListeners()`（省掉无谓 rebuild）。
  更彻底的增量拉取（`?after=messageId`）需要后端配合，作为可选二期。

### F-5 ⬜ 文件浏览器一次性构建目录全部条目
- **位置**：`lib/features/filesystem/file_system_screen.dart:542-590`（`_FileList`：
  `Column` + `for` 全量展开）；外层 `build` 是单 child 的 `ListView`（`:265`），无法惰性构建
- **问题**：进入 `node_modules`、`build` 这类几千项的目录时，一帧内构建+布局几千个
  `ListTile`（每个还带 IconButton、字符串格式化）—— 秒级冻结，且滚动时全部驻留。
  后端 `listAbsoluteDirectory` 不分页，会如实返回全部条目。
- **修复方向**：整页改 `CustomScrollView`：头部控件用 `SliverToBoxAdapter`，
  文件列表用 `SliverList.builder` 惰性构建。行为不变，只是按需建行。

### F-6 ⬜ 上传链路整文件驻留内存（≥2 份拷贝）
- **位置**：`lib/features/filesystem/file_system_screen.dart:163-175`
  （`FilePicker.pickFiles(withData: true)`）→ `backend_client.dart:1299-1330`
  （`uploadFile(bytes:)` 整块 POST）
- **问题**：选 100MB 文件 = picker 一份 Uint8List + http body 一份，手机上轻松 200MB+
  内存峰值，低端机直接 OOM 杀进程。多选文件时按顺序累积更糟。后端已支持流式接收
  （integrity pass 改造过），客户端却仍然整块发。
- **修复方向**：native 改 `withReadStream: true`（file_picker 支持）+ `http.StreamedRequest`
  流式上传；Web 保持 bytes（浏览器限制）。100MB 上限检查改用 `PlatformFile.size` 而非
  `bytes.length`，避免为检查大小先读全文件。

### F-7 ⬜ Web 下载全量缓冲在内存（已知平台限制，记录备查）
- **位置**：`lib/core/platform/file_saver_web.dart:16-40`（`BytesBuilder` 累积全部字节再造 Blob）
- **问题**：浏览器 Blob 需要完整字节，300MB 上限的下载会占满标签页内存。
  native 端已正确流式写盘（`file_saver_stub.dart`），仅 Web 受限。
- **修复方向**：可选方案是 service-worker 流式下载（StreamSaver 模式），复杂度高收益有限。
  **建议接受现状**，在文档注明 Web 端大文件下载的内存上限即可。

---

## 二、性能 / 优化（P）

### P-1 ⬜ 每个 API 请求 3 次 secure-storage/prefs 读 + 凭据 JSON 全量解码（最高频）
- **位置**：`lib/core/backend/backend_client.dart:1453-1483`
  （`_requireCredential` → `MachineCredentialsStore.readActive`：secure-storage 读 + 解码
  **全部**凭据 + prefs 读 activeId；`_headers` → `DeviceIdStore.readOrCreate`（secure-storage）
  + `WorkdirStore.read`）；`cards_service.dart` 同样的管线再来一遍
- **问题**：每个请求都走 2 次 FlutterSecureStorage 平台通道（Android Keystore 解密）+
  1 次 prefs + 凭据列表 JSON 解码。远端镜像时 2s 一次轮询、健康检查、流式聊天……
  全是这条路。单次几毫秒，但属于纯浪费的高频固定开销，secure storage 在部分
  Android 机型上一次读可达 10ms+。
- **修复方向**：三个 store 加内存缓存：deviceId 创建后不可变（读一次缓存永久）；
  凭据列表/activeId 在 `upsert`/`delete`/`setActive` 时失效；workdir 在 `write`/`clear` 时失效。
  全部写入都经过同一类的方法，失效时机可控（同后端 tokens.json 缓存的思路）。

### P-2 ⬜ 流式期间 AnimatedBuilder 重建整个聊天 Column
- **位置**：`lib/features/chat/bot_chat_screen.dart:320-419`
- **问题**：`AnimatedBuilder` 包住 desktop header + 登录 banner + 会话列表 + `_InputBar`，
  流式期间每 80ms 全部重建一遍。列表项有 RepaintBoundary + markdown 缓存兜底，
  但 header/banner/input bar 的重建是纯浪费（`_InputBar` 是 StatefulWidget,
  每次都走 didUpdateWidget 协调）。
- **修复方向**：把 conversation 区域单独用 `ListenableBuilder` 包住，
  header/banner/input bar 只监听各自需要的状态（isThinking 可以拆成 ValueNotifier，
  或简单点：把不随消息变化的部分提为 `child:` 参数传入 builder 复用实例）。

### P-3 ⬜ 卡片拖拽每帧 setState 重建整副牌
- **位置**：`lib/features/cards/card_deck_screen.dart:110-113`（`_onPanUpdate` setState）
- **问题**：拖拽中每个 pointer move 触发整个 State rebuild（3 张卡 + 按钮区 + 布局计算）。
  卡片内容不大所以目前能撑住，但这是标准的"动画走 rebuild"反模式。
- **修复方向**：拖拽偏移放进 `ValueNotifier<Offset>`，顶卡的 Transform 用
  `ValueListenableBuilder`/`AnimatedBuilder` 订阅，`CardWidget` 作为 child 缓存不重建。

### P-4 ⬜ `progressLinesFor` 每次 rebuild 都新建 List
- **位置**：`lib/features/chat/bot_chat_controller.dart:268-273`
- **问题**：流式期间每个可见气泡每个节流 tick 调用一次，
  每次 `whereType<String>().toList()` 新分配。小开销，顺手修。
- **修复方向**：metadata 里直接存 `List<String>`（不可变），读取时零拷贝返回；
  `_appendProgress` 写入时就构造好类型正确的列表。

---

## 三、安全（S）

> 前端攻击面远小于后端（无服务端口、凭据已走 secure storage、QR 是加密信封），
> 本节为低危加固项。

### S-1 ⬜ 明文 `http://` 凭据静默接受，token 裸奔
- **位置**：`lib/core/models/machine_credential.dart:60-86`（`validate` 允许 http）；
  `backend_client.dart:1469-1483`（每个请求 `Authorization: Bearer` 直接发）
- **问题**：导入 baseUrl 为 `http://` 的凭据没有任何提示，之后 bearer token、
  聊天内容、文件全部明文过网。局域网场景合理，但用户可能意识不到差别。
- **修复方向**：不禁止（局域网/自托管需要 http），但导入非 https 凭据时弹一次性
  警告对话框注明风险；连接状态 UI 给 http 机器加标识。

### S-2 ⬜ 错误信息直接 `toString()` 上屏
- **位置**：`file_system_screen.dart:95-122`（`_error = err.toString()`）、
  `machine_credentials_screen.dart:382-403`、`card_deck_screen.dart` 等
- **问题**：原始异常串包含内部 URL、绝对路径、Dart 类型名，既不友好也泄露细节。
  聊天控制器已有 `_friendlyError` 做了正确示范，其他屏幕没用。
- **修复方向**：把 `_friendlyError` 提升为公共 util（接 `AppStrings` 做本地化），
  各屏幕统一走它。

---

## 四、复用性 / 简洁性（R）

### R-1 ⬜ CardsService 复制 BackendClient 约 80 行连接管线
- **位置**：`lib/features/cards/cards_service.dart:70-144`
  （`_requestJson`/`_requireCredential`/`_uri`/`_headers`/`_exceptionFor` 与
  `backend_client.dart:1392-1519` 逐行雷同，注释自己都承认 "Mirrors the connection logic"）
- **问题**：双份维护：P-1 的缓存、新 header、错误码映射都要改两处，已经开始漂移
  （CardsService 少了网络错误分类 `_networkExceptionFor`）。
- **修复方向**：抽 `lib/core/backend/api_transport.dart`（持有 stores + httpClient，
  提供 `requestJson`/`uri`/`headers`/异常映射），BackendClient 与 CardsService 共用；
  或最简方案：CardsService 直接接受并复用一个 `BackendClient` 实例的公开方法。

### R-2 ⬜ `loadFor` 与 `_reloadConversation` 90% 重复
- **位置**：`lib/features/chat/bot_chat_controller.dart:275-326` 与 `:538-572`
- **问题**：重置状态块（8 个字段 + 停轮询）、ensureSession→fetch→apply→finally 序列
  两处各写一遍，靠人肉保持同步 —— `_historyLoadSeq` 这类竞态保护逻辑重复两份尤其危险。
- **修复方向**：抽私有 `_resetAndReload({bool clearSessionLists})`，两个入口只保留差异。

### R-3 ⬜ 字节/时间格式化函数三处重复
- **位置**：`_formatBytes`：`backend_client.dart:230-239` 与 `file_system_screen.dart:616-623`
  （两种实现、精度还不一致）；时间：`core/util/time_format.dart formatShortTime` 与
  `file_system_screen.dart:605-613 _formatModifiedAt`（后者自己手搓 pad2）
- **修复方向**：统一收敛到 `core/util/`（`format_bytes.dart` 或并入 time_format 同级），
  所有调用点改引用。

---

## 总体印象

前端整体素质不错：聊天列表已有 reverse + RepaintBoundary + markdown 缓存 + 80ms 节流，
下载有全局 DownloadManager + 进度节流，QR 解码已进 isolate，事件重连/请求竞态防护
（loadSeq、requestSerial）都有意识。真正会"整 app 卡死"的只有 F-1（确定性复现）和
F-2（条件触发但后果持久）；F-3/F-4/F-5 是大数据量下的明显掉帧；其余为锦上添花。
建议修复顺序：F-1 → F-2 → F-3/F-4 → P-1 → F-5/F-6 → R-1/R-2/R-3 → 其余。
