module models

import PormG.Models
import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING


Status = Models.Model(
  statusid=Models.IDField(),
  status=Models.CharField()
)

Circuit = Models.Model( # You can create a model like a Django model for each table so that you can define a huge number of tables at once in just one file. Please capitalize the names of models.
  circuitid=Models.IDField(), # House style: declare field names in lowercase snake_case. PormG preserves the case you declare (so mixed-case/uppercase legacy columns are supported) and field lookups are case-sensitive — query fields in the same case you declared them.
  circuitref=Models.CharField(),
  name=Models.CharField(),
  location=Models.CharField(),
  country=Models.CharField(),
  lat=Models.FloatField(),
  lng=Models.FloatField(),
  alt=Models.IntegerField(),
  url=Models.CharField()
)

Race = Models.Model(
  raceid=Models.IDField(),
  year=Models.IntegerField(),
  round=Models.IntegerField(),
  circuitid=Models.ForeignKey(Circuit, pk_field="circuitid", on_delete="CASCADE"),
  name=Models.CharField(),
  date=Models.DateField(),
  time=Models.TimeField(null=true),
  url=Models.CharField(),
  fp1_date=Models.DateField(null=true),
  fp1_time=Models.TimeField(null=true),
  fp2_date=Models.DateField(null=true),
  fp2_time=Models.TimeField(null=true),
  fp3_date=Models.DateField(null=true),
  fp3_time=Models.TimeField(null=true),
  quali_date=Models.DateField(null=true),
  quali_time=Models.TimeField(null=true),
  sprint_date=Models.DateField(null=true),
  sprint_time=Models.TimeField(null=true),
)

Driver = Models.Model(
  driverid=Models.IDField(),
  driverref=Models.CharField(),
  number=Models.IntegerField(null=true),
  code=Models.CharField(),
  forename=Models.CharField(),
  surname=Models.CharField(),
  dob=Models.DateField(),
  nationality=Models.CharField(),
  url=Models.CharField()
)

Driver_standings = Models.Model(
  driverstandingsid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete=" RESTRICT"),
  points = Models.FloatField(),  # F1 data has half-points (e.g. 1.5) from shared fastest-lap bonuses
  position = Models.IntegerField(),
  positiontext = Models.CharField(),
  wins = Models.IntegerField()
)

Lap_times = Models.Model(
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  lap = Models.IntegerField(),
  position = Models.IntegerField(),
  time = Models.DurationField(),
  milliseconds = Models.IntegerField()
)

Pit_stops = Models.Model(
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  stop = Models.IntegerField(),
  lap = Models.IntegerField(),
  time = Models.TimeField(),
  duration = Models.DurationField(),
  milliseconds = Models.IntegerField()
)

Constructor = Models.Model(
  constructorid=Models.IDField(),
  constructorref=Models.CharField(),
  name=Models.CharField(),
  nationality=Models.CharField(),
  url=Models.CharField()
)

Constructor_results = Models.Model(
  constructorresultsid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="RESTRICT"),
  points = Models.DecimalField(),
  status = Models.CharField()
)

Constructor_standings = Models.Model(
  constructorstandingsid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="RESTRICT"),
  points = Models.DecimalField(),
  position = Models.IntegerField(),
  positiontext = Models.CharField(),
  wins = Models.IntegerField()
)

Qualifying = Models.Model(
  qualifyingid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="RESTRICT"),
  number = Models.IntegerField(null=true),
  position = Models.IntegerField(null=true),
  q1 = Models.DurationField(null=true),
  q2 = Models.DurationField(null=true),
  q3 = Models.DurationField(null=true)
)

Sprint_results = Models.Model(
  sprintid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid = Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  constructorid = Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="RESTRICT"),
  number = Models.IntegerField(null=true),
  grid = Models.IntegerField(),
  position = Models.IntegerField(null=true),
  positiontext = Models.CharField(),
  positionorder = Models.IntegerField(),
  points = Models.FloatField(),
  laps = Models.IntegerField(),
  time = Models.CharField(null=true),
  milliseconds = Models.IntegerField(null=true),
  fastestlap = Models.IntegerField(null=true),
  fastestlaptime = Models.DurationField(null=true),
  statusid = Models.ForeignKey(Status, pk_field="statusid", on_delete="CASCADE")
)

