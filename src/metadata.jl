export @metadata, @fields, MetadataError, fieldmeta

struct MetadataError <: Exception
    msg::String
end
Base.showerror(io::IO, e::MetadataError) = print(io, e.msg)

@noinline _typeerror(T, k, v, c) = throw(MetadataError(
    "$v of type $(typeof(v)) is not <: $c for key :$k in $T"))


# (default, type-constraint) per declared key.
const REGISTRY = Dict{Symbol,Tuple{Any,Type}}()

# Per-(T, field, key) methods are emitted by `_emit!`.
# Per-key fallback (constant default) is emitted by `@metadata`.
# Querying an undeclared key intentionally raises MethodError.
function _meta end

@generated function _allfields(::Type{T}, ::Val{K}) where {T,K}
    Expr(:tuple, (:(_meta(T, Val{$(QuoteNode(f))}(), Val{K}())) for f in fieldnames(T))...)
end

@inline fieldmeta(::Type{T}, f::Symbol, k::Symbol) where T = _meta(T, Val{f}(), Val{k}())
@inline fieldmeta(x, f::Symbol, k::Symbol) = fieldmeta(typeof(x), f, k)

## AST helpers
_ispipe(e) = e isa Expr && e.head === :call && length(e.args) == 3 && e.args[1] === :|

function _find_struct(ex)
    ex isa Expr || return nothing
    ex.head === :struct && return ex
    for a in ex.args
        s = _find_struct(a)
        s === nothing || return s
    end
    nothing
end

_typname(s::Symbol) = s
_typname(e::Expr) = e.head in (:curly, :<:) ? _typname(e.args[1]) :
                    error("FieldMeta: bad type header `$e`")

_fieldname(s::Symbol) = s
_fieldname(e::Expr) = e.head === :(::) ? e.args[1] :
                      e.head === :(=) ? _fieldname(e.args[1]) :
                      _ispipe(e) ? _fieldname(e.args[2]) :
                      error("FieldMeta: bad field `$e`")

# 从左到右，踢除第一个meta
function _strip_leftmost!(args, i)
    e = args[i]
    _ispipe(e.args[2]) && return _strip_leftmost!(e.args, 2)
    val = e.args[3]
    args[i] = e.args[2]
    val
end

# Locate (slot_args, slot_i, field_name) for a metadata-carrying line.
# Returns nothing for plain field lines.
function _meta_slot(block_args, i)
    line = block_args[i]
    line isa Expr || return nothing
    _ispipe(line) && return (block_args, i, _fieldname(line))
    line.head === :(=) && _ispipe(line.args[2]) &&
        return (line.args, 2, _fieldname(line.args[1]))
    nothing
end

# 生成一个 (typname, fname, key) 专属的 _meta 方法；类型检查在结构体定义期执行一次。
function _emit!(methods, typname, fname, key, val)
    haskey(REGISTRY, key) ||
        error("FieldMeta: key :$key not declared via @metadata")
    c = REGISTRY[key][2]
    qk, qf = QuoteNode(key), QuoteNode(fname)
    push!(methods, esc(quote
        let v = $val
            v isa $c || $FieldMeta._typeerror($typname, $qk, v, $c)
        end
        @inline $FieldMeta._meta(::Type{<:$typname}, ::Val{$qf}, ::Val{$qk}) = $val
    end))
end


## @metadata: declare a key, generate accessors + a stackable per-key macro.
"""
    @metadata name default [Type=Any]

Declare a metadata key. Generates accessors `name(x_or_T[, field])` and a
stackable macro `@name` (use as `@bounds @units @description struct ... end`,
with the i-th macro consuming the i-th `|` value).
"""
macro metadata(name, default, checktyp=:Any)
    q = QuoteNode(name)
    esc(quote
        let d = $default, c = $checktyp
            d isa c || $FieldMeta._typeerror(:_default, $q, d, c)
            $FieldMeta.REGISTRY[$q] = (d, c)
        end
        @inline $FieldMeta._meta(::Type, ::Val, ::Val{$q}) = $default
        @inline $name(x, f::Symbol) = $FieldMeta._meta(typeof(x), Val{f}(), Val{$q}())
        @inline $name(::Type{T}, f::Symbol) where T = $FieldMeta._meta(T, Val{f}(), Val{$q}())
        @inline $name(x, ::Type{Val{F}}) where F = $FieldMeta._meta(typeof(x), Val{F}(), Val{$q}())
        @inline $name(::Type{T}, ::Type{Val{F}}) where {T,F} = $FieldMeta._meta(T, Val{F}(), Val{$q}())
        @inline $name(x) = $FieldMeta._allfields(typeof(x), Val{$q}())
        @inline $name(::Type{T}) where T = $FieldMeta._allfields(T, Val{$q}())
        macro $name(ex)
            $FieldMeta._stack(ex, $q, __source__)
        end
    end)
end


## Stackable per-key macro body and @fields multi-key macro.
function _process(ex, src::LineNumberNode, label::AbstractString, emit::Function)
    s = _find_struct(ex)
    s === nothing && error("$label: no struct found")
    typname = _typname(s.args[2])
    methods = Expr[]
    block_args = s.args[3].args
    for i in eachindex(block_args)
        slot = _meta_slot(block_args, i)
        slot === nothing && continue
        emit(methods, typname, slot...)
    end
    Expr(:block, src, esc(ex), methods...)
end

_stack(ex, key::Symbol, src::LineNumberNode) =
    _process(ex, src, "@$key", (methods, typname, args, idx, fname) -> begin
        val = _strip_leftmost!(args, idx)
        val === :_ || _emit!(methods, typname, fname, key, val)
    end)

"""
    @fields struct Foo
        a::Int        | (description="x", bounds=(0,10))
        b::Float64    | (description="y")
        c::String                                   # no metadata
    end

Single-shot multi-key form. Works with `Parameters.@with_kw` when stacked
inside: `@fields @with_kw struct ... end`.
"""
macro fields(ex)
    _process(ex, __source__, "@fields", (methods, typname, args, idx, fname) -> begin
        kws = args[idx].args[3]
        args[idx] = args[idx].args[2]
        (kws isa Expr && kws.head === :tuple) ||
            error("@fields: metadata must be `(k=v, ...)`, got `$kws`")
        for kw in kws.args
            (kw isa Expr && kw.head === :(=)) ||
                error("@fields: expected `k=v`, got `$kw`")
            _emit!(methods, typname, fname, kw.args[1], kw.args[2])
        end
    end)
end
