module models

import PormG.Models

Status = Models.Model(
  statusId = Models.IDField(),
  status = Models.CharField()
)

Circuit = Models.Model(
  circuitId = Models.IDField(),
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
  circuitId = Models.ForeignKey(Circuit, pk_field="circuitId", on_delete="models.RESTRICT"),
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
  number = Models.IntegerField(),
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
  raceId = Models.ForeignKey(Race, pk_field="raceId", on_delete="models.RESTRICT"),
  driverId = Models.ForeignKey(Driver, pk_field="driverId", on_delete="models.RESTRICT"),
  constructorId = Models.ForeignKey(Constructor, pk_field="constructorId", on_delete="models.RESTRICT"),
  number = Models.IntegerField(),
  grid = Models.IntegerField(),
  position = Models.IntegerField(),
  positionText = Models.CharField(),
  positionOrder = Models.IntegerField(),
  points = Models.FloatField(),
  laps = Models.IntegerField(),
  time = Models.CharField(),
  milliseconds = Models.IntegerField(),
  fastestLap = Models.IntegerField(),
  rank = Models.IntegerField(),
  fastestLapTime = Models.CharField(),
  fastestLapSpeed = Models.FloatField(),
  statusId = Models.ForeignKey(Status, pk_field="statusId", on_delete="models.RESTRICT")
)

Models.set_models(@__MODULE__, @__DIR__)

end
