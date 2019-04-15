"""
The `Functions` module provides types that represent decision variables and
functions of these decision variables that possess a certain structure,
such as being affine or quadratic in the decision variables.

Various operators are overloaded to make it easy to construct such functions.

# Example

```julia
julia> x, y = Variable.(1 : 2)
2-element Array{Parametron.Functions.Variable,1}:
 Parametron.Functions.Variable(1)
 Parametron.Functions.Variable(2)

julia> fun = 3 * (x + y) + 4
3 * x1 + 3 * x2 + 4

julia> typeof(fun)
Parametron.Functions.AffineFunction{Int64}

julia> fun.linear
2-element Array{Parametron.Functions.LinearTerm{Int64},1}:

 3 * x1
 3 * x2

julia> fun.constant
Base.RefValue{Int64}(4)
```

The `Functions` module also provides in-place versions of certain common operations, e.g.,
[`add!`](@ref), [`subtract!`](@ref), and [`vecdot!`](@ref), which may be used
to evaluate operations performed on the functions into a preallocated destination
without any heap allocations.
"""
module Functions

export
    Variable,
    LinearTerm,
    QuadraticTerm,
    AffineFunction,
    QuadraticFunction

export
    canonicalize,
    canonicalize!,
    prune_zero,
    prune_zero!

using LinearAlgebra
using DocStringExtensions

using Parametron: sort_and_combine!

coefftype(::Type{T}) where {T<:Number} = T


"""
$(SIGNATURES)

Re-express a term or function in a canonical form.
"""
function canonicalize end

"""
$(SIGNATURES)

In-place version of [`canonicalize`](@ref).
"""
function canonicalize! end

"""
$(METHODLIST)

Prune terms with (approximately) zero coefficients.
"""
function prune_zero end

"""
$(METHODLIST)

In-place version of [`prune_zero`](@ref).
"""
function prune_zero! end


# Variable

"""
$(TYPEDEF)

Represents a single decision variable.
"""
struct Variable
    index::Int
end
Base.hash(v::Variable, h::UInt) = hash(v.index, h)
coefftype(::Type{Variable}) = Int
Base.:+(var::Variable) = var

# LinearTerm, QuadraticTerm

"""
$(TYPEDEF)

Represents a scalar linear term, i.e. a decision variable scaled by a coefficient.
"""
struct LinearTerm{T}
    coeff::T
    var::Variable
end
LinearTerm{T}(var::Variable) where {T} = LinearTerm{T}(one(T), var)
LinearTerm{T}(x::LinearTerm{T}) where {T} = x
LinearTerm{T}(x::LinearTerm) where {T} = LinearTerm{T}(T(x.coeff), x.var)
Base.show(io::IO, term::LinearTerm) = print(io, term.coeff, " * ", "x", term.var.index)
getcoeff(term::LinearTerm) = term.coeff
setcoeff(term::LinearTerm, coeff) = LinearTerm(coeff, term.var)
Base.:*(coeff::Number, var::Variable) = LinearTerm(coeff, var)
Base.:*(var::Variable, coeff::Number) = LinearTerm(coeff, var)
Base.:-(var::Variable) = LinearTerm(-1, var)
Base.promote_rule(::Type{LinearTerm{T}}, ::Type{Variable}) where {T} = LinearTerm{T}
Base.convert(::Type{LinearTerm{T}}, var::Variable) where {T} = LinearTerm{T}(var)

function combine(t1::LinearTerm, t2::LinearTerm)
    t1.var === t2.var || throw(ArgumentError())
    LinearTerm(t1.coeff + t2.coeff, t1.var)
end

"""
$(TYPEDEF)

Represents a scalar quadratic term, i.e. the product of two decision variables scaled by a coefficient.
"""
struct QuadraticTerm{T}
    coeff::T
    rowvar::Variable
    colvar::Variable
end
QuadraticTerm{T}(x::QuadraticTerm{T}) where {T} = x
QuadraticTerm{T}(x::QuadraticTerm) where {T} = QuadraticTerm{T}(T(x.coeff), x.rowvar, x.colvar)
Base.show(io::IO, term::QuadraticTerm) = print(io, term.coeff, " * x", term.rowvar.index, " * x", term.colvar.index)
getcoeff(term::QuadraticTerm) = term.coeff
setcoeff(term::QuadraticTerm, coeff) = QuadraticTerm(coeff, term.rowvar, term.colvar)
Base.:*(x::Variable, y::LinearTerm) = QuadraticTerm(y.coeff, x, y.var)
Base.:*(y::LinearTerm, x::Variable) = QuadraticTerm(y.coeff, y.var, x)
Base.:*(x::Variable, y::Variable) = QuadraticTerm(1, x, y)
Base.:*(x::LinearTerm, y::LinearTerm) = QuadraticTerm(x.coeff * y.coeff, x.var, y.var)

for Term in [:LinearTerm, :QuadraticTerm]
    @eval begin
        Base.promote_rule(::Type{$Term{T1}}, ::Type{$Term{T2}}) where {T1, T2} = $Term{promote_type(T1, T2)}
        Base.convert(::Type{$Term{T}}, term::$Term{T}) where {T} = term
        Base.convert(::Type{$Term{T}}, term::$Term) where {T} = setcoeff(term, convert(T, getcoeff(term)))
        @inline coefftype(::Type{$Term{T}}) where {T} = T
        Base.:+(term::$Term) = term
        Base.:-(term::$Term) = setcoeff(term, -getcoeff(term))
        Base.:*(c::Number, term::$Term) = setcoeff(term, c * getcoeff(term))
        Base.:*(term::$Term, c::Number) = c * term
    end
