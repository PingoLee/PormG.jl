module models

import PormG.Models
import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING


Status = Models.Model(
  statusId=Models.IDField(),
  status=Models.CharField()
)

Circuit = Models.Model( # You can create a model like a Django model for each table so that you can define a huge number of tables at once in just one file. Please capitalize the names of models.
  circuitId=Models.IDField(), # the PormG automatically do a lowercase for the name of the field, so you can use a capital letter in the name of the field, Hoewver you need to use a lowercase in the query operations.
  circuitRef=Models.CharField(),
  name=Models.CharField(),
  location=Models.CharField(),
  country=Models.CharField(),
  lat=Models.FloatField(),
  lng=Models.FloatField(),
  alt=Models.IntegerField(),
  url=Models.CharField()
)

Race = Models.Model(
  raceId=Models.IDField(),
  year=Models.IntegerField(),
  round=Models.IntegerField(),
  circuitId=Models.ForeignKey(Circuit, pk_field="circuitId", on_delete="CASCADE"),
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
  driverId=Models.IDField(),
  driverRef=Models.CharField(),
  number=Models.IntegerField(null=true),
  code=Models.CharField(),
  forename=Models.CharField(),
  surname=Models.CharField(),
  dob=Models.DateField(),
  nationality=Models.CharField(),
  url=Models.CharField()
)

Driver_standings = Models.Model(
  driverStandingsId = Models.IDField(),
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  driverId = Models.ForeignKey(Driver, pk_field="driverId", on_delete=" RESTRICT"),
  points = Models.FloatField(),  # F1 data has half-points (e.g. 1.5) from shared fastest-lap bonuses
  position = Models.IntegerField(),
  positionText = Models.CharField(),
  wins = Models.IntegerField()
) 

Lap_times = Models.Model(
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  driverId = Models.ForeignKey(Driver, pk_field="driverId", on_delete="RESTRICT"),
  lap = Models.IntegerField(),
  position = Models.IntegerField(),
  time = Models.DurationField(),
  milliseconds = Models.IntegerField()
)

Pit_stops = Models.Model(
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  driverId = Models.ForeignKey(Driver, pk_field="driverId", on_delete="RESTRICT"),
  stop = Models.IntegerField(),
  lap = Models.IntegerField(),
  time = Models.TimeField(),
  duration = Models.DurationField(),
  milliseconds = Models.IntegerField()
)

Constructor = Models.Model(
  constructorId=Models.IDField(),
  constructorRef=Models.CharField(),
  name=Models.CharField(),
  nationality=Models.CharField(),
  url=Models.CharField()
)

Constructor_results = Models.Model(
  constructorResultsId = Models.IDField(),
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  constructorId = Models.ForeignKey(Constructor, pk_field="constructorId", on_delete="RESTRICT"),
  points = Models.DecimalField(),
  status = Models.CharField()
)

Constructor_standings = Models.Model(
  constructorStandingsId = Models.IDField(),
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  constructorId = Models.ForeignKey(Constructor, pk_field="constructorId", on_delete="RESTRICT"),
  points = Models.DecimalField(),
  position = Models.IntegerField(),
  positionText = Models.CharField(),
  wins = Models.IntegerField()
) 

Qualifying = Models.Model(
  qualifyingId = Models.IDField(),
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  driverId = Models.ForeignKey(Driver, pk_field="driverId", on_delete="RESTRICT"),
  constructorId = Models.ForeignKey(Constructor, pk_field="constructorId", on_delete="RESTRICT"),
  number = Models.IntegerField(null=true),
  position = Models.IntegerField(null=true),
  q1 = Models.DurationField(null=true),
  q2 = Models.DurationField(null=true),
  q3 = Models.DurationField(null=true)
)

