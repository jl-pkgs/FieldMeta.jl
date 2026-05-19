export parameters, update!
export @make_layers_struct, AbstractLayers, Layers


abstract type AbstractLayers{FT,S} end
# abstract type AbstractModel{FT} end

macro make_layers_struct(sname, sname_new=nothing)
    isnothing(sname_new) && (sname_new = Symbol(sname, :Layers))

    stype = getfield(__module__, sname)
    names_list = collect(fieldnames(stype))
    types_list = fieldtypes(stype)

    x = stype{Float64}() # for default values
    values = map(fname -> getfield(x, fname), names_list)

    field_expressions = []
    # push!(field_expressions, :(ntime::Int = 100))
    for (i, fname) in enumerate(names_list)
        ftype = types_list[i]
        value = values[i]
        ftype <: AbstractVector && continue
        push!(field_expressions, :($fname::Vector{FT} = fill($value, N)))
    end

    quote
        @with_kw mutable struct $sname_new{FT,N} <: AbstractLayers{FT,$sname}
            $(field_expressions...)
        end
    end |> esc
end

@generated function Layers(p::P, N::Int) where {P}
    FT = Float64
    for ft in fieldtypes(P)
        ft <: AbstractFloat && (FT = ft; break)
    end
    LayersRef = GlobalRef(parentmodule(P), Symbol(nameof(P), :Layers))
    kwargs = [:($(f) = fill(p.$f, N)) for f in fieldnames(P)]
    quote
        $LayersRef{$FT,N}($(kwargs...))
    end
end

has_definedbounds(x) = false
has_definedbounds(x::AbstractLayers) = true

function get_params(x::T; path=[], with_unit=true) where {FT,S,T<:AbstractLayers{FT,S}}
    N = length(getfield(x, first(fieldnames(T))))
    res = map(fieldnames(T)) do field
        value = getfield(x, field)
        _path = [path..., field]
        bound = bounds(S, field)
        unit = with_unit ? units(S, field) : ""

        map(i -> (; path=[_path..., i], name=field,
                value=value[i], type=eltype(value), bound, unit), 1:N)
    end
    res = vcat(res...)
    filter(x -> !isnothing(x.bound), res)
end


# 检查某字段是否在父结构体上明确定义了 bound = nothing（即显式隐藏）
# 专属方法（_emit! 生成）的 sig[2] == Type{<:T}；按 key 默认 fallback 的 sig[2] == Type
function is_explicitly_hidden(T::Type, field)
    field isa Symbol || return false
    m = which(_meta, Tuple{Type{T}, Val{field}, Val{:bounds}})
    sig = Base.unwrap_unionall(m.sig)
    sig.parameters[2] !== Type && isnothing(_meta(T, Val{field}(), Val{:bounds}()))
end

# 把 bounds 分解成字段路径和对应的约束
function split_bounds(x::S) where {S}
    function categorize(field)
        is_explicitly_hidden(S, field) && return :skip
        value = getfield(x, field)
        T = typeof(value)
        # 不递归进 Array/Tuple 等内建类型，直接当普通字段处理（无 bound 则过滤掉）
        (T <: AbstractArray || T <: Tuple) && return :macro
        (has_definedbounds(value) || isstructtype(T)) ? :predef : :macro
    end
    fields = fieldnames(S)
    (
        filter(f -> categorize(f) == :predef, fields),
        filter(f -> categorize(f) == :macro, fields)
        # :skip 的字段完全略过
    )
end


function get_params(x::S; path=[], with_unit=true) where {S}
    fs_predef, fs_macro = split_bounds(x)

    res_predef = map(field -> begin
            value = getfield(x, field)
            get_params(value; path=[path..., field])
        end, fs_predef)

    res_macro = map(field -> begin
            # @show bounds(x, field)
            value = getfield(x, field)
            unit = with_unit ? units(S, field) : ""
            (; path=[path..., field], name=field,
                value, type=eltype(value), bound=bounds(x, field), unit)
        end, fs_macro)
    res = vcat(res_macro..., res_predef...)
    filter(x -> !isnothing(x.bound), res)
end


function update!(model::S, paths::Vector, values::Vector{FT}; params=nothing) where {S,FT}
    isnothing(params) && (params = parameters(model))

    for (path, value) in zip(paths, values)
        inds = findall(==(path), params.path)
        isempty(inds)    && error("Parameter path $(path) not found in model!")
        length(inds) > 1 && error("Duplicated parameters found for path $(path)!")
        update!(model, params.path[inds[1]], value; type=params.type[inds[1]])
    end
end

function update!(model::S, path::Vector, value::FT; type::Type) where {S,FT}
    if length(path) == 1
        # @show model, path[1], value
        setfield!(model, path[1], type(value))
    elseif length(path) > 1
        submodel = getfield(model, path[1]) # 

        if isa(submodel, Vector) # 如果是多模型
            models = submodel
            i = path[2]

            if typeof(models[i]) == FT
                models[i] = type(value)
                return
            end
            # 下面是应对Struct Vector
            update!(models[i], path[3:end], value; type)
        else
            update!(submodel, path[2:end], value; type)
        end
    end
end


function parameters(model; paths=nothing, with_unit=true)
    params = get_params(model; with_unit) |> DataFrame
    if !isnothing(paths)
        inds = indexin(paths, params.path)
        params = params[inds, :]
    end
    length(unique(params.unit)) == 1 && (params = params[:, Not(:unit)])
    return params
end

function get_opt_info(model; paths=nothing)
    df = parameters(model; paths)
    x0 = Float64.(df.value)
    lb = Float64[b[1] for b in df.bound]
    ub = Float64[b[2] for b in df.bound]
    paths = df.path
    return x0, lb, ub, paths
end

export get_params, parameters, update!
