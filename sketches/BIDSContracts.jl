# =============================================================================
# BIDSContracts.jl — API sketch v0 (pre-implementation)
# =============================================================================
# The frozen interface layer for a Julia BIDS data representation.
#
# Design goals:
#   * ~zero dependencies  (stdlib only — no Tables.jl, no DimensionalData)
#   * stable forever      (registered 1.0; interface changes are breaking)
#   * cheap to adopt      (third parties implement traits against THIS package
#                          alone — they must not need BIDSBase or its deps)
#
# Consumers:
#   * Type authors (UnfoldSim, NeuroAnalyzer, user DimArray wrappers, ...) —
#     implement the traits + interface functions against this package only.
#   * BIDSBase.jl (schema machinery + reference types) — consumes this contract.
#
# Layers — the "types or traits?" debate resolved as "both, in three layers":
#   1. Traits          — Holy-style predicates; duck typing for third-party types
#   2. Abstract types  — shallow dispatch anchors (Makie / Tables / analysis pkgs)
#   3. Interface funcs — the real API: stubs + derived defaults, frozen semantics
#
# NOTE on zero deps: tabular interop (DataFrame, CSV, AlgebraOfGraphics) is
# BIDSBase's job — it implements Tables.jl on top of this contract. The contract
# only defines the *semantics*. Likewise, DimensionalData anchoring happens in
# BIDSBase (see §2 note below).
#
# Schema ground truth (BIDS 1.11):
#   * onset   — number; seconds from the beginning of the acquisition of the
#               FIRST data point; negative onsets allowed.
#   * duration— number; zero or positive, or `n/a` (→ `missing`).
#   * sample  — NOT defined in objects.columns (1.11) → the alignment convention
#               is owned by this contract (see sampleindices).
# =============================================================================

module BIDSContracts

# Public API — exported, as any interface package does (cf. Tables.jl).
export isevents, ischannels, iselectrodes, ismetadata, iscoordsystem, istimeseries,
       AbstractBIDSTable, AbstractEvents, AbstractChannels, AbstractElectrodes,
       AbstractBIDSMetadata, AbstractBIDSTimeseries,
       onsets, durations, trial_type, column, columnnames,
       data, samplingrate, nsamples, nchannels, duration,
       events, channels, electrodes, coordsystem, metadata,
       sampleindices

# -----------------------------------------------------------------------------
# 1. TRAITS — one method each, default `false`. This is the duck-typing surface.
#    Third-party types opt in by defining ONE method; no subtyping required.
# -----------------------------------------------------------------------------

"""
    isevents(x) -> Bool

`true` if `x` implements the BIDS **events** interface.

Semantic contract (frozen):
- `onsets(x)::AbstractVector{Float64}` — seconds, measured from the beginning of
  the acquisition of the first data point (BIDS `onset`); negative onsets allowed.
- `durations(x)::AbstractVector{Union{Float64,Missing}}` — seconds from onset;
  zero or positive; `n/a` → `missing` (derived fallback provided).
- `trial_type(x)::AbstractVector{Union{String,Missing}}` (BIDS `trial_type`).
- Arbitrary additional columns — BIDS allows them, and they are load-bearing for
  analysis workflows — via `column(x, name::Symbol)` and `columnnames(x)`.

Column convention (frozen): an *absent* column returns `nothing` from `column`;
a present-but-`n/a` value returns `missing`.
"""
isevents(x) = false

"""
    istimeseries(x) -> Bool

`true` if `x` implements the BIDS **timeseries** interface: `data`, `samplingrate`
(plus derived fallbacks `nsamples`, `duration`, `nchannels`).

Convention (frozen): multivariate signals are **channels × time** —  chosen for permute-free
interop with MNE/EEGLAB. Physical memory layout is implementation-defined:
column-major Julia makes **time × channels storage** contiguous per channel
(~50× faster on memory-bound per-channel ops like filtering/FFT), so reference
implementations should store time × channels and return a zero-copy
`PermutedDimsArray` from `data()`; hot loops use `parent(data(x))`.
Univariate signals are plain vectors.
"""
istimeseries(x) = false

"""
    ischannels(x) -> Bool

`true` if `x` implements the BIDS **channels** interface (channels.tsv semantics:
name / type / units / sampling_frequency / reference / status per channel).
"""
ischannels(x) = false

"""
    iselectrodes(x) -> Bool

`true` if `x` implements the BIDS **electrodes** interface (electrodes.tsv
semantics: name / x / y / z / type / material / impedance per electrode).
"""
iselectrodes(x) = false

"""
    ismetadata(x) -> Bool

`true` if `x` implements the BIDS **metadata** interface: JSON sidecar semantics
with BIDS inheritance (root → subject → session → run) already applied. Field
access via `metadata(x, field::Symbol)`; absent fields return `nothing`.
"""
ismetadata(x) = false

