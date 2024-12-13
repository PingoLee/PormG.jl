module Dialect
using SQLite
using DataFrames
using LibPQ
import ..PormG: SQLConn, SQLType, SQLInstruction, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeOper, SQLObject, AbstractModel, PormGModel, PormGField, sqlite_date_format_map, sqlite_type_map_reverse

# PostgreSQL
function EXTRACT_DATE(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
  format_str = format["format"]
  locale = get(format, "locale", "")
  nlsparam = get(format, "nlsparam", "")
  return "to_char($(column), '$(format_str)') $(locale) $(nlsparam)"
end
# SQLite
function EXTRACT_DATE(column::String, format::Dict{String, Any}, conn::SQLite.DB)
  format_str = format["format"]
  locale = get(format, "locale", "")
  return "strftime('$(sqlite_date_format_map[format_str])', $(column)) $(locale)"
end

function SUM(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "SUM($(column))"
end
function AVG(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "AVG($(column))"
end
function COUNT(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "COUNT($(column))"
end
function MAX(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "MAX($(column))"
end
function MIN(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "MIN($(column))"
end

# Same that function CAST in django ORM
# # relatorio = relatorio.annotate(quarter=functions.Concat(functions.Cast(f'{data}__year', CharField()), Value('-Q'), Case(
# # 					When(**{ f'{data}__month__lte': 4 }, then=Value('1')),
# # 					When(**{ f'{data}__month__lte': 8 }, then=Value('2')),
# # 					When(**{ f'{data}__month__lte': 12 }, then=Value('3')),
# # 					output_field=CharField()
# # 				)))
function VALUE(value::String, conn::LibPQ.Connection)
  return "('$(value)')::text"
end
function VALUE(value::String, conn::SQLite.DB)
  return "'$(value)'"
end
function CAST(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
  return """($column)::$(format["type"])"""
end
function CAST(column::String, format::Dict{String, Any}, conn::SQLite.DB)
  return "CAST($column AS $(sqlite_type_map_reverse[format["type"]]))"
end
function CONCAT(column::Array{Any, 1}, format::Dict{String, Any}, conn::LibPQ.Connection)
  return "CONCAT($(join(column, ",\n")))"
end
function CONCAT(column::Array{Any, 1}, format::Dict{String, Any}, conn::SQLite.DB)
  return "($(join(column, " ||\n")))"
end
function EXTRACT(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
  return "EXTRACT($(format["part"]) FROM $(column))$(format["format"])"  
end
function CASE(column::Vector{Any}, format::Dict{String, Any}, conn::LibPQ.Connection)
  if format["output_field"] != ""
    return """(CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END)::$(format["output_field"])
    """
  else 
    return """CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END
    """
  end
end
function CASE(column::Vector{Any}, format::Dict{String, Any}, conn::SQLite.DB)
  resp::String = """CASE
    $(join(column, "\n"))
    ELSE $(format["else"])
    END
    """
  if format["output_field"] != ""
    return CAST(resp, Dict{String, Any}("type" => format["output_field"]), conn)    
  else 
    return resp
  end
end
function WHEN(column::String, format::Dict{String, Any}, conn::Union{LibPQ.Connection,SQLite.DB})
  return "WHEN $(column) THEN $(format["then"])" |> string
end


# how generete the quarter
# SELECT 
#   "dash_dim_ibge"."cidade", 
#   CONCAT(
#     ((EXTRACT(YEAR FROM "dash_tab_vig_sinasc"."dt_nasc"))::varchar)::text, 
#     (
#       CONCAT(
#         (-Q)::text, 
#         (
#           CASE 
#             WHEN EXTRACT(MONTH FROM "dash_tab_vig_sinasc"."dt_nasc") <= 4 THEN 1 
#             WHEN EXTRACT(MONTH FROM "dash_tab_vig_sinasc"."dt_nasc") <= 8 THEN 2 
#             WHEN EXTRACT(MONTH FROM "dash_tab_vig_sinasc"."dt_nasc") <= 12 THEN 3 
#             ELSE NULL 
#           END
#         )::text
#       )
#     )::text
#   ) AS "quarter", 
#   COUNT("dash_tab_vig_sinasc"."id") AS "quant" 
# FROM 
#   "dash_tab_vig_sinasc" 
# INNER JOIN 
#   "dash_dim_ibge" 
# ON 
#   ("dash_tab_vig_sinasc"."id_mn_resi_id" = "dash_dim_ibge"."id") 
# WHERE 
#   ("dash_tab_vig_sinasc"."dt_nasc" >= '2014-01-01' AND "dash_tab_vig_sinasc"."id_mn_resi_id" = 172100) 
# GROUP BY 
#   "dash_dim_ibge"."cidade", 
#   2 
# ORDER BY 
#   2 ASC

# SQLITE version
# SELECT 
#   dash_dim_ibge.cidade, 
#   (strftime('%Y', dash_tab_vig_sinasc.dt_nasc) || '-Q' || 
#     CASE 
#       WHEN strftime('%m', dash_tab_vig_sinasc.dt_nasc) <= '04' THEN '1' 
#       WHEN strftime('%m', dash_tab_vig_sinasc.dt_nasc) <= '08' THEN '2' 
#       WHEN strftime('%m', dash_tab_vig_sinasc.dt_nasc) <= '12' THEN '3' 
#       ELSE NULL 
#     END
#   ) AS quarter, 
#   COUNT(dash_tab_vig_sinasc.id) AS quant 
# FROM 
#   dash_tab_vig_sinasc 
# INNER JOIN 
#   dash_dim_ibge 
# ON 
#   dash_tab_vig_sinasc.id_mn_resi_id = dash_dim_ibge.id 
# WHERE 
#   dash_tab_vig_sinasc.dt_nasc >= '2014-01-01' 
#   AND dash_tab_vig_sinasc.id_mn_resi_id = 172100 
# GROUP BY 
#   dash_dim_ibge.cidade, 
#   quarter 
# ORDER BY 
#   quarter ASC;

# PormG instructions
# PormG.QueryBuilder.FObject(
#   "CONCAT", 
#   PormG.SQLType[
#     PormG.QueryBuilder.FObject(
#       "CAST", 
#       PormG.QueryBuilder.FObject(
#         "TO_CHAR", 
#         ["dn1"], 
#         false, 
#         nothing, 
#         Dict{String, Any}("format" => "YYYY")
#       ), 
#       false, 
#       nothing, 
#       Dict{String, Any}("type" => "VARCHAR")
#     ), 
#     PormG.QueryBuilder.SQLText("-Q", nothing), 
#     PormG.QueryBuilder.FObject(
#       "CASE", 
#       PormG.QueryBuilder.FObject[
#         PormG.QueryBuilder.FObject(
#           "WHEN", 
#           PormG.QueryBuilder.OperObject(
#             "<=", 
#             4, 
#             PormG.QueryBuilder.FObject(
#               "TO_CHAR", 
#               ["dn1"], 
#               false, 
#               nothing, 
#               Dict{String, Any}("format" => "MM")
#             )
#           ), 
#           false, 
#           nothing, 
#           Dict{String, Any}("else" => missing, "then" => 1)
#         ), 
#         PormG.QueryBuilder.FObject(
#           "WHEN", 
#           PormG.QueryBuilder.OperObject(
#             "<=", 
#             8, 
#             PormG.QueryBuilder.FObject(
#               "TO_CHAR", 
#               ["dn1"], 
#               false, 
#               nothing, 
#               Dict{String, Any}("format" => "MM")
#             )
#           ), 
#           false, 
#           nothing, 
#           Dict{String, Any}("else" => missing, "then" => 2)
#         ), 
#         PormG.QueryBuilder.FObject(
#           "WHEN", 
#           PormG.QueryBuilder.OperObject(
#             "<=", 
#             12, 
#             PormG.QueryBuilder.FObject(
#               "TO_CHAR", 
#               ["dn1"], 
#               false, 
#               nothing, 
#               Dict{String, Any}("format" => "MM")
#             )
#           ), 
#           false, 
#           nothing, 
#           Dict{String, Any}("else" => missing, "then" => 3)
#         )
#       ], 
#       false, 
#       nothing, 
#       Dict{String, Any}("else" => "NULL", "output_field" => "VARCHAR")
#     )
#   ], 
#   false, 
#   "dn1__quarter", 
#   Dict{String, Any}("as" => "[\"dn1\"]__quarter", "output_field" => "VARCHAR")
# )

end