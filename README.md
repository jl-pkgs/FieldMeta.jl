# FieldMeta.jl

<!-- [![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://jl-pkgs.github.io/FieldMeta.jl/stable) -->
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://jl-pkgs.github.io/FieldMeta.jl/dev)
[![CI](https://github.com/jl-pkgs/FieldMeta.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/jl-pkgs/FieldMeta.jl/actions/workflows/CI.yml)
[![Codecov](https://codecov.io/gh/jl-pkgs/FieldMeta.jl/branch/master/graph/badge.svg)](https://app.codecov.io/gh/jl-pkgs/FieldMeta.jl/tree/master)


为 struct 字段附加元数据（bounds、units、description …）。`FieldMetadata.jl` 的重新设计版本，保留堆叠写法的可读性，去掉它内部的脆弱性。

## 快速上手

```julia
using FieldMeta, Parameters
import FieldMeta: @metadata, @fields

@metadata bounds      nothing  Any
@metadata units       "-"      String
@metadata description ""       String

# 堆叠写法（阅读顺序：最外层宏 = 最右边的 |）
@bounds @units @description @with_kw struct Muskingum{FT}
    x::FT  = 0.35   | (0.01, 0.5) | "-" | "Muskingum x"
    dt::FT = 1.0    | _           | "h" | "time step"
end
# Reading order is direct: the i-th macro consumes the i-th `|` value.
#   @bounds       @units    @description
#   (0.01, 0.5)    "-"       "Muskingum x"

m = Muskingum{Float64}()
bounds(m, :x)       # (0.01, 0.5)
units(m, :dt)       # "h"
description(m)      # ("Muskingum x", "time step")

# 或者一行命名写法
@fields @with_kw struct Muskingum2{FT}
    x::FT  = 0.35   | (bounds = (0.01, 0.5), units = "-", description = "x")
    dt::FT = 1.0    | (units = "h", description = "time step")
end
```

`_` 表示该 key 在这个字段上跳过，回落到 `@metadata` 注册的默认值。

## 与 `FieldMetadata.jl` 的不同

### 1. 元数据存储：每 key 一份方法集 → 单一统一 dispatcher

|                      | FieldMetadata                  | FieldMeta                                                       |
| -------------------- | ------------------------------ | --------------------------------------------------------------- |
| 每个 `@metadata` key | 生成约 10 个 dispatch 方法     | 共享单一 `_meta(::Type{<:T}, ::Val{field}, ::Val{key})`         |
| 默认值与类型检查     | 烧进每个生成的方法             | 集中在 `REGISTRY::Dict{Symbol,(default,check)}`，与字段方法解耦 |
| 后加新 key           | 需要重新展开 struct 的元数据宏 | 直接 `@metadata newkey ...`，旧 struct 立即可用，返回默认值     |

后果：`FieldMetadata` 里 `@generated fieldname_vals` 一旦返回 `Val(:x)` 实例而不是 `Val{:x}` 类型，10 个方法分支瞬间全失配 — 这是这次修复的根因之一。`FieldMeta` 没有这条多分支链。

### 2. 堆叠语义：跨宏共享状态 → 每宏独立剥一层

|                       | FieldMetadata                                           | FieldMeta                                                        |
| --------------------- | ------------------------------------------------------- | ---------------------------------------------------------------- |
| 宏栈层数 vs `\|` 数量 | 必须严格相等，少一根/多一根错位静默                     | 同上（语义未变），但每宏内部只关心自己那一层，不需要追踪整条管道 |
| 与 `@with_kw` 协作    | `@with_kw` 必须在最内层；外层宏看到尚未展开的 macrocall | 同左；处理逻辑用统一递归找 `:struct`，不依赖宏栈对齐             |
| 错误处理              | 在某些组合下静默丢弃字段元数据                          | 显式 `error()`：找不到 struct / pipe 解析失败立刻报              |

### 3. `@chain` 的多重坑

`FieldMetadata.@chain` 把多个宏拼成一个。它在生成的内层宏体里：
- 用 `@__LINE__` 而不是 `__source__` —— 用户调用点的行号被 FieldMetadata.jl 内部行号覆盖；
- 2-arg form 配 begin-block 会重复传 `typ`，导致部分链式宏失效（实测：`@chained @description @paramrange Described begin … end` 时 paramrange 不生效）。

`FieldMeta` **删除了 `@chain`**。需要"一次写完多 key"时直接用 `@fields`，省去了链式宏的所有边界问题。

### 4. 类型参数与子类型分发

|                                 | FieldMetadata                                                        | FieldMeta                                                          |
| ------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `Muskingum{Float64}` 的字段查找 | 依赖 `fieldname_vals` 返回 `Val{...}` 类型元组，并经过 5 跳 dispatch | 直接 `_meta(::Type{<:Muskingum}, Val{:x}, Val{:bounds})`，1 跳命中 |
| inference                       | 容易因任一中间方法不稳定而退化                                       | accessor 全部 `@inferred` 通过（测试覆盖）                         |

### 5. 字段名解析

| 形式                          | FieldMetadata | FieldMeta                      |
| ----------------------------- | ------------- | ------------------------------ |
| `a::T \| v`                   | ✓             | ✓                              |
| `a::T = d \| v`               | ✓             | ✓（递归到最内层 lhs 取字段名） |
| 链式 `a::T \| v1 \| v2 \| v3` | ✓             | ✓                              |
| `a::T \| (k1=v1, k2=v2)`      | ✗             | ✓（`@fields` 专用）            |

## 迁移指南（从 FieldMetadata.jl）

大部分代码改一行就能跑：

```julia
# Before
using FieldMetadata
import FieldMetadata: @metadata, @description, ...

# After
using FieldMeta
import FieldMeta: @metadata, @description, ...
```

不兼容点：

1. **`@chain` 被移除**。把 `@chain columns @description @paramrange` 改为直接堆叠 `@description @paramrange struct ...`，或改用 `@fields`。
2. **begin-block 形式（事后给已存在 struct 补元数据）暂未实现**。如有需要可以单独提一个 issue。
3. **`label(x::Type, ::Type{Val{F}}) where F = F` 这种默认值依赖字段名的特殊 fallback** 没有移植。若有需要，在 `@metadata` 之后手动定义：
   ```julia
   FieldMeta._meta(::Type, ::Val{F}, ::Val{:label}) where F = F
   ```

## 内部结构

```
@metadata <name> <default> [Type]
    │
    ├─ 写入 REGISTRY[:name] = (default, Type)
    ├─ 生成 6 个 accessor 方法 name(x|T, [field|Val{f}])
    └─ 生成 macro @name —— 调用 _stack_macro 剥一层 `|`

@fields struct ... end
    │
    └─ _process! → _stripblock! → _emit!
       为每个 (T, field, key) 生成一条 _meta(::Type{<:T}, ::Val{f}, ::Val{k})

# 运行期查找
name(x, :field)
  → _meta(typeof(x), Val{:field}(), Val{:name}())
  → 命中：返回特化方法的值（带类型检查）
  → 未命中：fallback `_meta(::Type, ::Val, ::Val{K})` 返回 REGISTRY[K][1]
```

## 测试

```
12 testsets, all passing
- single-key accessors / default fallback / type inference
- multi-key via @fields
- type check (MetadataError)
- @with_kw integration
- stacked macros + `_` skip + @with_kw stacked
```

运行：

```julia
julia --project test/runtests.jl
```
