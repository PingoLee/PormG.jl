module pending_migrations

import PormG.Migrations
import OrderedCollections: OrderedDict

# table: dim_estabelecimento
dim_estabelecimento = OrderedDict{String, String}(
"Alter field: publico" =>
 """ALTER TABLE "dim_estabelecimento" ALTER COLUMN "publico"  TYPE "publico" boolean NOT NULL DEFAULT FALSE;""",
 
"Alter field: hamigo" =>
 """ALTER TABLE "dim_estabelecimento" ALTER COLUMN "hamigo"  TYPE "hamigo" boolean NOT NULL DEFAULT FALSE;""")

# table: dim_ibge
dim_ibge = OrderedDict{String, String}(
"Alter field: iso" =>
 """ALTER TABLE "dim_ibge" ALTER COLUMN "iso"  TYPE "iso" integer NOT NULL DEFAULT 0;""",
 
"Alter field: cod_es" =>
 """ALTER TABLE "dim_ibge" ALTER COLUMN "cod_es"  TYPE "cod_es" integer NOT NULL DEFAULT 0;""")

# table: dim_municipio
dim_municipio = OrderedDict{String, String}(
"Alter field: at_ativo" =>
 """ALTER TABLE "dim_municipio" ALTER COLUMN "at_ativo"  TYPE "at_ativo" boolean NOT NULL DEFAULT TRUE;""",
 
"Alter field: atualizacao" =>
 """ALTER TABLE "dim_municipio" ALTER COLUMN "atualizacao"  TYPE "atualizacao" date NULL;""",
 
"Remove foreign key: servidor" =>
 """ALTER TABLE "dim_municipio" DROP CONSTRAINT ""dim_municipio_servidor_2noffc7j_fk"";""",
 
"Alter field: servidor" =>
 """ALTER TABLE "dim_municipio" ALTER COLUMN "servidor"  TYPE "servidor" bigint NULL;""",
 
"Alter field: ativo" =>
 """ALTER TABLE "dim_municipio" ALTER COLUMN "ativo"  TYPE "ativo" boolean NOT NULL DEFAULT TRUE;""",
 
"Alter field: ibge2" =>
 """ALTER TABLE "dim_municipio" ALTER COLUMN "ibge2"  TYPE "ibge2" integer NULL DEFAULT 0;""")

# table: dim_municipio_populacao_hist
dim_municipio_populacao_hist = OrderedDict{String, String}(
"Alter field: populacao" =>
 """ALTER TABLE "dim_municipio_populacao_hist" ALTER COLUMN "populacao"  TYPE "populacao" integer NOT NULL DEFAULT 0;""",
 
"Alter field: ano" =>
 """ALTER TABLE "dim_municipio_populacao_hist" ALTER COLUMN "ano"  TYPE "ano" integer NOT NULL DEFAULT 0;""")

end
