module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: driver
driver = OrderedDict{String, String}(
"Alter field: number" =>
 """ALTER TABLE "driver" ALTER COLUMN "number" DROP NOT NULL;""")

end