Result = Models.Model(
  resultid=Models.IDField(),
  raceid=Models.ForeignKey(Race, pk_field="raceid", on_delete="CASCADE"),
  driverid=Models.ForeignKey(Driver, pk_field="driverid", on_delete="RESTRICT"),
  constructorid=Models.ForeignKey(Constructor, pk_field="constructorid", on_delete="RESTRICT"),
  number=Models.IntegerField(null=true),
  grid=Models.IntegerField(),
  position=Models.IntegerField(null=true),
  positiontext=Models.CharField(),
  positionorder=Models.IntegerField(),
  points=Models.FloatField(),
  laps=Models.IntegerField(),
  time=Models.CharField(null=true),
  milliseconds=Models.IntegerField(null=true),
  fastestlap=Models.IntegerField(null=true),
  rank=Models.IntegerField(null=true),
  fastestlaptime=Models.DurationField(null=true),
  fastestlapspeed=Models.FloatField(null=true),
  statusid=Models.ForeignKey(Status, pk_field="statusid", on_delete="CASCADE")
)

Just_a_test_deletion = Models.Model(
  id=Models.IDField(),
  name=Models.CharField(),
  test_result=Models.ForeignKey(Result, pk_field="resultid", on_delete="CASCADE", null=true, related_name="test_deletion"),
  test_result2=Models.ForeignKey(Result, pk_field="resultid", on_delete="CASCADE", null=true, related_name="test_deletion2"),
  test_result_set_null=Models.ForeignKey(Result, pk_field="resultid", on_delete="SET_NULL", null=true, related_name="test_deletion_set_null"),
  test_result_set_default=Models.ForeignKey(Result, pk_field="resultid", on_delete="SET_DEFAULT", default=1, null=true, related_name="test_deletion_set_default")
)

Just_a_nested_roll_back = Models.Model(
  id=Models.IDField(),
  test=Models.ForeignKey(Just_a_test_deletion, pk_field="id", on_delete="CASCADE", null=true),
  description=Models.CharField()
)

New_join_position = Models.Model(
  id=Models.IDField(),
  description=Models.CharField(),
  result=Models.IntegerField(null=true),
  boolean_field=Models.BooleanField(null=true)
)

Field_validation_scratch = Models.Model("field_validation_scratch",
  id=Models.IDField(),
  uuid_token=Models.UUIDField(unique=true),
  canonical_url=Models.URLField(max_length=500),
  slug=Models.SlugField(max_length=120, unique=true),
  payload=Models.JSONField(null=true),
  # #296: real BLOB/BYTEA storage. `blob_payload` is unbounded so arbitrary byte sequences can be
  # round-tripped; `bounded_blob` carries a byte bound so the DDL CHECK is exercised against a live
  # database rather than only asserted as SQL text.
  blob_payload=Models.BinaryField(null=true),
  bounded_blob=Models.BinaryField(null=true, max_length=8)
)

# Mirrors the column types Django generates for DateTimeField/DateField/DecimalField.
# Used to validate PormG's wire-format compatibility with Django-managed PostgreSQL schemas
# without requiring Python or Django as a test dependency.
#
# The table is `contract_django_scratch`, NOT `django_contract_scratch` (#325): `django_` is a
# framework prefix in `postgres_ignore_table`, so a table named that way is deliberately invisible
# to introspection — which made `makemigrations` propose `CREATE TABLE` for it on every run and
# blocked the global schema-clean assertion. Ignoring Django's own tables is correct behavior; the
# fixture name was the mistake.
Django_contract_scratch = Models.Model("contract_django_scratch",
  id          = Models.IDField(),
  label       = Models.CharField(max_length=100, unique=true),
  created_at  = Models.DateTimeField(auto_now_add=true),    # Django: DateTimeField(auto_now_add=True)
  updated_at  = Models.DateTimeField(auto_now=true),        # Django: DateTimeField(auto_now=True)
  event_time  = Models.DateTimeField(null=true),            # Django: DateTimeField(null=True)
  event_date  = Models.DateField(null=true),                # Django: DateField(null=True)
  price       = Models.DecimalField(max_digits=10, decimal_places=2, null=true) # Django: DecimalField(max_digits=10, decimal_places=2)
)

# Permanent fixture models for bulk_update regressions that exercise mixed
# nullable fields, constrained foreign keys, date parsing, and boolean writes.
Bulk_update_required_parent_scratch = Models.Model("bulk_update_required_parent_scratch",
  id = Models.IDField(),
  label = Models.CharField()
)

