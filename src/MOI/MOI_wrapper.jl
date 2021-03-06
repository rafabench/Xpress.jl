@static if v"1.2" > VERSION >= v"1.1"
    # see: https://github.com/JuliaOpt/Xpress.jl/pull/44#issuecomment-585882858
    error("Versions 1.1.x of julia are not supported. The current verions is $(VERSION)")
end

import MathOptInterface
using SparseArrays

const MOI = MathOptInterface
const CleverDicts = MOI.Utilities.CleverDicts

@enum(
    VariableType,
    CONTINUOUS,
    BINARY,
    INTEGER,
    SEMIINTEGER,
    SEMICONTINUOUS,
)

@enum(
    BoundType,
    NONE,
    LESS_THAN,
    GREATER_THAN,
    LESS_AND_GREATER_THAN,
    INTERVAL,
    EQUAL_TO,
)

@enum(
    ObjectiveType,
    SINGLE_VARIABLE,
    SCALAR_AFFINE,
    SCALAR_QUADRATIC,
)

@enum(
    CallbackState,
    CB_NONE,
    CB_GENERIC,
    CB_LAZY,
    CB_USER_CUT,
    CB_HEURISTIC,
)

const SCALAR_SETS = Union{
    MOI.GreaterThan{Float64},
    MOI.LessThan{Float64},
    MOI.EqualTo{Float64},
    MOI.Interval{Float64},
}

mutable struct VariableInfo
    index::MOI.VariableIndex
    column::Int
    bound::BoundType
    type::VariableType
    start::Union{Float64, Nothing}
    name::String
    # Storage for constraint names associated with variables because Xpress can
    # only store names for variables and proper constraints. We can perform an
    # optimization and only store three strings for the constraint names
    # because, at most, there can be three SingleVariable constraints, e.g.,
    # LessThan, GreaterThan, and Integer.
    lessthan_name::String
    greaterthan_interval_or_equalto_name::String
    type_constraint_name::String
    # Storage for the lower bound if the variable is the `t` variable in a
    # second order cone.
    lower_bound_if_soc::Float64
    num_soc_constraints::Int
    previous_lower_bound::Float64
    previous_upper_bound::Float64
    function VariableInfo(index::MOI.VariableIndex, column::Int)
        return new(
            index,
            column,
            NONE,
            CONTINUOUS,
            nothing,
            "",
            "",
            "",
            "",
            NaN,
            0
        )
    end
end

mutable struct ConstraintInfo
    row::Int
    set::MOI.AbstractSet
    # Storage for constraint names. Where possible, these are also stored in the
    # Xpress model.
    # avoid passing names to xpress because it is a slow operation
    # perhaps call lazy on calls for writing lps and so on
    name::String
    ConstraintInfo(row::Int, set::MOI.AbstractSet) = new(row, set, "")
end

mutable struct CachedSolution
    variable_primal::Vector{Float64}
    variable_dual::Vector{Float64}

    linear_primal::Vector{Float64}
    linear_dual::Vector{Float64}

    # TODO double check this, xpress like to number all constraits with unique indexing
    quadratic_primal::Vector{Float64}
    quadratic_dual::Vector{Float64}

    has_primal_certificate::Bool
    has_dual_certificate::Bool

    solve_time::Float64
end

mutable struct Optimizer <: MOI.AbstractOptimizer
    # The low-level Xpress model.
    inner::XpressProblem

    # The model name. TODO: pass through to .inner.
    name::String

    # A flag to keep track of MOI.Silent, which over-rides the OutputFlag
    # parameter.
    # Windows is alway silent, callback or external file must be used
    silent::Bool

    # An enum to remember what objective is currently stored in the model.
    objective_type::ObjectiveType

    # A flag to keep track of MOI.FEASIBILITY_SENSE, since Xpress only stores
    # MIN_SENSE or MAX_SENSE. This allows us to differentiate between MIN_SENSE
    # and FEASIBILITY_SENSE.
    is_feasibility::Bool

    # A mapping from the MOI.VariableIndex to the Xpress column. VariableInfo
    # also stores some additional fields like what bounds have been added, the
    # variable type, and the names of SingleVariable-in-Set constraints.
    variable_info::CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}

    # An index that is incremented for each new constraint (regardless of type).
    # We can check if a constraint is valid by checking if it is in the correct
    # xxx_constraint_info. We should _not_ reset this to zero, since then new
    # constraints cannot be distinguished from previously created ones.
    last_constraint_index::Int
    # ScalarAffineFunction{Float64}-in-Set storage.
    affine_constraint_info::Dict{Int, ConstraintInfo}
    # ScalarQuadraticFunction{Float64}-in-Set storage.
    quadratic_constraint_info::Dict{Int, ConstraintInfo}
    # VectorOfVariables-in-Set storage.
    sos_constraint_info::Dict{Int, ConstraintInfo}
    # Note: we do not have a singlevariable_constraint_info dictionary. Instead,
    # data associated with these constraints are stored in the VariableInfo
    # objects.

    # Mappings from variable and constraint names to their indices. These are
    # lazily built on-demand, so most of the time, they are `nothing`.
    name_to_variable::Union{Nothing, Dict{String, Union{Nothing, MOI.VariableIndex}}}
    name_to_constraint_index::Union{Nothing, Dict{String, Union{Nothing, MOI.ConstraintIndex}}}

    # TODO: add functionality to the lower-level API to support querying single
    # elements of the solution.
    cached_solution::Union{Nothing, CachedSolution}
    conflict #::Union{Nothing, ConflictRefinerData}

    # Callback fields.
    callback_variable_primal::Vector{Float64}
    has_generic_callback::Bool
    callback_state::CallbackState
    lazy_callback::Union{Nothing, Function}
    user_cut_callback::Union{Nothing, Function}
    heuristic_callback::Union{Nothing, Function}

    params::Dict{Any, Any}

    """
        Optimizer()

    Create a new Optimizer object.
    """
    function Optimizer(; kwargs...)
        model = new()

        model.params = Dict{Any,Any}()

        for (name, value) in kwargs
            if name == :logfile
                continue
            end
            model.params[name] = value
        end

        model.inner = XpressProblem(logfile = get(kwargs, :logfile, nothing))

        # TODO: use MOI.set MOI.RawParameter instead
        for (name, value) in model.params
            Xpress.setcontrol!(model.inner, Symbol("XPRS_$(name)"), value)
        end

        if :OUTPUTLOG ∈ keys(model.params) && model.params[:OUTPUTLOG] == 0
            model.silent = true
        else
            model.silent = false
        end
        model.variable_info = CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}()
        model.affine_constraint_info = Dict{Int, ConstraintInfo}()
        model.quadratic_constraint_info = Dict{Int, ConstraintInfo}()
        model.sos_constraint_info = Dict{Int, ConstraintInfo}()
        model.callback_variable_primal = Float64[]
        MOI.empty!(model)  # MOI.empty!(model) re-sets the `.inner` field.

        return model
    end
end


function CachedSolution(model::Optimizer)
    num_variables = length(model.variable_info)
    num_affine = length(model.affine_constraint_info)
    num_quad = length(model.quadratic_constraint_info)
    return CachedSolution(
        fill(NaN, num_variables),
        fill(NaN, num_variables),
        fill(NaN, num_affine),
        fill(NaN, num_affine),
        fill(NaN, num_quad),
        fill(NaN, num_quad),
        false,
        false,
        NaN
    )
end

Base.show(io::IO, model::Optimizer) = show(io, model.inner)

function MOI.empty!(model::Optimizer)
    # Is there a better way to do this?
    # When MOI.empty! is called, we need to clear the memory associated with the XpressProblem
    # This is also a destructor callback in the XpressProblem constructor
    # Xpress.destroyprob(model.inner)
    # We cannot call it twice, finalize is called before atexit
    model.inner = XpressProblem(logfile = model.inner.logfile)
    MOI.set(model, MOI.RawParameter(Xpress.Lib.XPRS_MPSNAMELENGTH), 64)
    MOI.set(model, MOI.RawParameter(Xpress.Lib.XPRS_CALLBACKFROMMASTERTHREAD), 1)
    model.name = ""
    if model.silent
        MOI.set(model, MOI.RawParameter(Xpress.Lib.XPRS_OUTPUTLOG), 0)
    else
        MOI.set(model, MOI.RawParameter(Xpress.Lib.XPRS_OUTPUTLOG), 1)
    end
    Xpress.loadlp(model.inner)
    model.objective_type = SCALAR_AFFINE
    model.is_feasibility = true
    empty!(model.variable_info)
    empty!(model.affine_constraint_info)
    empty!(model.quadratic_constraint_info)
    empty!(model.sos_constraint_info)
    model.name_to_variable = nothing
    model.name_to_constraint_index = nothing
    empty!(model.callback_variable_primal)
    model.cached_solution = nothing
    model.conflict = nothing
    model.callback_state = CB_NONE
    model.has_generic_callback = false
    model.lazy_callback = nothing
    model.user_cut_callback = nothing
    model.heuristic_callback = nothing

    # TODO: use MOI.set MOI.RawParameter instead
    for (name, value) in model.params
        Xpress.setcontrol!(model.inner, Symbol("XPRS_$(name)"), value)
    end
    return
end

function MOI.is_empty(model::Optimizer)
    !isempty(model.name) && return false
    model.objective_type != SCALAR_AFFINE && return false
    model.is_feasibility == false && return false
    !isempty(model.variable_info) && return false
    length(model.affine_constraint_info) != 0 && return false
    length(model.quadratic_constraint_info) != 0 && return false
    length(model.sos_constraint_info) != 0 && return false
    model.name_to_variable !== nothing && return false
    model.name_to_constraint_index !== nothing && return false
    length(model.callback_variable_primal) != 0 && return false
    model.cached_solution !== nothing && return false
    model.callback_state != CB_NONE && return false
    model.has_generic_callback && return false
    model.lazy_callback !== nothing && return false
    model.user_cut_callback !== nothing && return false
    model.heuristic_callback !== nothing && return false
    return true
end

MOI.get(::Optimizer, ::MOI.SolverName) = "Xpress"

function MOI.supports(
    ::Optimizer,
    ::MOI.ObjectiveFunction{F}
) where {F <: Union{
    MOI.SingleVariable,
    MOI.ScalarAffineFunction{Float64},
    MOI.ScalarQuadraticFunction{Float64},
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.SingleVariable}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64},
    MOI.LessThan{Float64},
    MOI.GreaterThan{Float64},
    MOI.Interval{Float64},
    MOI.ZeroOne,
    MOI.Integer,
    # MOI.Semicontinuous{Float64}, # TODO
    # MOI.Semiinteger{Float64}, # TODO
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.VectorOfVariables}, ::Type{F}
) where {F <: Union{
    MOI.SOS1{Float64},
    MOI.SOS2{Float64},
    # MOI.SecondOrderCone, # TODO
    }
}
    return true
end

# We choose _not_ to support ScalarAffineFunction-in-Interval and
# ScalarQuadraticFunction-in-Interval due to the need for range constraints
# and the added complexity.

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarAffineFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64}, MOI.LessThan{Float64}, MOI.GreaterThan{Float64}
}}
    return true
end

function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarQuadraticFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.LessThan{Float64}, MOI.GreaterThan{Float64}
}}
    # Note: Xpress does not support quadratic equality constraints.
    return true
end

