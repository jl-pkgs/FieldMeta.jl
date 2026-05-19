# Stacked per-key macros: @bounds @units @description struct ... end
# Reading order is left-to-right: the i-th macro consumes the i-th `|` value.
@bounds @units @description struct Stacked
    x::Float64 | (0.01, 0.5) | "m" | "x label"
    y::Float64 | (0.0, 1.0) | "kg" | "y label"
end

@testset "stacked per-key macros" begin
    s = Stacked(0.1, 0.5)
    @test bounds(s, :x) == (0.01, 0.5)
    @test units(s, :x) == "m"
    @test description(s, :x) == "x label"
    @test bounds(s) == ((0.01, 0.5), (0.0, 1.0))
    @test units(s) == ("m", "kg")
    @test description(s) == ("x label", "y label")
end

# `_` skips a key on a particular field, falling through to the default.
@bounds @units @description struct Skipped
    x::Float64 | (0.0, 1.0) | "m" | _
    y::Float64 | _ | _ | "y desc"
end

@testset "underscore skips one key per field" begin
    s = Skipped(0.0, 0.0)
    @test bounds(s, :x) == (0.0, 1.0)
    @test units(s, :x) == "m"
    @test description(s, :x) == ""           # default
    @test bounds(s, :y) === nothing     # default
    @test units(s, :y) == "-"          # default
    @test description(s, :y) == "y desc"
end

# Stacked + @with_kw.
@bounds @units @description @with_kw struct StackedKW{FT}
    x::FT = 0.35 | (0.01, 0.5) | "-" | "Muskingum x"
    dt::FT = 1.0 | _ | "h" | "time step"
end

@testset "stacked + @with_kw" begin
    m = StackedKW{Float64}()
    @test m.x == 0.35 && m.dt == 1.0
    @test bounds(m, :x) == (0.01, 0.5)
    @test bounds(m, :dt) === nothing
    @test units(m, :dt) == "h"
    @test description(m, :dt) == "time step"
    # keyword constructor preserved
    @test StackedKW{Float64}(x=0.42).x == 0.42
end


## Integration with Parameters.@with_kw: `@fields @with_kw struct ...`
# Wrap order is `@fields` OUTSIDE, `@with_kw` INSIDE — @fields strips the
# `| (...)` metadata first, leaving plain `a::T = default` for @with_kw.
@fields @with_kw struct Muskingum{FT}
    x::FT = 0.35 | (bounds=(0.01, 0.5), units="-", description="Muskingum x")
    dt::FT = 1.0 | (units="h", description="time step")
    C0::FT = FT(NaN)
    C1::FT = FT(NaN)
    C2::FT = FT(NaN)
end

@testset "Parameters.@with_kw integration" begin
    m = Muskingum{Float64}()
    @test m.x == 0.35
    @test m.dt == 1.0
    @test isnan(m.C0) && isnan(m.C1) && isnan(m.C2)

    # keyword constructor still works
    m2 = Muskingum{Float64}(x=0.42)
    @test m2.x == 0.42 && m2.dt == 1.0

    # metadata attached to fields with defaults
    @test bounds(m, :x) == (0.01, 0.5)
    @test units(m, :x) == "-"
    @test units(m, :dt) == "h"
    @test description(m, :x) == "Muskingum x"
    @test description(m, :dt) == "time step"
    # field without metadata falls through to defaults
    @test bounds(m, :C0) === nothing
    @test units(m, :C0) == "-"

    # all-fields tuple over the 5 fields
    @test bounds(m) == ((0.01, 0.5), nothing, nothing, nothing, nothing)
    @test units(m) == ("-", "h", "-", "-", "-")
end

##
@bounds @units @with_kw mutable struct Muskingum2{FT}
    x::FT = 0.35 | (0.01, 0.5) | "-"

    dt::FT = 1.0
    C0::FT = FT(NaN)
    C1::FT = FT(NaN)
    C2::FT = FT(NaN)
end

@testset "work with Parameter" begin
    x = Muskingum2{Float64}()
    @show x  # display struct in CI logs
    @test bounds(x) == ((0.01, 0.5), nothing, nothing, nothing, nothing)
    @test units(x) == ("-", "-", "-", "-", "-")
end