end

"""
$(SIGNATURES)

Re-express the `QuadraticTerm` `term` so that the index of `term.rowvar` is
less than or equal to that of `term.colvar`.

# Example

```julia
julia> x, y = Variable.(1 : 2);

julia> term = 3 * y * x
3 * x2 * x1

julia> canonicalize(term)
3 * x1 * x2
```
"""
function canonicalize(term::QuadraticTerm)
    QuadraticTerm(term.coeff, Variable.(minmax(term.rowvar.index, term.colvar.index))...)
end

function combine(t1::QuadraticTerm, t2::QuadraticTerm)
    t1 = canonicalize(t1)
    t2 = canonicalize(t2)
    t1.rowvar == t2.rowvar && t1.colvar == t2.colvar || throw(ArgumentError())
    QuadraticTerm(t1.coeff + t2.coeff, t1.rowvar, t1.colvar)
end


# AffineFunction
"""
$(TYPEDEF)

A scalar affine function represented by a sum of [`LinearTerm`](@ref)s and a constant.

`AffineFunction` overloads the call operator, which can be used to evalute the function
given values for the decision variables. The call operator takes an `AbstractDict{Variable, T}`
collection, which associates values with variables.

# Example

```julia
julia> x, y = Variable.(1 : 2);

julia> affinefun = 2 * x + 3 * y + 4
2 * x1 + 3 * x2 + 4

julia> vals = Dict(x => 4, y => -3);

julia> affinefun(vals)
3
```
"""
struct AffineFunction{T}
    linear::Vector{LinearTerm{T}}
    constant::Base.RefValue{T}
end

AffineFunction{T}(linear::Vector{<:LinearTerm}, constant::Number) where {T} =
    AffineFunction{T}(copyto!(Vector{LinearTerm{T}}(undef, length(linear)), linear), Ref(T(constant)))
AffineFunction(linear::Vector{LinearTerm{T}}, constant::S) where {T, S<:Number} =
    AffineFunction{promote_type(T, S)}(linear, constant)

AffineFunction{T}(x::AffineFunction) where {T} = AffineFunction{T}(x.linear, x.constant[])
AffineFunction{T}(x::LinearTerm) where {T} = AffineFunction{T}([LinearTerm{T}(x)], zero(T))
AffineFunction{T}(x::Variable) where {T} = AffineFunction{T}(LinearTerm{T}(x))
AffineFunction{T}(x::Number) where {T} = AffineFunction{T}(LinearTerm{T}[], T(x))

AffineFunction(x::AffineFunction{T}) where {T} = AffineFunction{T}(x)
AffineFunction(x::LinearTerm{T}) where {T} = AffineFunction{T}(x)
AffineFunction(x::T) where {T<:Number} = AffineFunction{T}(x)

coefftype(::Type{AffineFunction{T}}) where {T} = T

Base.:(==)(x::AffineFunction, y::AffineFunction) = x.linear == y.linear && x.constant[] == y.constant[]
Base.isequal(x::AffineFunction, y::AffineFunction) = isequal(x.linear, y.linear) && isequal(x.constant[], y.constant[])
Base.hash(x::AffineFunction, h::UInt) = (h = hash(x.linear, h); hash(x.constant, h))

Base.zero(::Type{AffineFunction{T}}) where {T} = AffineFunction(LinearTerm{T}[], Ref(zero(T)))
zero!(f::AffineFunction) = (empty!(f.linear); f.constant[] = 0; f)

Base.convert(::Type{AffineFunction{T}}, x::AffineFunction{T}) where {T} = x
Base.convert(::Type{AffineFunction{T}}, x::AffineFunction) where {T} = AffineFunction{T}(x)
Base.convert(::Type{AffineFunction{T}}, x::Number) where {T} = AffineFunction(LinearTerm{T}[], convert(T, x))
Base.convert(::Type{AffineFunction{T}}, x::LinearTerm) where {T} = AffineFunction([convert(LinearTerm{T}, x)], zero(T))
Base.convert(::Type{AffineFunction{T}}, x::Variable) where {T} = AffineFunction{T}(x)

function Base.show(io::IO, f::AffineFunction)
    for term in f.linear
        print(io, term, " + ")
    end
    print(io, f.constant[])
end

function (f::AffineFunction{T})(vals::AbstractDict{Variable, S}) where {T, S}
    R′ = Base.promote_op(*, T, S)
    R = Base.promote_op(+, R′, R′)
    ret = convert(R, f.constant[])
    for term in f.linear
        ret += term.coeff * vals[term.var]
    end
    ret
end

function canonicalize!(f::AffineFunction)
    sort_and_combine!(f.linear; by=term -> term.var.index, combine=combine, alg=Base.Sort.QuickSort)
    f
end

"""
$(SIGNATURES)

Return a canonicalized version of `f::AffineFunction`, namely with linear terms
sorted by variable index and with terms corresponding to the same variable combined.

# Example

```julia
julia> x, y = Variable.(1 : 2);

julia> f = y + x - 2 * y + 3
1 * x2 + 1 * x1 + -2 * x2 + 3

julia> canonicalize(f)
1 * x1 + -1 * x2 + 3
```
"""
canonicalize(f::AffineFunction) = canonicalize!(AffineFunction(f))

