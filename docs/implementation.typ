#import "@preview/modern-cug-report:0.1.3": *
#show: doc => template(doc, size: 11.5pt,
  footer: "Dongdong Kong", header: "FieldMeta.jl 实现思路")

#set par(leading: 1em, spacing: 1em)

#align(center)[
  #text(20pt, weight: "bold")[FieldMeta.jl 实现思路]
  #v(0.4em)
  #text(11pt)[一个比 FieldMetadata.jl 更紧凑的 struct 字段元数据方案]
  #v(0.6em)
  #text(9.5pt, fill: gray)[版本 0.1.0 · 共 ~160 行]
]

#v(1em)

= 1 宏展开后生成什么

理解整个包，最快的方式是看最终生成了什么。

```julia
@metadata bounds nothing Any
@metadata units  "-"    String

@bounds @units struct Muskingum
    x::Float64 | (0.01, 0.5) | "m/s"
    dt::Float64
end
```

等价于：

```julia
struct Muskingum          # pipe 被剥干净
    x::Float64
    dt::Float64
end

# 每个 (类型, 字段, key) → 专属方法，直接返回常量
@inline _meta(::Type{<:Muskingum}, ::Val{:x}, ::Val{:bounds}) = (0.01, 0.5)
@inline _meta(::Type{<:Muskingum}, ::Val{:x}, ::Val{:units})  = "m/s"

# @metadata 为每个 key 生成的默认 fallback
@inline _meta(::Type, ::Val, ::Val{:bounds}) = nothing
@inline _meta(::Type, ::Val, ::Val{:units})  = "-"
```

用户调用 `bounds(model, :x)` 时，内部走 `_meta(Muskingum, Val{:x}(), Val{:bounds}())`。
三层优先级：*专属方法 > 按 key 默认 > MethodError（未声明的 key）*。
热路径全是方法派发，无 Dict 查询，完全类型稳定。

= 2 pipe 链与堆叠宏

`|` 在 Julia 里是左结合运算符：

```
x::T | v1 | v2 | v3   ≡   ((x::T | v1) | v2) | v3
```

最左值 `v1` 在最深的 `:|` 节点。Julia 宏从外向内展开，所以：

- `@bounds`（最外层）剥走 `v1`，余下 `x::T | v2 | v3` 交给下一个宏。
- `@units` 剥走 `v2`，余下 `x::T | v3`。
- `@description` 剥走 `v3`，余下纯净的 `x::T`。

核心实现是 `_strip_leftmost!(args, i)`（7 行），递归找到最深的 `:|` 节点，
原地替换并返回被剥掉的值。

= 3 类型检查在何时发生

#table(columns: (auto, 1fr),
  align: (left, left),
  stroke: 0.5pt + gray,
  table.header[时机][做什么],
  [宏展开期],     [从 `REGISTRY` 读约束 `c`，检查 key 是否已声明（未声明立即报错）],
  [结构体定义期], [`let v = $val; v isa c || _typeerror(...)` 执行一次],
  [访问期],       [专属方法直接 `return $val`，*零额外开销*],
)

`REGISTRY` 只在 `@metadata` 执行时写入、宏展开时读出，运行期不接触。

= 4 内部函数调用链

`@bounds struct ... end` 展开时，调用关系如下：

```
macro bounds(ex)
  _stack(ex, :bounds, src)
    _process(ex, src, emit_fn)
      1. _find_struct(ex)              # 找到 :struct，穿过 @with_kw 等 macrocall
      2. for each field line:
           a. _meta_slot(block, i)     # 该行有 pipe 吗？→ (args, idx, fname)
           b. _strip_leftmost!(args, idx)  # 原地剥最左 | 值，返回 val
           c. _emit!(methods, T, fname, key, val)
                - REGISTRY[key]        # 读约束 c（宏展开期，一次性）
                - push! 生成的方法块:
                    let v=val; v isa c || _typeerror(...) end  # 定义期执行
                    @inline _meta(::Type{<:T}, ::Val{f}, ::Val{k}) = val
      3. return Expr(:block, esc(ex), methods...)
```

步骤 2 是顺序的三步（a → b → c），不是嵌套调用。`ex` 在步骤 2 里被原地修改（pipe 已剥），步骤 3 返回时它已经是干净的 struct。

== 多宏堆叠时的展开顺序

堆叠不靠代码里的循环，而是 Julia 宏展开机制本身驱动。
展开（编译期）和执行（运行期）是两个阶段：

*展开阶段*（外 → 内，编译期）：
```
@bounds @units struct ... x | v1 | v2 end
  @bounds 展开 → block { esc(@units struct...x|v2 end),   # ex 放前面
                          @inline _meta(...bounds...) = v1 }
  @units  展开 → block { esc(struct...x end),              # ex 放前面
                          @inline _meta(...units...) = v2 }
```

*执行阶段*（顺序执行，运行期）：
```
1. struct ... x end                        ← struct 先定义
2. @inline _meta(...units...)  = v2        ← 方法引用 T，T 已存在 ✓
3. @inline _meta(...bounds...) = v1
```

`_process` 始终把 `esc(ex)` 放在 `methods` 之前返回，
保证 struct 定义先于任何引用它的 `_meta` 方法。

= 5 调试入口

```julia
import FieldMeta: _ispipe, _find_struct, _fieldname, _strip_leftmost!, _meta_slot

# 直接喂 quote 调用内部函数
holder = Any[:(x::Int | (0, 1) | "m")]
_strip_leftmost!(holder, 1)   # => :((0, 1))

# 观察完整展开
@macroexpand @bounds @units struct Foo; x::Int | 1 | "u"; end
```

每个 helper 的行为在 `test/test-internals.jl` 里都有可执行示例。
