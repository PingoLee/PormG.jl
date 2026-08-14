# ============================================================
# test/unit/test_bulk_default_fill_scope.jl
#
# Regression suite for #331 — WHEN PormG supplies a value of its own on a
# bulk write, and when it must not.
#
# THE ONE RULE:
#   PormG fills a value only into a column the DataFrame does NOT contain.
#   A column that IS present is caller-authored data, and PormG never
#   rewrites its cells.
#
# It covers every fill kind (static `default`, `auto_now`, `auto_now_add`,
# UUID `auto_add`), all three bulk operations, and both nullabilities.
#
# Before #331, `_prepare_bulk_df!` carried a fourth fill site that rewrote
# `missing`/`nothing` cells of a PRESENT column with the fill value. That made
# a DataFrame unable to express "I mean NULL here" on a defaulted field, and
# split the two insert paths: `create("f" => nothing)` stored NULL while
# `bulk_insert` of the identical row stored the default. Silent, and a real
# referential difference on a SET_DEFAULT foreign key.
#
# Sibling files, deliberately not duplicated here:
#   - test_bulk_update_column_scope.jl — the `columns=` scope contract, i.e.
#     which ABSENT fields may be injected on an explicit-scope bulk_update.
#   - test_bulk_no_mutation.jl — that none of these internal writes reaches
#     the caller's DataFrame (#132).
#
# Deterministic and DB-free: a mock PostgreSQL connection with
# `show_query = :dict`. bulk_insert and bulk_update both run their per-row
# loop in dry-run mode, so `validate_field_data` — and therefore the NOT NULL
# error asserted below — is genuinely exercised here. bulk_copy is the
# exception: it returns before its row loop, so only its column list is
# provable at this layer (see the bulk_copy testset).
# ============================================================

using Test
using PormG
using PormG.Models: Model, IDField, IntegerField, CharField, DateTimeField, UUIDField
using PormG.QueryBuilder: bulk_copy, bulk_insert, bulk_update
using PormG: InvalidValueError, PormGError
using UUIDs
import DataFrames

# Mock connection under a dedicated key so this file cannot contaminate (or be
# contaminated by) other unit files sharing Main in runtests.jl.
struct BulkFillScopeMockPg <: PormG.PormGPostgres end
PormG.config["bdfs_mock"] = PormG.Configuration.Settings(
    connections = BulkFillScopeMockPg(),
    change_data = true,
)

# Every fill kind, at both nullabilities where it matters. F1-flavored: a pit-stop
# stint sheet is exactly the shape of data that arrives from a CSV with holes in it.
Bdfs_stint = Model("bdfs_stint",
    id         = IDField(),
    driver     = CharField(),
    laps       = IntegerField(default = 0, null = true),        # static default, nullable
    pit_stops  = IntegerField(default = 0),                     # static default, NOT NULL
    checked_at = DateTimeField(auto_now_add = true, null = true),
    updated_at = DateTimeField(auto_now = true, null = true),
    token      = UUIDField(auto_add = true, null = true),
)
Bdfs_stint.connect_key = "bdfs_mock"

# A second model with NO auto-generated fields. `auto_now`/`auto_now_add`/`auto_add` mint a
# fresh value per call, so two calls can never produce equal parameter vectors — which would
# make the create()-vs-bulk_insert parity assertion below impossible to state exactly. Every
# column here is deterministic, so the two paths can be compared whole rather than slot by slot.
Bdfs_pitlane = Model("bdfs_pitlane",
    id        = IDField(),
    driver    = CharField(),
    laps      = IntegerField(default = 0, null = true),
    pit_stops = IntegerField(default = 0),
)
Bdfs_pitlane.connect_key = "bdfs_mock"

# A UUID auto_add PRIMARY KEY, for the #334 blank-rescue testset — `Bdfs_stint.token` is not a
# pk, so it cannot exercise `_drop_blank_auto_primary_keys!`.
Bdfs_uuid_pk = Model("bdfs_uuid_pk",
    token  = UUIDField(primary_key = true, auto_add = true),
    driver = CharField(),
)
Bdfs_uuid_pk.connect_key = "bdfs_mock"