MOI.supports(::Optimizer, ::MOI.VariableName, ::Type{MOI.VariableIndex}) = true
MOI.supports(::Optimizer, ::MOI.ConstraintName, ::Type{<:MOI.ConstraintIndex}) = true

MOI.supports(::Optimizer, ::MOI.Name) = true
MOI.supports(::Optimizer, ::MOI.Silent) = true
MOI.supports(::Optimizer, ::MOI.NumberOfThreads) = true
MOI.supports(::Optimizer, ::MOI.TimeLimitSec) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveSense) = true
MOI.supports(::Optimizer, ::MOI.RawParameter) = true

function MOI.set(model::Optimizer, param::MOI.RawParameter, value)
    Xpress.setcontrol!(model.inner, param.name, value)
    return
end

function MOI.get(model::Optimizer, param::MOI.RawParameter)
    return Xpress.getcontrol(model.inner, param.name)
end

function MOI.set(model::Optimizer, ::MOI.TimeLimitSec, limit::Real)
    MOI.set(model, MOI.RawParameter(Xpress.Lib.XPRS_MAXTIME), limit)
    return
end

function MOI.get(model::Optimizer, ::MOI.TimeLimitSec)
    return MOI.get(model, MOI.RawParameter(Xpress.Lib.XPRS_MAXTIME))
end

MOI.Utilities.supports_default_copy_to(::Optimizer, ::Bool) = true

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike; kwargs...)
    return MOI.Utilities.automatic_copy_to(dest, src; kwargs...)
end

function MOI.get(model::Optimizer, ::MOI.ListOfVariableAttributesSet)
    return MOI.AbstractVariableAttribute[MOI.VariableName()]
end

function MOI.get(model::Optimizer, ::MOI.ListOfModelAttributesSet)
    attributes = Any[MOI.ObjectiveSense()]
    typ = MOI.get(model, MOI.ObjectiveFunctionType())
    if typ !== nothing
        push!(attributes, MOI.ObjectiveFunction{typ}())
    end
    if MOI.get(model, MOI.Name()) != ""
        push!(attributes, MOI.Name())
    end
    return attributes
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraintAttributesSet)
    return MOI.AbstractConstraintAttribute[MOI.ConstraintName()]
end

function _indices_and_coefficients(
    indices::AbstractVector{<:Integer},
    coefficients::AbstractVector{Float64},
    model::Optimizer,
    f::MOI.ScalarAffineFunction{Float64}
)
    for (i, term) in enumerate(f.terms)
        indices[i] = _info(model, term.variable_index).column
        coefficients[i] = term.coefficient
    end
    return indices, coefficients
end

function _indices_and_coefficients(
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64}
)
    f_canon = MOI.Utilities.canonical(f)
    nnz = length(f_canon.terms)
    indices = Vector{Int}(undef, nnz)
    coefficients = Vector{Float64}(undef, nnz)
    _indices_and_coefficients(indices, coefficients, model, f_canon)
    return indices, coefficients
end

function _indices_and_coefficients(
    I::AbstractVector{Int},
    J::AbstractVector{Int},
    V::AbstractVector{Float64},
    indices::AbstractVector{Int},
    coefficients::AbstractVector{Float64},
    model::Optimizer,
    f::MOI.ScalarQuadraticFunction
)
    for (i, term) in enumerate(f.quadratic_terms)
        I[i] = _info(model, term.variable_index_1).column
        J[i] = _info(model, term.variable_index_2).column
        V[i] =  term.coefficient

        # MOI    represents objective as 0.5 x' Q x
        # Example: obj = 2x^2 + x*y + y^2
        #              = 2x^2 + (1/2)*x*y + (1/2)*y*x + y^2
        #   |x y| * |a b| * |x| = |ax+by bx+cy| * |x| = 0.5ax^2 + bxy + 0.5cy^2
        #           |b c|   |y|                   |y|
        #   Hence:
        #          0.5*Q = |  2    1/2 |  => Q = | 4  1 |
        #                  | 1/2    1  |         | 1  2 |
        #   Only one triangle (upper and lower are equal) is saved in MOI
        #   Hence:
        #          ScalarQuadraticTerm.([4.0, 1.0, 2.0], [x, x, y], [x, y, y])
        # Xpress ALSO represents objective as 0.5 x' Q x
        #   Again, only one triangle is added.
        #   In other words,
        #      Xpress uses the SAME convention as MOI for OBJECTIVE
        #      Hence, no modifications are needed for OBJECTIVE.
        #   However,
        #     For onstraints, Xpress does NOT have the 0.5 factor in front of the Q matrix
        #     Hence,
        #     Only for constraints, MOI -> Xpress => divide all by 2
        #     Only for constraints, Xpress -> MOI => multiply all by 2

    end
    for (i, term) in enumerate(f.affine_terms)
        indices[i] = _info(model, term.variable_index).column
        coefficients[i] = term.coefficient
    end
    return
end

function _indices_and_coefficients(
    model::Optimizer, f::MOI.ScalarQuadraticFunction
)
    f_canon = MOI.Utilities.canonical(f)
    nnz_quadratic = length(f_canon.quadratic_terms)
    nnz_affine = length(f_canon.affine_terms)
    I = Vector{Int}(undef, nnz_quadratic)
    J = Vector{Int}(undef, nnz_quadratic)
    V = Vector{Float64}(undef, nnz_quadratic)
    indices = Vector{Int}(undef, nnz_affine)
    coefficients = Vector{Float64}(undef, nnz_affine)
    _indices_and_coefficients(I, J, V, indices, coefficients, model, f_canon)
    return indices, coefficients, I, J, V
end

_sense_and_rhs(s::MOI.LessThan{Float64}) = (Cchar('L'), s.upper)
_sense_and_rhs(s::MOI.GreaterThan{Float64}) = (Cchar('G'), s.lower)
_sense_and_rhs(s::MOI.EqualTo{Float64}) = (Cchar('E'), s.value)

###
### Variables
###

# Short-cuts to return the VariableInfo associated with an index.
function _info(model::Optimizer, key::MOI.VariableIndex)
    if haskey(model.variable_info, key)
        return model.variable_info[key]
    end
    throw(MOI.InvalidIndex(key))
end

function MOI.add_variable(model::Optimizer)
    # Initialize `VariableInfo` with a dummy `VariableIndex` and a column,
    # because we need `add_item` to tell us what the `VariableIndex` is.
    index = CleverDicts.add_item(
        model.variable_info, VariableInfo(MOI.VariableIndex(0), 0)
    )
    info = _info(model, index)
    info.index = index
    info.column = length(model.variable_info)
    Xpress.addcols(
        model.inner,
        [0.0],#_dobj::Vector{Float64},
        Int[],#_mstart::Vector{Int},
        Int[],#_mrwind::Vector{Int},
        Float64[],#_dmatval::Vector{Float64},
        [-Inf],#_dbdl::Vector{Float64},
        [Inf],#_dbdu::Vector{Float64}
    )
    return index
end

function MOI.add_variables(model::Optimizer, N::Int)
    Xpress.addcols(
        model.inner,
        zeros(N),# _dobj::Vector{Float64},
        Int[],# _mstart::Vector{Int},
        Int[],# _mrwind::Vector{Int},
        Float64[],# _dmatval::Vector{Float64},
        fill(-Inf, N),# _dbdl::Vector{Float64},
        fill(Inf, N),# _dbdu::Vector{Float64}
    )
    indices = Vector{MOI.VariableIndex}(undef, N)
    num_variables = length(model.variable_info)
    for i in 1:N
        # Initialize `VariableInfo` with a dummy `VariableIndex` and a column,
        # because we need `add_item` to tell us what the `VariableIndex` is.
        index = CleverDicts.add_item(
            model.variable_info, VariableInfo(MOI.VariableIndex(0), 0)
        )
        info = _info(model, index)
        info.index = index
        info.column = num_variables + i
        indices[i] = index
    end
    return indices
end

function MOI.is_valid(model::Optimizer, v::MOI.VariableIndex)
    return haskey(model.variable_info, v)
end

function MOI.delete(model::Optimizer, v::MOI.VariableIndex)
    info = _info(model, v)
    if info.num_soc_constraints > 0
        throw(MOI.DeleteNotAllowed(v))
    end
    Xpress.delcols(model.inner, [info.column])
    delete!(model.variable_info, v)
    for other_info in values(model.variable_info)
        if other_info.column > info.column
            other_info.column -= 1
        end
    end
    model.name_to_variable = nothing
    # We throw away name_to_constraint_index so we will rebuild SingleVariable
    # constraint names without v.
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(model::Optimizer, ::Type{MOI.VariableIndex}, name::String)
    if model.name_to_variable === nothing
        _rebuild_name_to_variable(model)
    end
    if haskey(model.name_to_variable, name)
        variable = model.name_to_variable[name]
        if variable === nothing
            error("Duplicate variable name detected: $(name)")
        end
        return variable
    end
    return nothing
end

function _rebuild_name_to_variable(model::Optimizer)
    model.name_to_variable = Dict{String, Union{Nothing, MOI.VariableIndex}}()
    for (index, info) in model.variable_info
        if info.name == ""
            continue
        end
        if haskey(model.name_to_variable, info.name)
            model.name_to_variable[info.name] = nothing
        else
            model.name_to_variable[info.name] = index
        end
    end
    return
end

function MOI.get(model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex)
    return _info(model, v).name
end

function MOI.set(
    model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex, name::String
)
    info = _info(model, v)
    info.name = name
    # Note: don't set the string names in the Xpress C API because it complains
    # on duplicate variables.
    # That is, don't call `Xpress.addnames`.
    model.name_to_variable = nothing
    return
end

###
### Objectives
###

