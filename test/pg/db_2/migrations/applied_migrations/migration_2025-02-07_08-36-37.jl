module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: dim_teste_timezone
dim_teste_timezone = OrderedDict{String, String}(
"Rename field: update" =>
 """ALTER TABLE "dim_teste_timezone" RENAME COLUMN "data2" TO "update";""",
 
"Add field: create" =>
 """ALTER TABLE "dim_teste_timezone" ADD COLUMN "create" timestamptz NOT NULL DEFAULT '2025-02-07T08:22:50.666-03:00';""",
 
"Alter field: create" =>
 """ALTER TABLE "dim_teste_timezone" ALTER COLUMN "create" DROP DEFAULT;""")

end