function prune_zero!(f::AffineFunction{T}; atol=zero(T)) where T
    filter!(term -> abs(getcoeff(term)) > atol, f.linear)
    f
end

prune_zero(f::AffineFunction; kwargs...) = prune_zero!(AffineFunction(f); kwargs...)

# QuadraticFunction

"""
$(TYPEDEF)

A scalar quadratic function represented by a sum of [`QuadraticTerm`](@ref)s and an [`AffineFunction`](@ref).

`QuadraticFunction` overloads the call operator, which can be used to evalute the function
given values for the decision variables. The call operator takes an `AbstractDict{Variable, T}`
collection, which associates values with variables.

# Examples

```julia
julia> x, y = Variable.(1 : 2);

julia> quadraticfun = 2 * x^2 + 3 * x * y - 2 * y + 4
2 * x1 * x1 + 3 * x1 * x2 + -2 * x2 + 4

julia> vals = Dict(x => 4, y => -3);

julia> quadraticfun(vals)
6
```
"""
struct QuadraticFunction{T}
    quadratic::Vector{QuadraticTerm{T}}
    affine::AffineFunction{T}
end

QuadraticFunction(quadratic::Vector{QuadraticTerm{T}}, affine::AffineFunction{S}) where {T, S} =
    QuadraticFunction{promote_type(T, S)}(quadratic, affine)

QuadraticFunction{T}(x::QuadraticFunction) where {T} =
    QuadraticFunction{T}(copyto!(Vector{QuadraticTerm{T}}(undef, length(x.quadratic)), x.quadratic), AffineFunction{T}(x.affine))
QuadraticFunction{T}(x::AffineFunction) where {T} = QuadraticFunction{T}(QuadraticTerm{T}[], AffineFunction{T}(x))
QuadraticFunction{T}(x::QuadraticTerm) where {T} = QuadraticFunction([QuadraticTerm{T}(x)], zero(AffineFunction{T}))
QuadraticFunction{T}(x::LinearTerm) where {T} = QuadraticFunction{T}(QuadraticTerm{T}[], AffineFunction{T}(x))
QuadraticFunction{T}(x::Variable) where {T} = QuadraticFunction(AffineFunction{T}(x))
QuadraticFunction{T}(x::Number) where {T} = QuadraticFunction{T}(AffineFunction{T}(x))

QuadraticFunction(x::QuadraticFunction{T}) where {T} = QuadraticFunction{T}(x)
QuadraticFunction(x::AffineFunction{T}) where {T} = QuadraticFunction(QuadraticTerm{T}[], x)
QuadraticFunction(x::QuadraticTerm{T}) where {T} = QuadraticFunction([x], zero(AffineFunction{T}))
QuadraticFunction(x::LinearTerm{T}) where {T<:Number} = QuadraticFunction(QuadraticTerm{T}[], AffineFunction{T}(x))
QuadraticFunction(x::T) where {T<:Number} = QuadraticFunction(QuadraticTerm{T}[], AffineFunction{T}(x))

coefftype(::Type{QuadraticFunction{T}}) where {T} = T

Base.:(==)(x::QuadraticFunction, y::QuadraticFunction) = x.quadratic == y.quadratic && x.affine == y.affine
Base.isequal(x::QuadraticFunction, y::QuadraticFunction) = isequal(x.quadratic, y.quadratic) && isequal(x.affine, y.affine)
Base.hash(x::QuadraticFunction, h::UInt) = (h = hash(x.quadratic, h); hash(x.affine, h))

Base.zero(::Type{QuadraticFunction{T}}) where {T} = QuadraticFunction(QuadraticTerm{T}[], zero(AffineFunction{T}))
zero!(f::QuadraticFunction) = (empty!(f.quadratic); zero!(f.affine); f)

Base.convert(::Type{QuadraticFunction{T}}, x::QuadraticFunction{T}) where {T} = x
Base.convert(::Type{QuadraticFunction{T}}, x::QuadraticFunction) where {T} = QuadraticFunction{T}(x)
Base.convert(::Type{QuadraticFunction{T}}, x::QuadraticTerm) where {T} =
    QuadraticFunction([convert(QuadraticTerm{T}, x)], zero(AffineFunction{T}))
Base.convert(::Type{QuadraticFunction{T}}, x::AffineFunction) where {T} = QuadraticFunction{T}(x)
Base.convert(::Type{QuadraticFunction{T}}, x::Number) where {T} = QuadraticFunction{T}(x)
Base.convert(::Type{QuadraticFunction{T}}, x::LinearTerm) where {T} = QuadraticFunction{T}(x)
Base.convert(::Type{QuadraticFunction{T}}, x::Variable) where {T} = QuadraticFunction{T}(x)

function Base.show(io::IO, f::QuadraticFunction)
    for term in f.quadratic
        print(io, term, " + ")
    end
    print(io, f.affine)
end

function (f::QuadraticFunction{T})(vals::AbstractDict{Variable, S}) where {T, S}
    ret = f.affine(vals)
    for term in f.quadratic
        ret += term.coeff * vals[term.rowvar] * vals[term.colvar]
    end
    ret
end

function canonicalize!(f::QuadraticFunction)
    canonicalize!(f.affine)
    canonicalized_variable_index_tuple = term -> (term = canonicalize(term); (term.rowvar.index, term.colvar.index))
    sort_and_combine!(f.quadratic; by=canonicalized_variable_index_tuple, combine=combine, alg=Base.Sort.QuickSort)
    f