Bulk_update_optional_parent_scratch = Models.Model("bulk_update_optional_parent_scratch",
  id = Models.IDField(),
  label = Models.CharField()
)

Bulk_update_payload_scratch = Models.Model("bulk_update_payload_scratch",
  id = Models.IDField(),
  label = Models.CharField(),
  required_parent_id = Models.ForeignKey(Bulk_update_required_parent_scratch,
    pk_field = "id",
    on_delete = RESTRICT),
  optional_parent_id = Models.ForeignKey(Bulk_update_optional_parent_scratch,
    pk_field = "id",
    on_delete = SET_NULL,
    null = true),
  event_date = Models.DateField(null = true),
  is_active = Models.BooleanField(default = false),
  event_time = Models.DateTimeField(null = true),
  nullable_int = Models.IntegerField(null = true),
  # ImageField/FileField regression (#309): `bulk_update` used to cast this column to the
  # nonexistent `::blob` on PostgreSQL because its `.type` ("BLOB") was cast verbatim instead of
  # via the field's actual rendered column type (`TEXT`).
  photo = Models.ImageField(null = true)
)

# Scratch fixture for #334 — UUIDField(primary_key = true, auto_add = true), to prove
# bulk_insert/bulk_copy mint a DISTINCT uuid4() per row, and that an all-blank present column is
# rescued (dropped, treated absent) rather than raising. No existing fixture combines
# primary_key + auto_add on a UUIDField.
#
# PostgreSQL-only, deliberately: this model has NO SQLite counterpart in `db_sl/models.jl` — see
# the comment there for why (SQLite cannot introspect a UUID primary key distinctly from any other
# TEXT-collapsed primary key type; a pre-existing SQLite migration-engine limitation, not a #334
# regression). `bulk_copy` itself is PostgreSQL-only anyway, so nothing goes untested by omitting
# the SQLite side.
Bulk_uuid_pk_scratch = Models.Model("bulk_uuid_pk_scratch",
  token = Models.UUIDField(primary_key = true, auto_add = true),
  label = Models.CharField(),
)

# Fixture for the bulk_copy data-fidelity regression (#86): bulk_copy must store the SAME
# values as bulk_insert/create() (the field formatter is applied — e.g. a naive DateTime is
# labelled UTC) and must distinguish an empty string from NULL. Nullable char/float/bool/datetime
# cover the parity cases.
Bulk_copy_fidelity_scratch = Models.Model("bulk_copy_fidelity_scratch",
  id = Models.IDField(),
  name = Models.CharField(null = true),
  amount = Models.FloatField(null = true),
  active = Models.BooleanField(null = true),
  event_time = Models.DateTimeField(null = true)
)

# Scratch models exercising the ManyToManyField API (auto-generated through
# table) against the F1 scenario "drivers endorsed by sponsors".
M2m_sponsor_scratch = Models.Model("m2m_sponsor_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_endorsement_scratch = Models.Model("m2m_driver_endorsement_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  sponsors = Models.ManyToManyField(M2m_sponsor_scratch, related_name="drivers")
)

# Advanced M2M tests: Multi-hop joins (Driver -> Sponsor -> Country)
M2m_country_scratch = Models.Model("m2m_country_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_sponsor_with_country_scratch = Models.Model("m2m_sponsor_with_country_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true),
  country = Models.ForeignKey(M2m_country_scratch, on_delete=Models.PROTECT)
)

M2m_driver_multi_hop_scratch = Models.Model("m2m_driver_multi_hop_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  sponsors = Models.ManyToManyField(M2m_sponsor_with_country_scratch, related_name="drivers")
)

# Advanced M2M tests: Explicit through model
M2m_team_scratch = Models.Model("m2m_team_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_explicit_scratch = Models.Model("m2m_driver_explicit_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  teams = Models.ManyToManyField(M2m_team_scratch, through="M2m_membership_scratch", related_name="drivers")
)

M2m_membership_scratch = Models.Model("m2m_membership_scratch",
  id = Models.IDField(),
  driver = Models.ForeignKey(M2m_driver_explicit_scratch, on_delete=Models.CASCADE),
  team = Models.ForeignKey(M2m_team_scratch, on_delete=Models.CASCADE),
  joined_year = Models.IntegerField(null=true)
)

