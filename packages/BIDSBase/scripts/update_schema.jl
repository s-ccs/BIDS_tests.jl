# =============================================================================
# update_schema.jl — refresh the pinned BIDS schema from the official source
# =============================================================================
# Usage:
#   julia scripts/update_schema.jl            # report pinned vs latest (read-only)
#   julia scripts/update_schema.jl --update   # replace the pinned copy if newer
#
# Schema source: https://bids-specification.readthedocs.io/en/stable/schema.json
#
# A version bump is an artifact bump + test run, not a code change (that is the
# whole point of schema-as-data). After updating, run the test suite:
#   julia --project=. test/runtests.jl
# =============================================================================

using Downloads, JSON3

const SCHEMA_URL = "https://bids-specification.readthedocs.io/en/stable/schema.json"
const PINNED = normpath(joinpath(@__DIR__, "..", "src", "schema", "bids_schema.json"))

function main(update::Bool)
    latest_path = joinpath(tempdir(), "bids_schema_latest.json")
    println("Downloading latest schema ...")
    Downloads.download(SCHEMA_URL, latest_path)

    latest = JSON3.read(read(latest_path, String))
    pinned = JSON3.read(read(PINNED, String))

    println("pinned: BIDS $(pinned.bids_version) (schema $(pinned.schema_version))")
    println("latest: BIDS $(latest.bids_version) (schema $(latest.schema_version))")

    if String(pinned.bids_version) == String(latest.bids_version) &&
       String(pinned.schema_version) == String(latest.schema_version)
        println("✓ pinned schema is up to date")
    elseif update
        cp(latest_path, PINNED; force = true)
        println("✓ pinned schema replaced — now run: julia --project=. test/runtests.jl")
    else
        println("→ update available; rerun with --update to replace the pinned copy")
    end
end

main("--update" in ARGS)
