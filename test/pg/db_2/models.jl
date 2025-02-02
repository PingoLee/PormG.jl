module models

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

Dim_servidor = Models.Model("Dim_servidor",
  id = Models.IDField(),
  host = Models.CharField(),
  nome = Models.CharField(),
  password = Models.CharField(),
  port = Models.CharField(),
  user = Models.CharField())

Dim_tipologia = Models.Model("Dim_tipologia",
  id = Models.IDField(),
  abrev = Models.CharField(max_length=50),
  nome = Models.CharField(max_length=50))

Dim_INE_cat = Models.Model("Dim_INE_cat",
  id = Models.IDField(),
  nome = Models.CharField(),
  tipo = Models.CharField(max_length=50))

Dim_municipio = Models.Model("Dim_municipio",
  id = Models.IDField(),
  at_ativo = Models.BooleanField(default=true),
  ativo = Models.BooleanField(default=true),
  atualizacao = Models.DateField(blank=true, null=true),
  base = Models.CharField(blank=true, null=true),
  cibge = Models.BigIntegerField(null=true),
  dbname = Models.CharField(blank=true, null=true),
  estado = Models.CharField(blank=true, null=true),
  ibge2 = Models.IntegerField(blank=true, null=true, default=0),
  nome = Models.CharField(blank=true, null=true),
  origem = Models.CharField(blank=true, null=true),
  servidor = Models.ForeignKey("Dim_servidor", null=true, pk_field="id", on_delete="models.RESTRICT"))

Dim_municipio_populacao_hist = Models.Model("Dim_municipio_populacao_hist",
  id = Models.IDField(),
  ano = Models.IntegerField(default=0),
  dcnt = Models.IntegerField(null=true),
  ibge = Models.ForeignKey("Dim_municipio", pk_field="id", on_delete="models.CASCADE"),
  pop_15 = Models.IntegerField(null=true),
  populacao = Models.IntegerField(default=0))

Dim_teste_timezone = Models.Model("Dim_teste_timezone",
  id = Models.IDField(),
  texto = Models.CharField(),
  data2 = Models.DateTimeField(auto_now=true))

Models.set_models(@__MODULE__, @__DIR__)

end
