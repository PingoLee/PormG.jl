using Pkg
Pkg.activate(".")

using Revise
using PormG
using DataFrames
using Test

cd("test")
cd("pg")

PormG.Configuration.load()

PormG.connection()

# Loc = "/home/pingo02/app/portalsusV2/portal/dash/models.py"

# PormG.Migrations.import_models_from_django(Loc, force_replace=true)

# python example
# Ind_desem_municipio.objects.filter(ibge_id=request.user.municipio_id, quad_avaliacao_id__gte=202201, quad_avaliacao_id__lte=request.session['quad'])
# prod.values('quad_avaliacao_id', 'quad_avaliacao__curto', 'porcentagem', 'sim', 'total', 'indicador__abreviado', 'indicador_id').order_by('indicador_id')		


Base.include(PormG, "db/automatic_models.jl")
import PormG.automatic_models as AM

query = AM.Ind_desem_municipio |> object
query.filter("ibge"=>172100, "quad_avaliacao__@gte"=>202401, "quad_avaliacao__@lte"=>202401)
query.values("quad_avaliacao", "quad_avaliacao__curto", "porcentagem", "sim", "total", "indicador__abreviado", "indicador")
query |> show_query
query |> list |> DataFrame


# Tb_relc_bolsa_familia.objects.filter(ibge_id=request.user.municipio_id).order_by('-vigencia')
# query = AM.Tb_relc_bolsa_familia |> object
# query.filter("ibge"=>172100)
# query.order_by("-vigencia")
# query |> show_query

# SELECT
#   "dash_tb_relc_bolsa_familia"."id",
#   "dash_tb_relc_bolsa_familia"."ibge_id",
#   "dash_tb_relc_bolsa_familia"."vigencia",
#   "dash_tb_relc_bolsa_familia"."data_ini",
#   "dash_tb_relc_bolsa_familia"."data_fim",
#   "dash_tb_relc_bolsa_familia"."ativo",
#   "dash_tb_relc_bolsa_familia"."ds_hash_arquivo"
# FROM
#   "dash_tb_relc_bolsa_familia"
# WHERE
#   "dash_tb_relc_bolsa_familia"."ibge_id" = 172100
# ORDER BY
#   "dash_tb_relc_bolsa_familia"."vigencia" DESC;

# Django query
# relatorio = Tab_vig_hanseniase.objects.filter(modoentr_id=1, muniresat_id=request.user.municipio_id, check_ind=True, ibge_id=request.user.municipio_id)
# relatorio = relatorio.filter(Q(classatual_id=1, dt_diag__year=ano-1, esq_atu_n_id=1) | Q(classatual_id=2, dt_diag__year=ano-2, esq_atu_n_id=2))		
# relatorio = relatorio.values('dt_diag__month', 'ibge__nome')
# relatorio = relatorio.annotate(denominador=Count('dt_diag__month'),
                                  # numerador=Sum(Case(When(tpalta_n_id=1, then=1), default=0, output_field=IntegerField())),
                                  # )\
                                  # .order_by('dt_diag__month')


import PormG.QueryBuilder: Sum, Avg, Case, When, Count, Q, Qor, page

query = AM.Tab_vig_hanseniase |> object
query.filter("modoentr"=>1, "muniresat"=>172100, "check_ind"=>true, "ibge"=>172100)
query.filter(Qor(Q("classatual"=>1, "dt_diag__@year"=>2022, "esq_atu_n"=>1), Q("classatual"=>2, "dt_diag__@year"=>2021, "esq_atu_n"=>2)))
query.values("dt_diag__@month", "ibge__nome", "denominador" => Count("dt_diag"), "numerador" => Sum(Case(When("tpalta_n"=>1, then=1), default=0)))
query.order_by("dt_diag__@month")
query |> show_query
query |> list |> DataFrame

# SELECT 
#     "dash_dim_municipio"."nome", 
#     COUNT(EXTRACT(MONTH FROM "dash_tab_vig_hanseniase"."dt_diag")) AS "denominador", 
#     SUM(CASE WHEN "dash_tab_vig_hanseniase"."tpalta_n_id" = 1 THEN 1 ELSE 0 END) AS "numerador", 
#     EXTRACT(MONTH FROM "dash_tab_vig_hanseniase"."dt_diag") AS "dt_diag__month" 
# FROM 
#     "dash_tab_vig_hanseniase" 
# INNER JOIN 
#     "dash_dim_municipio" 
# ON 
#     ("dash_tab_vig_hanseniase"."ibge_id" = "dash_dim_municipio"."id") 
# WHERE 
#     ("dash_tab_vig_hanseniase"."check_ind" 
#     AND "dash_tab_vig_hanseniase"."ibge_id" = 172100 
#     AND "dash_tab_vig_hanseniase"."modoentr_id" = 1 
#     AND "dash_tab_vig_hanseniase"."muniresat_id" = 172100 
#     AND (("dash_tab_vig_hanseniase"."classatual_id" = 1 
#           AND "dash_tab_vig_hanseniase"."dt_diag" BETWEEN '2023-01-01' AND '2023-12-31' 
#           AND "dash_tab_vig_hanseniase"."esq_atu_n_id" = 1) 
#           OR ("dash_tab_vig_hanseniase"."classatual_id" = 2 
#               AND "dash_tab_vig_hanseniase"."dt_diag" BETWEEN '2022-01-01' AND '2022-12-31' 
#               AND "dash_tab_vig_hanseniase"."esq_atu_n_id" = 2))) 
# GROUP BY 
#     "dash_dim_municipio"."nome", 
#     4 
# ORDER BY 
#     4 ASC;


