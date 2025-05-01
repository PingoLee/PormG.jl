module models

import PormG.Models # if you use PormG in your package, you need import ..your_package.PormG.Models

Status = Models.Model(
  statusId = Models.IDField(),
  status = Models.CharField()
)

Circuit = Models.Model( # You can create a model like a Django model for each table so that you can define a huge number of tables at once in just one file. Please capitalize the names of models.
  circuitId = Models.IDField(), # the PormG automatically do a lowercase for the name of the field, so you can use a capital letter in the name of the field, Hoewver you need to use a lowercase in the query operations.
  circuitRef = Models.CharField(),
  name = Models.CharField(),
  location = Models.CharField(),
  country = Models.CharField(),
  lat = Models.FloatField(),
  lng = Models.FloatField(),
  alt = Models.IntegerField(),
  url = Models.CharField()
)

Race = Models.Model(
  raceId = Models.IDField(),
  year = Models.IntegerField(),
  round = Models.IntegerField(),
  circuitId = Models.ForeignKey(Circuit, pk_field="circuitId", on_delete="CASCADE"),
  name = Models.CharField(),
  date = Models.DateField(),
  time = Models.TimeField(null=true),
  url = Models.CharField(),
  fp1_date = Models.DateField(null=true),
  fp1_time = Models.TimeField(null=true),
  fp2_date = Models.DateField(null=true),
  fp2_time = Models.TimeField(null=true),
  fp3_date = Models.DateField(null=true),
  fp3_time = Models.TimeField(null=true),
  quali_date = Models.DateField(null=true),
  quali_time = Models.TimeField(null=true),
  sprint_date = Models.DateField(null=true),
  sprint_time = Models.TimeField(null=true),
)

Driver = Models.Model(
  driverId = Models.IDField(),
  driverRef = Models.CharField(),
  number = Models.IntegerField(null=true),
  code = Models.CharField(),
  forename = Models.CharField(),
  surname = Models.CharField(),
  dob = Models.DateField(),
  nationality = Models.CharField(),
  url = Models.CharField()
)

Constructor = Models.Model(
  constructorId = Models.IDField(),
  constructorRef = Models.CharField(),
  name = Models.CharField(),
  nationality = Models.CharField(),
  url = Models.CharField()
)

Result = Models.Model(
  resultId = Models.IDField(),
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="RESTRICT"),
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
  rank = Models.IntegerField(null=true),
  fastestLapTime = Models.TimeField(null=true),
  fastestLapSpeed = Models.FloatField(null=true),
  statusId = Models.ForeignKey(Status, pk_field="statusId", on_delete="CASCADE")
)

Just_a_test_deletion = Models.Model(
  id = Models.IDField(),
  name = Models.CharField(),
  test_result = Models.ForeignKey(Result, pk_field="resultId", on_delete="CASCADE")
)

Models.set_models(@__MODULE__, @__DIR__) # That is important to set the models in the module, otherwise it will not work, that need stay at the end of the file

end
