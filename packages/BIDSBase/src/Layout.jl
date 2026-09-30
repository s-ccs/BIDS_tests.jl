# =============================================================================
# Layout.jl — lazy dataset index over a BIDS tree  (M1)
# =============================================================================
# The Layout walks a dataset root, parses every file with `PathGrammar`
# (no content reads — the scan is lazy: TSV/JSON contents load on demand),
# and answers queries by entity/suffix/extension/datatype.
#
# The inheritance principle (BIDS spec §02) is implemented for JSON sidecars:
# a candidate sidecar must have the same suffix and every entity it carries
# must match the data file exactly; candidates may carry fewer entities.
# `sidecars` returns the chain ordered most-general (dataset root) →
# most-specific (same directory); `metadata` merges in that order so nearer
# files override.
#
# Ignored: dotfiles/dotdirs and the BIDS "magic" directories (code/,
# derivatives/, docs/, logs/, sourcedata/, stimuli/ — also listed as common
# rules in the schema). Derivatives are out of scope (raw datasets only).
# =============================================================================

module Layouts

import ..Schema, JSON3

using ..PathGrammar: BIDSPath, parse_path, build_path, validate_path,
                     getentity, hasentity, PathViolation

export Layout, files, get_subjects, get_sessions, get_tasks,
       get_suffixes, get_datatypes,
       sidecars, metadata, dataset_description, validate, filepath

# BIDS "magic" directories pruned from the walk (spec §02; schema:
# rules.files.common.core.{code,derivatives,docs,logs,sourcedata,stimuli})
const IGNORED_DIRS = ("code", "derivatives", "docs", "logs", "sourcedata", "stimuli")

"""
    Layout

A lazy index over a BIDS dataset. Fields: `root::String`,
`paths::Vector{BIDSPath}` (every indexed file, deterministically sorted).
Build with `Layout(root)` — the scan parses paths only; file contents are
read on demand by [`metadata`](@ref).
"""
struct Layout
    root::String
    paths::Vector{BIDSPath}
end

Base.show(io::IO, lt::Layout) =
    print(io, "Layout(", lt.root, "; ", length(lt.paths), " files)")

function Layout(root::AbstractString)
    root = abspath(String(root))
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    paths = BIDSPath[]
    for (dirpath, dirs, fnames) in walkdir(root)
        # prune dotdirs and top-level BIDS magic dirs; sort for determinism
        filter!(dirs) do d
            !(startswith(d, '.') || (dirpath == root && d in IGNORED_DIRS))
        end
        sort!(dirs)
        for f in sort!(fnames)
            startswith(f, '.') && continue
            push!(paths, parse_path(relpath(joinpath(dirpath, f), root)))
        end
    end
    sort!(paths; by = bp -> (build_path(bp), bp.prefix))
    return Layout(root, paths)
end

# ---- data access ---------------------------------------------------------------

"Absolute path of an indexed `bp` on disk."
filepath(lt::Layout, bp::BIDSPath) = joinpath(lt.root, build_path(bp))

# ---- queries ---------------------------------------------------------------------

"""
    files(lt; suffix, extension, datatype, <entity kwargs>) -> Vector{BIDSPath}

All indexed files matching the filter, in index order. Entity filters are
keyword arguments named by entity (`subject = "001", task = "meditation"`);
a file matches when it carries the entity with exactly that label. Filters
combine conjunctively; `files(lt)` returns everything indexed.
"""
function files(lt::Layout; suffix = nothing, extension = nothing,
               datatype = nothing, rest...)
    out = BIDSPath[]
    for bp in lt.paths
        (suffix === nothing    || bp.suffix    == String(suffix))    || continue
        (extension === nothing || bp.extension == String(extension)) || continue
        (datatype === nothing  || bp.datatype  == String(datatype))  || continue
        ok = true
        for (k, v) in rest
            getentity(bp, k) == String(v) || (ok = false; break)
        end
        ok && push!(out, bp)
    end
    return out
end

_labels(x, name::Symbol) =
    sort!(unique!([getentity(bp, name) for bp in x if hasentity(bp, name)]))

"Distinct subject labels in the dataset, sorted (pybids-style `get_*` names
avoid collisions with the Schema machinery vocabulary)."
get_subjects(lt::Layout) = _labels(lt.paths, :subject)

