# Copyright (c) 2017: Miles Lubin and contributors
# Copyright (c) 2017: Google Inc.
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

module TestMOF

import JSON
import JSONSchema
using Test

import MathOptInterface as MOI
import MathOptInterface.Utilities as MOIU
const MOF = MOI.FileFormats.MOF

const TEST_MOF_FILE = "test.mof.json"

const SCHEMA =
    JSONSchema.Schema(JSON.parsefile(MOI.FileFormats.MOF.SCHEMA_PATH))

function _validate(filename::String)
    MOI.FileFormats.compressed_open(
        filename,
        "r",
        MOI.FileFormats.AutomaticCompression(),
    ) do io
        object = JSON.parse(io)
        ret = JSONSchema.validate(SCHEMA, object)
        if ret !== nothing
            error(
                "Unable to read file because it does not conform to the MOF " *
                "schema: ",
                ret,
            )
        end
    end
end

struct UnsupportedSet <: MOI.AbstractSet end
struct UnsupportedFunction <: MOI.AbstractFunction end

function _test_model_equality(model_string, variables, constraints; suffix = "")
    model = MOF.Model()
    MOIU.loadfromstring!(model, model_string)
    MOI.write_to_file(model, TEST_MOF_FILE * suffix)
    model_2 = MOF.Model()
    MOI.read_from_file(model_2, TEST_MOF_FILE * suffix)
    MOI.Test.util_test_models_equal(model, model_2, variables, constraints)
    return _validate(TEST_MOF_FILE * suffix)
end

# hs071
# min x1 * x4 * (x1 + x2 + x3) + x3
# st  x1 * x2 * x3 * x4 >= 25
#     x1^2 + x2^2 + x3^2 + x4^2 = 40
#     1 <= x1, x2, x3, x4 <= 5
struct ExprEvaluator <: MOI.AbstractNLPEvaluator
    objective::Expr
    constraints::Vector{Expr}
end
MOI.features_available(::ExprEvaluator) = [:ExprGraph]
MOI.initialize(::ExprEvaluator, features) = nothing
MOI.objective_expr(evaluator::ExprEvaluator) = evaluator.objective
MOI.constraint_expr(evaluator::ExprEvaluator, i::Int) = evaluator.constraints[i]

function HS071(x::Vector{MOI.VariableIndex})
    x1, x2, x3, x4 = x
    return MOI.NLPBlockData(
        MOI.NLPBoundsPair.([25, 40], [Inf, 40]),
        ExprEvaluator(
            :(x[$x1] * x[$x4] * (x[$x1] + x[$x2] + x[$x3]) + x[$x3]),
            [
                :(x[$x1] * x[$x2] * x[$x3] * x[$x4] >= 25),
                :(x[$x1]^2 + x[$x2]^2 + x[$x3]^2 + x[$x4]^2 == 40),
            ],
        ),
        true,
    )
end

function test_HS071()
    model = MOF.Model()
    x = MOI.add_variables(model, 4)
    for (index, variable) in enumerate(x)
        MOI.set(model, MOI.VariableName(), variable, "var_$(index)")
    end
    MOI.add_constraints(model, x, Ref(MOI.Interval(1.0, 5.0)))
    MOI.set(model, MOI.NLPBlock(), HS071(x))
    MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.write_to_file(model, TEST_MOF_FILE)
    @test replace(read(TEST_MOF_FILE, String), '\r' => "") ==
          replace(read(joinpath(@__DIR__, "nlp.mof.json"), String), '\r' => "")
    _validate(TEST_MOF_FILE)
    return
end

function test_read_HS071()
    model = MOF.Model()
    MOI.read_from_file(model, joinpath(@__DIR__, "nlp.mof.json"))
    @test MOI.get(model, MOI.ListOfConstraintTypesPresent()) ==
          Tuple{Type,Type}[(MOI.VariableIndex, MOI.Interval{Float64})]
    x = MOI.get(model, MOI.ListOfVariableIndices())
    @test length(x) == 4
    @test MOI.get(model, MOI.VariableName(), x) == ["var_$i" for i in 1:4]
    block = MOI.get(model, MOI.NLPBlock())
    evaluator = block.evaluator
    MOI.initialize(evaluator, [:ExprGraph])
    hs071_block = HS071(x)
    hs071 = hs071_block.evaluator
    @test MOI.objective_expr(evaluator) == MOI.objective_expr(hs071)
    for i in 1:2
        @test MOI.constraint_expr(evaluator, i) == MOI.constraint_expr(hs071, i)
    end
    return
