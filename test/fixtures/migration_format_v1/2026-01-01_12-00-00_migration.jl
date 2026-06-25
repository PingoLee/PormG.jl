module migration_format_v1_fixture
# pormg-migration-format: 1
#
# FROZEN FIXTURE — do not edit. This is a representative format-version-1 migration file as
# emitted by an early (0.1.0-era) PormG release. `test/unit/test_migration_format_v1.jl` reads it
# to prove a committed v1 migration still parses and that its SQL re-hashes to the same checksum
# under the current engine. The generator names the live module `pending_migrations`; the distinct
# name here only avoids include collisions in the test session — the module name is not part of the
# frozen format contract (the file layout, header, and SQL are).

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: drivers
drivers = OrderedDict{String, String}(
"New model" =>
 """CREATE TABLE drivers (
  "driverid" BIGINT PRIMARY KEY,
  "surname" VARCHAR(255) NOT NULL
);""")

end