function _zero_objective(model::Optimizer)
    num_vars = length(model.variable_info)
    obj = zeros(Float64, num_vars)
    if model.objective_type == SCALAR_QUADRATIC
        # We need to zero out the existing quadratic objective.
        Xpress.delq!(model.inner)
    end
    Xpress.chgobj(model.inner, collect(1:num_vars), obj)
    Xpress.chgobj(model.inner, [0], [0.0])
    return
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense
)
    if sense == MOI.MIN_SENSE
        Xpress.chgobjsense(model.inner, :Min)
        model.is_feasibility = false
    elseif sense == MOI.MAX_SENSE
        Xpress.chgobjsense(model.inner, :Max)
        model.is_feasibility = false
    else
        @assert sense == MOI.FEASIBILITY_SENSE
        _zero_objective(model)
        Xpress.chgobjsense(model.inner, :Min)
        model.is_feasibility = true
    end
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveSense)
    sense = Xpress.objective_sense(model.inner)
    if model.is_feasibility
        return MOI.FEASIBILITY_SENSE
    elseif sense == :maximize
        return MOI.MAX_SENSE
    else
        @assert sense == :minimize
        return MOI.MIN_SENSE
    end
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.SingleVariable}
    MOI.set(
        model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        convert(MOI.ScalarAffineFunction{Float64}, f)
    )
    model.objective_type = SINGLE_VARIABLE
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunction{MOI.SingleVariable})
    obj = MOI.get(
        model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}()
    )
    return convert(MOI.SingleVariable, obj)
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.ScalarAffineFunction{Float64}}
    if model.objective_type == SCALAR_QUADRATIC
        # We need to zero out the existing quadratic objective.
        Xpress.delq!(model.inner)
    end
    num_vars = length(model.variable_info)
    # We zero all terms because we want to gurantee that the old terms
    # are removed
    obj = zeros(Float64, num_vars)
    for term in f.terms
        column = _info(model, term.variable_index).column
        obj[column] += term.coefficient
    end
    Xpress.chgobj(model.inner, collect(1:num_vars), obj)
    Xpress.chgobj(model.inner, [0], [-f.constant])
    model.objective_type = SCALAR_AFFINE
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}
)
    dest = Xpress.getobj(model.inner)
    terms = MOI.ScalarAffineTerm{Float64}[]
    for (index, info) in model.variable_info
        coefficient = dest[info.column]
        iszero(coefficient) && continue
        push!(terms, MOI.ScalarAffineTerm(coefficient, index))
    end
    constant = Xpress.getdblattrib(model.inner, Xpress.Lib.XPRS_OBJRHS)
    return MOI.ScalarAffineFunction(terms, constant)
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.ScalarQuadraticFunction{Float64}}
    # setting linear part also clears the existing quadratic terms
    MOI.set(
        model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        MOI.ScalarAffineFunction(f.affine_terms, f.constant)
    )
    affine_indices, affine_coefficients, I, J, V = _indices_and_coefficients(
        model, f
    )
    obj = zeros(length(model.variable_info))
    for (i, c) in zip(affine_indices, affine_coefficients)
        obj[i] = c
    end
    Xpress.chgmqobj(model.inner, I, J, V)
    model.objective_type = SCALAR_QUADRATIC
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}
)
    dest = zeros(length(model.variable_info))
    nnz = n_quadratic_elements(model.inner)
    n = n_variables(model.inner)
    nels = Array{Cint}(undef, 1)
    nels[1] = nnz
    mstart = Array{Cint}(undef, n + 1)
    mclind = Array{Cint}(undef, nnz)
    dobjval = Array{Float64}(undef, nnz)
    getmqobj(model.inner, mstart, mclind, dobjval, nnz, nels, 0, n - 1)
    triangle_nnz = nels[1]
    mstart[end] = triangle_nnz
    I = Array{Int}(undef, triangle_nnz)
    J = Array{Int}(undef, triangle_nnz)
    V = Array{Float64}(undef, triangle_nnz)
    for i in 1:length(mstart)-1
        for j in (mstart[i]+1):mstart[i+1]
            I[j] = i
            J[j] = mclind[j]+1
            V[j] = dobjval[j]
        end
    end
    q_terms = MOI.ScalarQuadraticTerm{Float64}[]
    row = 0
    for (i, j, coeff) in zip(I, J, V)
        iszero(coeff) && continue
        push!(
            q_terms,
            MOI.ScalarQuadraticTerm(
                coeff,
                model.variable_info[CleverDicts.LinearIndex(i)].index,
                model.variable_info[CleverDicts.LinearIndex(j)].index
            )
        )
    end
    affine_terms = MOI.get(model, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}()).terms
    constant = Xpress.getdblattrib(model.inner, Xpress.Lib.XPRS_OBJRHS)
    return MOI.ScalarQuadraticFunction(affine_terms, q_terms, constant)
end

function MOI.modify(
    model::Optimizer,
    ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}},
    chg::MOI.ScalarConstantChange{Float64}
)
    Xpress.chgobj(model.inner, [0], [-chg.new_constant])
    return
end

##
##  SingleVariable-in-Set constraints.
##

function _info(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    var_index = MOI.VariableIndex(c.value)
    if haskey(model.variable_info, var_index)
        return _info(model, var_index)
    end
    return throw(MOI.InvalidIndex(c))
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    if haskey(model.variable_info, MOI.VariableIndex(c.value))
        info = _info(model, c)
        return info.bound == LESS_THAN || info.bound == LESS_AND_GREATER_THAN
    end
    return false
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    if haskey(model.variable_info, MOI.VariableIndex(c.value))
        info = _info(model, c)
        return info.bound == GREATER_THAN || info.bound == LESS_AND_GREATER_THAN
    end
    return false
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).bound == INTERVAL
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).bound == EQUAL_TO
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == BINARY
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == INTEGER
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == SEMICONTINUOUS
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == SEMIINTEGER
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.SingleVariable(MOI.VariableIndex(c.value))
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}, ::MOI.SingleVariable
)
    return throw(MOI.SettingSingleVariableFunctionNotAllowed())
end

_bounds(s::MOI.GreaterThan{Float64}) = (s.lower, nothing)
_bounds(s::MOI.LessThan{Float64}) = (nothing, s.upper)
_bounds(s::MOI.EqualTo{Float64}) = (s.value, s.value)
_bounds(s::MOI.Interval{Float64}) = (s.lower, s.upper)

function _throw_if_existing_lower(
    bound::BoundType, var_type::VariableType,
    new_set::Type{<:MOI.AbstractSet},
    variable::MOI.VariableIndex
)
    existing_set = if bound == LESS_AND_GREATER_THAN || bound == GREATER_THAN
        MOI.GreaterThan{Float64}
    elseif bound == INTERVAL
        MOI.Interval{Float64}
    elseif bound == EQUAL_TO
        MOI.EqualTo{Float64}
    elseif var_type == SEMIINTEGER
        MOI.Semiinteger{Float64}
    elseif var_type == SEMICONTINUOUS
        MOI.Semicontinuous{Float64}
    else
        nothing  # Also covers `NONE` and `LESS_THAN`.
    end
    if existing_set !== nothing
        throw(MOI.LowerBoundAlreadySet{existing_set, new_set}(variable))
    end
end

function _throw_if_existing_upper(
    bound::BoundType,
    var_type::VariableType,
    new_set::Type{<:MOI.AbstractSet},
    variable::MOI.VariableIndex
)
    existing_set = if bound == LESS_AND_GREATER_THAN || bound == LESS_THAN
        MOI.LessThan{Float64}
    elseif bound == INTERVAL
        MOI.Interval{Float64}
    elseif bound == EQUAL_TO
        MOI.EqualTo{Float64}
    elseif var_type == SEMIINTEGER
        MOI.Semiinteger{Float64}
    elseif var_type == SEMICONTINUOUS
        MOI.Semicontinuous{Float64}
    else
        nothing  # Also covers `NONE` and `GREATER_THAN`.
    end
    if existing_set !== nothing
        throw(MOI.UpperBoundAlreadySet{existing_set, new_set}(variable))
    end
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::S
) where {S <: SCALAR_SETS}
    info = _info(model, f.variable)
    if S <: MOI.LessThan{Float64}
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = info.bound == GREATER_THAN ? LESS_AND_GREATER_THAN : LESS_THAN
    elseif S <: MOI.GreaterThan{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        info.bound = info.bound == LESS_THAN ? LESS_AND_GREATER_THAN : GREATER_THAN
    elseif S <: MOI.EqualTo{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = EQUAL_TO
    else
        @assert S <: MOI.Interval{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = INTERVAL
    end
    index = MOI.ConstraintIndex{MOI.SingleVariable, typeof(s)}(f.variable.value)
    MOI.set(model, MOI.ConstraintSet(), index, s)
    return index
end

function MOI.add_constraints(
    model::Optimizer, f::Vector{MOI.SingleVariable}, s::Vector{S}
) where {S <: SCALAR_SETS}
    for fi in f
        info = _info(model, fi.variable)
        if S <: MOI.LessThan{Float64}
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = info.bound == GREATER_THAN ? LESS_AND_GREATER_THAN : LESS_THAN
        elseif S <: MOI.GreaterThan{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            info.bound = info.bound == LESS_THAN ? LESS_AND_GREATER_THAN : GREATER_THAN
        elseif S <: MOI.EqualTo{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = EQUAL_TO
        else
            @assert S <: MOI.Interval{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = INTERVAL
        end
    end
    indices = [
        MOI.ConstraintIndex{MOI.SingleVariable, eltype(s)}(fi.variable.value)
        for fi in f
    ]
    _set_bounds(model, indices, s)
    return indices
end

function _set_bounds(
    model::Optimizer,
    indices::Vector{MOI.ConstraintIndex{MOI.SingleVariable, S}},
    sets::Vector{S}
) where {S}
    columns, senses, values = Int[], Cchar[], Float64[]
    for (c, s) in zip(indices, sets)
        lower, upper = _bounds(s)
        info = _info(model, c)
        if lower !== nothing
            push!(columns, info.column)
            push!(senses, Cchar('L'))
            push!(values, lower)
        end
        if upper !== nothing
            push!(columns, info.column)
            push!(senses, Cchar('U'))
            push!(values, upper)
        end
    end
    Xpress.chgbounds(model.inner, columns, senses, values)
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_upper_bound(model, info, Inf)
    if info.bound == LESS_AND_GREATER_THAN
        info.bound = GREATER_THAN
    else
        info.bound = NONE
    end
    info.lessthan_name = ""
    model.name_to_constraint_index = nothing
    return
end

"""
    _set_variable_lower_bound(model, info, value)

This function is used to indirectly set the lower bound of a variable.

We need to do it this way to account for potential lower bounds of 0.0 added by
VectorOfVariables-in-SecondOrderCone constraints.

See also `_get_variable_lower_bound`.
"""
function _set_variable_lower_bound(model, info, value)
    if info.num_soc_constraints == 0
        # No SOC constraints, set directly.
        @assert isnan(info.lower_bound_if_soc)
        Xpress.chgbounds(model.inner, [info.column], Cchar['L'], [value])
    else
        # TODO
        error("SOC not currently supported")
    end
    # elseif value >= 0.0
    #     # Regardless of whether there are SOC constraints, this is a valid bound
    #     # for the SOC constraint and should over-ride any previous bounds.
    #     info.lower_bound_if_soc = NaN
    #     CPLEX.c_api_chgbds(model.inner, [info.column], Cchar['L'], [value])
    # elseif isnan(info.lower_bound_if_soc)
    #     # Previously, we had a non-negative lower bound (i.e., it was set in the
    #     # case above). Now we're setting this with a negative one, but there are
    #     # still some SOC constraints, so we cache `value` and set the variable
    #     # lower bound to `0.0`.
    #     @assert value < 0.0
    #     CPLEX.c_api_chgbds(model.inner, [info.column], Cchar['L'], [0.0])
    #     info.lower_bound_if_soc = value
    # else
    #     # Previously, we had a negative lower bound. We're setting this with
    #     # another negative one, but there are still some SOC constraints.
    #     @assert info.lower_bound_if_soc < 0.0
    #     info.lower_bound_if_soc = value
    # end
end

"""
    _get_variable_lower_bound(model, info)

Get the current variable lower bound, ignoring a potential bound of `0.0` set
by a second order cone constraint.

See also `_set_variable_lower_bound`.
"""
function _get_variable_lower_bound(model, info)
    if !isnan(info.lower_bound_if_soc)
        # There is a value stored. That means that we must have set a value that
        # was < 0.
        @assert info.lower_bound_if_soc < 0.0
        return info.lower_bound_if_soc
    end
    lb = Xpress.getlb(model.inner, info.column, info.column)[]
    return lb == -Xpress.Lib.XPRS_MINUSINFINITY ? -Inf : lb
end

function _set_variable_upper_bound(model, info, value)
    Xpress.chgbounds(model.inner, [info.column], Cchar['U'], [value])
    return
end

function _get_variable_upper_bound(model, info)
    ub = Xpress.getub(model.inner, info.column, info.column)[]
    return ub == Xpress.Lib.XPRS_PLUSINFINITY ? Inf : ub
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    if info.bound == LESS_AND_GREATER_THAN
        info.bound = LESS_THAN
    else
        info.bound = NONE
    end
    info.greaterthan_interval_or_equalto_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    _set_variable_upper_bound(model, info, Inf)
    info.bound = NONE
    info.greaterthan_interval_or_equalto_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    _set_variable_upper_bound(model, info, Inf)
    info.bound = NONE
    info.greaterthan_interval_or_equalto_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    lower = _get_variable_lower_bound(model, _info(model, c))
    return MOI.GreaterThan(lower)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    upper = _get_variable_upper_bound(model, _info(model, c))
    return MOI.LessThan(upper)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    lower = _get_variable_lower_bound(model, _info(model, c))
    return MOI.EqualTo(lower)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    lower = _get_variable_lower_bound(model, info)
    upper = _get_variable_upper_bound(model, info)
    return MOI.Interval(lower, upper)
end

function MOI.set(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}, s::S
) where {S<:SCALAR_SETS}
    MOI.throw_if_not_valid(model, c)
    lower, upper = _bounds(s)
    info = _info(model, c)
    if lower !== nothing
        _set_variable_lower_bound(model, info, lower)
    end
    if upper !== nothing
        _set_variable_upper_bound(model, info, upper)
    end
    return
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, ::MOI.ZeroOne
)
    info = _info(model, f.variable)
    info.previous_lower_bound = _get_variable_lower_bound(model, info)
    info.previous_upper_bound = _get_variable_upper_bound(model, info)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['B'])
    info.type = BINARY
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}(f.variable.value)
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['C'])
    _set_variable_lower_bound(model, info, info.previous_lower_bound)
    _set_variable_upper_bound(model, info, info.previous_upper_bound)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.ZeroOne()
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, ::MOI.Integer
)
    info = _info(model, f.variable)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['I'])
    info.type = INTEGER
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}(f.variable.value)
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['C'])
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.Integer()
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::MOI.Semicontinuous{Float64}
)
    info = _info(model, f.variable)
    _throw_if_existing_lower(info.bound, info.type, typeof(s), f.variable)
    _throw_if_existing_upper(info.bound, info.type, typeof(s), f.variable)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['S'])
    _set_variable_lower_bound(model, info, s.lower)
    _set_variable_upper_bound(model, info, s.upper)
    info.type = SEMICONTINUOUS
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}(f.variable.value)
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['C'])
    _set_variable_lower_bound(model, info, -Inf)
    _set_variable_upper_bound(model, info, Inf)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    lower = _get_variable_lower_bound(model, info)
    upper = _get_variable_upper_bound(model, info)
    return MOI.Semicontinuous(lower, upper)
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::MOI.Semiinteger{Float64}
)
    info = _info(model, f.variable)
    _throw_if_existing_lower(info.bound, info.type, typeof(s), f.variable)
    _throw_if_existing_upper(info.bound, info.type, typeof(s), f.variable)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['P'])
    _set_variable_lower_bound(model, info, s.lower)
    _set_variable_upper_bound(model, info, s.upper)
    info.type = SEMIINTEGER
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}(f.variable.value)
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    Xpress.chgcoltype(model.inner, [info.column], Cchar['C'])
    _set_variable_lower_bound(model, info, -Inf)
    _set_variable_upper_bound(model, info, Inf)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    lower = _get_variable_lower_bound(model, info)
    upper = _get_variable_upper_bound(model, info)
    return MOI.Semiinteger(lower, upper)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}
) where {S}
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    if S <: MOI.LessThan
        return info.lessthan_name
    elseif S <: Union{MOI.GreaterThan, MOI.Interval, MOI.EqualTo}
        return info.greaterthan_interval_or_equalto_name
    else
        @assert S <: Union{MOI.ZeroOne, MOI.Integer, MOI.Semiinteger, MOI.Semicontinuous}
        return info.type_constraint_name
    end
