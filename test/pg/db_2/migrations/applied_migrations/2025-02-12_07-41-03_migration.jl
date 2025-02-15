module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: result
result = OrderedDict{String, String}(
"Alter field: rank" =>
 """ALTER TABLE "result" ALTER COLUMN "rank" DROP NOT NULL;""")

end
