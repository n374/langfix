<!-- doc-init template version: v1.0 -->
# LangFix 文档规约 / Documentation Conventions

> 本文件是 **LangFix** 项目的文档规约入口。详细硬规则见 doc-init skill 的 `~/.claude/skills/doc-init/AGENTS.md`。
> 本文件只列项目特有的扩展约束，不复述 skill 已定义的内容。

## 项目特有扩展

### 必须落地的扩展制品（由 constitution 决定）

V1 不强制 `testing/` `security/` `observability/` 等扩展目录。但下列两条以「就近」形式落地：

- **隐私与密钥**：作为红线写入 [overview/constitution.md](./overview/constitution.md)，不单独建 `security/`。
- **测试策略**：以 spec 中每个 Scenario 的「覆盖测试」字段就地承载，暂不建 `testing/strategy.md`。

### 项目特有的 capability 命名约定

- 单 capability 项目，capability 名 = `grammar-review`。新增独立子系统（如「术语库 / 个人风格学习」）时再开新 capability。

### 项目特有的红线（非通用部分）

详见 [overview/constitution.md](./overview/constitution.md)。核心三条：**密钥只进 Keychain**、**不记录消息内容**、**最小改动不可被破坏**。

## 强制流程入口

- **新增 capability / 新功能**：建 `changes/<slug>/` 走 proposal → design → tasks → spec-delta → archive
- **架构决策**：写 `decisions/NNNN-<topic>.md`
- **修改 living spec**：必须经过一个 change 的 archive（spec 只在 archive 阶段被改）
- **写文档前**：doc-init skill 自动加载本文件 + skill AGENTS.md + constitution.md

## 与 doc-init skill 的关系

| 位置 | 职责 | 谁维护 |
|---|---|---|
| `~/.claude/skills/doc-init/AGENTS.md` | 跨项目通用硬规则（EARS / 分工 / Owner 等） | doc-init skill 维护者 |
| 本文件（`docs/AGENTS.md`） | 项目特有扩展约束 | n374 |
| `docs/overview/constitution.md` | 项目红线 | n374 |
