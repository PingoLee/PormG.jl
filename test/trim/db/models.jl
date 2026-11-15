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
  # No `DateTimeField(auto_now_add = true)` yet: its text is validated through TimeZones.jl's string parser,
  # which a trimmed image cannot run (#1599), so the binary would stop there, before its INSERT.
  updated_on = Models.DateField(auto_now = true),
  token = Models.UUIDField(auto_add = true)
)

Models.@models Circuit Race

end
