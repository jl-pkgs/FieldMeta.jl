# Tests + runnable examples for FieldMeta's internal AST helpers.
# All examples can be copy-pasted into the REPL for debugging.

import FieldMeta: _ispipe, _find_struct, _typname, _fieldname,
                  _strip_leftmost!, _meta_slot, _emit!, _meta

##
# _ispipe(e): is `e` a `:call` Expr of the form `lhs | rhs`?
@testset "_ispipe" begin
    @test  _ispipe(:(a | b))
    @test  _ispipe(:(a | b | c))         # left-assoc: ((a|b)|c) — outer is :|
    @test !_ispipe(:(a + b))
    @test !_ispipe(:a)                   # Symbol
    @test !_ispipe(1)                    # literal
    @test !_ispipe(:(a | b | c).args[2]) === false  # inner (a|b) is also a pipe
end

##
# _find_struct(ex): walk an Expr tree and return the first :struct found.
# Used to locate the struct nested inside macrocalls like @with_kw.
@testset "_find_struct" begin
    # s[1]: mutable
    # s[2]: name
    # s[3]: body (block of field lines)
    s = _find_struct(:(struct Foo; x::Int; end))
    @test s isa Expr && s.head === :struct

    # Nested inside a macrocall (simulating `@with_kw struct ... end`)
    wrapped = :(@some_macro struct Bar; y::Float64; end)
    s = _find_struct(wrapped)
    @test s isa Expr && s.head === :struct && s.args[2] === :Bar

    @test _find_struct(:(a + b)) === nothing
    @test _find_struct(:foo)     === nothing
end

##
# _typname(header): extract the type name from a struct's header Expr.
# Handles `Foo`, `Foo{T}`, `Foo <: Abstract`, `Foo{T} <: Abstract{T}`.
@testset "_typname" begin
    @test _typname(:Foo)                  === :Foo
    @test _typname(:(Foo{T}))             === :Foo
    @test _typname(:(Foo <: AbstractFoo)) === :Foo
    @test _typname(:(Foo{T} <: AbstractFoo{T})) === :Foo
end

# _fieldname(line): walk through `::`, `=`, `|` wrappers to the field symbol.
@testset "_fieldname" begin
    @test _fieldname(:a)                                   === :a
    @test _fieldname(:(a::Int))                            === :a
    @test _fieldname(:(a::Int = 3))                        === :a
    @test _fieldname(:(a::Int | (0, 1)))                   === :a
    @test _fieldname(:(a::Int | (0, 1) | "kg"))            === :a
    @test _fieldname(:(a::Int | (0, 1) | "kg" | "label"))  === :a
end

##
# _strip_leftmost!(args, i): mutate args[i] to remove the leftmost `|` value.
# Returns the stripped value. Mirrors what each stacked macro does per field.
# 从左到右，踢除第一个meta
@testset "_strip_leftmost!" begin
    # Single pipe: `a | v` -> `a`, returns `v`.
    holder = Any[:(a | 7)]
    @test _strip_leftmost!(holder, 1) == 7
    @test holder[1] === :a

    # Two pipes: `a | v1 | v2` peels v1 first.
    holder = Any[:(a | 1 | 2)]
    @test _strip_leftmost!(holder, 1) == 1
    @test holder[1] == :(a | 2)
    @test _strip_leftmost!(holder, 1) == 2
    @test holder[1] === :a

    # Four-level chain (Form A in @stacked tests).
    line = :(x::Float64 | (0.01, 0.5) | "m" | "label")
    holder = Any[line]
    @test _strip_leftmost!(holder, 1) == :((0.01, 0.5))
    @test _strip_leftmost!(holder, 1) == "m"
    @test _strip_leftmost!(holder, 1) == "label"
    @test holder[1] == :(x::Float64)

    # Form B style: peeling default's pipe chain. Note `args` here is the
    # `:(=)` line's args slot 2, i.e., `2`: args[2]
    line = :(x::FT = 0.35 | (0.01, 0.5) | "-")
    @test _strip_leftmost!(line.args, 2) == :((0.01, 0.5))
    @test _strip_leftmost!(line.args, 2) == "-"
    @test line == :(x::FT = 0.35)
end

## _meta_slot(block_args, i): classify a field line.
# Returns (args, idx, fieldname) for metadata-bearing lines, else `nothing`.
# This is the entry point both @fields and @stacked use to find work to do.
@testset "_meta_slot" begin
    # Form A: bare pipe line.
    block = Expr(:block, :(a::Int | "x"), :(b::Float64), :(c | "z"))

    args, idx, fname = _meta_slot(block.args, 1)
    @test args === block.args && idx == 1 && fname === :a

    @test _meta_slot(block.args, 2) === nothing            # plain field, skip

    args, idx, fname = _meta_slot(block.args, 3)
    @test args === block.args && idx == 3 && fname === :c  # untyped works too

    # Form B: `field = default | val` — slot lives inside the `:(=)` line.
    line = :(x::FT = 0.35 | (0.01, 0.5))
    block2 = Expr(:block, line)
    args, idx, fname = _meta_slot(block2.args, 1)
    @test args === line.args && idx == 2 && fname === :x
end

##
# _emit!(methods, typname, fname, key, val):
#   push a specialized _meta method into `methods`.
#   Type check runs at struct-def time (eval); hot path just returns the constant.
@testset "_emit!" begin
    # undeclared key → error immediately (before any code is generated)
    @test_throws ErrorException _emit!(Expr[], :Foo, :a, :_no_such_key, 1)

    # declared key → pushes exactly one esc(quote...) block
    # `bounds` is declared in runtests.jl
    methods = Expr[]
    _emit!(methods, :Foo, :x, :bounds, :((0.01, 0.5)))
    @test length(methods) == 1

    # full cycle: emit → install → _meta returns the constant
    # bounds declared as `Any`, so (-1.0, 1.0) passes the type check
    @eval struct _EmitDemo; score::Float64; end
    m = Expr[]
    _emit!(m, :_EmitDemo, :score, :bounds, :( (-1.0, 1.0) ))
    eval(only(m).args[1])   # installs the _meta method
    @test _meta(_EmitDemo, Val{:score}(), Val{:bounds}()) == (-1.0, 1.0)

    # multiple keys for the same field: each _emit! call is independent
    m2 = Expr[]
    _emit!(m2, :_EmitDemo, :score, :units,       "pts")
    _emit!(m2, :_EmitDemo, :score, :description, "score value")
    @test length(m2) == 2
    for e in m2; eval(e.args[1]); end
    @test _meta(_EmitDemo, Val{:score}(), Val{:units}())       == "pts"
    @test _meta(_EmitDemo, Val{:score}(), Val{:description}()) == "score value"

    # wrong-type value → MetadataError when the let block runs at struct-def time
    # need a real existing type so Julia can compile the method signature in the block
    @eval struct _EmitTest; x::Float64; end
    bad = Expr[]
    _emit!(bad, :_EmitTest, :x, :units, 42)   # units expects String
    @test_throws MetadataError eval(only(bad).args[1])
end