end

function MOI.set(
    model::Optimizer,
    ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}, name::String
) where {S}
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    old_name = ""
    if S <: MOI.LessThan
        old_name = info.lessthan_name
        info.lessthan_name = name
    elseif S <: Union{MOI.GreaterThan, MOI.Interval, MOI.EqualTo}
        old_name = info.greaterthan_interval_or_equalto_name
        info.greaterthan_interval_or_equalto_name = name
    else
        @assert S <: Union{MOI.ZeroOne, MOI.Integer, MOI.Semiinteger, MOI.Semicontinuous}
        info.type_constraint_name
        info.type_constraint_name = name
    end
    model.name_to_constraint_index = nothing
    return
end

###
### ScalarAffineFunction-in-Set
###

function _info(
    model::Optimizer,
    key::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    if haskey(model.affine_constraint_info, key.value)
        return model.affine_constraint_info[key.value]
    end
    throw(MOI.InvalidIndex(key))
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    info = get(model.affine_constraint_info, c.value, nothing)
    if info === nothing
        return false
    else
        return typeof(info.set) == S
    end
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, MOI.EqualTo{Float64}}
)
    if !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    model.last_constraint_index += 1
    model.affine_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.affine_constraint_info) + 1, s)
    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    Xpress.addrows(
        model.inner,
        [sense],#_srowtype,
        [rhs],#_drhs,
        C_NULL,#_drng,
        [1],#_mstart,
        (indices),#_mclind,
        coefficients,#_dmatval
    )
    return MOI.ConstraintIndex{typeof(f), typeof(s)}(model.last_constraint_index)
end

function MOI.add_constraints(
    model::Optimizer, f::Vector{MOI.ScalarAffineFunction{Float64}},
    s::Vector{<:Union{MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, MOI.EqualTo{Float64}}}
)
    if length(f) != length(s)
        error("Number of functions does not equal number of sets.")
    end
    canonicalized_functions = MOI.Utilities.canonical.(f)
    # First pass: compute number of non-zeros to allocate space.
    nnz = 0
    for fi in canonicalized_functions
        if !iszero(fi.constant)
            throw(MOI.ScalarFunctionConstantNotZero{Float64, eltype(f), eltype(s)}(fi.constant))
        end
        nnz += length(fi.terms)
    end
    # Initialize storage
    indices = Vector{MOI.ConstraintIndex{eltype(f), eltype(s)}}(undef, length(f))
    row_starts = Vector{Int}(undef, length(f) + 1)
    row_starts[1] = 1
    columns = Vector{Int}(undef, nnz)
    coefficients = Vector{Float64}(undef, nnz)
    senses = Vector{Cchar}(undef, length(f))
    rhss = Vector{Float64}(undef, length(f))
    # Second pass: loop through, passing views to _indices_and_coefficients.
    for (i, (fi, si)) in enumerate(zip(canonicalized_functions, s))
        senses[i], rhss[i] = _sense_and_rhs(si)
        row_starts[i + 1] = row_starts[i] + length(fi.terms)
        _indices_and_coefficients(
            view(columns, row_starts[i]:row_starts[i + 1] - 1),
            view(coefficients, row_starts[i]:row_starts[i + 1] - 1),
            model, fi
        )
        model.last_constraint_index += 1
        indices[i] = MOI.ConstraintIndex{eltype(f), eltype(s)}(model.last_constraint_index)
        model.affine_constraint_info[model.last_constraint_index] =
            ConstraintInfo(length(model.affine_constraint_info) + 1, si)
    end
    pop!(row_starts)
    Xpress.addrows(
        model.inner,
        senses,#_srowtype,
        rhss,#_drhs,
        C_NULL,#_drng,
        row_starts,#_mstart,
        columns,#_mclind,
        coefficients,#_dmatval
        )
    return indices
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    row = _info(model, c).row
    Xpress.delrows(model.inner, [row])
    for (key, info) in model.affine_constraint_info
        if info.row > row
            info.row -= 1
        end
    end
    delete!(model.affine_constraint_info, c.value)
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    rhs = Vector{Cdouble}(undef, 1)
    row = _info(model, c).row
    @checked Lib.XPRSgetrhs(model.inner, rhs, row-1, row-1)
    return S(rhs[1])
end

function MOI.set(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}, s::S
) where {S}
    Xpress.chgrhs(model.inner, [_info(model, c).row], [MOI.constant(s)])
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    row = _info(model, c).row
    nzcnt_max = Xpress.n_non_zero_elements(model.inner)

    nzcnt = Xpress.getrows_nnz(model.inner, row, row)

    @assert nzcnt <= nzcnt_max

    rmatbeg = zeros(Cint, row-row+2)
    rmatind = Array{Cint}(undef,  nzcnt)
    rmatval = Array{Float64}(undef,  nzcnt)

    Xpress.getrows(
        model.inner,
        rmatbeg,#_mstart,
        rmatind,#_mclind,
        rmatval,#_dmatval,
        nzcnt,#maxcoeffs,
        row,#first::Integer,
        row,#last::Integer
        )

    terms = MOI.ScalarAffineTerm{Float64}[]
    for i = 1:nzcnt
        iszero(rmatval[i]) && continue
        push!(
            terms,
            MOI.ScalarAffineTerm(
                rmatval[i],
                model.variable_info[CleverDicts.LinearIndex(rmatind[i])].index
            )
        )
    end
    return MOI.ScalarAffineFunction(terms, 0.0)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any},
    name::String
)
    info = _info(model, c)
    info.name = name
    # Note: don't set the string names in the Xpress C API because it complains
    # on duplicate contraints.
    # That is, don't call `Xpress.addnames`.
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(model::Optimizer, ::Type{MOI.ConstraintIndex}, name::String)
    if model.name_to_constraint_index === nothing
        _rebuild_name_to_constraint_index(model)
    end
    if haskey(model.name_to_constraint_index, name)
        constr = model.name_to_constraint_index[name]
        if constr === nothing
            error("Duplicate constraint name detected: $(name)")
        end
        return constr
    end
    return nothing
end

function MOI.get(
    model::Optimizer, C::Type{MOI.ConstraintIndex{F, S}}, name::String
) where {F, S}
    index = MOI.get(model, MOI.ConstraintIndex, name)
    if typeof(index) == C
        return index::MOI.ConstraintIndex{F, S}
    end
    return nothing
end

function _rebuild_name_to_constraint_index(model::Optimizer)
    model.name_to_constraint_index = Dict{String, Union{Nothing, MOI.ConstraintIndex}}()
    _rebuild_name_to_constraint_index_util(
        model, model.affine_constraint_info, MOI.ScalarAffineFunction{Float64}
    )
    _rebuild_name_to_constraint_index_util(
        model, model.quadratic_constraint_info, MOI.ScalarQuadraticFunction{Float64}
    )
    _rebuild_name_to_constraint_index_util(
        model, model.sos_constraint_info, MOI.VectorOfVariables
    )
    _rebuild_name_to_constraint_index_variables(model)
    return
end

function _rebuild_name_to_constraint_index_util(model::Optimizer, dict, F)
    for (index, info) in dict
        if info.name == ""
            continue
        elseif haskey(model.name_to_constraint_index, info.name)
            model.name_to_constraint_index[info.name] = nothing
        else
            model.name_to_constraint_index[info.name] =
                MOI.ConstraintIndex{F, typeof(info.set)}(index)
        end
    end
    return
end

