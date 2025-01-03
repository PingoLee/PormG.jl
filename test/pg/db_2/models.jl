module automatic_models

import PormG.Models
Dim_uf = Models.Model("Dim_uf",
  id = Models.IDField(),
  nome = Models.CharField(max_length=50),
  sigla = Models.CharField(max_length=2))

Dim_ibge = Models.Model("Dim_ibge",
  id = Models.IDField(),
  cidade = Models.CharField(),
  cod_es = Models.IntegerField(default=0),
  estado = Models.CharField(max_length=50),
  iso = Models.IntegerField(default=0),
  lat = Models.DecimalField(max_digits=30, decimal_places=6),
  lng = Models.DecimalField(max_digits=30, decimal_places=6),
  regiao = Models.CharField(max_length=30),
  regional = Models.CharField(max_length=30, blank=true, null=true),
  uf = Models.CharField(max_length=2))

Dim_estabelecimento = Models.Model("Dim_estabelecimento",
  id = Models.IDField(),
  cnes = Models.CharField(),
  hamigo = Models.BooleanField(default=false),
  nome = Models.CharField(),
  publico = Models.BooleanField(default=false))

Models.set_models(@__MODULE__, @__DIR__)

end
