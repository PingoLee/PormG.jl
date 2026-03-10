module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: new_join_position
new_join_position = OrderedDict{String, String}(
"Add field: result" =>
 """ALTER TABLE "new_join_position" ADD COLUMN "result" integer NULL;""")

end
