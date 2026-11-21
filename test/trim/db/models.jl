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
  token = Models.UUIDField(auto_add = true)
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

Models.@models Circuit Race PitStop Driver

end