#
# next attempt
#
# Django query
# monitor_list = Aval_avaliacao_mensal_fim.objects.filter(ibge_id=request.user.municipio_id)
# monitor_list = monitor_list.filter(periodo_id=selmes)
# monitor_list = monitor_list.filter(nu_cnes__lat__isnull=False)
# 			rel = monitor_list.values('nu_cnes__no_cnes_a', 'nu_cnes_id', 'nu_cnes__lat', 'nu_cnes__lng') \
# 							.annotate(media=Avg('resultado'))

# query = AM.Aval_avaliacao_mensal_fim |> object
# query.filter("ibge"=>172100, "periodo"=>202412, "mat_rh__@isnull" => false)
# query.filter("nu_cnes__lat__@isnull" => false)
# query.values("nu_cnes__no_cnes_a", "nu_cnes", "nu_cnes__lat", "nu_cnes__lng", "media" => Avg("resultado"))
# query.order_by("id")
# query |> show_query
# query |> list |> DataFrame

# SELECT 
#     "dash_dim_cnes"."no_cnes_a", 
#     "dash_aval_avaliacao_mensal_fim"."nu_cnes_id", 
#     "dash_dim_cnes"."lat", 
#     "dash_dim_cnes"."lng", 
#     AVG("dash_aval_avaliacao_mensal_fim"."resultado") AS "media" 
# FROM 
#     "dash_aval_avaliacao_mensal_fim" 
# INNER JOIN 
#     "dash_dim_cnes" 
# ON 
#     ("dash_aval_avaliacao_mensal_fim"."nu_cnes_id" = "dash_dim_cnes"."id") 
# WHERE 
#     (
#         "dash_aval_avaliacao_mensal_fim"."ibge_id" = 172100 
#         AND "dash_aval_avaliacao_mensal_fim"."periodo_id" = 202412 
#         AND "dash_aval_avaliacao_mensal_fim"."mat_rh_id" IS NOT NULL 
#         AND "dash_dim_cnes"."lat" IS NOT NULL
#     ) 
# GROUP BY 
#     "dash_dim_cnes"."no_cnes_a", 
#     "dash_dim_cnes"."lat", 
#     "dash_dim_cnes"."lng", 
#     "dash_aval_avaliacao_mensal_fim"."id" 
# ORDER BY 
#     "dash_aval_avaliacao_mensal_fim"."id" ASC;


#
# next attempt query in query
#

query = AM.Bas_cad_ind |> object
query.filter("ibge"=>172100, "saida"=>3, "st_fora_area"=>false)
sub_query = AM.Relc_bolsa_familia |> object
sub_query.values("co_cid__pront")
sub_query.filter("ibge"=>172100, "vigencia"=>202402)
query.filter("pront__@in"=>sub_query)
query.order_by("id")
# query |> show_query
page(query, 10) |> list |> DataFrame
query |> list |> DataFrame



# SELECT 
#     "dash_bas_cad_ind"."id", 
#     "dash_bas_cad_ind"."nu_cpf", 
#     "dash_bas_cad_ind"."nu_cns" 
# FROM 
#     "dash_bas_cad_ind" 
# WHERE 
#     ("dash_bas_cad_ind"."ibge_id" = 172100 
#     AND "dash_bas_cad_ind"."saida_id" = 3 
#     AND NOT "dash_bas_cad_ind"."st_fora_area" 
#     AND "dash_bas_cad_ind"."pront_id" IN (
#         SELECT 
#             U1."pront_id" 
#         FROM 
#             "dash_relc_bolsa_familia" U0 
#         INNER JOIN 
#             "dash_dim_pront_dedup" U1 
#         ON 
#             (U0."co_cid_id" = U1."id") 
#         WHERE 
#             (U1."pront_id" IS NOT NULL 
#             AND U0."ibge_id" = 172100 
#             AND U0."vigencia" = 202402)
#     )
# ) 
# ORDER BY 
#     "dash_bas_cad_ind"."id" ASC 
# LIMIT 10;