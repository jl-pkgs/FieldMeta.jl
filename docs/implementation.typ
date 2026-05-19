#import "@preview/modern-cug-report:0.1.3": *
#show: doc => template(doc, size: 11.5pt,
  footer: "Dongdong Kong", header: "FieldMeta.jl 实现思路")

#set par(leading: 1em, spacing: 1em)

#align(center)[
  #text(20pt, weight: "bold")[FieldMeta.jl 实现思路]
  #v(0.4em)
  #text(11pt)[一个比 FieldMetadata.jl 更紧凑、更可调试的 struct 字段元数据方案]
  #v(0.6em)
  #text(9.5pt, fill: gray)[版本 0.1.0 · 共 ~160 行]
]

#v(1em)

= 1 目标

为 Julia struct 的每个字段附加键值元数据（如 `bounds`、`units`、`description`），
并通过函数式 API 在运行时查询：

```julia
bounds(model, :x)        # (0.01, 0.5)
description(model)       # ("Muskingum x", "time step")
```

要求：

- *写法直观*：`@bounds @units @description struct ...` 堆叠，左右顺序与 `|` 值一一对应。
- *类型稳定*：accessor 全部 `@inferred` 通过。
- *分发简单*：不要为每个 key 各自生成一打 dispatch 方法（这是旧版 FieldMetadata.jl 的脆弱点之一）。
- *可调试*：内部 helper 都是小函数，能在 REPL 里独立喂 `:(...)` quote 调用。

= 2 核心数据结构

整个包只有一个统一分发入口：

```julia
function _meta end
@inline _meta(::Type, ::Val, ::Val{K}) where K = REGISTRY[K][1]
```

- 由 `@fields` / 堆叠宏发射的特化方法形如：
  ```julia
  _meta(::Type{<:Muskingum}, ::Val{:x}, ::Val{:bounds}) = (0.01, 0.5)
  ```
- 命中 → 返回特化值（带类型检查）；未命中 → fallback 取注册表的默认值。

注册表本身：

```julia
const REGISTRY = Dict{Symbol, Tuple{Any, Type}}()
# REGISTRY[:bounds] = (nothing, Any)
# REGISTRY[:units]  = ("-", String)
```

`@metadata` 只往 `REGISTRY` 写一行 `(default, check)`，然后生成 accessor 包装、
以及一个用户级的堆叠宏 `@bounds`。

= 3 AST 层处理

== 3.1 `|` 是 Julia 自带的左结合运算符

```
a | b | c | d   ≡   ((a | b) | c) | d
```

解析树：

```
:call :|
├── :call :|
│   ├── :call :|
│   │   ├── a
│   │   └── b      ← 最左值
│   └── c
└── d              ← 最右值
```

要让"最外层宏对应最左 `|` 值"，每个堆叠宏只需做一件事：
*把最内层 `:|` 节点替换为它的 lhs*，并取走它的 rhs 作为本次元数据值。

// #pagebreak()

== 3.2 关键 helper：`_strip_leftmost!`

整个包最核心的一段代码（只有 7 行）：

```julia
function _strip_leftmost!(args, i)
    e = args[i]
    _ispipe(e.args[2]) && return _strip_leftmost!(e.args, 2)
    val = e.args[3]
    args[i] = e.args[2]
    val
end
```

调用约定：
- `args[i]` 是一个 `:|` Expr 链。
- 函数原地修改 `args[i]`（剥掉最内层），返回被剥掉的值。

REPL 演示：

```julia
julia> import FieldMeta: _strip_leftmost!
julia> holder = Any[:(x::Float64 | (0.01, 0.5) | "m" | "label")]
julia> _strip_leftmost!(holder, 1)
:((0.01, 0.5))
julia> holder
1-element Vector{Any}:
 :(x::Float64 | "m" | "label")
julia> _strip_leftmost!(holder, 1), _strip_leftmost!(holder, 1)
("m", "label")
julia> holder[1]
:(x::Float64)
```

== 3.3 宏扩展顺序

Julia 宏扩展是*从外向内*。`@bounds @units @description struct ...` 的过程：

#table(columns: (auto, 1fr, 1fr),
  align: (left, left, left),
  stroke: 0.5pt + gray,
  table.header[阶段][输入][剥离 / 输出],
  [`@bounds` 先跑], [`x::T \| (0.01, 0.5) \| "-" \| "lbl"`], [取 `(0.01, 0.5)`，余 `x::T \| "-" \| "lbl"`],
  [`@units` 跑],    [`x::T \| "-" \| "lbl"`],                [取 `"-"`，余 `x::T \| "lbl"`],
  [`@description`], [`x::T \| "lbl"`],                       [取 `"lbl"`，余 `x::T`],
  [最终 struct],    [`struct ... x::T ... end`],             [纯净 struct 进入编译]
)

= 4 两种用户 API

== 4.1 堆叠形式（`@bounds` / `@units` / ...）

每个 `@metadata` 声明都顺带生成一个同名宏：

