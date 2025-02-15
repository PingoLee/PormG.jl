module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: result
result = OrderedDict{String, String}(
"Alter field: fastestlapspeed" =>
 """ALTER TABLE "result" ALTER COLUMN "fastestlapspeed" DROP NOT NULL;""",
 
"Alter field: time" =>
 """ALTER TABLE "result" ALTER COLUMN "time" DROP NOT NULL;""",
 
"Alter field: fastestlaptime" =>
 """ALTER TABLE "result" ALTER COLUMN "fastestlaptime" DROP NOT NULL;""",
 
"Alter field: position" =>
 """ALTER TABLE "result" ALTER COLUMN "position" DROP NOT NULL;""",
 
"Alter field: fastestlap" =>
 """ALTER TABLE "result" ALTER COLUMN "fastestlap" DROP NOT NULL;""",
 
"Alter field: milliseconds" =>
 """ALTER TABLE "result" ALTER COLUMN "milliseconds" DROP NOT NULL;""")

end