# ------------------------------------------------------------------
# Read a bound value back BY COLUMN NAME rather than by a hard-coded index.
#
# An INSERT renders its column list in the same order it binds parameters, on the
# create() path and the bulk path alike, so a column's position in that list is its
# parameter index. Looking values up by name keeps these assertions readable and
# immune to a future change in the order injected columns are appended — which is a
# real risk here, since present columns come first and injected ones are appended.
# ------------------------------------------------------------------
function insert_columns(res)
    m = match(r"INSERT INTO\s+\S+\s*\((.*?)\)\s*VALUES"s, res[:sql_text])
    m === nothing && error("could not parse an INSERT column list from: $(res[:sql_text])")
    return [strip(c, ['"', ' ', '\n', '\r', '\t']) for c in split(m.captures[1], ",")]
end

function param_for(res, col)
    idx = findfirst(==(col), insert_columns(res))
    idx === nothing && error("column $(col) is not in the INSERT: $(res[:sql_text])")
    return res[:parameters][idx]
end

# The bulk_update VALUES source list plays the same role for an UPDATE.
function source_param_for(res, col)
    m = match(r"AS\s+source\s*\((.*?)\)"s, res[:sql_text])
    m === nothing && error("could not parse a source column list from: $(res[:sql_text])")
    cols = [strip(c, ['"', ' ', '\n', '\r', '\t']) for c in split(m.captures[1], ",")]
    idx = findfirst(==(col), cols)
    idx === nothing && error("column $(col) is not in the source list: $(res[:sql_text])")
    return res[:parameters][idx]
end

# Every bound value for `col`, across all rows — for asserting per-row DISTINCTNESS (#334) rather
# than just presence. `parameters` is a flat, row-major vector: bulk_insert renders one
# `VALUES (?,?),(?,?),...` clause per row in the same column order, so column `idx` out of `n`
# total columns appears at flat positions `idx, idx+n, idx+2n, ...`.
function params_for(res, col)
    cols = insert_columns(res)
    idx = findfirst(==(col), cols)
    idx === nothing && error("column $(col) is not in the INSERT: $(res[:sql_text])")
    n = length(cols)
    return res[:parameters][idx:n:end]
end

