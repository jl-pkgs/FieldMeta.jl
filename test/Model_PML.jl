# using ModelParams
# import ModelParams: bounds, units, @bounds, @units
using Parameters, Test

abstract type AbstractModel{FT} end

# 水分限制-GPP
abstract type AbstractWaterConsGPPModel{FT} <: AbstractModel{FT} end

# 光合
abstract type AbstractPhotosynthesisModel{FT} <: AbstractModel{FT} end


# 气孔导度
# abstract type AbstractStomatalModel{FT} <: AbstractModel{FT} end
@bounds @units @with_kw mutable struct β_GPP_Zhang2019{FT} <: AbstractWaterConsGPPModel{FT}
    ## water constraint
    "parameter to constrain `gc`"
    VPDmin::FT = 0.9 | (0.65, 1.5) | "kPa"

    "parameter to constrain `gc`"
    VPDmax::FT = 4.0 | (3.50, 6.5) | "kPa"
end


@bounds @units @with_kw mutable struct Photosynthesis_Rong2018{FT} <: AbstractPhotosynthesisModel{FT}
    "initial slope of the light response curve to assimilation rate, (i.e., quantum efficiency)"
    α::FT = 0.06 | (0.01, 0.10) | "μmol CO2 [μmol PAR]⁻¹"

    "initial slope of the CO2 response curve to assimilation rate, (i.e., carboxylation efficiency)"
    η::FT = 0.04 | (0.01, 0.07) | "μmol m⁻² s⁻¹ [μmol m⁻² s⁻¹]⁻¹"

    "carbon saturated rate of photosynthesis at 25 °C"
    VCmax25::FT = 50.00 | (5.00, 120.00) | "μmol m⁻² s⁻¹"

    "photoperiod constraint"
    d_pc::FT = 2.0 | (0.0, 5.0) | "-"

    "extinction coefficients for visible radiation" # 植被光合参数
    kQ::FT = 0.45 | (0.10, 1.0) | "-"

    watercons::AbstractWaterConsGPPModel{FT} = β_GPP_Zhang2019{FT}()
end

##
@testset "Model_PML" begin
    FT = Float64
    model = Photosynthesis_Rong2018{FT}()

    params = parameters(model)
    @test length(unique(params.unit)) == 5

    parnames = [:kQ, :VCmax25, :VPDmin]
    inds = indexin(parnames, params.name)
    paths = params.path[inds]

    parvalues = [0.6, 10., 0.8]
    @time update!(model, paths, parvalues; params)

    @test model.kQ == 0.6
    @test model.VCmax25 == 10.
    @test model.watercons.VPDmin == 0.8
end
