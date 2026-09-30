# =============================================================================
# Tabular.jl — Events: the first tabular component (reader-only, M1)
# =============================================================================
# BIDS-strict TSV reading + the `Events` type implementing the frozen
# BIDSContracts events interface. The Channels/Electrodes readers (later M1)
# reuse `_read_tsv` and the same struct pattern.
#
# BIDS-strict rules (spec TSVG):
#   * tab-separated, required header row, `n/a` = missing marker
#   * cells kept VERBATIM as strings — nothing coerced or dropped, so a
#     faithful writer could round-trip the file byte-for-byte (no writer
#     ships in M1; the round-trip is encoded as a test-only serializer)
#   * all rows must carry the header's cell count; duplicate columns rejected
#
# Typed access is schema-driven (`Schema.column(name).type` — `number`,
# `integer`, `string`); schema-less columns (rishikesh's `sample`, `value`)
# are typed by value inference — the verbatim strings stay authoritative for
# round-trip, so inference can only shape the typed view, never the data.
#
# Contract alignment: the interface function names are deliberately the frozen
# BIDSContracts ones (`onsets`, `durations`, `trial_type`, `column`,
# `columnnames`, `isevents`) — when the contract package materializes these
# become its methods unchanged. Column convention (frozen): absent column →
# `nothing` from `column`; present-but-`n/a` → `missing`.
# =============================================================================

module Tabulars

import ..Schema, JSON3

using ..PathGrammar: BIDSPath, build_path
using ..Layouts: Layout, files, filepath
import ..Layouts: metadata   # extended below (one generic, methods on Layout and Events)

export Events, events, column, columnnames, nrows, ncols,
       onsets, durations, trial_type, isevents

const NA = "n/a"   # the BIDS missing marker

# ---- BIDS-strict TSV reading (shared machinery) ---------------------------------

"""
    _read_tsv(path) -> (Vector{Symbol}, Vector{Vector{String}})

BIDS-strict TSV: tab-separated, required header row, `n/a` = missing marker,
cells kept verbatim as strings. All rows must have the header's cell count;
duplicate column names are rejected. Tolerates CRLF.
"""
function _read_tsv(path::AbstractString)
    text = read(path, String)
    lines = [rstrip(l, '\r') for l in split(text, '\n'; keepempty = false)]
    isempty(lines) && throw(ArgumentError("empty TSV: $path"))
    header = Symbol.(split(lines[1], '\t'))
    allunique(header) || throw(ArgumentError("duplicate column names in $path"))
    rows = [split(l, '\t') for l in lines[2:end]]
    for (i, r) in enumerate(rows)
        length(r) == length(header) || throw(ArgumentError(
            "row $i of $path has $(length(r)) cells, expected $(length(header))"))
    end
    return header, rows
end

# ---- column typing: schema-driven, value-inferred for schema-less columns -------

function _coltype(name::Symbol, cells::Vector{String})
    def = Schema.column(name)
    if def !== nothing
        t = String(get(def, :type, "string"))
        t == "number"  && return :number
        t == "integer" && return :integer
        return :string
    end
    # schema-less (arbitrary load-bearing column): infer from the values
    nonmiss = [v for v in cells if v != NA]
    isempty(nonmiss) && return :string
    all(v -> tryparse(Int, v) !== nothing, nonmiss) && return :integer
    if all(v -> tryparse(Float64, v) !== nothing, nonmiss)
        # integral floats (BIDS sample columns are often "18275.0000000000")
        # → Int, so the contract's frozen sampleindices stays Int-valued
        return all(v -> isinteger(parse(Float64, v)), nonmiss) ? :integerfloat : :number
    end
    return :string
end

_parse(::Val{:number}, v::String) = parse(Float64, v)
_parse(::Val{:integer}, v::String) = parse(Int, v)
_parse(::Val{:integerfloat}, v::String) = round(Int, parse(Float64, v))

# ---- the Events type ------------------------------------------------------------