@testset "#331: PormG fills only absent columns" begin

    # ─────────────────────────────────────────────────────────────────────────────
    # Insert-path parity: create() and bulk_insert must store the SAME value
    # This is the issue verbatim. `create("laps" => nothing)` has always stored NULL;
    # `bulk_insert` of a DataFrame carrying `laps = [missing]` stored the model default
    # instead, so switching a create() loop to one bulk_insert for speed silently changed
    # what was persisted. Both arms are asserted absolutely as well as against each other:
    # an equality check alone would stay green if BOTH paths regressed to the default.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "create() and bulk_insert agree on an explicit null" begin
        c = Bdfs_pitlane.objects.create("driver" => "Senna", "laps" => nothing,
                                        show_query = :dict)
        b = bulk_insert(Bdfs_pitlane.objects,
                        DataFrames.DataFrame(driver = ["Senna"], laps = [missing]),
                        show_query = :dict)

        # Same columns, same bound values — the two paths are substitutable.
        @test insert_columns(c) == insert_columns(b)
        @test isequal(c[:parameters], b[:parameters])

        # …and independently, the value is actually NULL on each path (pre-fix the bulk
        # arm bound 0 here, which is the whole bug).
        @test ismissing(param_for(c, "laps"))
        @test ismissing(param_for(b, "laps"))

        # The same call still fills the ABSENT column: `pit_stops` is in neither the
        # create() pairs nor the DataFrame, so both paths inject the default.
        @test param_for(c, "pit_stops") == 0
        @test param_for(b, "pit_stops") == 0
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # A present column is never rewritten — for ANY fill kind
    # #331 is one rule, not a default-only carve-out. A blank cell in a column the
    # caller supplied stays NULL whether the field carries a static `default`, an
    # `auto_now_add`/`auto_now` timestamp, or a UUID `auto_add`. Pre-fix this row came
    # out as (0, <now>, <now>, <fresh uuid>) — every one of them fabricated.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "present column + blank cells: every fill kind leaves them NULL" begin
        res = bulk_insert(Bdfs_stint.objects, DataFrames.DataFrame(
                driver     = ["Prost"],
                laps       = [missing],
                checked_at = [missing],
                updated_at = [missing],
                token      = [missing],
            ), show_query = :dict)

        @test ismissing(param_for(res, "laps"))
        @test ismissing(param_for(res, "checked_at"))   # not stamped with now()
        @test ismissing(param_for(res, "updated_at"))   # ditto
        @test ismissing(param_for(res, "token"))        # no UUID minted

        # `pit_stops` is the control: absent from the frame, so it IS still filled. Without
        # it this testset would also pass against a fix that simply stopped filling anything.
        @test param_for(res, "pit_stops") == 0
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # A present column with real values is left alone too
    # Guards the mirror-image error: a fix that blanked every present column, or that
    # re-derived auto_now from the clock while ignoring what the caller supplied.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "present column + concrete cells: values pass through verbatim" begin
        res = bulk_insert(Bdfs_stint.objects, DataFrames.DataFrame(
                driver = ["Piquet"],
                laps   = [71],
            ), show_query = :dict)

        @test param_for(res, "laps") == 71              # not reset to the default 0
        @test param_for(res, "pit_stops") == 0          # absent → injected, as always
        @test !ismissing(param_for(res, "checked_at"))  # absent → stamped, as always
        @test !ismissing(param_for(res, "token"))       # absent → minted, as always
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # NOT NULL + a default + a blank cell is an error, and the SAME error create() gives
    # On a `null = false` field there is no NULL to mean, so the blank is a caller mistake.
    # It must surface as PormG's own typed, actionable error — not as a raw backend constraint
    # violation, and not silently papered over with the default (which is what happened pre-fix:
    # the write succeeded, storing 0). That this testset runs against a mock with no database at
    # all is itself the proof that the diagnosis is PormG's and not the backend's.
    #
    # Both arms assert the same two substrings. That is what makes "the same error create()
    # raises" a tested claim rather than a comment in the source.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "NOT NULL field: a blank cell raises, matching create()" begin
        bulk_err = try
            bulk_insert(Bdfs_stint.objects,
                        DataFrames.DataFrame(driver = ["Lauda"], pit_stops = [missing]),
                        show_query = :dict)
            nothing
        catch e
            e
        end
        create_err = try
            Bdfs_stint.objects.create("driver" => "Lauda", "pit_stops" => nothing,
                                      show_query = :dict)
            nothing
        catch e
            e
        end

        for err in (bulk_err, create_err)
            @test err isa InvalidValueError
            @test err isa PormGError          # inside the taxonomy, so callers can catch broadly
            msg = sprint(showerror, err)
            @test occursin("pit_stops", msg)                    # names the offending field
            @test occursin("null values are not allowed", msg)  # says why
        end

        # The operation is still named correctly in each message, so the two are
        # distinguishable in a log even though the diagnosis is identical.
        @test occursin("bulk_insert", sprint(showerror, bulk_err))
        @test occursin("insert", sprint(showerror, create_err))
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Absent-column injection is untouched — the other half of the rule
    # #331 narrows WHEN PormG supplies a value; it must not stop it supplying one at all.
    # A frame carrying only `driver` still gets all four fill kinds injected, which is what
    # keeps a partial CSV loadable and NOT NULL columns satisfied.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "absent columns: all four fill kinds still inject" begin
        res = bulk_insert(Bdfs_stint.objects,
                          DataFrames.DataFrame(driver = ["Fittipaldi"]),
                          show_query = :dict)

        @test param_for(res, "laps") == 0
        @test param_for(res, "pit_stops") == 0
        @test !ismissing(param_for(res, "checked_at"))
        @test !ismissing(param_for(res, "updated_at"))
        @test !ismissing(param_for(res, "token"))
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # #334: absent UUID auto_add column — a distinct value per row, not one per batch
    # `resolve_absent_column_fill` used to call `uuid4()` ONCE per field and the injection
    # site broadcast that single value across the whole frame, so every row of an absent
    # `auto_add` UUID column got the identical value — an immediate collision on a primary
    # or unique column. The other three fill kinds (static default, TIMESTAMPTZ auto_now/
    # auto_now_add, DATE auto_now/auto_now_add) are deliberately UNCHANGED: one value per
    # batch remains correct and is asserted below alongside the UUID fix so a future change
    # cannot silently make everything per-row.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "#334: absent UUID auto_add column mints a distinct value per row" begin
        res = bulk_insert(Bdfs_stint.objects,
                          DataFrames.DataFrame(driver = ["Fangio", "Moss", "Hawthorn"]),
                          show_query = :dict)

        tokens = params_for(res, "token")
        @test length(tokens) == 3
        @test all(!ismissing, tokens)
        @test length(unique(tokens)) == 3   # pre-#334: all three were the SAME uuid4()

        # Control: the temporal and static fill kinds must stay ONE value for the whole
        # batch — this fix must not turn them per-row too.
        @test length(unique(params_for(res, "checked_at"))) == 1
        @test length(unique(params_for(res, "updated_at"))) == 1
        @test all(==(0), params_for(res, "laps"))
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # #334: a blank UUID auto_add PRIMARY KEY column is rescued, not raised
    # `_drop_blank_auto_primary_keys!` only recognized `auto_increment` primary keys before
    # this fix — a UUID `auto_add` pk has no `auto_increment` field at all, so an all-blank
    # present column fell through to the NOT NULL check and raised. It is now rescued the
    # same way: dropped, treated as absent, and minted per row by the fix above. A mixed
    # blank/explicit column still raises — unchanged.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "#334: an all-blank UUID auto_add primary key column is rescued, not raised" begin
        res = bulk_insert(Bdfs_uuid_pk.objects,
                          DataFrames.DataFrame(token = [missing, missing], driver = ["Senna", "Prost"]),
                          show_query = :dict)
        tokens = params_for(res, "token")
        @test length(tokens) == 2
        @test all(!ismissing, tokens)
        @test length(unique(tokens)) == 2   # dropped → absent → per-row mint, not a raise

        # Mixed blank/explicit still raises, unchanged.
        @test_throws PormG.QueryBuildError bulk_insert(Bdfs_uuid_pk.objects,
            DataFrames.DataFrame(token = [string(uuid4()), missing], driver = ["Senna", "Prost"]),
            show_query = :dict)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_update: a blank cell nulls the column out instead of being a silent no-op
    # This is the most damaging pre-fix case. Asking bulk_update to clear a defaulted
    # column wrote the default straight back, so the call reported success and changed
    # nothing the caller wanted changed. The auto_now injection must survive alongside.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_update: an explicit blank nulls the column" begin
        res = bulk_update(Bdfs_stint.objects,
                          DataFrames.DataFrame(id = [1], laps = [missing]),
                          columns = ["laps"], match_on = ["id"], show_query = :dict)

        @test ismissing(source_param_for(res, "laps"))      # pre-fix: 0
        # auto_now still injects on an explicit-scope update — the intentional ORM
        # side-effect, unchanged by #331.
        @test occursin("\"updated_at\"", res[:sql_text])
        @test !ismissing(source_param_for(res, "updated_at"))
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_update: an absent static default still must not leak into the SET
    # The `columns=` scope guard predates #331 and is asserted in full in
    # test_bulk_update_column_scope.jl. Restated as one line here so this file's
    # statement of the rule is self-contained: absent + explicit scope + static default
    # is the ONE case where an absent column is deliberately NOT filled.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_update: an absent static default stays out of an explicit scope" begin
        res = bulk_update(Bdfs_stint.objects,
                          DataFrames.DataFrame(id = [1], driver = ["Senna"]),
                          columns = ["driver"], match_on = ["id"], show_query = :dict)
        set_text = match(r"SET(.*?)FROM"s, res[:sql_text]).captures[1]

        @test occursin("\"driver\"", set_text)
        @test !occursin("laps", set_text)          # static default, absent → suppressed
        @test !occursin("pit_stops", set_text)     # ditto
        @test occursin("\"updated_at\"", set_text) # auto_now, absent → still injected
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # bulk_copy: the COPY column list obeys the same rule
    # SCOPE LIMIT: bulk_copy returns its prepared statement before the row loop, so
    # `validate_field_data` never runs under show_query and neither cell values nor the
    # NOT NULL error are observable here. Both are covered against a live PostgreSQL in
    # test/integration/test_bulk_copy.jl — this testset is the column list only. Do not
    # read the gap as coverage.
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "bulk_copy: present column participates, absent columns injected" begin
        res = bulk_copy(Bdfs_stint.objects,
                        DataFrames.DataFrame(driver = ["Regazzoni"], laps = [missing]),
                        show_query = :dict)

        @test occursin("COPY", res[:sql_text])
        @test occursin("\"laps\"", res[:sql_text])       # present, kept (its cells stay NULL)
        @test occursin("\"pit_stops\"", res[:sql_text])  # absent, injected
        @test occursin("\"checked_at\"", res[:sql_text])
        @test occursin("\"token\"", res[:sql_text])
    end
end
