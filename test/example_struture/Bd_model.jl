module Bd_model

import PormG: Models

# I name this as model
users = Models.Model("users", 
  name = Models.CharField(), 
  email = Models.CharField(), 
  age = Models.IntegerField()
)

cars = Models.Model("cars", 
  user = Models.ForeignKey(users, "CASCADE"),
  name = Models.CharField(), 
  brand = Models.CharField(), 
  year = Models.IntegerField()
)

end