function _rebuild_name_to_constraint_index_variables(model::Optimizer)
    for (key, info) in model.variable_info
        for S in (
            MOI.LessThan{Float64}, MOI.GreaterThan{Float64},
            MOI.EqualTo{Float64}, MOI.Interval{Float64}, MOI.ZeroOne,
            MOI.Integer, MOI.Semicontinuous{Float64}, MOI.Semiinteger{Float64}
        )
            constraint_name = ""
            if info.bound in _bound_enums(S)
                constraint_name = S == MOI.LessThan{Float64} ?
                    info.lessthan_name : info.greaterthan_interval_or_equalto_name
            elseif info.type in _type_enums(S)
                constraint_name = info.type_constraint_name
            end
            if constraint_name == ""
                continue
            elseif haskey(model.name_to_constraint_index, constraint_name)
                model.name_to_constraint_index[constraint_name] = nothing
            else
                model.name_to_constraint_index[constraint_name] =
                    MOI.ConstraintIndex{MOI.SingleVariable, S}(key.value)
            end
        end
    end
    return
end

###
### ScalarQuadraticFunction-in-SCALAR_SET
###

function _info(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    if haskey(model.quadratic_constraint_info, c.value)
        return model.quadratic_constraint_info[c.value]
    end
    throw(MOI.InvalidIndex(c))
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.ScalarQuadraticFunction{Float64}, s::SCALAR_SETS
)
    if !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    sense, rhs = _sense_and_rhs(s)
    indices, coefficients, I, J, V = _indices_and_coefficients(model, f)
    Xpress.addrows(
        model.inner, [sense], [rhs], C_NULL, [1], indices, coefficients
    )
    V .*= 0.5 # only for constraints
    Xpress.addqmatrix(model.inner, Xpress.n_constraints(model.inner), I, J, V)
    model.last_constraint_index += 1
    model.affine_constraint_info[model.last_constraint_index] = ConstraintInfo(length(model.affine_constraint_info) + 1, s)
    model.quadratic_constraint_info[model.last_constraint_index] = ConstraintInfo(length(model.quadratic_constraint_info) + 1, s)
    return MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, typeof(s)}(model.last_constraint_index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    info = get(model.quadratic_constraint_info, c.value, nothing)
    return info !== nothing && typeof(info.set) == S
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    info = _info(model, c)
    Xpress.delrows(model.inner, [info.row])
    for (key, info_2) in model.quadratic_constraint_info
        if info_2.row > info.row
            info_2.row -= 1
        end
    end
    delete!(model.quadratic_constraint_info, c.value)
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    rhs = Xpress.getrhs(model.inner, _info(model, c).row, _info(model, c).row)[1]
    return S(rhs)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}

    affine_terms = MOI.get(model, MOI.ConstraintFunction(), MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}(c.value)).terms

    mqcol1, mqcol2, dqe = getqrowqmatrixtriplets(model.inner, _info(model, c).row)

    quadratic_terms = MOI.ScalarQuadraticTerm{Float64}[]
    for (i, j, coef) in zip(mqcol1, mqcol2, dqe)
        push!(
            quadratic_terms,
            MOI.ScalarQuadraticTerm(
                2 * coef, # only for constraints
                model.variable_info[CleverDicts.LinearIndex(i)].index,
                model.variable_info[CleverDicts.LinearIndex(j)].index
            )
        )
    end
    return MOI.ScalarQuadraticFunction(affine_terms, quadratic_terms, 0.0)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S},
    name::String
) where {S}
    info = _info(model, c)
    info.name = name
    model.name_to_constraint_index = nothing
    return
end

###
### VectorOfVariables-in-SOS{I|II}
###

const SOS = Union{MOI.SOS1{Float64}, MOI.SOS2{Float64}}

function _info(
    model::Optimizer,
    key::MOI.ConstraintIndex{MOI.VectorOfVariables, <:SOS}
)
    if haskey(model.sos_constraint_info, key.value)
        return model.sos_constraint_info[key.value]
    end
    throw(MOI.InvalidIndex(key))
end

_sos_type(::MOI.SOS1) = convert(Cchar, '1')
_sos_type(::MOI.SOS2) = convert(Cchar, '2')

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S}
    info = get(model.sos_constraint_info, c.value, nothing)
    if info === nothing || typeof(info.set) != S
        return false
    end
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    return all(MOI.is_valid.(model, f.variables))
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.VectorOfVariables, s::SOS
)
    columns = Int[_info(model, v).column for v in f.variables]
    idx = [0, 0]
    Xpress.addsets(
        model.inner, # prob
        1, # newsets
        length(columns), # newnz
        Cchar[_sos_type(s)], # qstype
        idx, # msstart
        columns, # mscols
        s.weights, # dref
    )
    model.last_constraint_index += 1
    index = MOI.ConstraintIndex{MOI.VectorOfVariables, typeof(s)}(model.last_constraint_index)
    model.sos_constraint_info[index.value] = ConstraintInfo(
        length(model.sos_constraint_info) + 1, s
    )
    return index
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:SOS}
)
    row = _info(model, c).row
    idx = collect(row:row)
    numdel = length(idx)
    delsets(model.inner, numdel, idx .- 1)
    for (key, info) in model.sos_constraint_info
        if info.row > row
            info.row -= 1
        end
    end
    delete!(model.sos_constraint_info, c.value)
    model.name_to_constraint_index = nothing
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:Any}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer,
    ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:Any},
    name::String
)
    info = _info(model, c)
    info.name = name
    model.name_to_constraint_index = nothing
    return
end

function _get_sparse_sos(model)
    nnz = n_setmembers(model.inner)
    nsos = n_special_ordered_sets(model.inner)
    n = n_variables(model.inner)

    settypes = Array{Cchar}(undef, nsos)
    setstart = Array{Cint}(undef, nsos + 1)
    setcols = Array{Cint}(undef, nnz)
    setvals = Array{Float64}(undef, nnz)

    intents = Array{Cint}(undef, 1)
    nsets = Array{Cint}(undef, 1)

    Xpress.getglobal(
        model.inner, intents, nsets, C_NULL, C_NULL, C_NULL, settypes, setstart, setcols, setvals
    )

    setstart[end] = nnz

    I = Array{Int}(undef,  nnz)
    J = Array{Int}(undef,  nnz)
    V = Array{Float64}(undef,  nnz)
    for i in 1:length(setstart) - 1
        for j in (setstart[i]+1):setstart[i+1]
            I[j] = i
            J[j] = setcols[j] + 1
            V[j] = setvals[j]
        end
    end
    return sparse(I, J, V, nsets[1], n)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S <: SOS}
    A = _get_sparse_sos(model)
    return S(A[_info(model, c).row, :].nzval)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S <: SOS}
    A = _get_sparse_sos(model)
    indices = SparseArrays.nonzeroinds(A[_info(model, c).row, :])
    return MOI.VectorOfVariables([
        model.variable_info[CleverDicts.LinearIndex(i)].index for i in indices
    ])
end

###
### Optimize methods.
###

function check_moi_callback_validity(model::Optimizer)
    # TODO
    # has_moi_callback =
    #     model.lazy_callback !== nothing ||
    #     model.user_cut_callback !== nothing ||
    #     model.heuristic_callback !== nothing
    # if has_moi_callback && model.has_generic_callback
    #     error("Cannot use Gurobi.CallbackFunction as well as MOI.AbstractCallbackFunction")
    # end
    # return has_moi_callback
    return false
end

# const INTEGER_TYPES = Set{Symbol}([:MILP, :MIQP, :MIQCP])
# const CONTINUOUS_TYPES = Set{Symbol}([:LP, :QP, :QCP])

# function _make_problem_type_integer(optimizer::Optimizer)
#     optimizer.inner.has_int = true
#     prob_type = get_prob_type(optimizer.inner)
#     prob_type in INTEGER_TYPES && return
#     # prob_type_toggle_map is defined in file CplexSolverInterface.jl
#     set_prob_type!(optimizer.inner, prob_type_toggle_map[prob_type])
#     return
# end

# function _make_problem_type_continuous(optimizer::Optimizer)
#     optimizer.inner.has_int = false
#     prob_type = get_prob_type(optimizer.inner)
#     prob_type in CONTINUOUS_TYPES && return
#     # prob_type_toggle_map is defined in file CplexSolverInterface.jl
#     set_prob_type!(optimizer.inner, prob_type_toggle_map[prob_type])
#     return
# end

function MOI.optimize!(model::Optimizer)
    # TODO callbacks
    # Initialize callbacks if necessary.
    # if check_moi_callback_validity(model)
    #     MOI.set(model, CallbackFunction(), default_moi_callback(model))
    #     model.has_generic_callback = false
    # end

    # TODO improve caching
    # cache once and only reallocate with we have additions
    # maybe also additions
    model.cached_solution = nothing
    model.cached_solution = CachedSolution(model)
    # TODO allow soling relaxed version

    # TODO deal with algorithm flags
    start_time = time()
    if Xpress.is_mixedinteger(model.inner)
        Xpress.mipoptimize(model.inner)
    else
        Xpress.lpoptimize(model.inner)
    end
    solve_time = time() - start_time

    model.cached_solution.solve_time = solve_time

    if Xpress.is_mixedinteger(model.inner)
        #Xpress.getmipsol
        Xpress.Lib.XPRSgetmipsol(model.inner,
            model.cached_solution.variable_primal,
            model.cached_solution.linear_primal) # TODO
            fill!(model.cached_solution.linear_dual, NaN)
            fill!(model.cached_solution.variable_dual, NaN)
    else
        Xpress.Lib.XPRSgetlpsol(model.inner,
            model.cached_solution.variable_primal,
            model.cached_solution.linear_primal, # TODO
            model.cached_solution.linear_dual,
            model.cached_solution.variable_dual)
    end

    rhs = Xpress.getrhs(model.inner)
    model.cached_solution.linear_primal .= rhs .- model.cached_solution.linear_primal

    empty!(model.cached_solution.quadratic_primal)
    empty!(model.cached_solution.quadratic_dual)
    nrows, qcrows = getqrows(model.inner)
    for row in qcrows
        # we need row + 1 here because row is an Xpress Matrix Row index
        push!(model.cached_solution.quadratic_primal, model.cached_solution.linear_primal[row + 1])
        push!(model.cached_solution.quadratic_dual, model.cached_solution.linear_dual[row + 1])
    end
    for row in qcrows
        deleteat!(model.cached_solution.linear_primal, row + 1)
        deleteat!(model.cached_solution.linear_dual, row + 1)
    end

    status = MOI.get(model, MOI.PrimalStatus())
    if status == MOI.INFEASIBILITY_CERTIFICATE
        has_Ray = Int64[0]
        Xpress.getprimalray(model.inner, model.cached_solution.variable_primal , has_Ray)
        model.cached_solution.has_primal_certificate = _has_primal_ray(model)
    end
    status = MOI.get(model, MOI.DualStatus())
    if status == MOI.INFEASIBILITY_CERTIFICATE
        has_Ray = Int64[0]
        Xpress.getdualray(model.inner, model.cached_solution.linear_dual , has_Ray)
        model.cached_solution.has_dual_certificate = _has_dual_ray(model)
    end
    return
end

function _throw_if_optimize_in_progress(model, attr)
    if model.callback_state != CB_NONE
        throw(MOI.OptimizeInProgress(attr))
    end
end

