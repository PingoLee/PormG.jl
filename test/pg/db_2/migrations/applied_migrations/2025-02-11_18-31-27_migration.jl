module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: race
race = OrderedDict{String, String}(
"Alter field: fp2_date" =>
 """ALTER TABLE "race" ALTER COLUMN "fp2_date" DROP NOT NULL;""",
 
"Alter field: sprint_date" =>
 """ALTER TABLE "race" ALTER COLUMN "sprint_date" DROP NOT NULL;""",
 
"Alter field: quali_date" =>
 """ALTER TABLE "race" ALTER COLUMN "quali_date" DROP NOT NULL;""",
 
"Alter field: fp3_time" =>
 """ALTER TABLE "race" ALTER COLUMN "fp3_time" DROP NOT NULL;""",
 
"Alter field: fp1_date" =>
 """ALTER TABLE "race" ALTER COLUMN "fp1_date" DROP NOT NULL;""",
 
"Alter field: fp2_time" =>
 """ALTER TABLE "race" ALTER COLUMN "fp2_time" DROP NOT NULL;""",
 
"Alter field: fp3_date" =>
 """ALTER TABLE "race" ALTER COLUMN "fp3_date" DROP NOT NULL;""",
 
"Alter field: quali_time" =>
 """ALTER TABLE "race" ALTER COLUMN "quali_time" DROP NOT NULL;""",
 
"Alter field: fp1_time" =>
 """ALTER TABLE "race" ALTER COLUMN "fp1_time" DROP NOT NULL;""",
 
"Alter field: sprint_time" =>
 """ALTER TABLE "race" ALTER COLUMN "sprint_time" DROP NOT NULL;""")

end
