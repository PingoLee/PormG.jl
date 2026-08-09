module automatic_models

import PormG.Models
import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING

Just_a_test_deletion = Models.Model("just_a_test_deletion",
  id = Models.IDField(),
  name = Models.CharField(),
  test_result = Models.ForeignKey("result", null=true, pk_field="resultid"),
  test_result2 = Models.ForeignKey("result", null=true, pk_field="resultid"))

Models.set_models(@__MODULE__, @__DIR__)

end