end

function test_nonlinear_error_handling()
    node_list = MOF.Object[]
    string_to_variable = Dict{String,MOI.VariableIndex}()
    variable_to_string = Dict{MOI.VariableIndex,String}()
    # Test unsupported function for Expr -> MOF.
    @test_throws Exception MOF.convert_expr_to_mof(
        :(not_supported_function(x)),
        node_list,
        variable_to_string,
    )
    # Test unsupported function for MOF -> Expr.
    @test_throws Exception MOF.convert_mof_to_expr(
        MOF.OrderedObject("type" => "not_supported_function", "value" => 1),
        node_list,
        string_to_variable,
    )
    # Test n-ary function with no arguments.
    @test_throws Exception MOF.convert_expr_to_mof(
        :(min()),
        node_list,
        variable_to_string,
    )
    # Test unary function with two arguments.
    @test_throws Exception MOF.convert_expr_to_mof(
        :(sin(x, y)),
        node_list,
        variable_to_string,
    )
    # Test binary function with one arguments.
    @test_throws Exception MOF.convert_expr_to_mof(
        :(^(x)),
        node_list,
        variable_to_string,
    )
    # An expression with something other than :call as the head.
    @test_throws Exception MOF.convert_expr_to_mof(
        :(a <= b <= c),
        node_list,
        variable_to_string,
    )
    # Hit the default fallback with an un-interpolated complex number.
    @test_throws Exception MOF.convert_expr_to_mof(
        :(1 + 2im),
        node_list,
        variable_to_string,
    )
    # Invalid number of variables.
    @test_throws Exception MOF.substitute_variables(
        :(x[1] * x[2]),
        [MOI.VariableIndex(1)],
    )
    # Function-in-Set
    @test_throws Exception MOF.extract_function_and_set(:(foo in set))
    # Not a constraint.
    @test_throws Exception MOF.extract_function_and_set(:(x^2))
    # Two-sided constraints
    @test MOF.extract_function_and_set(:(1 <= x <= 2)) ==
          MOF.extract_function_and_set(:(2 >= x >= 1)) ==
          (:x, MOI.Interval(1, 2))
    # Less-than constraint.
    @test MOF.extract_function_and_set(:(x <= 2)) == (:x, MOI.LessThan(2))
end

function test_Roundtrip_nonlinear_expressions()
    x = MOI.VariableIndex(123)
    y = MOI.VariableIndex(456)
    z = MOI.VariableIndex(789)
    string_to_var = Dict{String,MOI.VariableIndex}("x" => x, "y" => y, "z" => z)
    var_to_string = Dict{MOI.VariableIndex,String}(x => "x", y => "y", z => "z")
    for expr in [
        2,
        2.34,
        2 + 3im,
        x,
        :(1 + $x),
        :($x - 1),
        :($x + $y),
        :($x + $y - $z),
        :(2 * $x),
        :($x * $y),
        :($x / 2),
        :(2 / $x),
        :($x / $y),
        :($x / $y / $z),
        :(2^$x),
        :($x^2),
        :($x^$y),
        :($x^(2 * $y + 1)),
        :(sin($x)),
        :(sin($x + $y)),
        :(2 * $x + sin($x)^2 + $y),
        :(sin($(3im))^2 + cos($(3im))^2),
        :($(1 + 2im) * $x),
        :(ceil($x)),
        :(floor($x)),
        :($x < $y),
        :($x <= $y),
        :($x > $y),
        :($x >= $y),
        :($x == $y),
        :($x != $y),
        # :($x && $y), :($x || $y),
        :(ifelse($x > 0, 1, $y)),
    ]
        node_list = MOF.OrderedObject[]
        object = MOF.convert_expr_to_mof(expr, node_list, var_to_string)
        @test MOF.convert_mof_to_expr(object, node_list, string_to_var) == expr
    end