end

"""
$(SIGNATURES)

Return a canonicalized version of `f::QuadraticFunction`. See [`canonicalize(f::QuadraticTerm)`](@ref)
and [`canonicalize(f::AffineFunction)`](@ref) for more details. Quadratic terms are ordered lexicographically
by `(term.rowvar, term.colvar)`.

# Example

```julia
julia> x, y = Variable.(1 : 2);

julia> f = x * y + y * x + y + y + x - y
1 * x1 * x2 + 1 * x2 * x1 + 1 * x2 + 1 * x2 + 1 * x1 + -1 * x2 + 0

julia> canonicalize(f)
2 * x1 * x2 + 1 * x1 + 1 * x2 + 0
```
"""
canonicalize(f::QuadraticFunction) = canonicalize!(QuadraticFunction(f))

function prune_zero!(f::QuadraticFunction{T}; atol=zero(T)) where T
    prune_zero!(f.affine)
    filter!(term -> abs(getcoeff(term)) > atol, f.quadratic)
    f
end

prune_zero(f::QuadraticFunction; kwargs...) = prune_zero!(QuadraticFunction(f); kwargs...)


# copyto!
Base.copyto!(f::AffineFunction, x::Number) = (zero!(f); f.constant[] = x; f)
Base.copyto!(f::AffineFunction, x::LinearTerm) = (zero!(f); push!(f.linear, x); f)
Base.copyto!(f::AffineFunction{T}, x::Variable) where {T} = copyto!(f, LinearTerm{T}(x))
function Base.copyto!(f::AffineFunction, x::AffineFunction)
    resize!(f.linear, length(x.linear))
    copyto!(f.linear, x.linear)
    f.constant[] = x.constant[]
    f
end
function Base.copyto!(f::QuadraticFunction, x::Union{<:Number, <:LinearTerm, Variable, <:AffineFunction})
     empty!(f.quadratic)
     copyto!(f.affine, x)
     f
end
Base.copyto!(f::QuadraticFunction, x::QuadraticTerm) = (zero!(f); push!(f.quadratic, x); f)
function Base.copyto!(f::QuadraticFunction, x::QuadraticFunction)
    resize!(f.quadratic, length(x.quadratic))
    copyto!(f.quadratic, x.quadratic)
    copyto!(f.affine, x.affine)
    f
end


# add!
"""
$(SIGNATURES)

Add `x` to `f`, modifying `f`.

$(METHODLIST)
"""
function add! end

add!(f::AffineFunction, x::Number) = (f.constant[] += x; f)
add!(f::AffineFunction{T}, x::Variable) where {T} = add!(f, LinearTerm{T}(x))
add!(f::AffineFunction, x::LinearTerm) = (push!(f.linear, x); f)
add!(f::AffineFunction, x::AffineFunction) = (append!(f.linear, x.linear); f.constant[] += x.constant[]; f)

add!(f::QuadraticFunction, x::Union{<:Number, <:LinearTerm, Variable, <:AffineFunction}) = (add!(f.affine, x); f)
add!(f::QuadraticFunction, x::QuadraticTerm) = (push!(f.quadratic, x); f)
add!(f::QuadraticFunction, x::QuadraticFunction) = (append!(f.quadratic, x.quadratic); add!(f.affine, x.affine); f)

add!(dest, x, y) = (copyto!(dest, x); add!(dest, y); dest)


# subtract!
"""
$(SIGNATURES)

Subtract `x` from `f`, modifying `f`.

$(METHODLIST)
"""
function subtract! end

subtract!(f::AffineFunction, x::Number) = (f.constant[] -= x; f)
subtract!(f::AffineFunction{T}, x::Variable) where {T} = subtract!(f, LinearTerm{T}(x))
subtract!(f::AffineFunction, x::LinearTerm) = add!(f, -x)
function subtract!(f::AffineFunction, x::AffineFunction)
    offset = length(f.linear)
    resize!(f.linear, offset + length(x.linear))
    @inbounds for i in eachindex(x.linear)
        f.linear[offset + i] = -x.linear[i]
    end
    f.constant[] -= x.constant[]
    f
end

subtract!(f::QuadraticFunction, x::Number) = (subtract!(f.affine, x); f)
subtract!(f::QuadraticFunction, x::LinearTerm) = (subtract!(f.affine, x); f)
subtract!(f::QuadraticFunction, x::Variable) = (subtract!(f.affine, x); f)
subtract!(f::QuadraticFunction, x::AffineFunction) = (subtract!(f.affine, x); f)
subtract!(f::QuadraticFunction, x::QuadraticTerm) = add!(f, -x)
function subtract!(f::QuadraticFunction, x::QuadraticFunction)
    offset = length(f.quadratic)
    resize!(f.quadratic, offset + length(x.quadratic))
    @inbounds for i in eachindex(x.quadratic)
        f.quadratic[offset + i] = -x.quadratic[i]
    end
    subtract!(f.affine, x.affine)
    f
end

subtract!(dest, x, y) = (copyto!(dest, x); subtract!(dest, y); dest)


# muladd!
"""
$(SIGNATURES)

Multiply `x` by `y` and add the result to `dest`.

$(METHODLIST)
"""
function muladd! end

function muladd!(dest::AffineFunction, x::AffineFunction, y::Number)
    offset = length(dest.linear)
    resize!(dest.linear, offset + length(x.linear))
    @inbounds for i in eachindex(x.linear)
        dest.linear[offset + i] = x.linear[i] * y
    end
    dest.constant[] += x.constant[] * y
    dest
