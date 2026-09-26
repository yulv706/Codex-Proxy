# Codex 跨电脑历史同步设计

## 目标与边界

本功能只同步 Codex 的会话 JSONL 和可重建的索引信息，不共享认证、插件或运行时数据库。这样移动硬盘可以作为“历史仓库”，但不会变成第二个完整的 `CODEX_HOME`。

明确不共享：

- `auth.json`、登录令牌和 `config.toml`；
- 技能、插件、WebView 状态和机器专属设置；
- `state_*.sqlite`、WAL/SHM、日志数据库以及正在写入的半条 JSONL。

Codex 的项目、会话和目录并不是一对一关系：一个项目可以有多个根目录，一个根目录也可能被多个项目使用。因此同步以 Codex 自己的项目 UUID 为主键，目录只作为项目的根路径集合和跨电脑映射信息。

## 数据流

```text
电脑 A ~/.codex                                      移动历史仓库                         电脑 B ~/.codex
local-projects + thread-project-assignments ──项目 UUID──> projects/<logical-id>.json <──绑定── Codex 项目 UUID
选定项目的 sessions/*.jsonl ──规范化/哈希──> objects/<sha256>.jsonl <──规范化/哈希── 选定项目的 sessions/*.jsonl
session_index.jsonl ──每机器引用──────────> refs/<machine-id>/sources/*.json <────────── 本机索引
state_*.sqlite       <──Codex 自己回填──── 不进入仓库 ──── Codex 自己回填──> state_*.sqlite
```

仓库对象按 SHA-256 寻址，写入后不修改；每台电脑只覆盖自己的引用文件。`projects/<logical-id>.json` 是跨电脑稳定的“同步项目”身份，里面记录每台电脑绑定的 Codex 项目 UUID 和根目录快照。

同步开始后会在仓库根目录创建 `sync.inflight.json`，并在仓库锁保护下恢复上次异常退出留下的标记。对象和引用写入仍然保持对象先于引用的顺序；对象路径在读写两端都必须通过仓库根目录校验。索引回填会先合并并去重，再使用临时文件原子替换。

## Codex 项目模型

程序读取本机 `.codex/.codex-global-state.json`：

- `local-projects` 提供 Codex 项目 UUID、名称和 `rootPaths`；
- `thread-project-assignments` 提供会话 UUID 到 Codex 项目的归属；这是确定项目归属的首选来源；
- 只有找不到会话分配时，才用会话 `session_meta.payload.cwd` 与根目录做最长匹配；匹配多个项目时标记为歧义，不自动导出。

界面“本机 Codex 项目”列表一行对应一个 Codex 项目，而不是一个目录。列表会显示该项目的全部根目录、活跃/归档会话数和绑定状态。两个不同 Codex 项目即使共享同一个根目录，也仍然会显示为两行并可分别选择。

用户在 A 电脑选择一个本机 Codex 项目后创建同步项目；在 B 电脑选择自己的 Codex 项目，再绑定到同一个同步项目。绑定比较的是 Codex 项目 UUID，不要求目录字符串相同，也不要求盘符相同。一个同步项目可包含多台电脑的多个本地 Codex 项目成员，必要时同一台电脑也可以绑定多个不同的 Codex 项目；但同一个 Codex 项目 UUID 不能同时绑定到两个同步项目。

## 规范化路径与盘符变化

每个仓库第一次创建时生成永久 `vaultId`。本机保存仓库 ID、上次绝对路径、卷内相对路径和已知盘符别名；移动硬盘从 F: 变成 E: 时，程序会在当前卷上用 `vaultId` 验证并重新定位仓库。

会话的 `cwd` 不再保存电脑 A 的绝对路径，而是保存为：

```text
codex-project://<logical-project-id>                 # 第一个根目录
codex-project://<logical-project-id>/r1/<relative>   # 第二个根目录或根目录下的相对路径
```

导入时根据目标电脑绑定的根目录集合恢复本机绝对路径；根目录索引保持不变，所以多根目录项目不会把会话错误地放到第一个目录。普通聊天文本、命令输出和用户输入中的路径不会被替换。

## 选择、导出与导入

