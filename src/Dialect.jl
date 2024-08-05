module Dialect
using SQLite
using DataFrames
using LibPQ
import ..PormG: SQLConn, SQLType, SQLInstruction, SQLTypeQ, SQLTypeQor, SQLTypeF, SQLTypeOper, SQLObject, AbstractModel, PormGModel, PormGField

# PostgreSQL
function TO_CHAR(column::String, format::Dict{String, Any}, conn::LibPQ.Connection)
    format_str = format["format"]
    locale = get(format, "locale", "")
    nlsparam = get(format, "nlsparam", "")
    return "to_char($(column), '$(format_str)') $(locale) $(nlsparam)"
end
# SQLite
function TO_CHAR(column::String, format::Dict{String, Any}, conn::SQLite.DB)
    format_str = format["format"]
    locale = get(format, "locale", "")
    return "strftime('$(format_str)', $(column)) $(locale)"
end

function SUM(column::String, conn::Union{LibPQ.Connection,SQLite.DB})
    return "SUM($(column))"
end
function AVG(column::String, conn::Union{LibPQ.Connection,SQLite.DB})
    return "AVG($(column))"
end
function COUNT(column::String, conn::Union{LibPQ.Connection,SQLite.DB})
    return "COUNT($(column))"
end
function MAX(column::String, conn::Union{LibPQ.Connection,SQLite.DB})
    return "MAX($(column))"
end
function MIN(column::String, conn::Union{LibPQ.Connection,SQLite.DB})
    return "MIN($(column))"
end

function WHEN(column::String, value::Any, conn::Union{LibPQ.Connection,SQLite.DB})
    return "WHEN $(column) = $(value)"
end


end