function MOI.get(model::Optimizer, attr::MOI.RawStatusString)
    _throw_if_optimize_in_progress(model, attr)
    stop = Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_STOPSTATUS)
    stop_str = STOPSTATUS_STRING[stop]
    if Xpress.is_mixedinteger(model.inner)
        stat = Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_MIPSTATUS)
        return Xpress.MIPSTATUS_STRING[stat] * " - " * stop_str
    else
        stat = Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_LPSTATUS)
        return Xpress.LPSTATUS_STRING[stat] * " - " * stop_str
    end
end

function MOI.get(model::Optimizer, attr::MOI.TerminationStatus)
    _throw_if_optimize_in_progress(model, attr)
    if model.cached_solution === nothing
        return MOI.OPTIMIZE_NOT_CALLED
    end
    stop = Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_STOPSTATUS)
    if stop == Xpress.Lib.XPRS_STOP_NONE
        if stop == Xpress.Lib.XPRS_STOP_TIMELIMIT
            return MOI.TIME_LIMIT
        elseif stop == Xpress.Lib.XPRS_STOP_CTRLC
            return MOI.INTERRUPTED
        elseif stop == Xpress.Lib.XPRS_STOP_NODELIMIT
            return MOI.NODE_LIMIT
        elseif stop == Xpress.Lib.XPRS_STOP_ITERLIMIT
            return MOI.MOI.ITERATION_LIMIT
        elseif stop == Xpress.Lib.XPRS_STOP_MIPGAP
            return MOI.OTHER_LIMIT # MOI.OPTIMAL TODO
        elseif stop == Xpress.Lib.XPRS_STOP_SOLLIMIT
            return MOI.SOLUTION_LIMIT
        elseif stop == Xpress.Lib.XPRS_STOP_USER
            return MOI.INTERRUPTED
        end
    end
    if Xpress.is_mixedinteger(model.inner)
        stat = Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_MIPSTATUS)
        if stat == Xpress.Lib.XPRS_MIP_NOT_LOADED
            return MOI.OPTIMIZE_NOT_CALLED
        # elseif stat == Xpress.Lib.XPRS_MIP_LP_NOT_OPTIMAL - is a STOP
        # elseif stat == Xpress.Lib.XPRS_MIP_LP_OPTIMAL - is a STOP
        # elseif stat == Xpress.Lib.XPRS_MIP_NO_SOL_FOUND - is a STOP
        # elseif stat == Xpress.Lib.XPRS_MIP_SOLUTION
        elseif stat == Xpress.Lib.XPRS_MIP_INFEAS
            return MOI.INFEASIBLE
        elseif stat == Xpress.Lib.XPRS_MIP_OPTIMAL
            return MOI.OPTIMAL
        elseif stat == Xpress.Lib.XPRS_MIP_UNBOUNDED
            return MOI.INFEASIBLE_OR_UNBOUNDED #? DUAL_INFEASIBLE?
        end
    else
        stat = Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_LPSTATUS)
        if stat == Xpress.Lib.XPRS_LP_UNSTARTED
            return MOI.OPTIMIZE_NOT_CALLED
        # elseif stat == Xpress.Lib.XPRS_MIP_LP_NOT_OPTIMAL - is a STOP
        # elseif stat == Xpress.Lib.XPRS_MIP_LP_OPTIMAL - is a STOP
        # elseif stat == Xpress.Lib.XPRS_MIP_NO_SOL_FOUND - is a STOP
        # elseif stat == Xpress.Lib.XPRS_MIP_SOLUTION
        elseif stat == Xpress.Lib.XPRS_LP_OPTIMAL
            return MOI.OPTIMAL
        elseif stat == Xpress.Lib.XPRS_LP_INFEAS
            return MOI.INFEASIBLE
        elseif stat == Xpress.Lib.XPRS_LP_CUTOFF
            return MOI.OTHER_LIMIT
        # elseif stat == Xpress.Lib.XPRS_LP_UNFINISHED - is a STOP
        elseif stat == Xpress.Lib.XPRS_LP_UNBOUNDED
            return MOI.DUAL_INFEASIBLE
        elseif stat == Xpress.Lib.XPRS_LP_CUTOFF_IN_DUAL
            return MOI.OTHER_LIMIT
        elseif stat == Xpress.Lib.XPRS_LP_UNSOLVED
            return MOI.NUMERICAL_ERROR
        elseif stat == Xpress.Lib.XPRS_LP_NONCONVEX
            return MOI.INVALID_OPTION
        end
    end
    return MOI.OTHER_ERROR
end

function _has_dual_ray(model::Optimizer)
    has_Ray = Int64[0]
    Xpress.getdualray(model.inner, C_NULL , has_Ray)
    return has_Ray[1] != 0
end

function _has_primal_ray(model::Optimizer)
    has_Ray = Int64[0]
    Xpress.getprimalray(model.inner, C_NULL , has_Ray)
    return has_Ray[1] != 0
end

function MOI.get(model::Optimizer, attr::MOI.PrimalStatus)
    _throw_if_optimize_in_progress(model, attr)
    if attr.N != 1
        return MOI.NO_SOLUTION
    end
    term_stat = MOI.get(model, MOI.TerminationStatus())
    if term_stat == MOI.OPTIMAL 
        return MOI.FEASIBLE_POINT
    elseif term_stat == MOI.LOCALLY_INFEASIBLE
        return MOI.INFEASIBLE_POINT
    elseif term_stat == MOI.DUAL_INFEASIBLE
        if _has_primal_ray(model)
            return MOI.INFEASIBILITY_CERTIFICATE
        end
    end
    return MOI.NO_SOLUTION
end

function MOI.get(model::Optimizer, attr::MOI.DualStatus)
    _throw_if_optimize_in_progress(model, attr)
    if attr.N != 1
        return MOI.NO_SOLUTION
    elseif Xpress.is_mixedinteger(model.inner)
        return MOI.NO_SOLUTION
    end
    term_stat = MOI.get(model, MOI.TerminationStatus())
    if term_stat == MOI.OPTIMAL
        return MOI.FEASIBLE_POINT
    elseif term_stat == MOI.INFEASIBLE
        if _has_dual_ray(model)
            return MOI.INFEASIBILITY_CERTIFICATE
        end
    end
    return MOI.NO_SOLUTION
end

function MOI.get(model::Optimizer, attr::MOI.VariablePrimal, x::MOI.VariableIndex)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    column = _info(model, x).column
    return model.cached_solution.variable_primal[column]
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    return MOI.get(model, MOI.VariablePrimal(), MOI.VariableIndex(c.value))
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    row = _info(model, c).row
    return model.cached_solution.linear_primal[row]
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    row = _info(model, c).row
    return model.cached_solution.quadratic_primal[row]
end

function _dual_multiplier(model::Optimizer)
    return MOI.get(model, MOI.ObjectiveSense()) == MOI.MIN_SENSE ? 1.0 : -1.0
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    column = _info(model, c).column
    reduced_cost = model.cached_solution.variable_dual[column]
    sense = MOI.get(model, MOI.ObjectiveSense())
    # The following is a heuristic for determining whether the reduced cost
    # applies to the lower or upper bound. It can be wrong by at most
    # `FeasibilityTol`.
    if sense == MOI.MIN_SENSE && reduced_cost < 0
        # If minimizing, the reduced cost must be negative (ignoring
        # tolerances).
        return reduced_cost
    elseif sense == MOI.MAX_SENSE && reduced_cost > 0
        # If minimizing, the reduced cost must be positive (ignoring
        # tolerances). However, because of the MOI dual convention, we return a
        # negative value.
        return -reduced_cost
    else
        # The reduced cost, if non-zero, must related to the lower bound.
        return 0.0
    end
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    column = _info(model, c).column
    reduced_cost = model.cached_solution.variable_dual[column]
    sense = MOI.get(model, MOI.ObjectiveSense())
    # The following is a heuristic for determining whether the reduced cost
    # applies to the lower or upper bound. It can be wrong by at most
    # `FeasibilityTol`.
    if sense == MOI.MIN_SENSE && reduced_cost > 0
        # If minimizing, the reduced cost must be negative (ignoring
        # tolerances).
        return reduced_cost
    elseif sense == MOI.MAX_SENSE && reduced_cost < 0
        # If minimizing, the reduced cost must be positive (ignoring
        # tolerances). However, because of the MOI dual convention, we return a
        # negative value.
        return -reduced_cost
    else
        # The reduced cost, if non-zero, must related to the lower bound.
        return 0.0
    end
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    column = _info(model, c).column
    reduced_cost = model.cached_solution.variable_dual[column]
    return _dual_multiplier(model) * reduced_cost
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    column = _info(model, c).column
    reduced_cost = model.cached_solution.variable_dual[column]
    return _dual_multiplier(model) * reduced_cost
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    row = _info(model, c).row
    return _dual_multiplier(model) * model.cached_solution.linear_dual[row]
end

function MOI.get(
    model::Optimizer, attr::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, <:Any}
)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    pi = model.cached_solution.quadratic_dual[_info(model, c).row]
    return _dual_multiplier(model) * pi
end

function MOI.get(model::Optimizer, attr::MOI.ObjectiveValue)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    if Xpress.is_mixedinteger(model.inner)
        return Xpress.getdblattrib(model.inner, Xpress.Lib.XPRS_MIPOBJVAL)
    else
        return Xpress.getdblattrib(model.inner, Xpress.Lib.XPRS_LPOBJVAL)
    end
end

function MOI.get(model::Optimizer, attr::MOI.ObjectiveBound)
    _throw_if_optimize_in_progress(model, attr)
    if Xpress.is_mixedinteger(model.inner)
        return Xpress.getdblattrib(model.inner, Xpress.Lib.XPRS_MIPBESTOBJVAL)
    else
        return Xpress.getdblattrib(model.inner, Xpress.Lib.XPRS_LPOBJVAL)
    end
end

function MOI.get(model::Optimizer, attr::MOI.SolveTime)
    _throw_if_optimize_in_progress(model, attr)
    return model.cached_solution.solve_time
end

function MOI.get(model::Optimizer, attr::MOI.SimplexIterations)
    _throw_if_optimize_in_progress(model, attr)
    return Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_SIMPLEXITER)
end

function MOI.get(model::Optimizer, attr::MOI.BarrierIterations)
    _throw_if_optimize_in_progress(model, attr)
    return Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_BARITER)
end

function MOI.get(model::Optimizer, attr::MOI.NodeCount)
    _throw_if_optimize_in_progress(model, attr)
    return Xpress.getintattrib(model.inner, Xpress.Lib.XPRS_NODES)
end

function MOI.get(model::Optimizer, attr::MOI.RelativeGap)
    _throw_if_optimize_in_progress(model, attr)
    BESTBOUND = MOI.get(model, MOI.ObjectiveBound())
    MIPOBJVAL = MOI.get(model, MOI.ObjectiveValue())
    return abs(MIPOBJVAL - BESTBOUND) / max(abs(BESTBOUND), abs(MIPOBJVAL))
end

function MOI.get(model::Optimizer, attr::MOI.DualObjectiveValue)
    _throw_if_optimize_in_progress(model, attr)
    MOI.check_result_index_bounds(model, attr)
    MOI.get(model, MOI.ObjectiveValue(attr.result_index))
end

