# Shared helpers for Bulk_update_*_scratch integration tests (bulk_insert + bulk_update).
# Included from runtests.jl at top level; do not wrap in @testset.

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

_bulk_update_scratch_to_date(value) = value isa Date ? value : Date(string(value))
_bulk_update_scratch_to_bool(value) = value isa Bool ? value : Int(value) != 0
_bulk_update_scratch_fk_string(id::Integer) = SubString("id=$(id)", 4)

function _clear_bulk_update_scratch_rows!()
    M.Bulk_update_payload_scratch.objects.delete(allow_delete_all = true)
    M.Bulk_update_optional_parent_scratch.objects.delete(allow_delete_all = true)
    M.Bulk_update_required_parent_scratch.objects.delete(allow_delete_all = true)
    return nothing
end

function _seed_bulk_update_scratch_parents!(required_labels::Vector{String}, optional_labels::Vector{String})
    required_ids = Dict{String, Int64}()
    optional_ids = Dict{String, Int64}()

    for label in required_labels
        row = M.Bulk_update_required_parent_scratch.objects.create("label" => label)
        required_ids[label] = Int64(row[:id])
    end

    for label in optional_labels
        row = M.Bulk_update_optional_parent_scratch.objects.create("label" => label)
        optional_ids[label] = Int64(row[:id])
    end

    return required_ids, optional_ids
end