end

function test_nonlinear_readingwriting()
    model = MOF.Model()
    (x, y) = MOI.add_variables(model, 2)
    MOI.set(model, MOI.VariableName(), x, "var_x")
    MOI.set(model, MOI.VariableName(), y, "y")
    con = MOI.add_constraint(
        model,
        MOF.Nonlinear(:(2 * $x + sin($x)^2 - $y)),
        MOI.EqualTo(1.0),
    )
    MOI.set(model, MOI.ConstraintName(), con, "con")
    MOI.write_to_file(model, TEST_MOF_FILE)
    # Read the model back in.
    model2 = MOF.Model()
    MOI.read_from_file(model2, TEST_MOF_FILE)
    block = MOI.get(model2, MOI.NLPBlock())
    MOI.initialize(block.evaluator, [:ExprGraph])
    @test MOI.constraint_expr(block.evaluator, 1) ==
          :(2 * x[$x] + sin(x[$x])^2 - x[$y] == 1.0)
    _validate(TEST_MOF_FILE)
    return
end

function test_show()
    @test sprint(show, MOF.Model()) == "A MathOptFormat Model"
end

function test_nonempty_model()
    model = MOF.Model(warn = true)
    MOI.add_variable(model)
    @test !MOI.is_empty(model)
    exception = ErrorException(
        "Cannot read model from file as destination model is not empty.",
    )
    @test_throws exception MOI.read_from_file(
        model,
        joinpath(@__DIR__, "empty_model.mof.json"),
    )
    options = MOF.get_options(model)
    @test options.warn
    MOI.empty!(model)
    @test MOI.is_empty(model)
    MOI.read_from_file(model, joinpath(@__DIR__, "empty_model.mof.json"))
    options2 = MOF.get_options(model)
    @test options2.warn
end

function test_failing_models()
    @testset "$(filename)" for filename in filter(
        f -> endswith(f, ".mof.json"),
        readdir(joinpath(@__DIR__, "failing_models")),
    )
        @test_throws Exception MOI.read_from_file(
            MOF.Model(),
            joinpath(@__DIR__, "failing_models", filename),
        )
    end
end

function test_Blank_variable_name()
    model = MOF.Model()
    variable = MOI.add_variable(model)
    @test_throws Exception MOF.moi_to_object(variable, model)
    MOI.FileFormats.create_unique_names(model, warn = true)
    @test MOF.moi_to_object(variable, model) ==
          MOF.OrderedObject("name" => "x1")
end

function test_Duplicate_variable_name()
    model = MOF.Model()
    x = MOI.add_variable(model)
    MOI.set(model, MOI.VariableName(), x, "x")
    y = MOI.add_variable(model)
    MOI.set(model, MOI.VariableName(), y, "x")
    @test MOF.moi_to_object(x, model) == MOF.OrderedObject("name" => "x")
    @test MOF.moi_to_object(y, model) == MOF.OrderedObject("name" => "x")
    MOI.FileFormats.create_unique_names(model, warn = true)
    @test MOF.moi_to_object(x, model) == MOF.OrderedObject("name" => "x")
    @test MOF.moi_to_object(y, model) == MOF.OrderedObject("name" => "x_1")
end

function test_Blank_constraint_name()
    model = MOF.Model()
    x = MOI.add_variable(model)
    MOI.set(model, MOI.VariableName(), x, "x")
    f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0)
    c = MOI.add_constraint(model, f, MOI.ZeroOne())
    name_map = Dict(x => "x")
    MOI.FileFormats.create_unique_names(model, warn = true)
    @test MOF.moi_to_object(c, model, name_map)["name"] == "c1"
end

