using FieldMeta, Test, Parameters
import FieldMeta: @metadata, @fields, MetadataError, fieldmeta

@metadata description "" String
@metadata default nothing Any
@metadata label "" String

include("test-internals.jl")
include("test-chain.jl")
include("test-fields.jl")
##
include("Model_PML.jl")
include("Model_BEPS.jl")
include("Model_SoilDiffEqs.jl.jl")