# Explicit through with only the two FK columns (manager mutators allowed).
M2m_team_plain_scratch = Models.Model("m2m_team_plain_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_plain_scratch = Models.Model("m2m_driver_plain_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  teams = Models.ManyToManyField(M2m_team_plain_scratch, through="M2m_link_plain_scratch", related_name="drivers")
)

M2m_link_plain_scratch = Models.Model("m2m_link_plain_scratch",
  id = Models.IDField(),
  driver = Models.ForeignKey(M2m_driver_plain_scratch, on_delete=Models.CASCADE),
  team = Models.ForeignKey(M2m_team_plain_scratch, on_delete=Models.CASCADE),
)

# Explicit through whose model declares a `db_table` (#363). Every other `through=` fixture in this
# file has a logical name equal to its physical table, which is precisely why the bug survived: the
# relation stored the LOGICAL name and rendered it as a table, and the two agreed everywhere it was
# tested. This is the shape of every model in an app-labelled Django import (#345/#346).
#
# The physical name is a DIFFERENT STRING, not merely a different case — SQLite compares identifiers
# case-insensitively, so a case-only difference would address the same table and `db_sl` could not
# tell a fixed tree from a broken one.
#
# FK-only on purpose: the mutators are then permitted, so the raw-SQL write path
# (`INSERT`/`DELETE ... FROM <through table>`) is exercised alongside the join path.
M2m_squad_dbtable_scratch = Models.Model("m2m_squad_dbtable_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_tester_dbtable_scratch = Models.Model("m2m_tester_dbtable_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  squads = Models.ManyToManyField(M2m_squad_dbtable_scratch, through="M2m_enrolment_dbtable_scratch", related_name="testers")
)

M2m_enrolment_dbtable_scratch = Models.Model("m2m_enrolment_dbtable_scratch",
  db_table = "m2m_enrolment_join_tbl",
  id = Models.IDField(),
  tester = Models.ForeignKey(M2m_tester_dbtable_scratch, on_delete=Models.CASCADE),
  squad = Models.ForeignKey(M2m_squad_dbtable_scratch, on_delete=Models.CASCADE),
)

# Explicit through whose foreign keys declare a `db_column` (#377) — the COLUMN-axis sibling of the
# `db_table` fixture above. The relation rendered the through model's FIELD name as the join column,
# which equals the physical column only while no `db_column` is declared; that was true of every
# `through=` fixture in this file, which is why #377 outlived #363.
#
# `db_table` is pinned here TOO, on purpose: that is the shape a Django import of a legacy schema
# produces (an app label AND `db_column=` on the FKs), and carrying both proves the two axes are
# independent rather than one accidentally covering the other.
#
# The field names carry Django's `_id` suffix because that is what `process_class_fields!` emits, and
# the columns are DIFFERENT STRINGS, not case variants — SQLite compares identifiers
# case-insensitively, so a case-only difference could not tell a fixed tree from a broken one.
#
# FK-only on purpose: the mutators are then permitted, so the raw-SQL write path
# (`INSERT`/`DELETE ... FROM <through table>`, plus the `SELECT <related column>` read-back behind
# `set`) is exercised alongside the join path.
M2m_crew_dbcol_scratch = Models.Model("m2m_crew_dbcol_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_mechanic_dbcol_scratch = Models.Model("m2m_mechanic_dbcol_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  crews = Models.ManyToManyField(M2m_crew_dbcol_scratch, through="M2m_crewslot_dbcol_scratch", related_name="mechanics")
)

M2m_crewslot_dbcol_scratch = Models.Model("m2m_crewslot_dbcol_scratch",
  db_table = "m2m_crewslot_join_tbl",
  id = Models.IDField(),
  mechanic_id = Models.ForeignKey(M2m_mechanic_dbcol_scratch, db_column="mech_ref", on_delete=Models.CASCADE),
  crew_id = Models.ForeignKey(M2m_crew_dbcol_scratch, db_column="crew_ref", on_delete=Models.CASCADE),
)

# Default reverse accessor (no related_name): target uses owner model name lowercase.
M2m_brand_scratch = Models.Model("m2m_brand_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_default_reverse_scratch = Models.Model("m2m_driver_default_reverse_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  partners = Models.ManyToManyField(M2m_brand_scratch),
)