end
muladd!(dest::AffineFunction, x::Number, y::AffineFunction) = muladd!(dest, y, x)

function muladd!(dest::QuadraticFunction, x::QuadraticFunction, y::Number)
    offset = length(dest.quadratic)
    resize!(dest.quadratic, offset + length(x.quadratic))
    @inbounds for i in eachindex(x.quadratic)
        dest.quadratic[offset + i] = x.quadratic[i] * y
    end
    muladd!(dest.affine, x.affine, y)
    dest
end
muladd!(dest::QuadraticFunction, x::Number, y::QuadraticFunction) = muladd!(dest, y, x)

function muladd!(dest::QuadraticFunction, x::AffineFunction, y::Union{Variable, <:LinearTerm})
    offset = length(dest.quadratic)
    resize!(dest.quadratic, offset + length(x.linear))
    @inbounds for i in eachindex(x.linear)
        dest.quadratic[offset + i] = x.linear[i] * y
    end
    add!(dest.affine, x.constant[] * y)
    dest
end
muladd!(dest::QuadraticFunction, x::Union{Variable, <:LinearTerm}, y::AffineFunction) = muladd!(dest, y, x)

function muladd!(dest::QuadraticFunction, x::AffineFunction, y::AffineFunction)
    xlinear = x.linear
    ylinear = y.linear
    quadoffset = length(dest.quadratic)
    resize!(dest.quadratic, quadoffset + length(xlinear) * length(ylinear))
    k = 1
    @inbounds for i in eachindex(xlinear)
        for j in eachindex(ylinear)
            dest.quadratic[quadoffset + k] = xlinear[i] * ylinear[j]
            k += 1
        end
    end
    destaffine = dest.affine
    xconst = x.constant[]
    yconst = y.constant[]
    linoffset = length(destaffine.linear)
    resize!(destaffine.linear, linoffset + length(xlinear) + length(ylinear))
    k = linoffset + 1
    @inbounds for i in eachindex(xlinear)
        destaffine.linear[k] = xlinear[i] * yconst
        k += 1
    end
    @inbounds for i in eachindex(ylinear)
        destaffine.linear[k] = ylinear[i] * xconst
        k += 1
    end
    destaffine.constant[] += xconst * yconst
    dest
end

mul!(dest::Union{<:AffineFunction, <:QuadraticFunction}, x, y) = (zero!(dest); muladd!(dest, x, y))

# Operators
for (op, fun!) in [(:+, add!), (:-, subtract!)]
    @eval begin
        Base.$op(x::LinearTerm{T}, y::LinearTerm{T}) where {T} = AffineFunction{T}([x, $op(y)], zero(T))
        Base.$op(x::LinearTerm, y::LinearTerm) = +(promote(x, y)...)
        Base.$op(x::Variable, y::Variable) = $op(LinearTerm{Int}(x), LinearTerm{Int}(y))
        Base.$op(x::LinearTerm, y::Number) = AffineFunction([x], $op(y))
        Base.$op(x::Number, y::LinearTerm) = AffineFunction([$op(y)], x)
        Base.$op(x::Variable, y::T) where {T<:Number} = $op(LinearTerm{T}(x), y)
        Base.$op(x::T, y::Variable) where {T<:Number} = $op(x, LinearTerm{T}(y))
        Base.$op(x::LinearTerm{T}, y::Variable) where T = $op(x, LinearTerm{T}(y))
        Base.$op(x::Variable, y::LinearTerm{T}) where T = $op(LinearTerm{T}(x), y)
        Base.$op(x::AffineFunction{T}, y::AffineFunction{S}) where {T, S} =
            $fun!(AffineFunction{promote_type(T, S)}(x), y)
        Base.$op(x::AffineFunction{T}, y::S) where {T, S<:Union{Number, Variable, LinearTerm}} =
            $fun!(AffineFunction{promote_type(T, coefftype(S))}(x), y)
        Base.$op(x::T, y::AffineFunction{S}) where {T<:Union{Number, Variable, LinearTerm}, S} =
            $fun!(AffineFunction{promote_type(coefftype(T), S)}(x), y)

        Base.$op(x::QuadraticTerm{T}, y::QuadraticTerm{T}) where {T} = QuadraticFunction([x, $op(y)], zero(AffineFunction{T}))
        Base.$op(x::QuadraticTerm, y::QuadraticTerm) = +(promote(x, y)...)
        Base.$op(x::QuadraticTerm{T}, y::LinearTerm{T}) where {T} = $fun!(QuadraticFunction(x), y)
        Base.$op(x::QuadraticTerm{T}, y::S) where {T, S<:Number} = $fun!(QuadraticFunction{promote_type(T, S)}(x), y)
        Base.$op(x::S, y::QuadraticTerm{T}) where {T, S<:Number} = $fun!(QuadraticFunction{promote_type(T, S)}(x), y)
        Base.$op(x::LinearTerm{T}, y::QuadraticTerm{T}) where {T} = $fun!(QuadraticFunction(x), y)
        Base.$op(x::LinearTerm{T}, y::QuadraticTerm{S}) where {T, S} = (R = promote_type(T, S); $op(LinearTerm{R}(x), QuadraticTerm{R}(y)))
        Base.$op(x::QuadraticTerm{T}, y::LinearTerm{S}) where {T, S} = (R = promote_type(T, S); $op(QuadraticTerm{R}(x), LinearTerm{R}(y)))
        Base.$op(x::QuadraticTerm{T}, y::Variable) where {T} = $op(x, LinearTerm{T}(y))
        Base.$op(x::Variable, y::QuadraticTerm{T}) where {T} = $op(LinearTerm{T}(x), y)
        Base.$op(x::QuadraticFunction{T}, y::QuadraticFunction{S}) where {T, S} =
            $fun!(QuadraticFunction{promote_type(T, S)}(x), y)
        Base.$op(x::QuadraticFunction{T}, y::S) where {T, S<:Union{Number, Variable, LinearTerm, QuadraticTerm, AffineFunction}} =
            $fun!(QuadraticFunction{promote_type(T, coefftype(S))}(x), y)
        Base.$op(x::T, y::QuadraticFunction{S}) where {T<:Union{Number, Variable, LinearTerm, QuadraticTerm, AffineFunction}, S} =
            $fun!(QuadraticFunction{promote_type(coefftype(T), S)}(x), y)
    end
