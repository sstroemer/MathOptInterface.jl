# Copyright (c) 2017: Miles Lubin and contributors
# Copyright (c) 2017: Google Inc.
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

"""
    SlackBridge{T,F,G}

The `SlackBridge` converts an objective function of type `G` into a
[`MOI.VariableIndex`](@ref) objective by creating a slack variable and a
`F`-in-[`MOI.LessThan`](@ref) constraint for minimization or
`F`-in-[`MOI.GreaterThan`](@ref) constraint for maximization where `F` is
`MOI.Utilities.promote_operation(-, T, G, MOI.VariableIndex}`.

!!! note
    When using this bridge, changing the optimization sense is not supported.
    Set the sense to `MOI.FEASIBILITY_SENSE` first to delete the bridge, then
    set [`MOI.ObjectiveSense`](@ref) and re-add the objective.
"""
struct SlackBridge{
    T,
    F<:MOI.AbstractScalarFunction,
    G<:MOI.AbstractScalarFunction,
} <: AbstractBridge
    slack::MOI.VariableIndex
    constraint::Union{
        MOI.ConstraintIndex{F,MOI.LessThan{T}},
        MOI.ConstraintIndex{F,MOI.GreaterThan{T}},
    }
end

const Slack{T,OT<:MOI.ModelLike} = SingleBridgeOptimizer{SlackBridge{T},OT}

function bridge_objective(
    ::Type{SlackBridge{T,F,G}},
    model::MOI.ModelLike,
    func::G,
) where {T,F,G<:MOI.AbstractScalarFunction}
    slack = MOI.add_variable(model)
    f = MOI.Utilities.operate(-, T, func, slack)
    if MOI.get(model, MOI.ObjectiveSense()) == MOI.MIN_SENSE
        set = MOI.LessThan(zero(T))
    elseif MOI.get(model, MOI.ObjectiveSense()) == MOI.MAX_SENSE
        set = MOI.GreaterThan(zero(T))
    else
        error(
            "Set `MOI.ObjectiveSense` before `MOI.ObjectiveFunction` when",
            " using `MOI.Bridges.Objective.SlackBridge`.",
        )
    end
    constraint = MOI.Utilities.normalize_and_add_constraint(model, f, set)
    MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), slack)
    return SlackBridge{T,F,G}(slack, constraint)
end

function supports_objective_function(
    ::Type{<:SlackBridge},
    ::Type{MOI.VariableIndex},
)
    return false
end

function supports_objective_function(
    ::Type{<:SlackBridge},
    ::Type{<:MOI.AbstractScalarFunction},
)
    return true
end

function MOI.Bridges.added_constrained_variable_types(::Type{<:SlackBridge})
    return Tuple{Type}[]
end

function MOI.Bridges.added_constraint_types(
    ::Type{<:SlackBridge{T,F}},
) where {T,F}
    return Tuple{Type,Type}[(F, MOI.GreaterThan{T}), (F, MOI.LessThan{T})]
end

function MOI.Bridges.set_objective_function_type(::Type{<:SlackBridge})
    return MOI.VariableIndex
end

function concrete_bridge_type(
    ::Type{<:SlackBridge{T}},
    G::Type{<:MOI.AbstractScalarFunction},
) where {T}
    F = MOI.Utilities.promote_operation(-, T, G, MOI.VariableIndex)
    return SlackBridge{T,F,G}
end

# Attributes, Bridge acting as a model
MOI.get(::SlackBridge, ::MOI.NumberOfVariables)::Int64 = 1

function MOI.get(bridge::SlackBridge, ::MOI.ListOfVariableIndices)
    return [bridge.slack]
end

function MOI.get(
    bridge::SlackBridge{T,F},
    ::MOI.NumberOfConstraints{F,S},
)::Int64 where {T,F,S<:Union{MOI.GreaterThan{T},MOI.LessThan{T}}}
    return bridge.constraint isa MOI.ConstraintIndex{F,S} ? 1 : 0
end

function MOI.get(
    bridge::SlackBridge{T,F},
    ::MOI.ListOfConstraintIndices{F,S},
) where {T,F,S<:Union{MOI.GreaterThan{T},MOI.LessThan{T}}}
    if bridge.constraint isa MOI.ConstraintIndex{F,S}
        return [bridge.constraint]
    else
        return MOI.ConstraintIndex{F,S}[]
    end
end

function MOI.delete(model::MOI.ModelLike, bridge::SlackBridge)
    MOI.delete(model, bridge.constraint)
    MOI.delete(model, bridge.slack)
    return
end

function MOI.get(
    model::MOI.ModelLike,
    attr::MOI.Bridges.ObjectiveFunctionValue{G},
    bridge::SlackBridge{T,F,G},
) where {T,F,G}
    slack = MOI.get(
        model,
        MOI.Bridges.ObjectiveFunctionValue{MOI.VariableIndex}(
            attr.result_index,
        ),
    )
    # There may be a gap between the value of the original objective `g` and the
    # value of `bridge.slack`. Since `bridge.constraint` is `g - slack`, we can
    # get the value of the original objective by summing the value of `slack`
    # with the `ConstraintPrimal` of the constraint.
    obj_slack_constant =
        MOI.get(model, MOI.ConstraintPrimal(), bridge.constraint)
    # The constant was moved to the set as it is a scalar constraint.
    constant =
        MOI.constant(MOI.get(model, MOI.ConstraintSet(), bridge.constraint))
    return obj_slack_constant + slack - constant
end

_constant_term(set::MOI.LessThan) = set.upper
_constant_term(set::MOI.GreaterThan) = set.lower

function MOI.get(
    model::MOI.ModelLike,
    ::MOI.ObjectiveFunction{G},
    bridge::SlackBridge{T,F,G},
) where {T,F,G<:MOI.AbstractScalarFunction}
    func = MOI.get(model, MOI.ConstraintFunction(), bridge.constraint)
    set = MOI.get(model, MOI.ConstraintSet(), bridge.constraint)
    f = MOI.Utilities.operate(-, T, func, _constant_term(set))
    g = MOI.Utilities.remove_variable(f, bridge.slack)
    return MOI.Utilities.convert_approx(G, g)
end