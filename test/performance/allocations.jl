## Dicts
# Scenario: Counting word frequencies in a large text
words_to_process = [
    "apple", "banana", "apple", "orange", "banana", "banana",
    "grape", "kiwi", "apple", "mango", "strawberry", "blueberry",
    "apple", "zebra", "yak", "xylophone", "wombat"
]

# Option A: No sizehint! (default behavior)
println("--- Option A: Without sizehint! ---")
@time begin
    word_counts_A = Dict{String, Int}()
    for word in words_to_process
        word_counts_A[word] = get(word_counts_A, word, 0) + 1
    end
end
println("Unique words (A): ", length(word_counts_A))
println("Capacity (A): ", Base.ht_keyindex(word_counts_A, "dummy")[1]) # Internal capacity check (heuristic)


# Option B: With sizehint! (knowing approximate unique words)
println("\n--- Option B: With sizehint! ---")
# Let's estimate we'll have about 15 unique words
estimated_unique_words = 15
@time begin
    word_counts_B = Dict{String, Int}()
    sizehint!(word_counts_B, estimated_unique_words) # Pre-allocate capacity
    for word in words_to_process
        word_counts_B[word] = get(word_counts_B, word, 0) + 1
    end
end
println("Unique words (B): ", length(word_counts_B))
println("Capacity (B): ", Base.ht_keyindex(word_counts_B, "dummy")[1]) # Internal capacity check (heuristic)