end

Base.:*(x::AffineFunction{T}, y::Variable) where {T} = muladd!(zero(QuadraticFunction{T}), x, y)
Base.:*(x::Variable, y::AffineFunction{T}) where {T} = muladd!(zero(QuadraticFunction{T}), x, y)
Base.:*(x::AffineFunction{T}, y::Union{LinearTerm{S}, AffineFunction{S}}) where {T, S} = muladd!(zero(QuadraticFunction{promote_type(T, S)}), x, y)
Base.:*(x::Union{LinearTerm{S}, AffineFunction{S}}, y::AffineFunction{T}) where {T, S} = muladd!(zero(QuadraticFunction{promote_type(T, S)}), x, y)
Base.:*(x::AffineFunction{T}, y::AffineFunction{S}) where {T, S} = muladd!(zero(QuadraticFunction{promote_type(T, S)}), x, y)
Base.:*(x::AffineFunction{T}, y::S) where {T, S<:Number} = muladd!(zero(AffineFunction{promote_type(T, S)}), x, y)
Base.:*(x::S, y::AffineFunction{T}) where {T, S<:Number} = muladd!(zero(AffineFunction{promote_type(T, S)}), x, y)
Base.:*(x::QuadraticFunction{T}, y::S) where {T, S<:Number} = muladd!(zero(QuadraticFunction{promote_type(T, S)}), x, y)
Base.:*(x::S, y::QuadraticFunction{T}) where {T, S<:Number} = muladd!(zero(QuadraticFunction{promote_type(T, S)}), x, y)

Base.:^(x::Variable, p::Integer) = Base.power_by_squaring(x, p)
Base.:^(x::LinearTerm, p::Integer) = Base.power_by_squaring(x, p)
Base.:^(x::AffineFunction, p::Integer) = Base.power_by_squaring(x, p)


# Number-like interface
const ParametronFunctions = Union{Variable, <:LinearTerm, <:QuadraticTerm, <:AffineFunction, <:QuadraticFunction}
Base.transpose(x::ParametronFunctions) = x
LinearAlgebra.dot(x::ParametronFunctions, y::ParametronFunctions) = x * y
LinearAlgebra.dot(x::ParametronFunctions, y::Number) = x * y
LinearAlgebra.dot(x::Number, y::ParametronFunctions) = x * y
Base.to_power_type(x::ParametronFunctions) = x # TODO: remove once https://github.com/JuliaLang/julia/issues/24151 is fixed
Base.zero(::T) where {T<:ParametronFunctions} = zero(T)
Base.one(::T) where {T<:ParametronFunctions} = one(T)
Base.adjoint(x::ParametronFunctions) = x
Base.broadcastable(x::ParametronFunctions) = Ref(x)
Base.conj(x::ParametronFunctions) = x


# Array operations
Base.:*(x::ParametronFunctions, y::AbstractArray) = broadcast(*, x, y)
Base.:*(x::AbstractArray, y::ParametronFunctions) = broadcast(*, x, y)

# TODO: reduce code duplication

"""
$(SIGNATURES)

Take the dot product of vectors `x` and `y`, storing the result in `dest`.

$(METHODLIST)
"""
function vecdot! end

function _vecdot!(dest::AffineFunction,
        x::AbstractArray{<:Union{Number, AffineFunction}},
        y::AbstractArray{<:Union{Number, AffineFunction}})
    zero!(dest)
    @boundscheck axes(x) == axes(y) || throw(DimensionMismatch())
    @inbounds for i in eachindex(x)
        muladd!(dest, x[i], y[i])
    end
    dest
end

function _vecdot!(dest::AffineFunction,
        x::AbstractArray{<:Union{Number, Variable, LinearTerm}},
        y::AbstractArray{<:Union{Number, Variable, LinearTerm}})
    zero!(dest)
    @boundscheck axes(x) == axes(y) || throw(DimensionMismatch())
    linear = dest.linear
    resize!(linear, length(x))
    @inbounds for i in eachindex(x)
        linear[i] = x[i] * y[i]
    end
    dest
end

function _vecdot!(dest::QuadraticFunction,
        x::AbstractVector{<:Union{<:Number, Variable, <:LinearTerm, <:QuadraticTerm}},
        y::AbstractVector{<:Union{<:Number, Variable, <:LinearTerm, <:QuadraticTerm}})
    zero!(dest)
    @boundscheck length(x) == length(y) || throw(DimensionMismatch())
    quadratic = dest.quadratic
    resize!(quadratic, length(x))
    @inbounds for i in eachindex(x)
        quadratic[i] = x[i] * y[i]
    end
    dest
