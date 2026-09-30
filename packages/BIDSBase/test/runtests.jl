using Test
using BIDSBase
using BIDSBase.Schema
# qualified access for machinery names that now also exist in the contract API
# (BIDSBase exports `column(e, :x)` for Events; Schema's `column(name)` stays here)
import BIDSBase.Schema as Schema
# explicit import: the contract API's `column` — resolves the ambiguity with
# Schema's machinery `column(name)`; the latter is used qualified (`Schema.column`)
using BIDSBase: column

@testset "BIDSBase.Schema" begin

    @testset "loading & versions" begin
        s = load_schema()                      # fresh parse of the pinned copy
        @test schema_version(s) == "2.0.0"
        @test bids_version(s) == "1.11.2"
        @test length(versions(s)) == 22
        @test first(versions(s)) == "1.11.2"   # newest first

        schema_isloaded() || schema()          # populate the cache
        @test schema_isloaded()
        @test schema() === schema()            # cached singleton
        reload_schema!()
        @test schema_isloaded()
    end

    @testset "survey numbers (schema-as-data ground truth)" begin
        @test length(entities())        == 35
        @test length(entity_order())    == 35
        @test length(datatypes())       == 16
        @test length(suffixes())        == 118
        @test length(columns())         == 101
        @test length(metadata_fields()) == 451
        @test length(modalities())      == 11
    end

    @testset "entity access & filename order" begin
        e = entity("subject")
        @test e !== nothing
        @test e.name == "sub"                  # short form lives in def.name
        @test e.format == "label"
        @test entity("no_such_entity") === nothing

        # entity ORDER for filenames comes from rules.entities (ordered),
        # not objects.entities (alphabetically keyed)
        @test first(entity_order()) == "subject"
        @test entity_order()[3] == "session"
        @test last(entity_order()) == "description"
    end

    @testset "column definitions (events ground truth)" begin
        onset = Schema.column("onset")
        @test onset !== nothing
        @test onset.type == "number"
        @test occursin("seconds", onset.description)
        @test occursin("Negative onsets are allowed", onset.description)

        duration = Schema.column("duration")
        @test duration !== nothing
        @test occursin("n/a", duration.description)

        # documented finding: the events `sample` column is NOT schema-defined
        # in 1.11 → its alignment semantics live in BIDSContracts
        @test Schema.column("sample") === nothing
        @test Schema.column("no_such_column") === nothing
    end

    @testset "datatype & modality" begin
        d = datatype("eeg")
        @test d !== nothing
        @test d.display_name == "Electroencephalography"

        @test modality_of("eeg") == :eeg
        @test :eeg in datatypes_of("eeg")
        @test modality_of("not_a_datatype") === nothing
    end

    @testset "suffixes_of (derived from file rules)" begin
        sufs = suffixes_of("eeg")
        for expected in (:eeg, :channels, :coordsystem, :electrodes, :events,
                         :physio, :physioevents, :stim)
            @test expected in sufs
        end
        @test isempty(suffixes_of("not_a_datatype"))
    end

    @testset "file rules & entity requirements (BIDSPath ground truth)" begin
        matches = suffix_rules(:eeg)
        @test length(matches) >= 1
        # find the _eeg data rule (suffix == :eeg, datatype == :eeg)
        i = findfirst(x -> x[1] == :eeg && x[2] == :eeg, matches)
        @test i !== nothing
        group, key, rule = matches[i]
        @test group == :eeg && key == :eeg

        # per-suffix extensions (EEG recording formats)
        exts = rule.extensions
        @test ".json" in exts
        @test ".edf"  in exts
        @test ".vhdr" in exts
        @test ".set"  in exts
        @test ".bdf"  in exts

        # per-suffix entity requirements: what BIDSPath will validate in M1
        ents = rule.entities
        @test ents.subject == "required"
        @test ents.task    == "required"
        @test ents.run     == "optional"
        @test ents.session == "optional"
    end

    @testset "sidecar rules (metadata requirements)" begin
        eeg_side = sidecar_rules().eeg
        @test haskey(eeg_side, :EEGRequired)
        fields = eeg_side.EEGRequired.fields
        # requirement values are heterogeneous (string or {level, ...}) —
        # requirement_level normalizes both:
        @test requirement_level(get(fields, :EEGReference, nothing)) == "required"
        @test requirement_level(get(fields, :SamplingFrequency, nothing)) == "required"
        # TaskName lives in EEGTaskInformation, not EEGRequired:
        task_info = eeg_side.EEGTaskInformation.fields
        @test requirement_level(get(task_info, :TaskName, nothing)) == "required"
    end

    @testset "tabular rules (events column requirements)" begin
        ev = tabular_rules().events.Events
        @test get(ev.columns, :onset,     nothing) == "required"
        @test get(ev.columns, :duration,  nothing) == "required"
        @test get(ev.columns, :trial_type, nothing) == "optional"
        # schema-level confirmation of the arbitrary-columns decision:
        @test get(ev, :additional_columns, nothing) == "allowed"
    end

