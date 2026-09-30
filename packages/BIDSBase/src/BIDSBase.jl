module BIDSBase

# =============================================================================
# BIDSBase.jl — the schema-driven BIDS implementation package
# =============================================================================
# Architecture (see the project plan): BIDSBase consumes the frozen BIDSContracts
# interface and provides the schema machinery + reference types.
#
#   src/Schema.jl      ← the BIDS machine specification, loaded as data  (done)
#   src/BIDSPath.jl    ← path grammar: parse/build/validate filenames    (done)
#   src/Layout.jl      ← lazy dataset index; JSON sidecar inheritance    (done)
#   src/Tabular.jl     ← Events reader (BIDS-strict, contract interface) (done)
#   (M2) EEGDataset    ← DimensionalData-based signal container + readers
#
# The schema-as-data layer lives in BIDSBase.Schema and is intentionally NOT
# re-exported here: its vocabulary (`column`, `entities`, `metadata`) is
# machinery and would collide with the BIDSContracts interface API
# (`column(e, :x)`) re-exported in M1. Usage: `using BIDSBase.Schema`.
# =============================================================================

include("Schema.jl")
include("BIDSPath.jl")

# the path-grammar submodule is named PathGrammar (not BIDSPath) so that the
# exported struct name `BIDSPath` does not collide with the module binding
using .PathGrammar
include("Layout.jl")

# the layout submodule is named Layouts (not Layout) for the same reason
using .Layouts
include("Tabular.jl")

# Tabulars extends the Layouts `metadata` generic — one function, methods on
# Layout (paths) and Events (sidecar contents)
using .Tabulars
export BIDSPath, PathViolation,
       parse_path, build_path, validate_path, isvalid,
       getentity, hasentity,
       Layout, files, get_subjects, get_sessions, get_tasks,
       get_suffixes, get_datatypes,
       sidecars, metadata, dataset_description, validate, filepath,
       Events, events, column, columnnames, nrows, ncols,
       onsets, durations, trial_type, isevents

end