"Distinct session labels; `get_sessions(lt, subject)` narrows to one subject."
get_sessions(lt::Layout) = _labels(lt.paths, :session)
get_sessions(lt::Layout, subject::AbstractString) =
    _labels(files(lt; subject = subject), :session)

"Distinct task labels in the dataset, sorted."
get_tasks(lt::Layout) = _labels(lt.paths, :task)

"Distinct suffixes among indexed files, sorted."
get_suffixes(lt::Layout) = sort!(unique!([bp.suffix for bp in lt.paths if bp.suffix !== nothing]))

"Distinct datatype directories among indexed files, sorted."
get_datatypes(lt::Layout) = sort!(unique!([bp.datatype for bp in lt.paths if bp.datatype !== nothing]))

# ---- inheritance (JSON sidecars) -------------------------------------------------

_depth(bp::BIDSPath) = count('/', bp.prefix) + (isempty(bp.prefix) ? 0 : 1)

"""
    sidecars(lt, bp) -> Vector{BIDSPath}

The JSON sidecar inheritance chain for `bp`, ordered most-general (dataset
root) → most-specific (same directory; within a level, fewer entities is
more general). A candidate must share `bp`'s suffix and every entity it
carries must match `bp` exactly — candidates may carry fewer entities (the
inheritance principle, BIDS spec §02).
"""
function sidecars(lt::Layout, bp::BIDSPath)
    bp.suffix === nothing && return BIDSPath[]
    cands = BIDSPath[]
    for c in lt.paths
        c.extension == ".json" || continue
        c.suffix == bp.suffix || continue
        ok = true
        for (n, label) in c.entities
            getentity(bp, n) == label || (ok = false; break)
        end
        ok && push!(cands, c)
    end
    return sort!(cands; by = c -> (_depth(c), length(c.entities)))
end

"""
    metadata(lt, bp) -> Dict{String,Any}

Merged JSON sidecar contents for `bp`, merged general → specific (nearer
files override), plus `bp`'s own content when it is itself a JSON file.
Reads on demand — the Layout stays lazy.
"""
function metadata(lt::Layout, bp::BIDSPath)
    if bp.extension == ".json"
        p = filepath(lt, bp)
        return isfile(p) ? JSON3.read(read(p, String), Dict{String,Any}) :
                           Dict{String,Any}()
    end
    merged = Dict{String,Any}()
    for sc in sidecars(lt, bp)
        p = filepath(lt, sc)
        isfile(p) || continue
        merge!(merged, JSON3.read(read(p, String), Dict{String,Any}))
    end
    return merged
end

# ---- dataset-level helpers -------------------------------------------------------

"Top-level `dataset_description.json`, parsed."
function dataset_description(lt::Layout)
    JSON3.read(read(joinpath(lt.root, "dataset_description.json"), String),
               Dict{String,Any})
end

# does bp match a rules.files.common rule (stem + extension)?
function _is_common_file(bp::BIDSPath)
    isempty(bp.prefix) || return false
    bp.suffix === nothing && return false
    for (_, rules) in Schema.file_rules().common
        rules isa JSON3.Object || continue
        haskey(rules, Symbol(bp.suffix)) || continue
        rule = rules[Symbol(bp.suffix)]
        exts = get(rule, :extensions, nothing)
        if exts === nothing
            return true                                        # exact-name rule
        elseif bp.extension === nothing
            String("") in exts && return true                  # plain "README"
        else
            String(bp.extension) in exts && return true
        end
    end
    return false
end

"""
    validate(lt::Layout) -> Vector{Pair{String,Vector{PathViolation}}}

Dataset-level sanity report: [`validate_path`](@ref) over data files
(non-JSON files with a raw file rule). JSON sidecars are skipped — they
legitimately lack subject/session entities (inheritance); common top-level
files (`README`, `participants.tsv`, ...) are skipped — they are not raw
file rules. Empty ⇔ every data file is a valid BIDS path.
"""
function validate(lt::Layout)
    out = Pair{String,Vector{PathViolation}}[]
    for bp in lt.paths
        bp.extension == ".json" && continue
        _is_common_file(bp) && continue
        v = validate_path(bp)
        isempty(v) || push!(out, build_path(bp) => v)
    end
    return out
end

end # module Layouts
