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


Base.include(PormG, "db/models/automatic_models.jl")
import PormG.automatic_models as AM

query = AM.Ind_desem_municipio |> object
query.filter("ibge"=>1, "quad_avaliacao__@gte"=>202201, "quad_avaliacao__@lte"=>202201)
query.values("quad_avaliacao", "quad_avaliacao__curto", "porcentagem", "sim", "total", "indicador__abreviado", "indicador")
query.query()