```julia
macro $name(ex)
    $FieldMeta._stack(ex, $q, __source__)
end
```

`_stack` 流程：

+ `_find_struct(ex)` —— 递归找到 `:struct` Expr（穿过任意层 macrocall，如 `@with_kw`）。
+ 遍历字段块 `s.args[3].args`。
+ 每行用 `_meta_slot` 定位元数据所在的 `(args, idx, fname)`。
+ 调 `_strip_leftmost!` 剥一层，并 emit 一条 `_meta(::Type{<:T}, ::Val{f}, ::Val{k})` 方法。
+ 返回 `Expr(:block, src, esc(ex), methods...)`，把（已被原地修改的）`ex` 交还给下一个宏。

== 4.2 一次性命名形式（`@fields`）

```julia
@fields @with_kw struct Muskingum{FT}
    x::FT  = 0.35  | (bounds=(0.01, 0.5), units="-", description="x")
    dt::FT = 1.0   | (units="h")
end
```

`@fields` 不剥层，而是直接把 `(k=v, k=v)` 这个 `:tuple` 展开成多条 `_emit!`。
和堆叠形式共用同一套 `_meta` 方法表，accessor 行为完全一致。

// #pagebreak()

= 5 形式 A 与 形式 B

字段行有两种带元数据的形态：

#table(columns: (1fr, 2fr),
  align: (left, left),
  stroke: 0.5pt + gray,
  table.header[形态][AST],
  [`a::T | v`],          [`Expr(:call, :\|, :(a::T), v)`，行就是 `:|` 表达式],
  [`a::T = default | v`], [`Expr(:(=), :(a::T), Expr(:call, :\|, default, v))`，`:|` 嵌在 `:(=)` 内],
)

`_meta_slot` 用一个分支就把两种形态统一返回 `(slot_args, slot_idx, fieldname)`：

```julia
function _meta_slot(block_args, i)
    line = block_args[i]
    line isa Expr || return nothing
    _ispipe(line) && return (block_args, i, _fieldname(line))
    line.head === :(=) && _ispipe(line.args[2]) &&
        return (line.args, 2, _fieldname(line.args[1]))
    nothing
end
```

下游 `_strip_leftmost!` 和 `_emit!` 不需要知道是哪种形态。

= 6 类型检查

每条 emit 的方法体里做一次 `isa` 检查，不命中时通过专门的 `@noinline`
错误函数抛出，避免让正常路径吃错误处理的字节码：

```julia
@inline function _meta(::Type{<:T}, ::Val{f}, ::Val{k})
    v = $val
    _, c = REGISTRY[k]
    v isa c || _typeerror(T, k, v, c)
    v
end
```

= 7 与 `Parameters.@with_kw` 的协作

约定写法：`@bounds @units @description @with_kw struct ...`。

执行顺序（外→内）：

+ `@bounds` 看到 `@units @description @with_kw struct...`，递归找到 `:struct`，
  剥掉它字段里的最左 `|`，发射 `bounds` 方法，返回的 block 中仍然包含未展开的
  `@units @description @with_kw`。
+ `@units`、`@description` 依次同理。
+ 最后 `@with_kw` 看到的 struct 字段已经是纯净的 `x::FT = 0.35`，正常生成
  关键字构造器。

因此元数据宏完全感知不到 `@with_kw` 的存在，只关心找到 `:struct` 然后剥层。

= 8 调试入口

`test/test-internals.jl` 里每个内部 helper 都附了 testset + 例子。
建议的调试流程：

+ 在 REPL `using FieldMeta`，`import FieldMeta: _ispipe, _find_struct, _fieldname, _strip_leftmost!, _meta_slot`。
+ 用 `:(struct Foo; x::Int \| (0,1); end)` 这种 quote 直接喂内部函数。
+ `@macroexpand @bounds @units struct ... end` 观察展开树。
+ 配合 `docs/playground.ipynb` 里准备好的可执行 cell。

= 9 设计取舍

#table(columns: (1fr, 1fr, 1fr),
  align: (left, left, left),
  stroke: 0.5pt + gray,
  table.header[决策][选择][代价 / 备注],
  [元数据存储], [单一 `_meta` + 注册表 fallback], [每次访问要查一次 `REGISTRY` 默认值（仅在 miss 路径）],
  [字段名解析], [`_fieldname` 递归穿 `::` / `=` / `\|`], [新增 wrapper 时需在此处加分支],
  [`_` 跳过], [`val === :_` 不 emit，落到 fallback], [字段不能用 `_` 当字面值],
  [类型检查时机], [访问时（命中 emit 方法里）], [声明 struct 时不立即报错，需要至少访问一次],
)

= 10 后续可扩展

- `@fields T begin ... end` —— 给已有 struct 后期补 / 改元数据。
- `@inferred` 计入测试 —— 当前 `@inferred` 跑过但不计 `@test` 计数。
- 字段名重叠处理（同字段同 key 多次 emit 会触发 method overwrite warning）。