end

@testset "BIDSPath (path grammar)" begin

    @testset "parse" begin
        p = parse_path("sub-01/ses-02/eeg/sub-01_ses-02_task-faces_run-1_eeg.edf")
        @test p isa BIDSPath
        @test getentity(p, "subject") == "01"      # String or Symbol accepted
        @test getentity(p, :session)  == "02"
        @test getentity(p, :task)     == "faces"
        @test getentity(p, :run)      == "1"
        @test getentity(p, :acquisition) === nothing
        @test hasentity(p, :run)
        @test !hasentity(p, :acquisition)
        @test p.suffix == "eeg"
        @test p.extension == ".edf"
        @test p.datatype == "eeg"
        @test p.prefix == "sub-01/ses-02"
        # filename order preserved — the substrate for order validation
        @test first.(p.entities) == [:subject, :session, :task, :run]
    end

    @testset "parse: sidecars, plain files, extensions" begin
        ev = parse_path("sub-01/eeg/sub-01_task-faces_events.tsv")
        @test ev.suffix == "events"
        @test ev.extension == ".tsv"
        @test ev.datatype == "eeg"
        @test getentity(ev, :task) == "faces"

        cs = parse_path("sub-01/eeg/sub-01_task-faces_coordsystem.json")
        @test cs.suffix == "coordsystem"
        @test cs.extension == ".json"

        # BrainVision binary/marker extensions are schema-listed
        bv = parse_path("sub-01/eeg/sub-01_task-faces_eeg.eeg")
        @test bv.suffix == "eeg" && bv.extension == ".eeg" && isvalid(bv)

        # multi-part extension survives the first-dot split
        @test parse_path("sub-01/anat/sub-01_T1w.nii.gz").extension == ".nii.gz"

        # filenames that do not follow the entity grammar → suffix-only
        dd = parse_path("dataset_description.json")
        @test dd.suffix == "dataset_description" && dd.extension == ".json"
        @test isempty(dd.entities) && dd.datatype === nothing
        readme = parse_path("README")
        @test readme.suffix == "README" && readme.extension === nothing
        @test isempty(readme.entities)
    end

    @testset "build & round-trip" begin
        p = parse_path("sub-01/ses-02/eeg/sub-01_ses-02_task-faces_run-1_eeg.edf")
        @test build_path(p) == "sub-01/ses-02/eeg/sub-01_ses-02_task-faces_run-1_eeg.edf"

        # from scratch — entities out of grammar order are schema-reordered
        bp = BIDSPath([:task => "faces", :subject => "01"], "eeg", ".edf"; datatype = "eeg")
        @test build_path(bp) == "sub-01/eeg/sub-01_task-faces_eeg.edf"

        # subject/session duplicated into the directory prefix (BIDS convention)
        bp2 = BIDSPath([:subject => "01", :session => "02", :task => "rest"],
                       "channels", ".tsv"; datatype = "eeg")
        @test build_path(bp2) == "sub-01/ses-02/eeg/sub-01_ses-02_task-rest_channels.tsv"

        # round-trips over real EEG filenames
        for f in ["sub-01/eeg/sub-01_task-faces_eeg.edf",
                  "sub-01/eeg/sub-01_task-faces_events.tsv",
                  "sub-01/eeg/sub-01_task-faces_coordsystem.json",
                  "sub-01/eeg/sub-01_electrodes.tsv",
                  "sub-01/eeg/sub-01_task-rest_eeg.bdf"]
            @test build_path(parse_path(f)) == f
        end
    end

    @testset "validate against the schema" begin
        # valid EEG recording files
        @test isvalid(parse_path("sub-01/eeg/sub-01_task-faces_eeg.edf"))
        @test isvalid(parse_path("sub-01/eeg/sub-01_task-faces_eeg.eeg"))
        @test isvalid(parse_path("sub-01/eeg/sub-01_task-faces_events.tsv"))
        @test isvalid(parse_path("sub-01/eeg/sub-01_task-faces_events.json"))
        @test isvalid(parse_path("sub-01/eeg/sub-01_task-faces_coordsystem.json"))
        # task is optional for electrodes.tsv
        @test isvalid(parse_path("sub-01/eeg/sub-01_electrodes.tsv"))

        # `task` is REQUIRED for eeg channels/events (schema ground truth)
        bad4 = parse_path("sub-01/eeg/sub-01_channels.tsv")
        @test !isvalid(bad4)
        @test any(v -> v.kind == :missing_required_entity, validate_path(bad4))
        bad5 = parse_path("sub-01/eeg/sub-01_events.tsv")
        @test !isvalid(bad5)
        @test any(v -> v.kind == :missing_required_entity, validate_path(bad5))

        # entity order: run must not precede task
        bad1 = parse_path("sub-01/eeg/sub-01_run-1_task-faces_eeg.edf")
        @test !isvalid(bad1)
        @test any(v -> v.kind == :entity_order, validate_path(bad1))

        # unknown entity — preserved, reported, still round-trips
        bad2 = parse_path("sub-01/eeg/sub-01_task-faces_bogus-1_eeg.edf")
        @test any(v -> v.kind == :unknown_entity, validate_path(bad2))
        @test build_path(bad2) == "sub-01/eeg/sub-01_task-faces_bogus-1_eeg.edf"

        # wrong extension for suffix/datatype
        bad3 = parse_path("sub-01/eeg/sub-01_task-faces_eeg.tsv")
        @test any(v -> v.kind == :bad_extension, validate_path(bad3))

        # label charset: hyphens are not allowed in labels
        bad6 = parse_path("sub-01/eeg/sub-01_task-fa-ces_eeg.edf")
        @test any(v -> v.kind == :bad_label, validate_path(bad6))

        # unknown suffix (also covers entity-grammar-less filenames)
        bad7 = parse_path("sub-01/eeg/sub-01_task-faces_nosuch.tsv")
        @test any(v -> v.kind == :unknown_suffix, validate_path(bad7))

        # datatype filter: the eeg rule does not cover anat datatypes
        bad8 = parse_path("sub-01/anat/sub-01_task-faces_eeg.edf")
        @test any(v -> v.kind == :unknown_suffix, validate_path(bad8))

        # scope: common top-level files are not raw rules → unknown_suffix
        @test any(v -> v.kind == :unknown_suffix,
                  validate_path(parse_path("dataset_description.json")))
    end

