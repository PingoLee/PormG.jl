module models

import PormG.Models

Circuit::Models.ModelType = Models.Model(
  circuitid = Models.IDField(),
  circuitref = Models.CharField(),
  name = Models.CharField(),
  country = Models.CharField()
)

Race::Models.ModelType = Models.Model(
  raceid = Models.IDField(),
  year = Models.IntegerField(),
  round = Models.IntegerField(),
  circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "CASCADE"),
  name = Models.CharField(),
  date = Models.DateField(),
  # Filled by the write itself (#1694): the entry's `create` leaves them out, so it runs the default fill.
  created_at = Models.DateTimeField(auto_now_add = true),
  updated_on = Models.DateField(auto_now = true),
  token = Models.UUIDField(auto_add = true),
  # The drivers who have a result in the race (#1689, #1599 layer 5): a many-to-many through `Result`, the F1 schema's
  # own link, read forward (`drivers__surname`) and backward from a driver (`races__year`) by `m2m_step`.
  drivers = Models.ManyToManyField("Driver", through = "Result", related_name = "races")
)

# A race's pit stops (#1694, #1599 layer 7): deleting a race deletes them (`CASCADE`), in the ORM's own collector.
PitStop::Models.ModelType = Models.Model(
  pitstopid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "CASCADE"),
  stop = Models.IntegerField(),
  lap = Models.IntegerField()
)

# A driver's debut race (#1694, #1599 layer 7): deleting the race keeps the driver and clears the reference
# (`SET_NULL`).
Driver::Models.ModelType = Models.Model(
  driverid = Models.IDField(),
  surname = Models.CharField(),
  debut_raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "SET_NULL", null = true)
)

# The circuit a constructor falls back to (#1694, #1599 layer 7), seeded by each `prep.jl` with this fixed id, far above
# any id a sequence gives in the fixture, so its `default` is a constant on every engine.
const DEFAULT_CIRCUIT_ID = 9_000_100

# A constructor and the one it became (#1694, #1599 layer 7): deleting a constructor deletes the ones that came after it
# (`CASCADE` on its own table, #1377), and deleting its home circuit puts it back on the default circuit (`SET_DEFAULT`).
Constructor::Models.ModelType = Models.Model(
  constructorid = Models.IDField(),
  name = Models.CharField(),
  parentid = Models.ForeignKey("Constructor", pk_field = "constructorid", on_delete = "CASCADE", null = true),
  home_circuitid = Models.ForeignKey(Circuit, pk_field = "circuitid", on_delete = "SET_DEFAULT",
                                     default = DEFAULT_CIRCUIT_ID)
)

# A race's results (#1694, #1599 layer 7): a race that has one cannot be deleted (`PROTECT`), nor its driver (`RESTRICT`),
# the shape the F1 schema's results and lap times have. `delete_rules_step` (`../tools/writes.jl`) checks both refusals.
Result::Models.ModelType = Models.Model(
  resultid = Models.IDField(),
  raceid = Models.ForeignKey(Race, pk_field = "raceid", on_delete = "PROTECT"),
  driverid = Models.ForeignKey(Driver, pk_field = "driverid", on_delete = "RESTRICT"),
  position = Models.IntegerField()
)

# A season and the one before it (#1694, #1599 layer 7): deleting a season clears the next one's reference (`SET_NULL`
# on its own table).
Season::Models.ModelType = Models.Model(
  seasonid = Models.IDField(),
  year = Models.IntegerField(),
  previousid = Models.ForeignKey("Season", pk_field = "seasonid", on_delete = "SET_NULL", null = true)
)

# A car's telemetry on one lap (#1599, #1838 decision 2): a JSON document, an array and a network address, the three
# column kinds of the lookups only PostgreSQL has (`docs/src/backends.md`). Only the Postgres.jl variant creates its
# table: on SQLite and MySQL `lookup_refusals_step` (`../tools/reads.jl`) is refused before any SQL.
CarTelemetry::Models.ModelType = Models.Model(
  telemetryid = Models.IDField(),
  payload = Models.JSONField(null = true),
  pit_laps = Models.ArrayField(Models.IntegerField()),
  pit_ip = Models.GenericIPAddressField()
)

Models.@models Circuit Race PitStop Driver Constructor Result Season CarTelemetry

end
