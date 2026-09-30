# =============================================================================
# Schema.jl — the BIDS machine specification, loaded as data
# =============================================================================
# The core idea of the project: BIDS is a machine specification. Entities,
# datatypes, suffixes, columns, metadata fields, and modalities are DATA here,
# not hand-written Julia code. Only the five structural kinds are code; this
# module provides the data side of that.
#
# Schema source: https://bids-specification.readthedocs.io/en/stable/schema.json
# Pinned copy:   src/schema/bids_schema.json   (refresh: scripts/update_schema.jl)
#
# Schema structure this loader is built against (BIDS 1.11.2, schema 2.0.0):
#
#   objects.entities      35 definitions, keyed by entity name ("subject" → {name: "sub", ...})
#   rules.entities        ORDERED list of 35 entity names — the filename grammar order
#                         (subject, template, session, ..., description)
#   objects.datatypes     16 (anat, beh, dwi, eeg, emg, fmap, func, ieeg, meg, micr,
#                         motion, mrs, perf, pet, phenotype, nirs)
#   objects.suffixes      118
#   objects.columns       101 column definitions (onset, duration, trial_type, ...)
#   objects.metadata      451 field definitions (SamplingFrequency, TaskName, ...)
#   objects.modalities    11
#   rules.modalities.<modality>            → {"datatypes": [...]}
#   rules.files.raw.<group>.<key>          → per-suffix file rules:
#       {suffixes, extensions, datatypes, entities: {<entity> => "required"|"optional"}}
#   rules.sidecars.<group>.<rule>          → sidecar field requirements:
#       {selectors: [...], fields: {<field> => "optional"|"required"|"recommended"}}
#   rules.tabular_data.<key>.<rule>        → TSV column requirements
#       (events: onset required, duration required; additional_columns: "allowed")
#
# NOTE on JSON3 value types: object keys are Symbols, string values are
# SubString{String}. All accessors normalize with String()/Symbol() so callers
# can pass either.
#
# API design note: this submodule is intentionally NOT re-exported from BIDSBase.
# Its accessor vocabulary (`column`, `entities`, `metadata`) is machinery — it
# would collide with the BIDSContracts interface API (`column(e, :x)`) that
# BIDSBase re-exports in M1. Usage: `using BIDSBase.Schema`.
# =============================================================================

module Schema

using JSON3

export load_schema, schema, schema_isloaded, reload_schema!,
       schema_version, bids_version, versions,
       objects, rules, meta,
       entities, entity, entity_order,
       datatypes, datatype, suffixes, suffix,
       columns, column, metadata_fields, metadata_field,
       modalities, modality,
       file_rules, sidecar_rules, tabular_rules,
       suffix_rules, suffix_entities, suffixes_of, datatypes_of, modality_of,
       requirement_level

const DEFAULT_SCHEMA_PATH = joinpath(@__DIR__, "schema", "bids_schema.json")

"""
    BIDSSchema

The machine-readable BIDS specification, loaded as data. Create with
[`load_schema`](@ref) or the cached [`schema`](@ref).
"""
struct BIDSSchema
    raw::JSON3.Object
end

# ---- loading (lazy, cached singleton) ---------------------------------------

"Load the schema from `path` (fresh parse; default: the pinned copy)."
function load_schema(path::AbstractString=DEFAULT_SCHEMA_PATH)
    return BIDSSchema(JSON3.read(read(path, String)))
end

const SCHEMA_REF = Ref{Union{Nothing,BIDSSchema}}(nothing)

"`true` if the cached schema has been loaded."
schema_isloaded() = SCHEMA_REF[] !== nothing

"""
    schema([path]) -> BIDSSchema

The cached schema. Loads (and caches) on first call; subsequent calls return
the cached object. Use [`reload_schema!`](@ref) to refresh.
"""
function schema(path::AbstractString=DEFAULT_SCHEMA_PATH)
    if SCHEMA_REF[] === nothing
        SCHEMA_REF[] = load_schema(path)
    end
    return SCHEMA_REF[]::BIDSSchema