end

@testset "Layout (eeg_rishikesh)" begin
    root = normpath(joinpath(@__DIR__, "..", "..", "..", "bids-examples", "eeg_rishikesh"))
    lt = Layout(root)

    @testset "scan & counts" begin
        @test lt isa Layout
        # 40 session dirs × 4 files + 6 top-level files (stimuli/, code/ ignored)
        @test length(lt.paths) == 166
        @test length(get_subjects(lt)) == 24
        @test first(get_subjects(lt)) == "001"
        @test get_sessions(lt) == ["01", "02", "03"]
        @test get_sessions(lt, "024") == ["01"]
        @test get_tasks(lt) == ["meditation"]
        @test get_datatypes(lt) == ["eeg"]
        @test get_suffixes(lt) == ["CHANGES", "README", "channels",
                                   "dataset_description", "eeg", "events",
                                   "participants"]
    end

    @testset "queries" begin
        @test length(files(lt; suffix = "events", extension = ".tsv")) == 40
        @test length(files(lt; suffix = "events")) == 41   # + root .json sidecar
        @test length(files(lt; suffix = "eeg", extension = ".bdf")) == 40
        @test length(files(lt; subject = "001")) == 8      # 2 sessions × 4 files
        @test length(files(lt; subject = "024")) == 4      # 1 session
        @test length(files(lt; subject = "022")) == 12     # 3 sessions

        evs = files(lt; subject = "001", session = "01", suffix = "events")
        @test length(evs) == 1
        bp = only(evs)
        @test getentity(bp, :task) == "meditation"
        @test build_path(bp) == "sub-001/ses-01/eeg/sub-001_ses-01_task-meditation_events.tsv"

        bd = only(files(lt; subject = "022", session = "03",
                        suffix = "eeg", extension = ".bdf"))
        @test build_path(bd) == "sub-022/ses-03/eeg/sub-022_ses-03_task-meditation_eeg.bdf"
    end

    @testset "sidecar inheritance" begin
        # events.tsv inherits the ROOT sidecar (task-only match)
        ev = only(files(lt; subject = "001", session = "01", suffix = "events"))
        sc = sidecars(lt, ev)
        @test length(sc) == 1
        @test build_path(only(sc)) == "task-meditation_events.json"

        # the .bdf inherits only its own sidecar — other subjects'/sessions'
        # eeg.json are candidates but mismatch on subject/session
        bd = only(files(lt; subject = "001", session = "01", suffix = "eeg", extension = ".bdf"))
        sc2 = sidecars(lt, bd)
        @test length(sc2) == 1
        @test build_path(only(sc2)) == "sub-001/ses-01/eeg/sub-001_ses-01_task-meditation_eeg.json"
    end

    @testset "metadata merge" begin
        bd = only(files(lt; subject = "001", session = "01", suffix = "eeg", extension = ".bdf"))
        md = metadata(lt, bd)
        @test md["TaskName"] == "meditation"
        @test md["SamplingFrequency"] == 256
        @test md["EEGChannelCount"] == 64

        # a JSON file returns its own content
        @test metadata(lt, only(sidecars(lt, bd)))["TaskName"] == "meditation"

        # events.tsv merges the root sidecar's column descriptions
        ev = only(files(lt; subject = "001", session = "01", suffix = "events"))
        mev = metadata(lt, ev)
        @test haskey(mev, "onset")
        @test haskey(mev, "sample")   # root sidecar documents the sample column
        @test haskey(mev["trial_type"], "Levels")
        @test haskey(mev["value"], "Levels")
    end

    @testset "dataset description & validation" begin
        dd = dataset_description(lt)
        @test dd["Name"] == "EEG meditation study"
        @test dd["License"] == "CC0"
        @test haskey(dd, "BIDSVersion")

        # all 120 data files (channels.tsv, eeg.bdf, events.tsv) are valid paths;
        # sidecars and common files are skipped by scope
        @test isempty(validate(lt))
    end