end

function _vecdot!(dest::QuadraticFunction, x::AbstractVector, y::AbstractVector)
    zero!(dest)
    @boundscheck length(x) == length(y) || throw(DimensionMismatch())
    for i in eachindex(x)
        muladd!(dest, x[i], y[i])
    end
    dest
end

function vecdot!(dest, x, y)
    # generic fallback
    dot(x, y)
end

vecdot!(dest::AffineFunction, x::AbstractArray{<:Number}, y::AbstractArray{<:Union{Variable, LinearTerm, AffineFunction}}) =
    _vecdot!(dest, x, y)
vecdot!(dest::AffineFunction, x::AbstractArray{<:Union{Variable, LinearTerm, AffineFunction}}, y::AbstractArray{<:Number}) =
    _vecdot!(dest, x, y)
vecdot!(dest::QuadraticFunction, x::AbstractVector{<:Union{Variable, LinearTerm}}, y::AbstractVector{<:Union{Variable, LinearTerm}}) =
    _vecdot!(dest, x, y)
vecdot!(dest::QuadraticFunction, x::AbstractVector{<:Number}, y::AbstractVector{<:QuadraticTerm}) =
    _vecdot!(dest, x, y)
vecdot!(dest::QuadraticFunction, x::AbstractVector{<:QuadraticTerm}, y::AbstractVector{<:Number}) =
    _vecdot!(dest, x, y)
vecdot!(dest::QuadraticFunction, x::AbstractVector{<:AffineFunction}, y::AbstractVector{<:Union{Variable, <:LinearTerm}}) =
    _vecdot!(dest, x, y)
vecdot!(dest::QuadraticFunction, x::AbstractVector{<:Union{Variable, <:LinearTerm}}, y::AbstractVector{<:AffineFunction}) =
    _vecdot!(dest, x, y)
vecdot!(dest::QuadraticFunction, x::AbstractVector{<:AffineFunction}, y::AbstractVector{<:AffineFunction}) =
    _vecdot!(dest, x, y)

"""
$(SIGNATURES)

Add vector `x` to vector `y`, storing the result in `dest`.

$(METHODLIST)
"""
function vecadd! end

"""
$(SIGNATURES)

Subtract vector `y` from vector `x`, storing the result in `dest`.

$(METHODLIST)
"""
function vecsubtract! end

for (vecfun!, scalarfun!) in [(:vecadd!, :add!), (:vecsubtract!, :subtract!)]
    @eval begin
        function $vecfun!(dest::AbstractVector{AffineFunction{T}}, x::AbstractVector, y::AbstractVector) where T
            n = length(x)
            @boundscheck n == length(y) || throw(DimensionMismatch())
            length(dest) == n || resize!(dest, n)
            @inbounds for i in eachindex(dest)
                zero!(dest[i])
                $scalarfun!(dest[i], x[i], y[i])
            end
            dest
        end
    end
end

"""
$(SIGNATURES)

Compute the matrix-vector product `A * x`, storing the result in `y`.

$(METHODLIST)
"""
function matvecmul! end

function matvecmul!(
        y::AbstractVector{AffineFunction{T}},
        A::AbstractMatrix{T},
        x::AbstractVector{Variable}) where T
    rows, cols = size(A)
    @boundscheck length(y) == rows || throw(DimensionMismatch())
    @boundscheck length(x) == cols || throw(DimensionMismatch())
    @inbounds for row in eachindex(y)
        if isassigned(y, row)
            zero!(y[row])
        else
            y[row] = zero(AffineFunction{T})
        end
        resize!(y[row].linear, cols)
    end
    i = 1
    @inbounds for col in Base.OneTo(cols)
        for row in Base.OneTo(rows)
            y[row].linear[col] = A[i] * x[col]
            i += 1
        end
    end
    y
end

function matvecmul!(
    y::AbstractVector{AffineFunction{T}},
    A::AbstractMatrix{<:Number},
    x::AbstractVector{<:AffineFunction}) where T
    rows, cols = size(A)
    @boundscheck length(y) == rows || throw(DimensionMismatch())
    @boundscheck length(x) == cols || throw(DimensionMismatch())
    @inbounds for row in eachindex(y)
        if isassigned(y, row)
            zero!(y[row])
        else
            y[row] = zero(AffineFunction{T})
        end
    end
    i = 1
    @inbounds for col in Base.OneTo(cols)
        for row in Base.OneTo(rows)
            muladd!(y[row], A[i], x[col])
            i += 1
        end
    end
    y
end

function matvecmul!(
        dest::Union{AffineFunction, QuadraticFunction},
        x::Union{Transpose{<:Any, <:AbstractVector}, Adjoint{<:Any, <:AbstractVector}},
        y::AbstractVector)
    vecdot!(dest, parent(x), y)
end

"""
$(SIGNATURES)

Compute the bilinear form `transpose(x) * A * y`, storing the result in `dest`.

$(METHODLIST)
"""
function bilinearmul! end