end

"Force-reload the cached schema (e.g. after an update to the pinned copy)."
reload_schema!(path::AbstractString=DEFAULT_SCHEMA_PATH) = (SCHEMA_REF[] = load_schema(path))

# ---- version accessors -------------------------------------------------------

"Schema format version (e.g. `\"1.2.1\"`)."
schema_version(s::BIDSSchema = schema()) = String(s.raw.schema_version)

"BIDS specification version the schema targets (e.g. `\"1.11.1\"`)."
bids_version(s::BIDSSchema = schema()) = String(s.raw.bids_version)

"BIDS version history shipped in the schema (newest first)."
versions(s::BIDSSchema = schema()) = String.(s.raw.meta.versions)

# ---- raw access ---------------------------------------------------------------

"The `objects` subtree: entities, datatypes, suffixes, columns, metadata, modalities, ..."
objects(s::BIDSSchema = schema()) = s.raw.objects

"The `rules` subtree: entities, files, sidecars, tabular_data, modalities, checks, errors, ..."
rules(s::BIDSSchema = schema()) = s.raw.rules

"The `meta` subtree (context, versions, ...)."
meta(s::BIDSSchema = schema()) = s.raw.meta

# ---- object accessors (schema-as-data) ----------------------------------------
# Each returns the definitions dict, or a single definition (`nothing` if absent).
# Names may be given as String or Symbol; values are JSON3 objects (getproperty access).

"""
    entities([s])          → definitions for all 35 entities
    entity(name[, s])      → definition for one entity (`nothing` if absent)

Entity definitions are keyed by entity *name* (`"subject"`), with the filename
short form in `def.name` (`"sub"`).
"""
entities(s::BIDSSchema = schema()) = objects(s).entities
entity(name, s::BIDSSchema = schema()) = get(objects(s).entities, Symbol(name), nothing)

"""
    entity_order([s]) -> Vector{String}

The BIDS entity ordering — the filename grammar order (subject, template,
session, ..., description). From `rules.entities`, NOT from `objects.entities`
(which is alphabetically keyed and therefore unordered for this purpose).
"""
entity_order(s::BIDSSchema = schema()) = String.(rules(s).entities)

"See [`entities`](@ref)." 
datatypes(s::BIDSSchema = schema()) = objects(s).datatypes
datatype(name, s::BIDSSchema = schema()) = get(objects(s).datatypes, Symbol(name), nothing)

"See [`entities`](@ref)."
suffixes(s::BIDSSchema = schema()) = objects(s).suffixes
suffix(name, s::BIDSSchema = schema()) = get(objects(s).suffixes, Symbol(name), nothing)

"""
    columns([s])           → definitions for all 101 TSV column names
    column(name[, s])      → definition for one column (`nothing` if absent)

Ground truth for the events reader (M1): `column("onset").type == "number"`,
negative onsets allowed; `column("sample") === nothing` — the events `sample`
column is NOT schema-defined in 1.11, so its semantics live in BIDSContracts.
"""
columns(s::BIDSSchema = schema()) = objects(s).columns
column(name, s::BIDSSchema = schema()) = get(objects(s).columns, Symbol(name), nothing)

"See [`entities`](@ref)."
metadata_fields(s::BIDSSchema = schema()) = objects(s).metadata
metadata_field(name, s::BIDSSchema = schema()) = get(objects(s).metadata, Symbol(name), nothing)

"See [`entities`](@ref)."
modalities(s::BIDSSchema = schema()) = objects(s).modalities
modality(name, s::BIDSSchema = schema()) = get(objects(s).modalities, Symbol(name), nothing)

# ---- rules accessors ------------------------------------------------------------

"The `rules.files` subtree (`raw`, `deriv`, `common`)."
file_rules(s::BIDSSchema = schema()) = rules(s).files

"The `rules.sidecars` subtree (per-group field requirements)."
sidecar_rules(s::BIDSSchema = schema()) = rules(s).sidecars