function test_Duplicate_constraint_name()
    model = MOF.Model()
    x = MOI.add_variable(model)
    MOI.set(model, MOI.VariableName(), x, "x")
    f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0)
    c1 = MOI.add_constraint(model, f, MOI.LessThan(1.0))
    c2 = MOI.add_constraint(model, f, MOI.GreaterThan(0.0))
    MOI.set(model, MOI.ConstraintName(), c1, "c")
    MOI.set(model, MOI.ConstraintName(), c2, "c")
    name_map = Dict(x => "x")
    @test MOF.moi_to_object(c1, model, name_map)["name"] == "c"
    @test MOF.moi_to_object(c2, model, name_map)["name"] == "c"
    MOI.FileFormats.create_unique_names(model, warn = true)
    @test MOF.moi_to_object(c1, model, name_map)["name"] == "c_1"
    @test MOF.moi_to_object(c2, model, name_map)["name"] == "c"
end

function test_empty_model()
    model = MOF.Model()
    MOI.write_to_file(model, TEST_MOF_FILE)
    model_2 = MOF.Model()
    MOI.read_from_file(model_2, TEST_MOF_FILE)
    return MOI.Test.util_test_models_equal(model, model_2, String[], String[])
end

function test_FEASIBILITY_SENSE()
    model = MOF.Model()
    x = MOI.add_variable(model)
    MOI.set(model, MOI.VariableName(), x, "x")
    MOI.set(model, MOI.ObjectiveSense(), MOI.FEASIBILITY_SENSE)
    MOI.write_to_file(model, TEST_MOF_FILE)
    model_2 = MOF.Model()
    MOI.read_from_file(model_2, TEST_MOF_FILE)
    return MOI.Test.util_test_models_equal(model, model_2, ["x"], String[])
end

function test_empty_function_term()
    model = MOF.Model()
    x = MOI.add_variable(model)
    MOI.set(model, MOI.VariableName(), x, "x")
    c = MOI.add_constraint(
        model,
        MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[], 0.0),
        MOI.GreaterThan(1.0),
    )
    MOI.set(model, MOI.ConstraintName(), c, "c")
    MOI.write_to_file(model, TEST_MOF_FILE)
    model_2 = MOF.Model()
    MOI.read_from_file(model_2, TEST_MOF_FILE)
    return MOI.Test.util_test_models_equal(model, model_2, ["x"], ["c"])
end

function test_min_objective()
    return _test_model_equality(
        """
variables: x
minobjective: x
""",
        ["x"],
        String[],
    )
end

function test_max_objective()
    return _test_model_equality(
        """
variables: x
maxobjective: x
""",
        ["x"],
        String[],
        suffix = ".gz",
    )
end

function test_min_scalaraffine()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
""",
        ["x"],
        String[],
    )
end

function test_max_scalaraffine()
    return _test_model_equality(
        """
variables: x
maxobjective: 1.2x + 0.5
""",
        ["x"],
        String[],
        suffix = ".gz",
    )
end

function test_min_vector_of_variables()
    return _test_model_equality(
        """
variables: x, y
minobjective: [x, y]
""",
        ["x", "y"],
        String[],
    )
end

function test_max_vector_affine()
    return _test_model_equality(
        """
variables: x, y
maxobjective: [1.0 * x, 2.0 * y, 3.0 * x + 4.0 * y + 5.0]
""",
        ["x", "y"],
        String[],
    )
end

function test_max_vector_quadratic()
    return _test_model_equality(
        """
variables: x, y
maxobjective: [1.0 * x * x + 2.0 * x * y]
""",
        ["x", "y"],
        String[],
    )
end

function test_singlevariable_in_lower()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
x >= 1.0
""",
        ["x"],
        String[],
    )
end

function test_singlevariable_in_upper()
    return _test_model_equality(
        """
variables: x
maxobjective: 1.2x + 0.5
x <= 1.0
""",
        ["x"],
        String[],
        suffix = ".gz",
    )
end

function test_singlevariable_in_interval()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
x in Interval(1.0, 2.0)
""",
        ["x"],
        String[],
    )
end

function test_singlevariable_in_equalto()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
x == 1.0
""",
        ["x"],
        String[],
    )
end

function test_singlevariable_in_zeroone()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
x in ZeroOne()
""",
        ["x"],
        String[],
    )
end

function test_singlevariable_in_integer()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
x in Integer()
""",
        ["x"],
        String[],
    )
end

