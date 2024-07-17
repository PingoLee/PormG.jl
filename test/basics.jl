
using Pkg
Pkg.activate(".")
using Revise
# include("src/PormG.jl")
using PormG

PormG.Configuration.load()

a = object("tb_fat_visita_domiciliar")
a.values("co_dim_tempo__dt_registro__y_month", "co_seq_fat_visita_domiciliar", "co_fat_cidadao_pec__co_fat_cad_domiciliar",
"co_fat_cidadao_pec__co_dim_tempo_validade", "co_fat_cidadao_pec__co_dim_tempo")
a.filter("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "A", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")

a.filter(Qor("co_seq_fat_visita_domiciliar__isnull" => true, Q("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")))

a.query()

Q("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")


Qor("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "A", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")

Qor("co_dim_tempo__dt_registro__y_month__gte" => "2023-01", "co_dim_tempo__dt_registro__y_month__lte" => "2025-01")


		
filtro = request.POST.get('filtro')
pacE = request.POST.get('pacE')
sicE = request.POST.get('sicE')
selloc = request.POST.get('selloc') # tipo de filtro por tempo
dataE = request.POST.get('dataE')
selalt = request.POST.get("selalt") # classificação da lâmina
modo = request.POST.get("modo")
unid_id = request.user.unidade_id	
    
monitor_list = Tb_cito_map_cad_am.objects.filter(unid__ref_co=unid_id, rem__dt_env__isnull=False).order_by('-rem__ano', '-rem__remessa', 'unid_id', '-ord')

monitor_list = monitor_list.filter(Q(tb_cito_map_proc_am_res__revisao=0) | Q(tb_cito_map_proc_am_res__revisao__isnull=True))

if selloc[-1] == 'd':
  num = selloc.replace('d', '')			
  dt = datetime.date.today() - datetime.timedelta(days=(int(''.join(num))))			
  monitor_list = monitor_list.filter(rem__dt_cr__gte=dt)
elif selloc == 'cr_rem':
  ano = request.POST.get('rem_ano')
  ini = request.POST.get('rem_ini')
  fim = request.POST.get('rem_fim')			
  monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__rem__dt_cr__year=ano)
  if ini != '':
    monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__rem__remessa__gte=ini)
  if fim != '':
    monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__rem__remessa__lte=fim)
elif selloc in ['intervalo']:					
  if not "até" in dataE:
    if dataE == "":
      dataE = '1900-01-01'					
    monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__rem__dt_cr=dataE)
  else:
    dt = dataE.split(' até ')		
    monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__rem__dt_cr__gte=dt[0], tb_cito_map_proc_am_res__rem__dt_cr__lte=dt[1])

if selalt == 'pend':			
  monitor_list = monitor_list.annotate(dif_d=ExtractDay(F('tb_cito_map_proc_am_res__rem__dt_env')-F('rem__dt_rec'))+1)
  monitor_list = monitor_list.filter(Q(dif_d__lt=0)|Q(dif_d__gte=60))

elif selalt == 'atipias':
  monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__atip_st=1)
elif selalt == 'insatis':
  print('foi')
  monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__adeq_st=0, tb_cito_map_proc_am_res__rejec_st=0)
elif selalt == 'rejec':
  monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__rejec_st=True)
elif selalt == 'n_finalizados':
  monitor_list = monitor_list.filter(tb_cito_map_proc_am_res__rem__status_id=4, tb_cito_map_proc_am_res__st_res_id__lt=3)
  
if pacE != "":
  monitor_list = monitor_list.filter(pac__contains=pacE.upper())

if sicE != "":
  monitor_list = monitor_list.filter(siscan__contains=sicE)