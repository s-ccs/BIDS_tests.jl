# =============================================================================
# BIDSPath.jl — the BIDS path grammar: parse, build, validate  (M1)
# =============================================================================
# One of BIDS' structural kinds (plan §1): the filename grammar
#
#     [sub-<label>/][ses-<label>/][<datatype>/]key-label_key-label_<suffix><ext>
#
# Every grammatical decision is validated against the schema (Schema module):
#   * entity order         — `Schema.entity_order()`      (rules.entities)
#   * entity short forms   — `Schema.entity(name).name`   ("sub", "task", ...)
#   * suffix/extension/datatype combos — `Schema.suffix_rules()`
#   * required entities    — `Schema.suffix_entities()`
#
# BIDSPath is deliberately lenient about what it *stores* and strict about what
# it *validates*: unknown entities and unknown suffixes are preserved so that
# `validate_path` can report them — never silently dropped (round-trip fidelity).
#
# Schema access is qualified (`Schema.xxx`): BIDSPath defines user-facing short
# names and must not accidentally extend the machinery vocabulary.
# =============================================================================

module PathGrammar

import ..Schema

export BIDSPath, PathViolation,
       parse_path, build_path, validate_path, isvalid,
       getentity, hasentity

"""
    BIDSPath

A parsed or constructed BIDS path. Fields (read via property access):

  * `entities::Vector{Pair{Symbol,String}}` — entity *name* => label, in filename order
  * `suffix::Union{Nothing,String}`
  * `extension::Union{Nothing,String}`
  * `prefix::String` — leading directories, verbatim (minus the datatype directory)
  * `datatype::Union{Nothing,String}` — detected from a datatype directory

Convenience constructor: `BIDSPath(entities, suffix, extension; prefix, datatype)`.
"""
struct BIDSPath
    entities::Vector{Pair{Symbol,String}}
    suffix::Union{Nothing,String}
    extension::Union{Nothing,String}
    prefix::String
    datatype::Union{Nothing,String}
end

BIDSPath(entities::Vector{Pair{Symbol,String}}, suffix, extension;
         prefix::AbstractString = "", datatype = nothing) =
    BIDSPath(entities, suffix, extension, String(prefix),
             datatype === nothing ? nothing : String(datatype))

Base.show(io::IO, bp::BIDSPath) = print(io, "BIDSPath(", build_path(bp), ")")

"""
    PathViolation

One schema violation found by [`validate_path`](@ref): `kind::Symbol` in
`:unknown_entity`, `:entity_order`, `:bad_label`, `:unknown_suffix`,
`:bad_extension`, `:missing_required_entity` — plus a human `message`.
"""
struct PathViolation
    kind::Symbol
    message::String
end

Base.show(io::IO, v::PathViolation) = print(io, v.kind, ": ", v.message)

# ---- entity key <-> name maps (derived from the schema) ----------------------

# filename short form => entity name ("sub" => :subject); rebuilt per call —
# 35 entity definitions, negligible next to the schema cache.
function key_to_entity(key::AbstractString)
    d = Dict{String,Symbol}()
    for (name, def) in Schema.entities()
        short = get(def, :name, nothing)
        short !== nothing && (d[String(short)] = name)
    end
    return get(d, String(key), nothing)
end

"Entity name → filename short form (`:subject` → `\"sub\"`); unknown ⇒ itself."
function entity_to_key(name::Symbol)
    def = Schema.entity(name)
    def === nothing && return String(name)
    short = get(def, :name, nothing)
    return short === nothing ? String(name) : String(short)
end

# ---- data access ---------------------------------------------------------------

"Label of entity `name` (Symbol or String) in `bp`, or `nothing`."
function getentity(bp::BIDSPath, name::Symbol)
    for (n, label) in bp.entities
        n === name && return label
    end
    return nothing
end
getentity(bp::BIDSPath, name::AbstractString) = getentity(bp, Symbol(name))

