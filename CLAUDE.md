# CLAUDE.md

为 Claude Code 在此仓库上工作的项目级提示。

## 包定位

- 单一分发函数 `_meta(::Type{<:T}, ::Val{field}, ::Val{key})` 取代旧版每 key 一打方法的设计。
- 三层 dispatch 优先级：专属方法（`_emit!` 生成）> 按 key 默认（`@metadata` 生成）> `MethodError`。
- `REGISTRY` 只在 `@metadata` 执行时写入、`_emit!` 宏展开期读出；运行期热路径不接触 REGISTRY。
- 类型检查在**结构体定义期**执行一次（`let v=val; v isa c || _typeerror(...) end`），不在访问期。
- 删除了 `@chain`（连同它 `__source__` / begin-block 的两个坑）。

修复 / 改动时遇到与旧版行为不一致的情况，先查 `README.md` 的"与 FieldMetadata.jl 的不同"，避免误把"故意改掉的设计"当成 bug 修回去。

## 目录布局

```
src/FieldMeta.jl       核心实现，~160 行，单文件
test/runtests.jl       入口，include 三个文件
test/test-internals.jl 内部 helper 的单元测试 + REPL 用法示例
test/test-chain.jl     堆叠宏（@bounds @units @description）行为
test/test-fields.jl    @fields 命名形式 + @with_kw 集成
docs/implementation.typ 中文实现思路（用 Typst 写，编译到 PDF）
docs/playground.ipynb  Jupyter 调试 notebook
```

## 编辑核心实现的注意点

`src/FieldMeta.jl` 内的几个关键 helper 都有契约，改动前先看一下 `test-internals.jl` 对应 testset：

| Helper                          | 契约                                                                       |
| ------------------------------- | -------------------------------------------------------------------------- |
| `_ispipe(e)`                    | `e isa Expr && head=:call && args[1]=:\|`，三个条件缺一不可                |
| `_find_struct(ex)`              | 递归找第一个 `:struct`；穿过 macrocall（如 `@with_kw`）                    |
| `_typname(header)`              | 处理 `Foo` / `Foo{T}` / `Foo <: A` / `Foo{T} <: A{T}` 四种                 |
| `_fieldname(e)`                 | 穿过 `::`、`=`、`\|` 三种 wrapper 到达 Symbol                              |
| `_strip_leftmost!(args, i)`     | 原地修改 `args[i]`，剥掉最内层 `:\|` 的 rhs（最左 pipe 值），返回它        |
| `_meta_slot(block_args, i)`     | 把 Form A / Form B 两种字段行统一返回 `(slot_args, slot_idx, fname)`       |
| `_emit!(methods, T, f, k, val)` | 宏展开期从 REGISTRY 读约束；push 一个含类型检查+方法定义的 `esc(quote...)` |

修改任一 helper 都要同步更新 `test-internals.jl` 里的 testset；这些测试同时是 REPL 调试用的可执行示例。

## 堆叠语义（重要）

`@bounds @units @description struct ... a::T | v1 | v2 | v3 end`：

- 第 i 个**宏**对应第 i 个 `|` **值**（左到右一一对应）。
- 实现层面是"最外层宏剥最左 pipe 值"（最外层 = 最先展开 = `@bounds`；最左 pipe = `v1`）。
- `|` 是左结合：`a | v1 | v2 | v3 == ((a|v1)|v2)|v3`，最左值 `v1` 在最深的 `:|` 节点 `args[3]`。

如果改动需要调整顺序语义，先想清楚：宏扩展顺序（外→内）、`|` 结合性（左结合）、用户视觉期望（左→左对应）三者之间的映射。不要单独动其中一项。

## 与 `Parameters.@with_kw` 协作

约定写法 `@bounds @units @description @with_kw struct ... end`：
- 元数据宏在外，`@with_kw` 在最内。
- `_find_struct` 会穿过 `@with_kw` 这个 macrocall 找到真正的 `:struct`。
- 元数据宏剥层时只动字段的 pipe 部分；`= default` 部分留给 `@with_kw` 生成关键字构造器。

不要把元数据宏放在 `@with_kw` 里面 —— `@with_kw` 展开后已经没有原始字段行的 pipe 结构。

## 常用命令

```bash
# 跑测试
julia --project=. -e 'using Pkg; Pkg.test()'

# 编译实现思路 PDF（typst 已在 PATH）
typst compile docs/implementation.typ docs/implementation.pdf

# 启动 notebook（前提是 IJulia 已装）
# 直接在 VSCode 里打开 docs/playground.ipynb 即可
```

## 写代码风格

- 简洁优先。`src/FieldMeta.jl` 整文件 ~160 行，新增功能时优先考虑能不能复用 `_meta_slot` / `_process` 这种已有的小抽象，而不是再开一个并列函数。
- 注释只写"为什么"，不写"做什么"（命名已经说明做什么）。
- 不要恢复 `@chain` 或重新引入"每 key 各自一套 dispatch"的设计，这两条是这次重写明确要丢掉的。

## 文档同步

改动接口（导出名、宏语法、accessor 签名）时同步更新：
1. `README.md`（用户视角）
2. `docs/implementation.typ`（开发者视角，注意编译时 `*..._..*` 内的下划线会被 Typst 当成强调标记，要么避开要么用 `#strong[...]` 函数式语法）
3. `docs/playground.ipynb`（如果接口变了，示例 cell 要跟着改）
4. `test/test-internals.jl` 里相关 testset 的开头注释