1. 程序扫描本机 Codex 项目清单，但默认不选择任何项目，也默认隐藏归档会话。
2. 用户选择某个 Codex 项目并创建或绑定同步项目；未绑定项目不会导出，未选定项目的仓库引用不会导入。
3. 导出使用会话分配表确定 `CodexProjectId`，引用中同时保存逻辑项目 ID、Codex 项目 ID、项目根索引和项目根路径。
4. 另一台电脑绑定对应的本地 Codex 项目后，导入过滤按逻辑项目和引用中的 Codex 项目成员信息解析绑定，并把会话归入本机 Codex 项目；同时更新 `thread-project-assignments`，使 Codex 自己的项目列表能够识别导入会话。
5. 停止绑定只删除本机映射，不删除本机会话、仓库项目、引用或对象；重新绑定即可继续同步。

## 合并和冲突

线程 UUID 是第一层身份，规范化内容哈希是第二层身份：

1. UUID 和哈希相同：跳过；
2. 一方是另一方的逐字节前缀：采用较长版本；
3. 两者互不为前缀：保留本机原线程，并用“原 UUID + 分支哈希”确定性生成冲突 UUID，外部分支作为冲突副本导入。

不使用“最后写入者获胜”，避免时钟、时区和复制顺序造成数据丢失。

## Codex 索引兼容与安全边界

运行中的实时同步只读取完整 JSONL，并写入历史仓库对象、引用和机器心跳，不写本机 `sessions`、`session_index.jsonl` 或 SQLite，因此不会阻塞 Codex。文件仍在快速增长或最后一条记录不完整时，当前轮次跳过，下一轮重试。

只有完整双向合并确实需要把外部会话写入本机时，程序才会执行导入：

1. 自动模式在 Codex 运行期间只做仓库快照，不导入外部会话；
2. Codex 退出后，或用户在安全时机点击“立即同步”，才写入本机 JSONL 和 `session_index.jsonl`；
3. 写入前备份将被覆盖的会话、索引和可用的 Codex SQLite；
4. 导入完成后将 `backfill_state` 设为 `pending`，由 Codex 下次启动自行回填元数据。

这样既支持实时保存，又不要求程序关闭当前 Codex 进程，也不会在 Codex 正在运行时修改其会话数据库。

## 生命周期与保护开关

- “历史同步”总开关默认关闭；关闭时不会执行自动同步，也不会修改本机历史文件。
- “后台自动写入”默认关闭；开启后才允许托盘监控和文件监听自动保存仓库快照。
- 用户点击“立即同步”属于明确操作，可在自动写入关闭时执行；Codex 运行中仍只保存仓库快照，退出后再执行导入。
- 归档会话默认不显示、不导出、不导入；在设置中开启“同步并显示归档会话”后才纳入筛选。
- 仓库锁、原子写入、内容哈希和本机备份用于防止两台电脑同时写入或移动硬盘突然断开。

## 恢复与兼容范围

本机备份位于 `%LOCALAPPDATA%\CodexProxy\history-backups\<时间-运行ID>`；仓库对象只增加不删除。任何导入失败都会保留源数据并记录到 `%LOCALAPPDATA%\CodexProxy\logs\history-sync.log`。

当前支持标准 `rollout-*.jsonl` 活跃和归档会话；不修改压缩的 `.jsonl.zst`。旧版按目录绑定的仓库仍可读取，程序会在没有 Codex 项目状态时回退到旧目录逻辑，但新建绑定使用 Codex 项目 UUID。仓库包含聊天历史，移动硬盘应使用 BitLocker 或其他磁盘加密。

## 参考

- OpenAI Codex 环境变量：<https://learn.chatgpt.com/docs/config-file/environment-variables>
- OpenAI Codex 配置参考：<https://learn.chatgpt.com/docs/config-file/config-reference>
- Codex SQLite 回填入口：<https://github.com/openai/codex/blob/main/codex-rs/rollout/src/state_db.rs>
- Codex rollout 元数据和扫描：<https://github.com/openai/codex/blob/main/codex-rs/rollout/src/metadata.rs>
- Codex 会话索引：<https://github.com/openai/codex/blob/main/codex-rs/rollout/src/session_index.rs>