"Does `bp` carry entity `name`?"
hasentity(bp::BIDSPath, name::Union{Symbol,AbstractString}) =
    getentity(bp, name) !== nothing

# ---- parse ----------------------------------------------------------------------

"""
    parse_path(path) -> BIDSPath

Parse a BIDS path (relative, absolute, or filename-only) into entities,
suffix, extension and datatype. Lenient: unknown entity keys are preserved
(as raw symbols) so [`validate_path`](@ref) can report them. Filenames that
do not follow the entity grammar at all (e.g. `dataset_description.json`,
`README`) parse as suffix-only with no entities — `validate_path` reports
them if they are not legitimate BIDS files.
"""
function parse_path(path::AbstractString)
    path = String(path)
    dir, fname = splitdir(path)

    # a datatype directory (e.g. .../eeg/) sets `datatype`; other dirs → prefix
    dtnames = String.(keys(Schema.datatypes()))
    kept = String[]
    dt = nothing
    for d in split(dir, '/'; keepempty = false)
        if d in dtnames
            dt = d
        else
            push!(kept, d)
        end
    end
    prefix = isempty(kept) ? "" : joinpath(kept...)

    isempty(fname) &&
        return BIDSPath(Pair{Symbol,String}[], nothing, nothing, prefix, dt)

    tokens = split(fname, '_')
    # extension = everything from the first dot in the last token, so multi-part
    # extensions (.nii.gz) stay intact; stem = fname without the extension
    last = String(tokens[end])
    dot = findfirst('.', last)
    ext = dot === nothing ? nothing : String(last[dot:end])
    stem = ext === nothing ? fname : String(fname[1:end - length(ext)])

    # pre-suffix tokens must all be key-label pairs; otherwise the filename
    # does not follow the entity grammar → suffix-only, no entities
    pre = tokens[1:end-1]
    ents = Pair{Symbol,String}[]
    if all(t -> occursin('-', t), pre)
        for tok in pre
            t = String(tok)
            hy = findfirst('-', t)
            key, label = String(t[1:hy-1]), String(t[hy+1:end])
            name = key_to_entity(key)
            push!(ents, (name === nothing ? Symbol(key) : name) => label)
        end
        sfx = dot === nothing ? last : String(last[1:dot-1])
    else
        sfx = stem
    end

    return BIDSPath(ents,
                    isempty(sfx) ? nothing : String(sfx),
                    ext, prefix, dt)
end

# ---- build ----------------------------------------------------------------------

"""
    build_path(bp::BIDSPath) -> String

Assemble the *canonical* BIDS location for `bp`: entities ordered by the BIDS
entity table (short forms via the schema), then suffix + extension;
`subject`/`session` are duplicated into the directory prefix (BIDS convention),
then the datatype directory. Arbitrary `prefix` directories of a parsed path
are not reconstructed — this is the canonicalizer for the `Layout`.
"""
function build_path(bp::BIDSPath)
    order = Schema.entity_order()
    pos(n::Symbol) = begin
        i = findfirst(==(String(n)), order)
        i === nothing ? typemax(Int) : i
    end
    ents = sort(bp.entities; by = p -> pos(p.first))

    parts = [string(entity_to_key(n), '-', label) for (n, label) in ents]
    fname = join(parts, "_")
    if bp.suffix !== nothing
        fname = isempty(fname) ? String(bp.suffix) : fname * "_" * String(bp.suffix)
    end
    bp.extension !== nothing && (fname *= String(bp.extension))

    dirs = String[]
    sub, ses = getentity(bp, :subject), getentity(bp, :session)
    sub !== nothing && push!(dirs, "sub-" * sub)
    ses !== nothing && push!(dirs, "ses-" * ses)
    bp.datatype !== nothing && push!(dirs, String(bp.datatype))
    return isempty(dirs) ? fname : joinpath(dirs..., fname)
end

# ---- validate -------------------------------------------------------------------

