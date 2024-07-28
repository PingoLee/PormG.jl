module Automatic_models
import PormG.Models

b1_proc = Models.Model("b1_proc",
  index = Models.IDField(auto_increment=false, null=true),
  cod = Models.CharField(null=true),
  dn = Models.CharField(),
  dr = Models.CharField(),
  _end = Models.CharField(),
  ibge = Models.CharField(null=true),
  mn = Models.CharField(),
  mnm = Models.CharField(),
  nome = Models.CharField(null=true),
  nome_mae = Models.CharField(),
  pn = Models.CharField(null=true),
  pnm = Models.CharField(),
  sexo = Models.CharField(null=true),
  sn = Models.CharField(),
  sxpn = Models.CharField(null=true),
  sxpnm = Models.CharField(),
  sxsn = Models.CharField(),
  sxun = Models.CharField(null=true),
  sxunm = Models.CharField(),
  un = Models.CharField(null=true),
  unm = Models.CharField())

rel_avan = Models.Model("rel_avan",
  id = Models.IDField(null=true),
  definition = Models.CharField(),
  _function = Models.CharField(),
  nome = Models.CharField(),
  ordem = Models.IntegerField(),
  rel_id = Models.ForeignKey("opc_cruz_rel", pk_field="id"))

banco_subs = Models.Model("banco_subs",
  id = Models.IDField(null=true),
  antigo = Models.CharField(null=true),
  banco_id = Models.ForeignKey("bancos", pk_field="id"),
  novo = Models.CharField(null=true))

freq_n = Models.Model("freq_n",
  campo = Models.CharField(null=true),
  st = Models.IntegerField(null=true))

bancos = Models.Model("bancos",
  id = Models.IDField(null=true),
  abrev = Models.CharField(null=true),
  formato = Models.CharField(),
  _function = Models.CharField(),
  nome = Models.CharField(null=true),
  obs = Models.IntegerField())

b2_proc = Models.Model("b2_proc",
  index = Models.IDField(auto_increment=false, null=true),
  cod = Models.CharField(null=true),
  dn = Models.CharField(),
  dr = Models.CharField(),
  _end = Models.CharField(),
  ibge = Models.CharField(null=true),
  mn = Models.CharField(),
  mnm = Models.CharField(),
  nome = Models.CharField(null=true),
  nome_mae = Models.CharField(),
  pn = Models.CharField(null=true),
  pnm = Models.CharField(),
  sexo = Models.CharField(null=true),
  sn = Models.CharField(),
  sxpn = Models.CharField(null=true),
  sxpnm = Models.CharField(),
  sxsn = Models.CharField(),
  sxun = Models.CharField(null=true),
  sxunm = Models.CharField(),
  un = Models.CharField(null=true),
  unm = Models.CharField())

banco_cols = Models.Model("banco_cols",
  id = Models.IDField(null=true),
  banco_id = Models.ForeignKey("bancos", pk_field="id"),
  col = Models.CharField(),
  _function = Models.CharField(),
  obrig = Models.IntegerField(null=true, default=1),
  ordem = Models.IntegerField())

list_cruz_rv = Models.Model("list_cruz_rv",
  id = Models.IDField(null=true),
  list_id = Models.ForeignKey("list_cruz", null=true, pk_field="id"),
  par_rev = Models.CharField(),
  regra = Models.CharField())

st_cruz = Models.Model("st_cruz",
  id = Models.IDField(null=true),
  b1_n = Models.BinaryField(),
  b2_n = Models.CharField(),
  crz_id = Models.ForeignKey("opc_cruzamento", pk_field="id"),
  importado = Models.IntegerField(default=0),
  linkado = Models.IntegerField(default=0),
  max_rev = Models.IntegerField(default=0),
  modo_rev = Models.FloatField(null=true, default="0"),
  rel_modo = Models.IntegerField(null=true, default=0),
  rel_n = Models.CharField(),
  revisado = Models.FloatField(default="0"),
  selrel = Models.IntegerField())

rel_cols = Models.Model("rel_cols",
  id = Models.IDField(null=true),
  banco_id = Models.ForeignKey("bancos", pk_field="id"),
  cruz_rel_id = Models.IntegerField(),
  ordem = Models.IntegerField(),
  var_org_id = Models.IntegerField(),
  var_rel = Models.CharField())

opc_cruz_rel = Models.Model("opc_cruz_rel",
  id = Models.IDField(null=true),
  nome = Models.CharField(),
  obs = Models.CharField(),
  opc_cruz_id = Models.ForeignKey("opc_cruzamento", pk_field="id"))

defs_linkage = Models.Model("defs_linkage",
  id = Models.IDField(null=true),
  limiar_nome = Models.FloatField(null=true),
  limiar_sms = Models.FloatField(null=true))

opc_cruzamento = Models.Model("opc_cruzamento",
  id = Models.IDField(null=true),
  ativo = Models.IntegerField(null=true, default=0),
  b1_id = Models.ForeignKey("bancos", pk_field="id"),
  b2_id = Models.IntegerField(),
  nome = Models.CharField(null=true),
  obs = Models.CharField())

banco_prep = Models.Model("banco_prep",
  id = Models.IDField(null=true),
  banco_id = Models.ForeignKey("bancos", pk_field="id"),
  definition = Models.CharField(),
  _function = Models.CharField(),
  ordem = Models.IntegerField())

rel_pos = Models.Model("rel_pos",
  id = Models.IDField(null=true),
  definition = Models.CharField(),
  _function = Models.CharField(),
  ordem = Models.IntegerField(),
  rel_id = Models.ForeignKey("opc_cruz_rel", pk_field="id"))

list_cruz = Models.Model("list_cruz",
  id = Models.IDField(auto_increment=false, null=true),
  abrev = Models.CharField(null=true),
  difday = Models.BigIntegerField(null=true),
  distdn = Models.BigIntegerField(null=true),
  dn1 = Models.CharField(),
  dn2 = Models.CharField(),
  dt_flag = Models.CharField(),
  escore = Models.BigIntegerField(null=true),
  escore_prob = Models.FloatField(),
  id1 = Models.BigIntegerField(null=true),
  id2 = Models.BigIntegerField(null=true),
  levn = Models.BigIntegerField(null=true),
  levnm = Models.BigIntegerField(),
  nm_m1 = Models.CharField(),
  nm_m2 = Models.CharField(),
  nome1 = Models.CharField(null=true),
  nome2 = Models.CharField(null=true),
  par_rev = Models.CharField(null=true, default="-"),
  pn = Models.CharField(),
  pnm = Models.CharField(),
  regra = Models.CharField(null=true),
  sexo1 = Models.CharField(),
  sexo2 = Models.CharField(),
  sn = Models.CharField(),
  un = Models.CharField(),
  unm = Models.CharField())

defs_prob = Models.Model("defs_prob",
  id = Models.IDField(null=true),
  desc = Models.CharField(null=true, default="Novo"),
  dnpm = Models.FloatField(null=true),
  dnpu = Models.FloatField(null=true),
  lim_dn = Models.FloatField(null=true),
  lim_m = Models.FloatField(null=true),
  lim_n = Models.FloatField(null=true),
  mpm = Models.FloatField(null=true),
  mpu = Models.FloatField(null=true),
  npm = Models.FloatField(null=true),
  npu = Models.FloatField(null=true))


Models.set_models(@__MODULE__)

end
