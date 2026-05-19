using FieldMeta, Parameters, DataFrames, Test

abstract type AbstractSoilParam{T<:Real} end


@bounds @units @with_kw mutable struct VanGenuchten{T<:Real} <: AbstractSoilParam{T}
    θ_sat::T = 0.287 | (0.25, 0.50) | "m3 m-3"   # [m3 m-3]
    θ_res::T = 0.075 | (0.03, 0.20) | "m3 m-3"     # [m3 m-3]
    Ksat::T = 34.0 | (0.002, 60.0) | "cm h-1"        # [cm h-1]
    α::T = 0.027 | (0.002, 0.300) | "cm-1"        # [cm-1]
    n::T = 3.96 | (1.05, 4.00) | "-"         # [-]
    m::T = 1.0 - 1.0 / n
end

@bounds @units @with_kw mutable struct Campbell{T<:Real} <: AbstractSoilParam{T}
    θ_sat::T = 0.287 | (0.25, 0.50) | "m3 m-3"
    ψ_sat::T = -10.0 | (-100.0, -5.0) | "cm"
    Ksat::T = 34.0 | (0.002, 100.0) | "cm h-1"
    b::T = 4.0 | (3.0, 15.0) | "-"
end

@make_layers_struct VanGenuchten
@make_layers_struct Campbell


@bounds @units @with_kw mutable struct ParamThermal{FT<:AbstractFloat}
    κ::FT = FT(0.2) | (0.1, 10.0) | "W m-1 K-1"     # thermal conductivity
    cv::FT = FT(2.0e6) | (1.0e6, 5.0e6) | "J m-3 K-1" # soil bulk density [kg m-3]
end

@make_layers_struct ParamThermal

const SoilHydraulic{FT,N} = Union{VanGenuchtenLayers{FT,N},CampbellLayers{FT,N}} where {FT<:AbstractFloat,N}

@bounds @with_kw mutable struct SoilModel{FT<:AbstractFloat}
    N::Int = 5
    hydraulic::SoilHydraulic{FT} = VanGenuchtenLayers{FT,N}()
    thermal::ParamThermalLayers{FT} = ParamThermalLayers{FT,N}()
    thermal_hide::ParamThermalLayers{FT} = ParamThermalLayers{FT,N}() | nothing
end

##
# FT = Float64
# N = 5
model = SoilModel{Float64}(; N=1)
model = SoilModel{Float64}(; N=5)
parameters(model)

##
# p = Campbell(; b=2.0)
# model = SoilModel(p, 4)
# parameters(model)
