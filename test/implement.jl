# SELECT 
#     "dash_dim_ibge"."cidade", 
#     CONCAT(
#         ((EXTRACT(YEAR FROM "dash_tab_vig_sinasc"."dt_nasc"))::varchar)::text, 
#         (
#             CONCAT(
#                 (-Q)::text, 
#                 (
#                     CASE 
#                         WHEN EXTRACT(MONTH FROM "dash_tab_vig_sinasc"."dt_nasc") <= 4 THEN 1 
#                         WHEN EXTRACT(MONTH FROM "dash_tab_vig_sinasc"."dt_nasc") <= 8 THEN 2 
#                         WHEN EXTRACT(MONTH FROM "dash_tab_vig_sinasc"."dt_nasc") <= 12 THEN 3 
#                         ELSE NULL 
#                     END
#                 )::text
#             )
#         )::text
#     ) AS "quarter", 
#     COUNT("dash_tab_vig_sinasc"."id") AS "quant" 
# FROM 
#     "dash_tab_vig_sinasc" 
# INNER JOIN 
#     "dash_dim_ibge" 
# ON 
#     ("dash_tab_vig_sinasc"."id_mn_resi_id" = "dash_dim_ibge"."id") 
# WHERE 
#     ("dash_tab_vig_sinasc"."dt_nasc" >= '2014-01-01' AND "dash_tab_vig_sinasc"."id_mn_resi_id" = 172100) 
# GROUP BY 
#     "dash_dim_ibge"."cidade", 
#     2 
# ORDER BY 
#     2 ASC