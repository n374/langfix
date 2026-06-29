<!-- doc-init template version: v1.0 -->
# LangFix 文档 / Documentation

> LangFix 是一个 macOS 菜单栏划词写作纠错工具：选中你用非母语（首要场景是英文，不限于英文）写的一段文本 → PopClip 触发 → 弹窗给出「最小改动」的语法 / 拼写 / 用词 / 地道度修正，并用你的母语（中文）解释哪里错、为什么、怎么改。
> 项目所有文档的入口与导航。详细规约见 [AGENTS.md](./AGENTS.md)。

## 文档地图

| 区域 | 路径 | 说明 |
|---|---|---|
| 世界观 | [overview/](./overview/) | 项目背景、范围、技术栈、宪法（红线） |
| 架构 | [architecture/](./architecture/) | 总览、数据流、技术选型、核心模块 |
| 决策记录 | [decisions/](./decisions/) | ADR（关键架构/选型决策） |
| Living spec | [specs/](./specs/) | 各 capability 的 source of truth（EARS 需求） |

> `api/` `operations/` `changes/` `archive/` 在首次需要时按规约创建。

## 角色入门

- **了解项目**：先读 [overview/project.md](./overview/project.md) 与 [overview/constitution.md](./overview/constitution.md)
- **动手实现**：读 [architecture/README.md](./architecture/README.md) → 三个核心模块 → [specs/grammar-review/spec.md](./specs/grammar-review/spec.md)
- **为什么这么设计**：读 [decisions/README.md](./decisions/README.md)

## 技术路线

原生 SwiftUI 菜单栏 App + PopClip **Service action** 触发 + **OpenAI 兼容端点**（base URL / key / model 全可配）。

## 文档规约

所有文档规约见 [AGENTS.md](./AGENTS.md)。任何写 `docs/` 下文档的动作必须由 `doc-init` skill 主导。
