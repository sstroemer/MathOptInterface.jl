```@meta
CurrentModule = MathOptInterface
DocTestSetup = quote
    import MathOptInterface as MOI
end
DocTestFilters = [r"MathOptInterface|MOI"]
```

# [Constraints](@id constraints_ref)

## Types

```@docs
ConstraintIndex
```

## Functions

```@docs
is_valid(::ModelLike,::ConstraintIndex)
add_constraint
add_constraints
transform
supports_constraint
```

## Attributes

```@docs
AbstractConstraintAttribute
ConstraintName
ConstraintPrimalStart
ConstraintDualStart
ConstraintPrimal
ConstraintDual
ConstraintBasisStatus
BasisStatusCode
ConstraintFunction
CanonicalConstraintFunction
ConstraintSet
```