function test_singlevariable_in_Semicontinuous()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
x in Semicontinuous(1.0, 2.0)
""",
        ["x"],
        String[],
    )
end

function test_singlevariable_in_Semiinteger()
    return _test_model_equality(
        """
variables: x
minobjective: 1.2x + 0.5
x in Semiinteger(1.0, 2.0)
""",
        ["x"],
        String[],
    )
end

function test_scalarquadratic_objective()
    return _test_model_equality(
        """
variables: x
minobjective: 1.0*x*x + -2.0x + 1.0
""",
        ["x"],
        String[],
    )
end

function test_SOS1()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in SOS1([1.0, 2.0, 3.0])
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_SOS2()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in SOS2([1.0, 2.0, 3.0])
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_Reals()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in Reals(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_Zeros()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in Zeros(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_Nonnegatives()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in Nonnegatives(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_Nonpositives()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in Nonpositives(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_PowerCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in PowerCone(2.0)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_DualPowerCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in DualPowerCone(0.5)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_GeometricMeanCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in GeometricMeanCone(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_Complements()
    return _test_model_equality(
        "variables: x, y\nc1: [x, y] in Complements(2)",
        ["x", "y"],
        ["c1"],
    )
end

function test_vectoraffine_in_zeros()
    return _test_model_equality(
        """
variables: x, y
minobjective: x
c1: [1.0x + -3.0, 2.0y + -4.0] in Zeros(2)
""",
        ["x", "y"],
        ["c1"],
    )
end

function test_vectorquadratic_in_nonnegatives()
    return _test_model_equality(
        """
variables: x, y
minobjective: x
c1: [1.0*x*x + -2.0x + 1.0, 2.0y + -4.0] in Nonnegatives(2)
""",
        ["x", "y"],
        ["c1"],
    )
end

function test_ExponentialCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in ExponentialCone()
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_DualExponentialCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in DualExponentialCone()
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_SecondOrderCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in SecondOrderCone(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_RotatedSecondOrderCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in RotatedSecondOrderCone(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_PositiveSemidefiniteConeTriangle()
    return _test_model_equality(
        """
variables: x1, x2, x3
minobjective: x1
c1: [x1, x2, x3] in PositiveSemidefiniteConeTriangle(2)
""",
        ["x1", "x2", "x3"],
        ["c1"],
    )
end

function test_PositiveSemidefiniteConeSquare()
    return _test_model_equality(
        """
variables: x1, x2, x3, x4
minobjective: x1
c1: [x1, x2, x3, x4] in PositiveSemidefiniteConeSquare(2)
""",
        ["x1", "x2", "x3", "x4"],
        ["c1"],
    )
end

function test_LogDetConeTriangle()
    return _test_model_equality(
        """
variables: t, u, x1, x2, x3
minobjective: x1
c1: [t, u, x1, x2, x3] in LogDetConeTriangle(2)
""",
        ["t", "u", "x1", "x2", "x3"],
        ["c1"],
    )
end

function test_LogDetConeSquare()
    return _test_model_equality(
        """
variables: t, u, x1, x2, x3, x4
minobjective: x1
c1: [t, u, x1, x2, x3, x4] in LogDetConeSquare(2)
""",
        ["t", "u", "x1", "x2", "x3", "x4"],
        ["c1"],
    )
end

function test_RootDetConeTriangle()
    return _test_model_equality(
        """
variables: t, x1, x2, x3
minobjective: x1
c1: [t, x1, x2, x3] in RootDetConeTriangle(2)
""",
        ["t", "x1", "x2", "x3"],
        ["c1"],
    )
end

function test_RootDetConeSquare()
    return _test_model_equality(
        """
variables: t, x1, x2, x3, x4
minobjective: x1
c1: [t, x1, x2, x3, x4] in RootDetConeSquare(2)
""",
        ["t", "x1", "x2", "x3", "x4"],
        ["c1"],
    )
end

function test_Indicator()
    _test_model_equality(
        """
variables: x, y
minobjective: x
c1: [x, y] in Indicator{ACTIVATE_ON_ONE}(GreaterThan(1.0))
""",
        ["x", "y"],
        ["c1"],
    )

    return _test_model_equality(
        """
