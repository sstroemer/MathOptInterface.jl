# Copyright (c) 2017: Miles Lubin and contributors
# Copyright (c) 2017: Google Inc.
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

"""
    _FixParametricVariablesBridge{T,S} <: AbstractBridge

!!! danger
    `_FixParametricVariablesBridge` is experimental, and the functionality may
    change in any future release.

`_FixParametricVariablesBridge` implements the following reformulation:

  * ``f(x) \\in S`` into ``g(x) \\in S``, where ``f(x)`` is a
    [`MOI.ScalarQuadraticFunction{T}`](@ref) and ``g(x)`` is a
    [`MOI.ScalarAffineFunction{T}`](@ref), where all variables that are fixed
    using a [`MOI.VariableIndex`](@ref)-in-[`MOI.Parameter`](@ref) constraint
    and that appear in a quadratic term are replaced by their corresponding
    constant.

For example, if `p == 3`, this bridge converts the quadratic term `0.3 * p * x`
into the linear term `0.9 * x`. Moreover, a linear term such as `0.3 * p` is
left as `0.3 * p`.

An error is thrown if, after fixing variables, ``g(x)`` is not an affine
function,

!!! warning
    This transformation turns a quadratic function into an affine function by
    substituting decision variables for their fixed values. This can cause the
    dual solution of the substituted fixed variable to be incorrect. Therefore,
    this bridge is not added automatically by [`MOI.Bridges.full_bridge_optimizer`](@ref).
    Care is recommended when adding this bridge to a optimizer.

## Source node

`_FixParametricVariablesBridge` supports:

* [`MOI.ScalarQuadraticFunction{T}`](@ref) in `S`

## Target nodes

`_FixParametricVariablesBridge` creates:

  * [`MOI.ScalarAffineFunction{T}`](@ref) in `S`
"""
struct _FixParametricVariablesBridge{T,S} <: AbstractBridge
    affine_constraint::MOI.ConstraintIndex{MOI.ScalarAffineFunction{T},S}
    f::MOI.ScalarQuadraticFunction{T}
    values::Dict{MOI.VariableIndex,Union{Nothing,T}}
    new_coefs::Dict{MOI.VariableIndex,T}
end

const FixParametricVariables{T,OT<:MOI.ModelLike} =
    SingleBridgeOptimizer{_FixParametricVariablesBridge{T},OT}

function bridge_constraint(
    ::Type{_FixParametricVariablesBridge{T,S}},
    model::MOI.ModelLike,
    f::MOI.ScalarQuadraticFunction{T},
    s::S,
) where {T,S<:MOI.AbstractScalarSet}
    affine = MOI.ScalarAffineFunction(f.affine_terms, f.constant)
    ci = MOI.add_constraint(model, affine, s)
    values = Dict{MOI.VariableIndex,Union{Nothing,T}}()
    new_coefs = Dict{MOI.VariableIndex,T}()
    for term in f.quadratic_terms
        values[term.variable_1] = nothing
        values[term.variable_2] = nothing
        new_coefs[term.variable_1] = zero(T)
        new_coefs[term.variable_2] = zero(T)
    end
    return _FixParametricVariablesBridge{T,S}(ci, f, values, new_coefs)
end

function MOI.supports_constraint(
    ::Type{<:_FixParametricVariablesBridge{T}},
    ::Type{MOI.ScalarQuadraticFunction{T}},
    ::Type{<:MOI.AbstractScalarSet},
) where {T}
    return true
end

function concrete_bridge_type(
    ::Type{<:_FixParametricVariablesBridge},
    ::Type{MOI.ScalarQuadraticFunction{T}},
    ::Type{S},
) where {T,S<:MOI.AbstractScalarSet}
    return _FixParametricVariablesBridge{T,S}
end

function MOI.Bridges.added_constrained_variable_types(
    ::Type{<:_FixParametricVariablesBridge},
)
    return Tuple{Type}[]
end

function MOI.Bridges.added_constraint_types(
    ::Type{_FixParametricVariablesBridge{T,S}},
) where {T,S}
    return Tuple{Type,Type}[(MOI.ScalarAffineFunction{T}, S)]
end

function MOI.get(
    ::MOI.ModelLike,
    ::MOI.ConstraintFunction,
    bridge::_FixParametricVariablesBridge,
)
    return bridge.f
end

function MOI.get(
    model::MOI.ModelLike,
    ::MOI.ConstraintSet,
    bridge::_FixParametricVariablesBridge,
)
    return MOI.get(model, MOI.ConstraintSet(), bridge.affine_constraint)
end

function MOI.delete(model::MOI.ModelLike, bridge::_FixParametricVariablesBridge)
    MOI.delete(model, bridge.affine_constraint)
    return
end

MOI.get(::_FixParametricVariablesBridge, ::MOI.NumberOfVariables)::Int64 = 0

function MOI.get(::_FixParametricVariablesBridge, ::MOI.ListOfVariableIndices)
    return MOI.VariableIndex[]
end

function MOI.get(
    bridge::_FixParametricVariablesBridge{T,S},
    ::MOI.NumberOfConstraints{MOI.ScalarAffineFunction{T},S},
)::Int64 where {T,S}
    return 1
end

function MOI.get(
    bridge::_FixParametricVariablesBridge{T,S},
    ::MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{T},S},
) where {T,S}
    return [bridge.affine_constraint]
end

function MOI.modify(
    model::MOI.ModelLike,
    bridge::_FixParametricVariablesBridge{T,S},
    chg::MOI.ScalarCoefficientChange{T},
) where {T,S}
    MOI.modify(model, bridge.affine_constraint, chg)
    MOI.Utilities.modify_function!(bridge.f, chg)
    return
end

MOI.Bridges.needs_final_touch(::_FixParametricVariablesBridge) = true

function MOI.Bridges.final_touch(
    bridge::_FixParametricVariablesBridge{T,S},
    model::MOI.ModelLike,
) where {T,S}
    for x in keys(bridge.values)
        bridge.values[x] = nothing
        bridge.new_coefs[x] = zero(T)
        ci = MOI.ConstraintIndex{MOI.VariableIndex,MOI.Parameter{T}}(x.value)
        if MOI.is_valid(model, ci)
            bridge.values[x] = MOI.get(model, MOI.ConstraintSet(), ci).value
        end
    end
    for term in bridge.f.affine_terms
        if haskey(bridge.new_coefs, term.variable)
            bridge.new_coefs[term.variable] += term.coefficient
        end
    end
    for term in bridge.f.quadratic_terms
        v1, v2 = bridge.values[term.variable_1], bridge.values[term.variable_2]
        if v1 !== nothing
            if term.variable_1 == term.variable_2
                # This is needed because `ScalarQuadraticFunction` has a factor
                # of 0.5 in front of the Q matrix.
                bridge.new_coefs[term.variable_2] += v1 * term.coefficient / 2
            else
                bridge.new_coefs[term.variable_2] += v1 * term.coefficient
            end
        elseif v2 !== nothing
            bridge.new_coefs[term.variable_1] += v2 * term.coefficient
        else
            error(
                "unable to use `_FixParametricVariablesBridge: at least one " *
                "variable is not fixed",
            )
        end
    end
    for (k, v) in bridge.new_coefs
        MOI.modify(
            model,
            bridge.affine_constraint,
            MOI.ScalarCoefficientChange(k, v),
        )
    end
    return
end