# does a raw file rule apply to the given datatype? (`nothing` ⇒ all rules)
_applies(rule, datatype::Nothing) = true
function _applies(rule, datatype::String)
    dts = get(rule, :datatypes, nothing)
    dts === nothing || String(datatype) in dts
end

"""
    validate_path(bp::BIDSPath) -> Vector{PathViolation}

Validate `bp` against the schema:

  1. entities are known BIDS entities (`:unknown_entity`)
  2. entity order follows the BIDS entity table (`:entity_order`)
  3. labels are letters/digits only, non-empty (`:bad_label`)
  4. suffix is known (`:unknown_suffix`)
  5. extension valid for the suffix (and datatype, when known) (`:bad_extension`)
  6. required entities present, per the matching file rules (`:missing_required_entity`)

Scope: validation runs against `rules.files.raw` (recording files). Common
top-level files (`dataset_description.json`, `participants.tsv`, `README`)
are not raw file rules, so they surface as `:unknown_suffix` — the `Layout`
identifies those by exact filename.

Empty result ⇔ [`isvalid`](@ref).
"""
function validate_path(bp::BIDSPath)
    out = PathViolation[]
    order = Schema.entity_order()

    # 1. known entities
    for (n, _) in bp.entities
        Schema.entity(n) === nothing &&
            push!(out, PathViolation(:unknown_entity, "unknown entity \"$n\""))
    end

    # 2. grammar order — positions of consecutive *known* entities non-decreasing
    prev = 0
    for (n, _) in bp.entities
        i = findfirst(==(String(n)), order)
        i === nothing && continue
        if i < prev
            push!(out, PathViolation(:entity_order,
                "entity \"$n\" out of order (BIDS entity-table order)"))
        else
            prev = i
        end
    end

    # 3. label charset — BIDS labels: letters and digits only
    for (n, label) in bp.entities
        isempty(label) && push!(out, PathViolation(:bad_label,
            "empty label for entity \"$n\""))
        occursin(r"[^A-Za-z0-9]", label) && push!(out, PathViolation(:bad_label,
            "invalid label \"$label\" for entity \"$n\" (letters and digits only)"))
    end

    bp.suffix === nothing && return out

    # 4. suffix known?
    matched = Schema.suffix_rules(bp.suffix)
    if isempty(matched)
        push!(out, PathViolation(:unknown_suffix, "unknown suffix \"$(bp.suffix)\""))
        return out
    end

    applicable = [rule for (_, _, rule) in matched if _applies(rule, bp.datatype)]
    isempty(applicable) && push!(out, PathViolation(:unknown_suffix,
        "suffix \"$(bp.suffix)\" is not valid for datatype \"$(bp.datatype)\""))

    # 5. extension ∈ valid extensions of the applicable rules
    if bp.extension !== nothing && !isempty(applicable)
        valid = sort(unique(String.(e for rule in applicable
                                    for e in get(rule, :extensions, ()))))
        String(bp.extension) in valid || push!(out, PathViolation(:bad_extension,
            "extension \"$(bp.extension)\" is not valid for suffix \"$(bp.suffix)\"" *
            " (valid: $(join(valid, ", ")))"))
    end

    # 6. required entities present
    isempty(applicable) && return out
    required = Symbol[]
    for rule in applicable
        ents = get(rule, :entities, nothing)
        ents === nothing && continue
        for (n, lvl) in ents
            Schema.requirement_level(lvl) == "required" &&
                Symbol(n) ∉ required && push!(required, Symbol(n))
        end
    end
    for n in required
        hasentity(bp, n) || push!(out, PathViolation(:missing_required_entity,
            "missing required entity \"$n\" for suffix \"$(bp.suffix)\""))
    end

    return out
end

"`validate_path(bp)` is empty. Extends `Base.isvalid` — same binding, no ambiguity."
Base.isvalid(bp::BIDSPath) = isempty(validate_path(bp))

end # module PathGrammar
