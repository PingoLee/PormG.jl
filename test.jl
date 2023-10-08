
using Pkg
Pkg.activate(".")
using Revise
# include("src/PormG.jl")
using PormG

PormG.Configuration.load()

a = object("tb_fat_visita_domiciliar")
a.values("co_dim_tempo__dt_registro__y_month", "co_seq_fat_visita_domiciliar", "co_fat_cidadao_pec__co_fat_cad_domiciliar",
"co_fat_cidadao_pec__co_dim_tempo_validade", "co_fat_cidadao_pec__co_dim_tempo")
a.filter("co_dim_tempo__dt_registro__y_month__gte" => "2023-01")

a.query()

include("src/QueryBuilder.jl")
