module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: result
result = OrderedDict{String, String}(
"Alter field: number" =>
 """ALTER TABLE "result" ALTER COLUMN "number" DROP NOT NULL;""")

end