variables: x, y
minobjective: x
c1: [x, y] in Indicator{ACTIVATE_ON_ZERO}(GreaterThan(1.0))
""",
        ["x", "y"],
        ["c1"],
    )
end

function test_NormOneCone()
    return _test_model_equality(
        """
variables: x, y
minobjective: x
c1: [x, y] in NormOneCone(2)
""",
        ["x", "y"],
        ["c1"],
    )
end

function test_NormInfinityCone()
    return _test_model_equality(
        """
variables: x, y
minobjective: x
c1: [x, y] in NormInfinityCone(2)
""",
        ["x", "y"],
        ["c1"],
    )
end

function test_RelativeEntropyCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in RelativeEntropyCone(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_NormSpectralCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in NormSpectralCone(1, 2)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_NormNuclearCone()
    return _test_model_equality(
        """
variables: x, y, z
minobjective: x
c1: [x, y, z] in NormNuclearCone(1, 2)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_v04()
    model = MOF.Model()
    MOI.read_from_file(model, joinpath(@__DIR__, "v0.4.mof.json"))
    model_2 = MOF.Model()
    MOI.Utilities.loadfromstring!(
        model_2,
        """
variables: x, y
minobjective: x
c: x + y >= 1.0
x in Interval(0.0, 1.0)
y in ZeroOne()
""",
    )
    MOI.Test.util_test_models_equal(model, model_2, ["x", "y"], ["c"])
    return
end

function test_AllDifferent()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, z] in AllDifferent(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_BinPacking()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, z] in BinPacking(3.0, [1.0, 2.0, 3.0])
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_Circuit()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, z] in Circuit(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_CountAtLeast()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, y, z] in CountAtLeast(1, [2, 2], Set([3]))
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_CountBelongs()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, z] in CountBelongs(3, Set([3, 4, 5]))
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_CountDistinct()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, z] in CountDistinct(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_CountGreaterThan()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, z] in CountGreaterThan(3)
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_Cumulative()
    return _test_model_equality(
        """
variables: a, b, c, d, e, f, g, h, i, j
c1: [a, b, c, d, e, f, g, h, i, j] in Cumulative(10)
""",
        ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
        ["c1"],
    )
end

function test_Path()
    return _test_model_equality(
        """
variables: s, t, n1, n2, n3, n4, e1, e2, e3, e4, e5
c1: [s, t, n1, n2, n3, n4, e1, e2, e3, e4, e5] in Path([1, 1, 2, 2, 3], [2, 3, 3, 4, 4])
""",
        ["s", "t", "n1", "n2", "n3", "n4", "e1", "e2", "e3", "e4", "e5"],
        ["c1"],
    )
end

function test_Table()
    return _test_model_equality(
        """
variables: x, y, z
c1: [x, y, z] in Table([1.0 1.0 0.0; 0.0 0.0 0.0])
""",
        ["x", "y", "z"],
        ["c1"],
    )
end

function test_VariablePrimalStart()
    model_w = MOF.Model()
    x = MOI.add_variable(model_w)
    MOI.set(model_w, MOI.VariableName(), x, "x")
    y = MOI.add_variable(model_w)
    MOI.set(model_w, MOI.VariableName(), y, "y")
    MOI.set(model_w, MOI.VariablePrimalStart(), y, 1e+3)
    f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0)
    c1 = MOI.add_constraint(model_w, f, MOI.LessThan(1.0))
    c2 = MOI.add_constraint(model_w, f, MOI.GreaterThan(0.0))
    MOI.write_to_file(model_w, TEST_MOF_FILE)
    _validate(TEST_MOF_FILE)
    model_r = MOF.Model()
    MOI.read_from_file(model_r, TEST_MOF_FILE)
    start_x = MOI.get(
        model_r,
        MOI.VariablePrimalStart(),
        MOI.get(model_r, MOI.VariableIndex, "x"),
    )
    start_y = MOI.get(
        model_r,
        MOI.VariablePrimalStart(),
        MOI.get(model_r, MOI.VariableIndex, "y"),
    )
    @test isnothing(start_x)
    @test start_y == 1e+3
end

