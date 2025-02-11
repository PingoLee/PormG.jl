module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: race
race = OrderedDict{String, String}(
"Alter field: time" =>
 """ALTER TABLE "race" ALTER COLUMN "time" DROP NOT NULL;""")

end
