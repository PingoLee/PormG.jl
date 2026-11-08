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
  date = Models.DateField()
)

Models.@models Circuit Race

end