function test_constraint_start_scalar()
    model_w = MOF.Model()
    x = MOI.add_variable(model_w)
    MOI.set(model_w, MOI.VariableName(), x, "x")
    y = MOI.add_variable(model_w)
    MOI.set(model_w, MOI.VariableName(), y, "y")
    f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0)
    c1 = MOI.add_constraint(model_w, f, MOI.LessThan(1.0))
    MOI.set(model_w, MOI.ConstraintName(), c1, "c1")
    c2 = MOI.add_constraint(model_w, f, MOI.GreaterThan(0.0))
    MOI.set(model_w, MOI.ConstraintName(), c2, "c2")
    MOI.set(model_w, MOI.ConstraintDualStart(), c2, 1e+3)
    MOI.set(model_w, MOI.ConstraintPrimalStart(), c2, 1e+4)
    MOI.write_to_file(model_w, TEST_MOF_FILE)
    _validate(TEST_MOF_FILE)
    model_r = MOF.Model()
    MOI.read_from_file(model_r, TEST_MOF_FILE)
    dual_start_c1 = MOI.get(
        model_r,
        MOI.ConstraintDualStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c1"),
    )
    dual_start_c2 = MOI.get(
        model_r,
        MOI.ConstraintDualStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c2"),
    )
    primal_start_c1 = MOI.get(
        model_r,
        MOI.ConstraintPrimalStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c1"),
    )
    primal_start_c2 = MOI.get(
        model_r,
        MOI.ConstraintPrimalStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c2"),
    )
    @test isnothing(dual_start_c1)
    @test dual_start_c2 == 1e+3
    @test isnothing(primal_start_c1)
    @test primal_start_c2 == 1e+4
end

function test_constraint_start_conic()
    model_w = MOF.Model()
    x = MOI.add_variables(model_w, 4)
    for (index, variable) in enumerate(x)
        MOI.set(model_w, MOI.VariableName(), variable, "var_$(index)")
    end
    c1 = MOI.add_constraint(model_w, [i for i in x], MOI.SecondOrderCone(4))
    MOI.set(model_w, MOI.ConstraintName(), c1, "c1")
    MOI.set(model_w, MOI.ConstraintDualStart(), c1, [1, 0, 0, 0])
    MOI.set(model_w, MOI.ConstraintPrimalStart(), c1, [1, 1, 1, 1])
    c2 = MOI.add_constraint(model_w, [i for i in x], MOI.SecondOrderCone(4))
    MOI.set(model_w, MOI.ConstraintName(), c2, "c2")
    MOI.write_to_file(model_w, TEST_MOF_FILE)
    _validate(TEST_MOF_FILE)
    model_r = MOF.Model()
    MOI.read_from_file(model_r, TEST_MOF_FILE)
    dual_start_c1 = MOI.get(
        model_r,
        MOI.ConstraintDualStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c1"),
    )
    dual_start_c2 = MOI.get(
        model_r,
        MOI.ConstraintDualStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c2"),
    )
    primal_start_c1 = MOI.get(
        model_r,
        MOI.ConstraintPrimalStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c1"),
    )
    primal_start_c2 = MOI.get(
        model_r,
        MOI.ConstraintPrimalStart(),
        MOI.get(model_r, MOI.ConstraintIndex, "c2"),
    )

    @test dual_start_c1 == [1, 0, 0, 0]
    @test isnothing(dual_start_c2)
    @test primal_start_c1 == [1, 1, 1, 1]
    @test isnothing(primal_start_c2)
end

function test_parse_int_coefficient_scalaraffineterm()
    x = MOI.VariableIndex(1)
    object = Dict{String,Any}("coefficient" => 2, "variable" => "x")
    @test MOF.parse_scalar_affine_term(object, Dict("x" => x)) ==
          MOI.ScalarAffineTerm{Float64}(2.0, x)
    return
end

function test_parse_int_coefficient_scalaraffinefunction()
    x = MOI.VariableIndex(1)
    object = Dict{String,Any}(
        "type" => "ScalarAffineFunction",
        "terms" => [],
        "constant" => 2,
    )
    @test MOF.function_to_moi(object, Dict("x" => x)) ≈
          MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[], 2.0)
    return
