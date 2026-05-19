module FieldMeta

export bounds, units, @bounds, @units

using DataFrames

include("metadata.jl")
include("ModelParam.jl")

@metadata bounds nothing Any
@metadata units "-" String


end # module