function MOI.get(model::Optimizer, attr::MOI.ResultCount)
    _throw_if_optimize_in_progress(model, attr)
    if model.cached_solution === nothing
        return 0
    elseif model.cached_solution.has_dual_certificate
        return 1
    elseif model.cached_solution.has_primal_certificate
        return 1
    else
        st = MOI.get(model, MOI.PrimalStatus())
        return st == MOI.FEASIBLE_POINT ? 1 : 0
    end
end

function MOI.get(model::Optimizer, ::MOI.Silent)
    return model.silent
end

function MOI.set(model::Optimizer, ::MOI.Silent, flag::Bool)
    model.silent = flag
    # https://www.fico.com/fico-xpress-optimization/docs/latest/solver/optimizer/HTML/OUTPUTLOG.html
    if Sys.iswindows()
        @warn "Silent has no effect on windows. See https://www.fico.com/fico-xpress-optimization/docs/latest/solver/optimizer/HTML/OUTPUTLOG.html"
    end
    MOI.set(model, MOI.RawParameter(Xpress.Lib.XPRS_OUTPUTLOG), flag ? 0 : 1)
    return
end

function MOI.get(model::Optimizer, ::MOI.NumberOfThreads)
    return Int(MOI.get(model, MOI.RawParameter(Xpress.Lib.XPRS_THREADS)))
end

function MOI.set(model::Optimizer, ::MOI.NumberOfThreads, x::Int)
    return MOI.set(model, MOI.RawParameter(Xpress.Lib.XPRS_THREADS), x)
end

function MOI.get(model::Optimizer, ::MOI.Name)
    return model.name
end

function MOI.set(model::Optimizer, ::MOI.Name, name::String)
    model.name = name
    return
end

MOI.get(model::Optimizer, ::MOI.NumberOfVariables) = length(model.variable_info)
function MOI.get(model::Optimizer, ::MOI.ListOfVariableIndices)
    return sort!(collect(keys(model.variable_info)), by = x -> x.value)
end

MOI.get(model::Optimizer, ::MOI.RawSolver) = model.inner

function MOI.set(
    model::Optimizer,
    ::MOI.VariablePrimalStart,
    x::MOI.VariableIndex,
    value::Union{Nothing, Float64}
)
    info = _info(model, x)
    info.start = value
    return
end

function MOI.get(
    model::Optimizer, ::MOI.VariablePrimalStart, x::MOI.VariableIndex
)
    return _info(model, x).start
end

function MOI.supports(
    ::Optimizer, ::MOI.VariablePrimalStart, ::Type{MOI.VariableIndex})
    return true
end

function MOI.get(model::Optimizer, ::MOI.NumberOfConstraints{F, S}) where {F, S}
    # TODO: this could be more efficient.
    return length(MOI.get(model, MOI.ListOfConstraintIndices{F, S}()))
end

_bound_enums(::Type{<:MOI.LessThan}) = (LESS_THAN, LESS_AND_GREATER_THAN)
_bound_enums(::Type{<:MOI.GreaterThan}) = (GREATER_THAN, LESS_AND_GREATER_THAN)
_bound_enums(::Type{<:MOI.Interval}) = (INTERVAL,)
_bound_enums(::Type{<:MOI.EqualTo}) = (EQUAL_TO,)
_bound_enums(::Any) = (nothing,)

_type_enums(::Type{MOI.ZeroOne}) = (BINARY,)
_type_enums(::Type{MOI.Integer}) = (INTEGER,)
_type_enums(::Type{<:MOI.Semicontinuous}) = (SEMICONTINUOUS,)
_type_enums(::Type{<:MOI.Semiinteger}) = (SEMIINTEGER,)
_type_enums(::Any) = (nothing,)

function MOI.get(
    model::Optimizer, ::MOI.ListOfConstraintIndices{MOI.SingleVariable, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.SingleVariable, S}[]
    for (key, info) in model.variable_info
        if info.bound in _bound_enums(S) || info.type in _type_enums(S)
            push!(indices, MOI.ConstraintIndex{MOI.SingleVariable, S}(key.value))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}[]
    for (key, info) in model.affine_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}[]
    for (key, info) in model.quadratic_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer, ::MOI.ListOfConstraintIndices{MOI.VectorOfVariables, S}
) where {S <: Union{<:MOI.SOS1, <:MOI.SOS2}}
    indices = MOI.ConstraintIndex{MOI.VectorOfVariables, S}[]
    for (key, info) in model.sos_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.VectorOfVariables, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    indices = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}[
        MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}(key)
        for (key, info) in model.quadratic_constraint_info
            if typeof(info.set) == MOI.SecondOrderCone
    ]
    return sort!(indices, by = x -> x.value)
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraints)
    constraints = Set{Tuple{DataType, DataType}}()
    for info in values(model.variable_info)
        if info.bound == NONE
        elseif info.bound == LESS_THAN
            push!(constraints, (MOI.SingleVariable, MOI.LessThan{Float64}))
        elseif info.bound == GREATER_THAN
            push!(constraints, (MOI.SingleVariable, MOI.GreaterThan{Float64}))
        elseif info.bound == LESS_AND_GREATER_THAN
            push!(constraints, (MOI.SingleVariable, MOI.LessThan{Float64}))
            push!(constraints, (MOI.SingleVariable, MOI.GreaterThan{Float64}))
        elseif info.bound == EQUAL_TO
            push!(constraints, (MOI.SingleVariable, MOI.EqualTo{Float64}))
        elseif info.bound == INTERVAL
            push!(constraints, (MOI.SingleVariable, MOI.Interval{Float64}))
        end
        if info.type == CONTINUOUS
        elseif info.type == BINARY
            push!(constraints, (MOI.SingleVariable, MOI.ZeroOne))
        elseif info.type == INTEGER
            push!(constraints, (MOI.SingleVariable, MOI.Integer))
        elseif info.type == SEMICONTINUOUS
            push!(constraints, (MOI.SingleVariable, MOI.Semicontinuous{Float64}))
        elseif info.type == SEMIINTEGER
            push!(constraints, (MOI.SingleVariable, MOI.Semiinteger{Float64}))
        end
    end
    for info in values(model.affine_constraint_info)
        push!(constraints, (MOI.ScalarAffineFunction{Float64}, typeof(info.set)))
    end
    for info in values(model.quadratic_constraint_info)
        if typeof(info.set) == MOI.SecondOrderCone
            push!(constraints, (MOI.VectorOfVariables, MOI.SecondOrderCone))
        else
            push!(constraints, (MOI.ScalarQuadraticFunction{Float64}, typeof(info.set)))
        end
    end
    for info in values(model.sos_constraint_info)
        push!(constraints, (MOI.VectorOfVariables, typeof(info.set)))
    end
    return collect(constraints)
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunctionType)
    if model.is_feasibility
        return nothing
    elseif model.objective_type == SINGLE_VARIABLE
        return MOI.SingleVariable
    elseif model.objective_type == SCALAR_AFFINE
        return MOI.ScalarAffineFunction{Float64}
    else
        @assert model.objective_type == SCALAR_QUADRATIC
        return MOI.ScalarQuadraticFunction{Float64}
    end
end

function MOI.modify(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any},
    chg::MOI.ScalarCoefficientChange{Float64}
)
    Xpress.chgcoef(
        model.inner,
        _info(model, c).row,
        _info(model, chg.variable).column,
        chg.new_coefficient
    )
    return
end

function MOI.modify(
    model::Optimizer,
    c::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}},
    chg::MOI.ScalarCoefficientChange{Float64}
)
    column = _info(model, chg.variable).column
    Xpress.chgobj(model.inner, [column], [chg.new_coefficient])
    return
end

"""
    _replace_with_matching_sparsity!(
        model::Optimizer,
        previous::MOI.ScalarAffineFunction,
        replacement::MOI.ScalarAffineFunction, row::Int
    )

Internal function, not intended for external use.

Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` have exactly the same sparsity pattern w.r.t. which variables
they include and that both constraint functions are in canonical form (as
returned by `MOIU.canonical()`. Neither assumption is checked within the body
of this function.
"""
function _replace_with_matching_sparsity!(
    model::Optimizer,
    previous::MOI.ScalarAffineFunction,
    replacement::MOI.ScalarAffineFunction, row::Int
)
    for term in replacement.terms
        col = _info(model, term.variable_index).column
        Xpress.chgcoef(
            model.inner, row, col, MOI.coefficient(term)
        )
    end
    return
end

"""
    _replace_with_different_sparsity!(
        model::Optimizer,
        previous::MOI.ScalarAffineFunction,
        replacement::MOI.ScalarAffineFunction, row::Int
    )

Internal function, not intended for external use.

    Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` may have different sparsity patterns.

This function (and `_replace_with_matching_sparsity!` above) are necessary
because in order to fully replace a linear constraint, we have to zero out the
current matrix coefficients and then set the new matrix coefficients. When the
sparsity patterns match, the zeroing-out step can be skipped.
"""
function _replace_with_different_sparsity!(
    model::Optimizer,
    previous::MOI.ScalarAffineFunction,
    replacement::MOI.ScalarAffineFunction, row::Int
)
    # First, zero out the old constraint function terms.
    for term in previous.terms
        col = _info(model, term.variable_index).column
        Xpress.chgcoef(model.inner, row, col, 0.0)
    end

    # Next, set the new constraint function terms.
    for term in previous.terms
        col = _info(model, term.variable_index).column
        Xpress.chgcoef(model.inner, row, col, MOI.coefficient(term))
    end
    return
end

"""
    _matching_sparsity_pattern(
        f1::MOI.ScalarAffineFunction{Float64},
        f2::MOI.ScalarAffineFunction{Float64}
    )

Internal function, not intended for external use.

Determines whether functions `f1` and `f2` have the same sparsity pattern
w.r.t. their constraint columns. Assumes both functions are already in
canonical form.
"""
function _matching_sparsity_pattern(
    f1::MOI.ScalarAffineFunction{Float64}, f2::MOI.ScalarAffineFunction{Float64}
)
    if axes(f1.terms) != axes(f2.terms)
        return false
    end
    for (f1_term, f2_term) in zip(f1.terms, f2.terms)
        if MOI.term_indices(f1_term) != MOI.term_indices(f2_term)
            return false
        end
    end
    return true
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:SCALAR_SETS},
    f::MOI.ScalarAffineFunction{Float64}
)
    previous = MOI.get(model, MOI.ConstraintFunction(), c)
    MOI.Utilities.canonicalize!(previous)
    replacement = MOI.Utilities.canonical(f)
    # If the previous and replacement constraint functions have exactly
    # the same sparsity pattern, then we can take a faster path by just
    # passing the replacement terms to the model. But if their sparsity
    # patterns differ, then we need to first zero out the previous terms
    # and then set the replacement terms.
    row = _info(model, c).row
    if _matching_sparsity_pattern(previous, replacement)
        _replace_with_matching_sparsity!(model, previous, replacement, row)
    else
        _replace_with_different_sparsity!(model, previous, replacement, row)
    end
    rhs = Xpress.getrhs(model.inner, row, row)
    rhs[1] -= replacement.constant - previous.constant
    Xpress.chgrhs(model.inner, [row], rhs)
    return
end

# function MOI.get(
#     model::Optimizer, ::MOI.ConstraintBasisStatus,
#     c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
# ) where {S <: SCALAR_SETS}
#     row = _info(model, c).row
#     # TODO
#     cbasis = 0 # get_intattrelement(model.inner, "CBasis", row)
#     if cbasis == 0
#         return MOI.BASIC
#     elseif cbasis == -1
#         return MOI.NONBASIC
#     else
#         error("CBasis value of $(cbasis) isn't defined.")
#     end
# end