end

function test_parse_int_coefficient_scalarquadraticterm()
    x = MOI.VariableIndex(1)
    object = Dict{String,Any}(
        "coefficient" => 2,
        "variable_1" => "x",
        "variable_2" => "x",
    )
    @test MOF.parse_scalar_quadratic_term(object, Dict("x" => x)) ==
          MOI.ScalarQuadraticTerm{Float64}(2.0, x, x)
    return
end

function test_parse_int_coefficient_scalarquadraticfunction()
    x = MOI.VariableIndex(1)
    object = Dict{String,Any}(
        "type" => "ScalarQuadraticFunction",
        "quadratic_terms" => [],
        "affine_terms" => [],
        "constant" => 2,
    )
    f = MOI.ScalarQuadraticFunction(
        MOI.ScalarQuadraticTerm{Float64}[],
        MOI.ScalarAffineTerm{Float64}[],
        2.0,
    )
    @test MOF.function_to_moi(object, Dict("x" => x)) ≈ f
    return
end

function test_parse_constraintname_variable()
    io = IOBuffer()
    print(
        io,
        """{
    "version": {"major": 1, "minor": 2},
    "variables": [{"name": "x", "primal_start": 0.0}],
    "objective": {"sense": "min", "function": {"type": "Variable", "name": "x"}},
    "constraints": [{
        "name": "x >= 1",
        "function": {
            "type": "ScalarAffineFunction",
            "terms": [{"coefficient": 1, "variable": "x"}],
            "constant": 0
        },
        "set": {"type": "GreaterThan", "lower": 1},
        "primal_start": 1,
        "dual_start": 0
    }, {
        "name": "x ∈ [0, 1]",
        "function": {"type": "Variable", "name": "x"},
        "set": {"type": "Interval", "lower": 0, "upper": 1}
    }]
}""",
    )
    seekstart(io)
    model = MOF.Model()
    read!(io, model)
    x = MOI.get(model, MOI.VariableIndex, "x")
    @test MOI.get(model, MOI.NumberOfVariables()) == 1
    @test MOI.get(model, MOI.VariablePrimalStart(), x) == 0.0
    F, S = MOI.VariableIndex, MOI.Interval{Float64}
    @test MOI.get(model, MOI.NumberOfConstraints{F,S}()) == 1
    ci = first(MOI.get(model, MOI.ListOfConstraintIndices{F,S}()))
    @test MOI.get(model, MOI.ConstraintFunction(), ci) == x
    @test MOI.get(model, MOI.ConstraintSet(), ci) == MOI.Interval(0.0, 1.0)
    F, S = MOI.ScalarAffineFunction{Float64}, MOI.GreaterThan{Float64}
    @test isa(
        MOI.get(model, MOI.ConstraintIndex, "x >= 1"),
        MOI.ConstraintIndex{F,S},
    )
    return
end

function test_parse_nonlinear_objective_only()
    io = IOBuffer()
    print(
        io,
        """{
    "version": {"major": 1, "minor": 2},
    "variables": [{"name": "x"}],
    "objective": {
        "sense": "min",
        "function": {
            "type": "ScalarNonlinearFunction",
            "root": {"type": "node", "index": 1},
            "node_list": [{"type": "sin", "args": [{"type": "variable", "name": "x"}]}]
        }
    },
    "constraints": []
}""",
    )
    seekstart(io)
    model = MOF.Model()
    read!(io, model)
    block = MOI.get(model, MOI.NLPBlock())
    @test block isa MOI.NLPBlockData
    @test block.has_objective
    MOI.initialize(block.evaluator, Symbol[])
    @test MOI.eval_objective(block.evaluator, [2.0]) ≈ sin(2.0)
    return
end

function runtests()
    for name in names(@__MODULE__, all = true)
        if startswith("$(name)", "test_")
            @testset "$name" begin
                getfield(@__MODULE__, name)()
            end
        end
    end
    sleep(1.0)  # allow time for unlink to happen
    rm(TEST_MOF_FILE, force = true)
    rm(TEST_MOF_FILE * ".gz", force = true)
    return
end

end

TestMOF.runtests()