Sprint_results = Models.Model(
  sprintId = Models.IDField(),
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  driverId = Models.ForeignKey(Driver, pk_field="driverId", on_delete="RESTRICT"),
  constructorId = Models.ForeignKey(Constructor, pk_field="constructorId", on_delete="RESTRICT"),
  number = Models.IntegerField(null=true),
  grid = Models.IntegerField(),
  position = Models.IntegerField(null=true),
  positionText = Models.CharField(),
  positionOrder = Models.IntegerField(),
  points = Models.FloatField(),
  laps = Models.IntegerField(),
  time = Models.CharField(null=true),
  milliseconds = Models.IntegerField(null=true),
  fastestLap = Models.IntegerField(null=true),
  fastestLapTime = Models.DurationField(null=true),
  statusId = Models.ForeignKey(Status, pk_field="statusId", on_delete="CASCADE")
)

Result = Models.Model(
  resultId=Models.IDField(),
  raceId=Models.ForeignKey(Race, pk_field="raceId", on_delete="CASCADE"),
  driverId=Models.ForeignKey(Driver, pk_field="driverId", on_delete="RESTRICT"),
  constructorId=Models.ForeignKey(Constructor, pk_field="constructorId", on_delete="RESTRICT"),
  number=Models.IntegerField(null=true),
  grid=Models.IntegerField(),
  position=Models.IntegerField(null=true),
  positionText=Models.CharField(),
  positionOrder=Models.IntegerField(),
  points=Models.FloatField(),
  laps=Models.IntegerField(),
  time=Models.CharField(null=true),
  milliseconds=Models.IntegerField(null=true),
  fastestLap=Models.IntegerField(null=true),
  rank=Models.IntegerField(null=true),
  fastestLapTime=Models.DurationField(null=true),
  fastestLapSpeed=Models.FloatField(null=true),
  statusId=Models.ForeignKey(Status, pk_field="statusId", on_delete="CASCADE")
)

Just_a_test_deletion = Models.Model(
  id=Models.IDField(),
  name=Models.CharField(),
  test_result=Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE", null=true, related_name="test_deletion"),
  test_result2=Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE", null=true, related_name="test_deletion2"),
  test_result_set_null=Models.ForeignKey(Result, pk_field="resultId", on_delete="SET_NULL", null=true, related_name="test_deletion_set_null"),
  test_result_set_default=Models.ForeignKey(Result, pk_field="resultId", on_delete="SET_DEFAULT", default=1, null=true, related_name="test_deletion_set_default")
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
  payload=Models.JSONField(null=true)
)

# Mirrors the column types Django generates for DateTimeField/DateField/DecimalField.
# Used to validate PormG's wire-format compatibility with Django-managed PostgreSQL schemas
# without requiring Python or Django as a test dependency.
Django_contract_scratch = Models.Model("django_contract_scratch",
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
  nullable_int = Models.IntegerField(null = true)
)

# Scratch models exercising the ManyToManyField API (auto-generated through
# table) against the F1 scenario "drivers endorsed by sponsors".
M2m_sponsor_scratch = Models.Model("m2m_sponsor_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_endorsement_scratch = Models.Model("m2m_driver_endorsement_scratch",
  id = Models.IDField(),
  driverRef = Models.CharField(unique=true),
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
  driverRef = Models.CharField(unique=true),
  sponsors = Models.ManyToManyField(M2m_sponsor_with_country_scratch, related_name="drivers")
)

# Advanced M2M tests: Explicit through model
M2m_team_scratch = Models.Model("m2m_team_scratch",
  id = Models.IDField(),
  name = Models.CharField(unique=true)
)

M2m_driver_explicit_scratch = Models.Model("m2m_driver_explicit_scratch",
  id = Models.IDField(),
  driverRef = Models.CharField(unique=true),
  teams = Models.ManyToManyField(M2m_team_scratch, through="M2m_membership_scratch", related_name="drivers")
)

M2m_membership_scratch = Models.Model("m2m_membership_scratch",
  id = Models.IDField(),
  driver = Models.ForeignKey(M2m_driver_explicit_scratch, on_delete=Models.CASCADE),
  team = Models.ForeignKey(M2m_team_scratch, on_delete=Models.CASCADE),
  joined_year = Models.IntegerField()
)

end
