module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: result
result = OrderedDict{String, String}(
"Alter field: fastestlaptime" =>
 """ALTER TABLE "result" ALTER COLUMN "fastestlaptime" TYPE time;""")

end