end

@testset "Events (eeg_rishikesh)" begin
    root = normpath(joinpath(@__DIR__, "..", "..", "..", "bids-examples", "eeg_rishikesh"))
    lt = Layout(root)
    e = events(lt; subject = "001", session = "01")

    @testset "accessor & BIDS-strict columns" begin
        @test e isa Events
        @test isevents(e)
        @test columnnames(e) == [:onset, :duration, :trial_type,
                                 :response_time, :sample, :value]
        @test ncols(e) == 6
        @test nrows(e) == 87
        @test e.src == "sub-001/ses-01/eeg/sub-001_ses-01_task-meditation_events.tsv"
    end

    @testset "typed columns (schema-driven + value inference)" begin
        on = onsets(e)
        @test eltype(on) <: Union{Float64,Missing}   # contract: AbstractVector{Float64}
        @test all(!ismissing, on)                    # onset is required
        @test on[1] ≈ 71.38671875
        @test on[end] ≈ 2654.76171875

        dur = durations(e)
        @test all(ismissing, dur)                    # 87/87 rows are n/a

        tt = trial_type(e)
        @test tt[1] == "stimulus"
        @test unique(collect(skipmissing(tt))) == ["stimulus", "response"]

        # sample: schema-less → integral floats inferred as Int (contract:
        # the sample column is the authoritative alignment source)
        s = column(e, :sample)
        @test eltype(s) == Int
        @test s[1] == 18275

        # value: schema-less arbitrary column → Int inference
        v = column(e, :value)
        @test eltype(v) == Int
        @test unique(v) == [128, 2, 4]

        # response_time: schema number, all n/a → missing
        @test all(ismissing, column(e, :response_time))

        # frozen convention: absent column → nothing
        @test column(e, :no_such_column) === nothing
        @test column(e, "no_such_column") === nothing
    end

    @testset "sidecar inheritance & metadata" begin
        # merged metadata = the root task-meditation_events.json (column docs)
        @test metadata(e, :onset) !== nothing
        @test haskey(metadata(e, :onset), "Units")
        @test haskey(metadata(e, :trial_type), "Levels")
        # the events sidecar documents the sample column (starting at 0)
        @test haskey(metadata(e, :sample), "Description")
        # no TaskName in an events sidecar
        @test metadata(e, :TaskName) === nothing
        @test metadata(e) === e.meta
    end

    @testset "alignment convention vs real data (contract M1 verification)" begin
        # the contract docstring says: "Verify against bids-examples in M1".
        # Frozen semantics: sample column authoritative, sample 0 == onset 0.0 s.
        # rishikesh confirms it row-exactly against the eeg.json sampling rate.
        on = collect(onsets(e))
        @test column(e, :sample) == round.(Int, on .* 256.0)
        @test on[1] * 256.0 == 18275.0   # 18275/256 = 71.38671875, exact
    end

    @testset "BIDS-strict round-trip (test-only serializer)" begin
        # no writer ships in M1; this test-only serializer proves the reader
        # preserves everything a faithful writer would need: verbatim cells,
        # column order, n/a markers, row order — byte-exact for canonical files
        text = read(joinpath(root, "sub-001", "ses-01", "eeg",
                             "sub-001_ses-01_task-meditation_events.tsv"), String)
        lines = [join(string.(columnnames(e)), '\t')]
        for i in 1:nrows(e)
            push!(lines, join([c[i] for c in e.cells], '\t'))
        end
        @test join(lines, '\n') * '\n' == text
    end

    @testset "accessor semantics" begin
        @test_throws ArgumentError events(lt)          # 40 files match
        @test events(lt; subject = "999") === nothing  # no match → nothing
        # direct constructor without layout: empty metadata
        e2 = Events(joinpath(root, "sub-001", "ses-01", "eeg",
                             "sub-001_ses-01_task-meditation_events.tsv"))
        @test nrows(e2) == 87
        @test isempty(metadata(e2))
        # malformed TSVs (row cell count ≠ header) are rejected
        mktempdir() do d
            f = joinpath(d, "bad.tsv")
            write(f, "a\tb\n1\t2\t3\n")
            @test_throws ArgumentError Events(f)
        end
    end

end