# #364 — SELF-referential ManyToManyField: both ends of the relation resolve to THIS model, so the
# join columns take Django's `from_`/`to_` spelling (`from_m2m_teammate_scratch_id` /
# `to_m2m_teammate_scratch_id`) instead of the same `<model>_<pk>` string twice. Mirrors the Django
# importer fixture's `racing.Driver.teammates` (#346), which reaches the same shape by pinning.
#
# The target is a STRING on purpose: a model cannot reference its own binding before it exists, so
# the string is the only way to write this by hand — and it is resolved at `set_models`.
#
# `related_name` is set because the reverse accessor lands on this same model alongside the forward
# one; the default would be the bare model name, which reads as a foreign key rather than the other
# end of a teammate link. PormG has no Django `symmetrical=`, so the relation is DIRECTIONAL.
M2m_teammate_scratch = Models.Model("m2m_teammate_scratch",
  id = Models.IDField(),
  driverref = Models.CharField(unique=true),
  teammates = Models.ManyToManyField("M2m_teammate_scratch", related_name="teammate_of"),
)

# Case-preservation (#57) fixtures — DELIBERATELY mixed-case COLUMNS (driverRef,
# foreName, parentRef, lapTime) to prove PormG creates and queries genuinely
# mixed-case columns on a live DB. These are capability fixtures, NOT the house
# style: declare lowercase snake_case in real models. Table names stay lowercase.
Case_preserve_parent_scratch = Models.Model("case_preserve_parent_scratch",
  id = Models.IDField(),
  driverRef = Models.CharField(unique=true),
  foreName = Models.CharField(null=true),
)

Case_preserve_child_scratch = Models.Model("case_preserve_child_scratch",
  id = Models.IDField(),
  parentRef = Models.ForeignKey(Case_preserve_parent_scratch, pk_field="id", on_delete="CASCADE", related_name="children"),
  lapTime = Models.IntegerField(null=true),
)

# db_column (#50) fixtures — the FIELD name differs from the physical COLUMN name.
# `sku` → column "product_sku"; the FK `parent` → column "parent_fk". Proves PormG
# creates/queries the db_column physical names while results stay keyed by field name.
Db_column_scratch = Models.Model("db_column_scratch",
  id = Models.IDField(),
  sku = Models.CharField(db_column="product_sku"),
  name = Models.CharField(null=true),
)

Db_column_child_scratch = Models.Model("db_column_child_scratch",
  id = Models.IDField(),
  parent = Models.ForeignKey(Db_column_scratch, db_column="parent_fk", on_delete="CASCADE", related_name="children", null=true),
  note = Models.CharField(null=true),
)

# db_column on a PRIMARY KEY (#50): field `code` → physical column "pk_code". Exercises
# sequence sync / id allocation against the db_column column on insert.
Db_column_pk_scratch = Models.Model("db_column_pk_scratch",
  code = Models.IDField(db_column="pk_code"),
  label = Models.CharField(null=true),
)

# SET_NULL child over a db_column FK (#50): deleting the parent must NULL "parent_fk"
# (exercises the cascade SET_NULL UPDATE on the physical column).
Db_column_setnull_child_scratch = Models.Model("db_column_setnull_child_scratch",
  id = Models.IDField(),
  parent = Models.ForeignKey(Db_column_scratch, db_column="parent_fk", on_delete="SET_NULL", related_name="snchildren", null=true),
  note = Models.CharField(null=true),
)

# FK over a RENAMED parent PK (#50): references Db_column_pk_scratch.code (physical column
# "pk_code") via pk_field; the FK constraint AND joins must resolve the parent's db_column.
Db_column_pk_child_scratch = Models.Model("db_column_pk_child_scratch",
  id = Models.IDField(),
  parent = Models.ForeignKey(Db_column_pk_scratch, pk_field="code", db_column="parent_code_fk", on_delete="CASCADE", related_name="pkchildren", null=true),
  tag = Models.CharField(null=true),
)

# #62: the SAME renamed-parent relationship, but the FK target is the model-name STRING
# "Db_column_pk_scratch" (not the model instance). set_models must resolve it so the FK
# constraint and join ON clause still target the parent's db_column ("pk_code").
Db_column_pk_strchild_scratch = Models.Model("db_column_pk_strchild_scratch",
  id = Models.IDField(),
  parent = Models.ForeignKey("Db_column_pk_scratch", pk_field="code", db_column="parent_code_strfk", on_delete="CASCADE", related_name="pkstrchildren", null=true),
  tag = Models.CharField(null=true),
)