"""
    Events

A parsed BIDS `events.tsv` — the first tabular component (reader-only in M1).

BIDS-strict by construction: columns in file order (arbitrary load-bearing
columns preserved), cells verbatim (round-trip fidelity), `n/a` → `missing`
in typed access, typed access schema-driven with value inference for
schema-less columns.

Fields: `src` (relative path), `columns::Vector{Symbol}`,
`cells::Vector{Vector{String}}` (per-column, verbatim), `meta::Dict{String,Any}`
(merged sidecar, BIDS inheritance applied).

Convenience constructors:
  * `Events(path; meta)` — parse a TSV file
  * `Events(lt, bp)` — read via a `Layout`, merging inherited sidecar metadata
"""
struct Events
    src::String
    columns::Vector{Symbol}
    cells::Vector{Vector{String}}
    meta::Dict{String,Any}
end

Base.show(io::IO, e::Events) =
    print(io, "Events(", e.src, "; ", nrows(e), " events × ", ncols(e), " columns)")

function Events(path::AbstractString; meta = Dict{String,Any}(), src = path)
    header, rows = _read_tsv(path)
    cells = Vector{String}[String[String(r[j]) for r in rows]
                           for j in eachindex(header)]
    return Events(String(src), header, cells, meta)
end

function Events(lt::Layout, bp::BIDSPath)
    return Events(filepath(lt, bp); meta = metadata(lt, bp), src = build_path(bp))
end

# ---- contract interface ----------------------------------------------------------

"""
    events(lt; <entity kwargs>) -> Union{Events,Nothing}

The unique `events.tsv` of `lt` matching the entity filters (as in `files`),
read with its inherited sidecar metadata. `nothing` when no file matches;
`ArgumentError` when several do (narrow the filter).
"""
function events(lt::Layout; kwargs...)
    matches = files(lt; suffix = "events", extension = ".tsv", kwargs...)
    isempty(matches) && return nothing
    length(matches) == 1 || throw(ArgumentError(
        "$(length(matches)) events.tsv files match; narrow the filter: " *
        join([build_path(bp) for bp in matches], ", ")))
    return Events(lt, only(matches))
end

"`x` implements the BIDS events interface."
isevents(::Events) = true

"Column names in BIDS TSV order (`onset` first)."
columnnames(e::Events) = e.columns

"Number of rows (events)."
nrows(e::Events) = isempty(e.cells) ? 0 : length(e.cells[1])

"Number of columns."
ncols(e::Events) = length(e.columns)

"""
    column(e, name) -> Union{AbstractVector,Nothing}

Any column by name — BIDS allows arbitrary (load-bearing) columns. Schema-
driven typing; `nothing` for an absent column, `missing` for present-but-`n/a`
values (frozen column convention).
"""
function column(e::Events, name::Symbol)
    i = findfirst(==(name), e.columns)
    i === nothing && return nothing
    cells = e.cells[i]
    T = _coltype(name, cells)
    if T === :string
        return Union{String,Missing}[v == NA ? missing : v for v in cells]
    end
    t = Val(T)
    return [v == NA ? missing : _parse(t, v) for v in cells]
end
column(e::Events, name::AbstractString) = column(e, Symbol(name))

"""
    onsets(e) -> Vector{Union{Float64,Missing}}

Event onsets in seconds from the first recorded data point (BIDS `onset`,
schema type `number`; negative onsets allowed). BIDS requires the column
present and filled — `missing` elements signal a malformed file.
"""
function onsets(e::Events)
    c = column(e, :onset)
    c === nothing && throw(ArgumentError("no onset column in $(e.src)"))
    return c
end

"""
    durations(e) -> Vector{Union{Float64,Missing}}

Event durations in seconds; `n/a` → `missing` (BIDS `duration` may be `n/a`
throughout — the contract's derived default for tables without the column).
"""
function durations(e::Events)
    c = column(e, :duration)
    return c === nothing ? fill(missing, nrows(e)) : c
end

"""
    trial_type(e) -> Union{Vector{Union{String,Missing}},Nothing}

Trial types (BIDS `trial_type`, optional); `nothing` when the column is
absent (frozen column convention).
"""
trial_type(e::Events) = column(e, :trial_type)

# metadata — extends the Layouts generic (one function; methods on Layout and Events)
"Sidecar metadata of `e` (BIDS inheritance already applied)."
metadata(e::Events) = e.meta
metadata(e::Events, field::Symbol) = get(e.meta, String(field), nothing)

end # module Tabulars
