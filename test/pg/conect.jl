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

# # test importation
# schemas = PormG.Migrations.get_database_schema()
# teste = PormG.Migrations.import_models_from_sql()

# teste2 = PormG.Migrations.convertSQLToModel(teste)

Loc = "/home/pingo02/app/portalsusV2/portal/dash/models.py"
# PormG.Migrations.import_models_from_django(Loc)

model_py_string = read(Loc, String)
# replace ' by " from Django
model_py_string = replace(model_py_string, "'" => "\"")
# model_regex = r"class\s+(\w+)\(models\.Model\):\n((?:\s*#[^\n]*\n|\s*[^\n]+\n)*?)(?=(\n+)?class\s|\Z)" 
# field_regex = r"\s*(\w+)\s*=\s*models\.(\w+)\(([^)]*)\)"
  

# te = eachmatch(model_regex, model_py_string)

model_py_string = "\nclass Dim_uf(models.Model):\n    nome = models.CharField(max_length=50)\n    sigla = models.CharField(max_length=2)\n\nclass Dim_ibge(models.Model):\n    cidade = models.CharField(max_length=250)\n    estado = models.CharField(max_length=50)\n    uf = models.CharField(max_length=2)\n    regiao = models.CharField(max_length=30)\n    regional = models.CharField(max_length=30, null=True, blank=True)\n    iso = models.IntegerField(default=0)\n    lat = models.DecimalField(max_digits=30,decimal_places=6)\n    lng = models.DecimalField(max_digits=30,decimal_places=6)\n    cod_es = models.IntegerField(default=0)\n\nclass Dim_estabelecimento(models.Model):\n    nome = models.CharField(max_length=250)\n    cnes = models.CharField(max_length=250)\n    hamigo = models.BooleanField(default=False)\n    publico = models.BooleanField(default=False)\n\n\nclass Dim_servidor(models.Model):\n    nome = models.CharField(max_length=250)\n    host = models.CharField(max_length=250)\n    port = models.CharField(max_length=250)\n    user = models.CharField(max_length=250)\n    password = models.CharField(max_length=250)\n\nclass Dim_tipologia(models.Model):\n    nome = models.CharField(max_length=50)\n    abrev = models.CharField(max_length=50)\n\nclass Dim_INE_cat(models.Model):\n    nome = models.CharField(max_length=250) # descrição da equipe segundo o ministério\n    tipo = models.CharField(max_length=50) # define o que vai ser computado\n\n"

PormG.Migrations.import_models_from_django(model_py_string, force_replace=true)
first_match = nothing  # Initialize to store the first match

i = 1
for match in eachmatch(model_regex, model_py_string, overlap = true)
    first_match = match  # Store the current matc
    i == 2 && break                # Exit the loop after the first match

    i += 1
end

class_content = first_match.captures[2]  # Extract the class content


fisrt_class_match = nothing

i = 1
for match in eachmatch(field_regex, class_content)
  fisrt_class_match = match  
  i == 2 && break
  i += 1
end


field_name = fisrt_class_match.captures[1]
field_type = fisrt_class_match.captures[2]
field_options = fisrt_class_match.captures[3]      

options = Dict{Symbol, Any}()
capture::Bool = true
for option in split(field_options, ",")
  key_value = split(option, "=")
  if length(key_value) == 2
    key = strip(key_value[1])
    value = strip(key_value[2])
    # Check if value is a True or False and convert to Bool
    value == "True" && (value = true)
    value == "False" && (value = false)
    # primary key are not suported yeat
    if key == "primary_key"
      @warn("Primary key is not supported yet, the field $field_name will be ignored in model $class_name")
      capture = false
    end
    options[key |> Symbol] = value
  end
end

getfield(PormG.Models, field_type |> Symbol )(; options...)


  # Iterate over the fields in the class content
  fields_dict = Dict{Symbol, Any}()
  for match in eachmatch(field_regex, class_content)
    field_name = match.captures[1]
    field_type = match.captures[2]
    field_options = match.captures[3]      

    
                
    # Parse field options
    options = Dict{Symbol, Any}()
    capture::Bool = true
    for option in split(field_options, ",")
      key_value = split(option, "=")
      if length(key_value) == 2
        key = strip(key_value[1])
        value = strip(key_value[2])
        value == "True" && (value = true)
        value == "False" && (value = false)
        # primary key are not suported yeat
        if key == "primary_key"
          @warn("Primary key is not supported yet, the field $field_name will be ignored in model $class_name")
          capture = false
        end
        options[key |> Symbol] = value
      end
    end
    # Check if the field is a primary key

    # # Generate the field instance
    if capture
      fields_dict[Symbol(field_name)] = getfield(PormG.Models, field_type |> Symbol )(; options...)
    end
  end