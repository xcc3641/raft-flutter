# raft_mobile 交接说明

自建 Raft（botiverse/raft-source）的 Flutter 移动端伴侣 App。范围：**只做 Channel + 聊天**（含 Thread、表情回应、收藏、Agent 实时状态）。PWA 体验被否决，所以有这个 App。

## 仓库与分支

- 唯一工作目录：`~/Work/Flutter/raft_mobile`，分支 `main`。不再使用 Orca worktree。
- 提交：一行 subject，`type(scope): imperative`；不要 push 远端，除非广志明确要求。

## 权威源（只读，接口字段一律以源码为准）

- 服务端/网页源码：`~/Work/AI/raft-source`（`packages/server`、`packages/web`）
- 自建生产部署：`~/Work/AI/raft-prod`（Caddy :8080 同源反代 `/api`、`/socket.io`；手机经 Tailscale `http://hugomini.tail0666f2.ts.net:15244`，**纯 HTTP**，iOS ATS / Android cleartext 已放开）
- 计划与票：`docs/PLAN.md`、`docs/tickets/T1–T5`
- UI 还原依据：`docs/design/README.md`（数值出处）、`docs/design/web-ref/`（网页版截图）

## 已完成

| 模块 | 关键文件 |
|---|---|
| 鉴权 / refresh 单飞 / 选服 | `lib/core/api_client.dart`、`lib/features/auth/` |
| 首页（sidebar-order 分组、像素头像、状态点） | `lib/features/conversations/`（`sidebar_sections.dart` 纯逻辑） |
| 聊天 / Thread / 长按菜单 / 表情 / 收藏 | `lib/features/chat/`（`chat_page.dart`、`message_row.dart`、`reaction_logic.dart`） |
| 实时（Socket.IO、sync:resume、前后台） | `lib/realtime/` |
| Agent 实时状态（首页底栏、聊天输入框上方、DM 顶栏） | `lib/features/activity/`（`agent_activity.dart` 纯逻辑，移植 web `liveAgentActivity.ts`） |
| Brutal 主题 / 字体 / 像素头像 | `lib/core/theme/`、`lib/ui/` |

已知约定与坑：
- socket 握手 `clientKind: 'web'`（`mobile` 有原生推送专属语义，我们没有推送）。
- REST 需 `Authorization: Bearer` + `X-Server-Id`；历史分页参数是 `before`，已读 body 是 `{seq}`。
- 本实例 `read_receipts_v0` 关闭，没有已读回执；「Agent 收到没」靠 `agent:activity`。
- Flutter 无障碍树基本为空，`sim-use ui` 读不到消息；模拟器操作用 `adb shell input tap/swipe`，截图用 `adb exec-out screencap -p`。
- 在模拟器 Chrome 看网页版对照：`adb reverse tcp:18080 tcp:8080` 后开 `http://localhost:18080`（10.0.2.2 非安全上下文会白屏）。

## 验证

- `flutter analyze` 必须 0 issue，`flutter test` 全绿（当前 168 个）。
- 禁止写 Widget / UI / 快照测试；单测只写纯逻辑。
- 改 UI 后在 Android 模拟器 `emulator-5554`（AVD `Pixel_9a`，已登录）上 `flutter build apk --debug` + `adb install -r` 截图核对。不要动 USB 连着的 Pixel 8 Pro（广志发 Threads 用）。
- 在真实工作区发消息会唤醒 Agent，先问广志或用与小秘书的 DM。

## iOS TestFlight 发版

- App Store Connect：App「Raft Mobile」ID `6821233681`，bundle `com.hugo.raftMobile`，团队 `QWM63DD4A6`，内部测试组「Internal」（自动收到所有 build）。
- 本机 Xcode **没登录 Apple 账号**，`flutter build ipa` 的导出会失败（`No Accounts`），归档可用；用 asc 手动签名导出：

```bash
BN=$(date +%Y%m%d%H%M)
flutter build ipa --release --export-method app-store --build-number=$BN   # 导出失败可忽略
ASC_PROFILE=xcc asc xcode export --archive-path build/ios/archive/Runner.xcarchive \
  --ipa-path .asc/artifacts/Raft.ipa --signing-style manual --team-id QWM63DD4A6 --overwrite
ASC_PROFILE=xcc ASC_TIMEOUT=30m asc builds upload --app 6821233681 --ipa .asc/artifacts/Raft.ipa --wait
```

- build 号用分钟时间戳且必须递增；App Store 描述文件「Raft Mobile AppStore」已装在本机（到期 2027-01-19）。

## 未做（超出范围，需广志点头才做）

底部 Tasks/Members/Settings、Search/Activity/Saved 页、任务徽标与转任务、多选、附件上传与预览、@ 联想、Agent 模型标签、原生推送。