# #64: M2M where BOTH participating models' PKs are renamed via db_column. The through-table
# join must target the physical PK columns ("driver_pk" / "sponsor_pk"), NOT the field name
# "code" — exercises owner_pk (through key_a) and related_pk (related key_b) resolution.
M2m_rpk_sponsor_scratch = Models.Model("m2m_rpk_sponsor_scratch",
  code = Models.IDField(db_column="sponsor_pk"),
  name = Models.CharField(unique=true),
)

M2m_rpk_driver_scratch = Models.Model("m2m_rpk_driver_scratch",
  code = Models.IDField(db_column="driver_pk"),
  driverref = Models.CharField(unique=true),
  sponsors = Models.ManyToManyField(M2m_rpk_sponsor_scratch, related_name="rpkdrivers"),
)

# #59 — model-level db_table. The LOGICAL name is lowercase (as every model name must be); the
# PHYSICAL table is mixed-case, which is the spelling PormG could not express before this option.
# On PostgreSQL a quoted identifier is case-sensitive, so this fixture only round-trips if every
# renderer — DDL, SELECT/INSERT/UPDATE/DELETE, FK REFERENCES, migration diffing — agrees on
# "Db_Table_Scratch". SQLite folds case and so cannot catch a disagreement here; that asymmetry is
# the whole reason these live on both backends.
Db_table_scratch = Models.Model("db_table_scratch",
  db_table = "Db_Table_Scratch",
  id = Models.IDField(),
  name = Models.CharField(null=true),
)

# A child whose FK targets the db_table-mapped parent — the REFERENCES clause must name the
# parent's PHYSICAL table, not its logical name. This is the half that failed silently before #300
# (the constraint can bind to a different table that merely happens to exist).
Db_table_child_scratch = Models.Model("db_table_child_scratch",
  id = Models.IDField(),
  parent = Models.ForeignKey(Db_table_scratch, on_delete="CASCADE", related_name="dbtchildren", null=true),
  note = Models.CharField(null=true),
)

# db_table AND db_column together: the two overrides are independent axes (table vs column) and
# must both apply to the same statements.
Db_table_col_scratch = Models.Model("db_table_col_scratch",
  db_table = "Db_Table_Col_Scratch",
  id = Models.IDField(),
  sku = Models.CharField(db_column="product_sku", null=true),
)


# #394 — a physical TABLE name that PormG's DDL renders but its query builder used to REFUSE.
# `db_table` is deliberately not shape-validated (#59), because naming what PormG's own conventions
# could not produce is the point of the option — yet the query side ran every table through a
# fail-closed identifier pattern that rejects a space. So `migrate` created this table and every
# SELECT against it raised `InvalidValueError`. The same name also broke the generated
# `pending_migrations.jl`, which writes each table as a Julia BINDING.
#
# A space rather than an embedded quote: it exercises the validator-versus-escaper split exactly,
# without also stressing the introspection quote-doubling path (#389) inside the migration diff. No
# index, no unique constraint and no foreign key, so the fixture stays clear of the index-name and
# REFERENCES renderers, which Db_table_scratch above already covers.
#
# The COLUMN axis is covered too, since #414. `driverref` pins `db_column = "driver ref"`, so this
# one fixture carries a spaced TABLE name and a spaced COLUMN name through every layer at once:
# `Dialect.field_to_column` escapes it in DDL, `safe_column_identifier` renders it in queries
# (pinned at the unit layer in `test/unit/test_identifier_quoting.jl`), and PostgreSQL introspection
# now reads it back whole.
#
# It could not be here before #414. The PostgreSQL `columns` aggregate is
# `quote_ident(name) || ' ' || format_type(…)` and the reader split it on `" "`, so `"driver ref"`
# came back as the phantom `"driver` — WITH the leading quote, which `_unquote_ident` correctly
# refuses to strip from a lone unbalanced pair. The planner renders that phantom through
# `_julia_field_identifier`, which sanitizes it to the legal binding `driver`, so the drift line
# read `Add field: driverref; Remove field: driver` and never converged. That is what makes the
# GLOBAL no-drift assertion in `test_db_table_db.jl` the live mutation gate for this issue: revert
# the parse and this fixture drifts forever.
Odd_identifier_scratch = Models.Model("odd_identifier_scratch",
  db_table = "Odd Identifier Scratch",
  id = Models.IDField(),
  driverref = Models.CharField(max_length=30, null=true, db_column="driver ref"),
  points = Models.IntegerField(null=true),
)

end
