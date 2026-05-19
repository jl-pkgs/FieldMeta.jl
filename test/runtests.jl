using FieldMeta, Test, Parameters
import FieldMeta: @metadata, @fields, MetadataError, fieldmeta

@metadata description "" String
@metadata units "-" String
@metadata bounds nothing Any
@metadata default nothing Any
@metadata label "" String

include("test-chain.jl")
include("test-fields.jl")
##
