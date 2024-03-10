
using Pkg
Pkg.activate(".")
using Revise
# include("src/PormG.jl")
using PormG

PormG.Configuration.load()

# a = object("tb_fat_visita_domiciliar")
# a.values("co_dim_tempo__dt_registro__y_month", "co_seq_fat_visita_domiciliar", "co_fat_cidadao_pec__co_fat_cad_domiciliar",
# "co_fat_cidadao_pec__co_dim_tempo_validade", "co_fat_cidadao_pec__co_dim_tempo")
# a.filter("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "A", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")


# a.query()
using BenchmarkTools

@time Q("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")


# Qor("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "A", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")

@time Qor("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")


a = object("tb_fat_visita_domiciliar")
a.values("co_dim_tempo__dt_registro__y_month", "co_seq_fat_visita_domiciliar", "co_fat_cidadao_pec__co_fat_cad_domiciliar")
# a.values(TO_CHAR("co_dim_tempo__dt_registro", "YYYY-MM"), "co_seq_fat_visita_domiciliar", "co_fat_cidadao_pec__co_fat_cad_domiciliar")
a.filter("co_dim_tempo__dt_registro__y_month__gte" => "2023-01")
a.filter(Qor("co_seq_fat_visita_domiciliar__isnull" => true, Q("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")))

function teste()
  a = object("tb_fat_visita_domiciliar")
  a.values("co_dim_tempo__dt_registro__y_month", "co_seq_fat_visita_domiciliar", "co_fat_cidadao_pec__co_fat_cad_domiciliar")
  a.filter(Qor("co_seq_fat_visita_domiciliar__isnull" => true, Q("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")))
  a.query()
end
@time begin
  teste()
end

@time a = object("tb_fat_visita_domiciliar")
@time a.values("co_dim_tempo__dt_registro__y_month", "co_seq_fat_visita_domiciliar", "co_fat_cidadao_pec__co_fat_cad_domiciliar")
@time a.filter(Qor("co_seq_fat_visita_domiciliar__isnull" => true, Q("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")))


@time a.query()

df = PormG.config.columns
column = Symbol("table_name")
filtro = "tb_fat_visita_domiciliar"
@time DataFrames.filter(row -> row[column] == filtro, df)
@time DataFrames.filter(AsTable([column]) => (@. x -> x[column] == filtro), df)
@time subset(df, AsTable([Symbol("table_name")]) => ( @. row -> row.table_name == filtro) )


allowmissing!(df)