"""
    iscoordsystem(x) -> Bool

`true` if `x` implements the BIDS **coordsystem** interface (coordsystem.json
semantics: coordinate system + units for EEG/MEG/iEEG sensors and landmarks).
"""
iscoordsystem(x) = false

# -----------------------------------------------------------------------------
# 2. ABSTRACT TYPES — shallow anchors for dispatch. Subtyping is OPTIONAL
#    (traits suffice), but anchors give free ecosystem integration: Makie
#    recipes, analysis packages, and BIDSBase's Tables.jl implementation can
#    all dispatch on these.
#
#    NOTE: no DimensionalData dependency here (zero deps). In BIDSBase,
#    `AbstractBIDSTimeseries` may re-anchor on `AbstractDimArray`.
# -----------------------------------------------------------------------------
abstract type AbstractBIDSTable end
abstract type AbstractEvents     <: AbstractBIDSTable end
abstract type AbstractChannels   <: AbstractBIDSTable end
abstract type AbstractElectrodes <: AbstractBIDSTable end

abstract type AbstractBIDSMetadata end

abstract type AbstractBIDSTimeseries end

# -----------------------------------------------------------------------------
# 3. INTERFACE FUNCTIONS — the real API. Stubs only; implementations add methods.
#    The few *derived* defaults below are overridable.
# -----------------------------------------------------------------------------

# ---- events interface ------------------------------------------------------

"Event onsets in seconds from the first recorded data point (BIDS `onset`)."
function onsets end

"Event durations in seconds (`n/a` → `missing`; BIDS `duration`)."
function durations end

"Trial types (BIDS `trial_type`)."
function trial_type end

"""
    column(x, name::Symbol)

Access any column by name — BIDS allows arbitrary (load-bearing) columns.
Returns `nothing` for an absent column, `missing` for present-but-`n/a` values.
"""
function column end

"All column names, in BIDS TSV order (`onset` first)."
function columnnames end

# Derived default: BIDS allows `duration` to be `n/a` throughout, so a table
# without the column still satisfies the interface. Only meaningful for
# `isevents` types (otherwise `onsets` will MethodError — the intended failure).
"Default: all `missing` (BIDS `duration` may be `n/a`). Override in implementations carrying the column."
durations(x) = fill(missing, length(onsets(x)))

# ---- timeseries interface --------------------------------------------------

"""
    data(x)

The underlying signal. Multivariate convention (frozen): channels × time,
channels first, time last.
"""
function data end

"Sampling frequency in Hz (BIDS `SamplingFrequency`)."
function samplingrate end

"""
    nsamples(x)

Number of samples. Default: last dimension of `data(x)` (frozen channels × time
convention). Override for lazy / streamed storage.
"""
nsamples(x) = last(size(data(x)))

"""
    nchannels(x)

Number of channels. Default: first dimension of `data(x)`. Multivariate
implementations must store channels × time; univariate signals should override.
"""
nchannels(x) = first(size(data(x)))

"""
    duration(x)

Recording duration in seconds. Default (derived): `nsamples(x) / samplingrate(x)`.
"""
duration(x) = nsamples(x) / samplingrate(x)

# ---- component accessors on containers -------------------------------------
# (dataset-like objects: a BIDSLayout record, an EEGDataset, a recording, ...)

"The events table of `x` (an `isevents` type), or `nothing` if absent."
function events end

"The channels table of `x` (an `ischannels` type), or `nothing` if absent."
function channels end

"The electrodes table of `x` (an `iselectrodes` type), or `nothing` if absent."
function electrodes end

"The coordinate-system description of `x` (an `iscoordsystem` type), or `nothing`."
function coordsystem end

"""
    metadata(x)                → the metadata container (an `ismetadata` type) or `nothing`
    metadata(x, field::Symbol) → field value, or `nothing` if absent

Data-driven core API: BIDSBase generates named convenience getters for common
fields on top of this; the contract only fixes the two-arg form.
"""
function metadata end

# ---- alignment semantics (FROZEN — defined once, here) ----------------------

"""
    sampleindices(ts, e) -> Vector{Int}

Sample indices of events `e` (an `isevents` type) in timeseries `ts` (an
`istimeseries` type).

FROZEN SEMANTICS:
1. If `e` carries a `:sample` column, it is authoritative.
2. Otherwise: `sample = round.(Int, onsets(e) .* samplingrate(ts))`.

Time-origin convention: sample 0 == first recorded sample == onset 0.0 s.
(NOTE: the BIDS `sample` column is not defined in schema 1.11 `objects.columns`;
this convention is owned by this contract. Verify against bids-examples in M1.)

This one function is what lets any consumer (a viewer, an epoching tool,
Unfold.jl) place events on a signal without reimplementing the convention.
"""
function sampleindices(ts, e)
    s = column(e, :sample)                     # absent column → nothing
    s === nothing ? round.(Int, onsets(e) .* samplingrate(ts)) : s
end

end # module