"The `rules.tabular_data` subtree (TSV column requirements)."
tabular_rules(s::BIDSSchema = schema()) = rules(s).tabular_data

# ---- derived queries (the payoff of schema-as-data) ------------------------------

"""
    suffix_rules(name[, s]) -> Vector{Tuple{Symbol,Symbol,JSON3.Object}}

All raw file rules whose `suffixes` contain `name`. One suffix name can have
several rules across datatypes (e.g. `coordsystem` appears once per modality as
`coordsystem__eeg`, ...). Returns `(group, key, rule)` triples, `rule` being the
raw file rule with `suffixes`, `extensions`, `datatypes`, `entities`.
"""
function suffix_rules(name, s::BIDSSchema = schema())
    out = Vector{Tuple{Symbol,Symbol,JSON3.Object}}()
    sn = String(name)
    for (group, rls) in file_rules(s).raw
        rls isa JSON3.Object || continue
        for (key, rule) in rls
            rule isa JSON3.Object || continue
            sufs = get(rule, :suffixes, nothing)
            sufs !== nothing && sn in sufs || continue
            push!(out, (Symbol(group), Symbol(key), rule))
        end
    end
    return out
end

"""
    suffix_entities(name[, s]) -> Vector{JSON3.Object}

Per-datatype entity requirements for files with suffix `name` — one entry per
matching raw file rule, each a dict of entity name => `"required"`/`"optional"`.
This is the ground truth `BIDSPath` (M1) validates filenames against.
"""
function suffix_entities(name, s::BIDSSchema = schema())
    out = Vector{JSON3.Object}()
    for (_, _, rule) in suffix_rules(name, s)
        ents = get(rule, :entities, nothing)
        ents !== nothing && push!(out, ents)
    end
    return out
end

"""
    suffixes_of(datatype[, s]) -> Vector{Symbol}

All suffixes valid for a datatype, derived by scanning the raw file rules.
For EEG: `(eeg, channels, coordsystem, electrodes, events, physio, stim, ...)`.
"""
function suffixes_of(datatype_name, s::BIDSSchema = schema())
    out = Symbol[]
    dn = String(datatype_name)
    for (group, rls) in file_rules(s).raw
        rls isa JSON3.Object || continue
        for (key, rule) in rls
            rule isa JSON3.Object || continue
            dts = get(rule, :datatypes, nothing)
            dts === nothing || dn in dts || continue
            for suf in get(rule, :suffixes, ())
                suf = Symbol(suf)
                suf in out || push!(out, suf)
            end
        end
    end
    return out
end

"""
    datatypes_of(modality[, s]) -> Vector{Symbol}

Datatypes belonging to a modality, from `rules.modalities`
(e.g. `datatypes_of("eeg") == [:eeg]`).
"""
function datatypes_of(modality_name, s::BIDSSchema = schema())
    def = get(rules(s).modalities, Symbol(modality_name), nothing)
    def === nothing && return Symbol[]
    dts = get(def, :datatypes, nothing)
    return dts === nothing ? Symbol[] : Symbol.(dts)
end

"""
    modality_of(datatype[, s]) -> Union{Symbol,Nothing}

Inverse of [`datatypes_of`](@ref): the modality a datatype belongs to.
"""
function modality_of(datatype_name, s::BIDSSchema = schema())
    dn = String(datatype_name)
    for (mod, def) in rules(s).modalities
        dts = get(def, :datatypes, nothing)
        dts !== nothing && dn in dts && return Symbol(mod)
    end
    return nothing
end

"""
    requirement_level(v) -> String

Normalize a field-requirement value from the schema. Requirement values are
heterogeneous — a plain string (`"required"`) or a dict with a `level` key
(`{level: "required", description_addendum: "..."}`). Returns the level string.

Schema ground truth (1.11.1): 483 string values vs 143 dict values across all
sidecar rules — heterogeneous is systematic, not an edge case.
"""
requirement_level(v::AbstractDict) = String(get(v, :level, ""))
requirement_level(v) = String(v)

end # module
