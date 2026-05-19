## Described
@fields struct Described
    a::Int | (description="an Int",)
    b | (description="an untyped field",)
    c::Float64 | (description="a Float64 field",)
end

@testset "single-key accessors" begin
    d = Described(1, 1.0, 2.0)
    @test description(d, :a) == "an Int"
    @test description(d, :b) == "an untyped field"
    @test description(d, :c) == "a Float64 field"
    @test description(Described, :a) == "an Int"
    @test description(d, Val{:a}) == "an Int"
    @test description(Described, Val{:c}) == "a Float64 field"
    @test description(d) == ("an Int", "an untyped field", "a Float64 field")
    @test description(Described) == ("an Int", "an untyped field", "a Float64 field")
end

@testset "default falls through for undeclared field" begin
    d = Described(1, 1.0, 2.0)
    @test description(d, :missing_field) == ""
    @test description(d, Val{:missing_field}) == ""
end

@testset "all accessors are inferable" begin
    d = Described(1, 1.0, 2.0)
    @inferred description(Described, Val{:a})
    @inferred description(d, Val{:a})
    @inferred description(d)
    @inferred description(Described)
end

## Multiple metadata keys in one @fields call (replaces stacked macros).
@fields struct Combined{T}
    a::T | (description="an a", bounds=(0, 100), units="kg")
    b::T | (description="a b", bounds=(2, 9))
    c::T                                                       # no metadata
end

@testset "multiple keys per field" begin
    c = Combined{Float64}(3.0, 5.0, 0.0)
    @test c.a == 3 && c.b == 5 && c.c == 0.0
    @test description(c, :a) == "an a"
    @test bounds(c, :a) == (0, 100)
    @test units(c, :a) == "kg"
    # missing metadata → registered defaults
    @test units(c, :b) == "-"
    @test description(c, :c) == ""
    @test bounds(c, :c) === nothing
end

@testset "all-fields tuple aggregation" begin
    c = Combined{Float64}(3.0, 5.0, 0.0)
    @test description(c) == ("an a", "a b", "")
    @test bounds(c) == ((0, 100), (2, 9), nothing)
    @test units(c) == ("kg", "-", "-")
end

# Generic `fieldmeta(T, field, key)` lookup.
@testset "fieldmeta generic API" begin
    c = Combined{Float64}(3.0, 5.0, 0.0)
    @test fieldmeta(c, :a, :description) == "an a"
    @test fieldmeta(Combined, :a, :bounds) == (0, 100)
    @test fieldmeta(c, :c, :description) == ""    # falls back to default
end

# Adding a new metadata key after the struct is defined still works
# (default fallback is decoupled from struct definition).
@testset "metadata declared after struct: returns default" begin
    c = Combined{Float64}(3.0, 5.0, 0.0)
    @test label(c, :a) == ""
    @test label(c) == ("", "", "")
end

## Type checking — wrong value type throws MetadataError on first access.
@fields struct WrongType
    a::Int | (description=:a_symbol_not_a_string,)
end

@testset "type check on metadata value" begin
    @test_throws MetadataError description(WrongType, :a)
    @test_throws MetadataError description(WrongType)
end