function bilinearmul!(
        dest::QuadraticFunction,
        Q::AbstractMatrix,
        x::Union{Transpose{Variable, <:AbstractVector{Variable}}, Adjoint{Variable, <:AbstractVector{Variable}}},
        y::AbstractVector{Variable})
    @boundscheck size(Q) == (length(x), length(y)) || throw(DimensionMismatch())
    zero!(dest)
    quadratic = dest.quadratic
    resize!(quadratic, length(Q))
    k = 1
    @inbounds for row in eachindex(x)
        xrow = x[row]
        for col in eachindex(y)
            quadratic[k] = QuadraticTerm(Q[k], xrow, y[col])
            k += 1
        end
    end
    dest
end

function Base.:*(A::StridedMatrix{T}, x::StridedVector{Variable}) where {T<:LinearAlgebra.BlasFloat}
    matvecmul!(similar(x, AffineFunction{T}, size(A, 1)) , A, x)
end

"""
$(SIGNATURES)

Scale a vector by a number and store the result in `dest`.

$(METHODLIST)
"""
function scale! end

function scale!(
        dest::AbstractVector{<:LinearTerm},
        x::Number,
        y::AbstractVector{Variable})
    @boundscheck axes(dest) == axes(y) || throw(DimensionMismatch())
    @inbounds for i in eachindex(dest)
        dest[i] = x * y[i]
    end
    dest
end

function scale!(
        dest::AbstractVector{<:LinearTerm},
        x::AbstractVector{Variable},
        y::Number)
    @boundscheck axes(dest) == axes(x) || throw(DimensionMismatch())
    @inbounds for i in eachindex(dest)
        dest[i] = x[i] * y
    end
    dest
end

function scale!(
        dest::AbstractVector{<:AffineFunction},
        x::Number,
        y::AbstractVector{<:AffineFunction})
    @boundscheck axes(dest) == axes(y) || throw(DimensionMismatch())
    @inbounds for i in eachindex(dest)
        mul!(dest[i], x, y[i])
    end
    dest
end

function scale!(
        dest::AbstractVector{<:AffineFunction},
        x::AbstractVector{<:AffineFunction},
        y::Number)
    @boundscheck axes(dest) == axes(x) || throw(DimensionMismatch())
    @inbounds for i in eachindex(dest)
        mul!(dest[i], x[i], y)
    end
    dest
end

function scale!(dest::AbstractArray{<:Number}, x::AbstractArray{<:Number}, y::Number)
    dest .= x .* y
    dest
end

function scale!(dest::AbstractArray{<:Number}, x::Number, y::AbstractArray{<:Number})
    dest .= x .* y
    dest
end

function LinearAlgebra.mul!(y::StridedVector{AffineFunction{T}}, A::AbstractMatrix{T}, x::StridedVector{Variable}) where {T <: LinearAlgebra.BlasFloat}
    matvecmul!(y, A, x)
end

function LinearAlgebra.dot(x::AbstractArray{T}, y::AbstractArray{S}) where {T<:Number, S<:Union{Variable, <:LinearTerm, <:AffineFunction}}
    R = promote_type(coefftype(T), coefftype(S))
    vecdot!(zero(AffineFunction{R}), x, y)
end

function LinearAlgebra.dot(x::AbstractArray{T}, y::AbstractArray{S}) where {T<:Union{Variable, <:LinearTerm, <:AffineFunction}, S<:Number}
    R = promote_type(coefftype(T), coefftype(S))
    vecdot!(zero(AffineFunction{R}), x, y)
end

function LinearAlgebra.dot(
        x::AbstractArray{T},
        y::AbstractArray{S}) where {T <: Union{Variable, <:LinearTerm, <:AffineFunction}, S <: Union{Variable, <:LinearTerm, <:AffineFunction}}
    R = promote_type(coefftype(T), coefftype(S))
    vecdot!(zero(QuadraticFunction{R}), x, y)
end

function LinearAlgebra.dot(x::AbstractArray{T}, y::AbstractArray{S}) where {T<:Number, S<:QuadraticTerm}
    R = promote_type(coefftype(T), coefftype(S))
    vecdot!(zero(QuadraticFunction{R}), x, y)
end

function LinearAlgebra.dot(x::AbstractArray{T}, y::AbstractArray{S}) where {T<:QuadraticTerm, S<:Number}
    R = promote_type(coefftype(T), coefftype(S))
    vecdot!(zero(QuadraticFunction{R}), x, y)
end

# vcat!

"""
$(SIGNATURES)

Vertically concatenate a number of vectors, storing the result in `y`.

$(METHODLIST)
"""
function vcat! end

function _vcat!(dest::AbstractVector{<:AffineFunction}, i::Integer)
    @boundscheck i == lastindex(dest) + 1 || throw(DimensionMismatch())
    dest
end

function _vcat!(
        dest::AbstractVector{<:AffineFunction},
        i::Integer,
        source::AbstractVector{<:AffineFunction},
        remaining::Vararg{<:AbstractVector{<:AffineFunction}, N}) where {N}
    @boundscheck i >= firstindex(dest) && (i + length(source) - 1) <= lastindex(dest) || throw(DimensionMismatch())
    @inbounds for s in source
        copyto!(dest[i], s)
        i += 1
    end
    _vcat!(dest, i, remaining...)
end

function vcat!(y::AbstractVector{<:AffineFunction},
               args::Vararg{<:AbstractVector{<:AffineFunction}, N}) where N
    @inbounds for i in eachindex(y)
        zero!(y[i])
    end
    _vcat!(y, 1, args...)
    y
end


# GetField
struct GetField{Field} end
(::GetField{Field})(arg) where {Field} = getfield(arg, Field)

end
