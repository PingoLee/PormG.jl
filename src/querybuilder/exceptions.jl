struct DoesNotExist <: Exception
  model_name::String
  filters::String
end

struct MultipleObjectsReturned <: Exception
  model_name::String
  count::Int
  filters::String
end

Base.showerror(io::IO, e::DoesNotExist) =
  print(io, "$(e.model_name).DoesNotExist: No record found matching filters: $(e.filters)")

Base.showerror(io::IO, e::MultipleObjectsReturned) =
  print(io, "$(e.model_name).MultipleObjectsReturned: Expected 1 record, got $(e.count) for filters: $(e.filters)")