# function MOI.get(
#     model::Optimizer, ::MOI.ConstraintBasisStatus,
#     c::MOI.ConstraintIndex{MOI.SingleVariable, S}
# ) where {S <: SCALAR_SETS}
#     column = _info(model, c).column
#     _update_if_necessary(model)
#     vbasis = get_intattrelement(model.inner, "VBasis", column)
#     if vbasis == 0
#         return MOI.BASIC
#     elseif vbasis == -1
#         if S <: MOI.LessThan
#             return MOI.BASIC
#         elseif !(S <: MOI.Interval)
#             return MOI.NONBASIC
#         else
#             return MOI.NONBASIC_AT_LOWER
#         end
#     elseif vbasis == -2
#         MOI.NONBASIC_AT_UPPER
#         if S <: MOI.GreaterThan
#             return MOI.BASIC
#         elseif !(S <: MOI.Interval)
#             return MOI.NONBASIC
#         else
#             return MOI.NONBASIC_AT_UPPER
#         end
#     elseif vbasis == -3
#         return MOI.SUPER_BASIC
#     else
#         error("VBasis value of $(vbasis) isn't defined.")
#     end
# end

###
### VectorOfVariables-in-SecondOrderCone
###

#=

function _info(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    if haskey(model.quadratic_constraint_info, c.value)
        return model.quadratic_constraint_info[c.value]
    end
    throw(MOI.InvalidIndex(c))
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.VectorOfVariables, s::MOI.SecondOrderCone
)
    if length(f.variables) != s.dimension
        error("Dimension of $(s) does not match number of terms in $(f)")
    end

    # SOC is the cone: t ≥ ||x||₂ ≥ 0. In quadratic form, this is
    # t² - Σᵢ xᵢ² ≥ 0 and t ≥ 0.

    # First, check the lower bound on t.

    t_info = _info(model, f.variables[1])
    lb = _get_variable_lower_bound(model, t_info)
    if isnan(t_info.lower_bound_if_soc) && lb < 0.0
        t_info.lower_bound_if_soc = lb
        CPLEX.c_api_chgbds(model.inner, Cint[t_info.column], Cchar['L'], [0.0])
    end
    t_info.num_soc_constraints += 1

    # Now add the quadratic constraint.

    I = Cint[_info(model, v).column for v in f.variables]
    V = fill(Cdouble(-1.0), length(f.variables))
    V[1] = 1.0
    CPLEX.add_qconstr!(model.inner, Cint[], Cdouble[], I, I, V, Cchar('G'), 0.0)
    model.last_constraint_index += 1
    model.quadratic_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.quadratic_constraint_info) + 1, s)
    return MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}(model.last_constraint_index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    info = get(model.quadratic_constraint_info, c.value, nothing)
    return info !== nothing && typeof(info.set) == MOI.SecondOrderCone
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    info = _info(model, c)
    CPLEX.c_api_delqconstrs(model.inner, Cint(info.row - 1), Cint(info.row - 1))
    for (key, info_2) in model.quadratic_constraint_info
        if info_2.row > info.row
            info_2.row -= 1
        end
    end
    model.name_to_constraint_index = nothing
    delete!(model.quadratic_constraint_info, c.value)
    # Reset the lower bound on the `t` variable.
    t_info = _info(model, f.variables[1])
    t_info.num_soc_constraints -= 1
    if t_info.num_soc_constraints > 0
        # Don't do anything. There are still SOC associated with this variable.
        return
    elseif isnan(t_info.lower_bound_if_soc)
        # Don't do anything. It must have a >0 lower bound anyway.
        return
    end
    # There was a previous bound that we over-wrote, and it must have been
    # < 0 otherwise we wouldn't have needed to overwrite it.
    @assert t_info.lower_bound_if_soc < 0.0
    tmp_lower_bound = t_info.lower_bound_if_soc
    t_info.lower_bound_if_soc = NaN
    _set_variable_lower_bound(model, t_info, tmp_lower_bound)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    return _info(model, c).set
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    a, b, I, J, V = CPLEX.c_api_getqconstr(model.inner, _info(model, c).row)
    @assert length(a) == length(b) == 0  # Check for no linear terms.
    t = nothing
    x = MOI.VariableIndex[]
    for (i, j, coef) in zip(I, J, V)
        v = model.variable_info[CleverDicts.LinearIndex(i + 1)].index
        @assert i == j  # Check for no off-diagonals.
        if coef == 1.0
            @assert t === nothing  # There should only be one `t`.
            t = v
        else
            @assert coef == -1.0  # The coefficients _must_ be -1 for `x` terms.
            push!(x, v)
        end
    end
    @assert t !== nothing  # Check that we found a `t` variable.
    return MOI.VectorOfVariables([t; x])
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    return MOI.get(model, MOI.VariablePrimal(), f.variables)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone},
    name::String
)
    info = _info(model, c)
    if !isempty(info.name) && model.name_to_constraint_index !== nothing
        delete!(model.name_to_constraint_index, info.name)
    end
    info.name = name
    if model.name_to_constraint_index === nothing || isempty(name)
        return
    end
    if haskey(model.name_to_constraint_index, name)
        model.name_to_constraint_index = nothing
    else
        model.name_to_constraint_index[c] = name
    end
    return
end

=#

###
### IIS
###

#=

"""
    compute_conflict(model::Optimizer)

Compute a minimal subset of the constraints and variables that keep the model
infeasible.

See also `CPLEX.ConflictStatus` and `CPLEX.ConstraintConflictStatus`.

Note that if `model` is modified after a call to `compute_conflict`, the
conflict is not purged, and any calls to the above attributes will return
values for the original conflict without a warning.
"""
function compute_conflict(model::Optimizer)
    # In case there is no conflict, c_api_getconflict throws an error, while the
    # conflict data structure can handle more gracefully this case (via a status
    # check).

    # TODO: decide what to do about the POSSIBLE statuses for the constraints
    # (CPX_CONFLICT_POSSIBLE_MEMBER, CPX_CONFLICT_POSSIBLE_UB,
    # CPX_CONFLICT_POSSIBLE_LB).
    try
        model.conflict = c_api_getconflict(model.inner)
    catch exc
        if isa(exc, CplexError) && exc.code == CPXERR_NO_CONFLICT
            model.conflict = ConflictRefinerData(
                CPX_STAT_CONFLICT_FEASIBLE, 0, Cint[], Cint[], 0, Cint[], Cint[]
            )
        else
            rethrow(exc)
        end
    end
    return
end

function _ensure_conflict_computed(model::Optimizer)
    if model.conflict === nothing
        error(
            "Cannot access conflict status. Call " *
            "`CPLEX.compute_conflict(model)` first. In case the model is " *
            "modified, the computed conflict will not be purged."
        )
    end
end

"""
    ConflictStatus()

Return an `MOI.TerminationStatusCode` indicating the status of the last
computed conflict. If a minimal conflict is found, it will return
`MOI.OPTIMAL`. If the problem is feasible, it will return `MOI.INFEASIBLE`. If
`compute_conflict` has not been called yet, it will return
`MOI.OPTIMIZE_NOT_CALLED`.
"""
struct ConflictStatus <: MOI.AbstractModelAttribute  end

MOI.is_set_by_optimize(::ConflictStatus) = true

function MOI.get(model::Optimizer, ::ConflictStatus)
    if model.conflict === nothing
        return MOI.OPTIMIZE_NOT_CALLED
    elseif model.conflict.stat == CPX_STAT_CONFLICT_MINIMAL
        return MOI.OPTIMAL
    elseif model.conflict.stat == CPX_STAT_CONFLICT_FEASIBLE
        return MOI.INFEASIBLE
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_CONTRADICTION
        return MOI.OTHER_LIMIT
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_DETTIME_LIM
        return MOI.TIME_LIMIT
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_IT_LIM
        return MOI.ITERATION_LIMIT
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_MEM_LIM
        return MOI.MEMORY_LIMIT
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_NODE_LIM
        return MOI.NODE_LIMIT
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_OBJ_LIM
        return MOI.OBJECTIVE_LIMIT
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_TIME_LIM
        return MOI.TIME_LIMIT
    elseif model.conflict.stat == CPX_STAT_CONFLICT_ABORT_USER
        return MOI.OTHER_LIMIT
    else
        return MOI.OTHER_LIMIT
    end
end

function MOI.supports(::Optimizer, ::ConflictStatus)
    return true
end

"""
    ConstraintConflictStatus()

A Boolean constraint attribute indicating whether the constraint participates
in the last computed conflict.
"""
struct ConstraintConflictStatus <: MOI.AbstractConstraintAttribute end

MOI.is_set_by_optimize(::ConstraintConflictStatus) = true

function _get_conflict_status(
    model::Optimizer,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    _ensure_conflict_computed(model)
    column = _info(model, index).column
    for (col, stat) in zip(model.conflict.colind, model.conflict.colstat)
        if column - 1 == col
            return stat
        end
    end
    return nothing
end

function MOI.get(
    model::Optimizer,
    ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:MOI.LessThan}
)
    status = _get_conflict_status(model, index)
    if status === nothing
        return false
    end
    return status == CPLEX.CPX_CONFLICT_MEMBER ||
        status == CPLEX.CPX_CONFLICT_UB
end

function MOI.get(
    model::Optimizer,
    ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:MOI.GreaterThan})
    status = _get_conflict_status(model, index)
    if status === nothing
        return false
    end
    return status == CPLEX.CPX_CONFLICT_MEMBER ||
        status == CPLEX.CPX_CONFLICT_LB
end

function MOI.get(
    model::Optimizer,
    ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:Union{MOI.EqualTo, MOI.Interval}}
)
    status = _get_conflict_status(model, index)
    if status === nothing
        return false
    end
    return status == CPLEX.CPX_CONFLICT_MEMBER ||
        status == CPLEX.CPX_CONFLICT_LB ||
        status == CPLEX.CPX_CONFLICT_UB
end

function MOI.get(
    model::Optimizer,
    ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{
        <:MOI.ScalarAffineFunction,
        <:Union{MOI.LessThan, MOI.GreaterThan, MOI.EqualTo}
    }
)
    _ensure_conflict_computed(model)
    return (_info(model, index).row - 1) in model.conflict.rowind
end

function MOI.supports(
    ::Optimizer,
    ::ConstraintConflictStatus,
    ::Type{MOI.ConstraintIndex{<:MOI.SingleVariable, <:SCALAR_SETS}}
)
    return true
end

function MOI.supports(
    ::Optimizer,
    ::ConstraintConflictStatus,
    ::Type{MOI.ConstraintIndex{
        <:MOI.ScalarAffineFunction,
        <:Union{MOI.LessThan, MOI.GreaterThan, MOI.EqualTo}
    }}
)
    return true
end

include("MOI_callbacks.jl")
=#
function extension(str::String)
    try
        match(r"\.[A-Za-z0-9]+$", str).match
    catch
        ""
    end
end

function MOI.write_to_file(model::Optimizer, name::String)
    ext = extension(name)
    if ext == ".lp"
        Xpress.writeprob(model.inner, name, "l")
    elseif ext == ".mps"
        Xpress.writeprob(model.inner, name)
    else
        Xpress.writeprob(model.inner, name, "l")
    end
end
