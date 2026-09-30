# =============================================================================
# BIDSContracts_demo.jl — runnable self-test for the API sketch
# =============================================================================
# Run with:  julia sketches/BIDSContracts_demo.jl
#
# Demonstrates the three design claims of the plan:
#   1. ZERO dependencies (stdlib only — no packages to install)
#   2. Trait adoption WITHOUT subtyping (the third-party story: UnfoldSim,
#      NeuroAnalyzer, or a user's own type implements the contract in ~6 lines)
#   3. Derived defaults + frozen alignment semantics work across arbitrary
#      contract-conformant types (the "types or traits" answer: both)
# =============================================================================

include(joinpath(@__DIR__, "BIDSContracts.jl"))
using .BIDSContracts

# -----------------------------------------------------------------------------
# (a) Third-party adoption pattern — NO subtyping, pure trait opt-in.
#     This is what an UnfoldSim / user package would look like.
# -----------------------------------------------------------------------------
struct MockEvents            # could be anything — no BIDS types in the struct
    onset::Vector{Float64}
    trial_type::Vector{String}
    rt::Vector{Float64}      # arbitrary column: load-bearing for analysis
end

BIDSContracts.isevents(::MockEvents)   = true
BIDSContracts.onsets(e::MockEvents)    = e.onset
BIDSContracts.trial_type(e::MockEvents) = e.trial_type
BIDSContracts.columnnames(::MockEvents) = (:onset, :trial_type, :rt)
function BIDSContracts.column(e::MockEvents, nm::Symbol)
    nm === :rt         ? e.rt :
    nm === :trial_type ? e.trial_type :
    nm === :onset      ? e.onset  : nothing
end
# durations NOT implemented → derived fallback (all `missing`) applies.

struct MockTimeseries       # channels × time, frozen convention
    x::Matrix{Float64}
    sf::Float64
end

BIDSContracts.istimeseries(::MockTimeseries) = true
BIDSContracts.data(t::MockTimeseries)        = t.x
BIDSContracts.samplingrate(t::MockTimeseries) = t.sf

# -----------------------------------------------------------------------------
# (b) Subtyping the anchor is the *optional* convenience route.
#     (Qualified name here to avoid export-ambiguity in mixed environments —
#     a realistic pattern for adopters.)
# -----------------------------------------------------------------------------
struct MockChannels <: BIDSContracts.AbstractChannels
    names::Vector{String}
end
BIDSContracts.ischannels(::MockChannels) = true

# -----------------------------------------------------------------------------
# Self-test
# -----------------------------------------------------------------------------
e = MockEvents([0.5, 1.25, 2.0], ["go", "no-go", "go"], [0.31, 0.28, 0.35])
t = MockTimeseries(rand(4, 10_000), 500.0)
ch = MockChannels(["Fz", "Cz", "Pz", "Oz"])

# traits
@assert isevents(e)  "trait adoption without subtyping failed"
@assert istimeseries(t)
@assert ischannels(ch)

# derived defaults
@assert nsamples(t) == 10_000        "nsamples fallback (last dim of data)"
@assert nchannels(t) == 4            "nchannels fallback (first dim of data)"
@assert duration(t) ≈ 20.0           "duration fallback (nsamples / samplingrate)"
@assert isequal(durations(e), [missing, missing, missing])  "durations fallback (BIDS n/a)"

# frozen alignment semantics: sample column absent → onset × samplingrate
@assert isequal(sampleindices(t, e), [250, 625, 1000])

# column conventions: arbitrary columns OK, absent column → nothing
@assert isequal(column(e, :rt), e.rt)
@assert column(e, :stim_file) === nothing

println("BIDSContracts sketch self-test passed ✓")
println("  zero deps, trait adoption without subtyping,")
println("  derived defaults, and frozen alignment all verified.")
