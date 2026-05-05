# How Django Creates Many-to-Many Join Tables: A Step-by-Step Technical Guide

## 1. Field Declaration and Introspection

When you define a model with a `ManyToManyField`, Django does **not** add a column to either of the two related tables. Instead, it registers the relationship in the model's internal `_meta` API.

```python
# models.py
class Author(models.Model):
    name = models.CharField(max_length=100)

class Book(models.Model):
    title = models.CharField(max_length=200)
    authors = models.ManyToManyField(Author, related_name="books")
```

Internally, `Book._meta.get_field('authors')` returns a `ManyToManyField` instance that stores:
- `remote_field.model` → `Author`
- `related_name` → `"books"`
- `m2m_target_field_name()` → `"id"` (the PK on Author)
- `m2m_reverse_target_field_name()` → `"id"` (the PK on Book)

---

## 2. Automatic Through Model Generation

If you do **not** provide an explicit `through` model, Django synthesizes one dynamically at runtime.

### 2.1 The hidden `create_many_to_many_intermediary_model` function

Django calls an internal factory that builds a new model class in memory:

```python
# Conceptual equivalent inside Django
class Book_authors(models.Model):
    id = models.AutoField(primary_key=True)
    book = models.ForeignKey(Book, on_delete=models.CASCADE)
    author = models.ForeignKey(Author, on_delete=models.CASCADE)

    class Meta:
        db_table = "appname_book_authors"   # auto-generated
        unique_together = ("book", "author")
        auto_created = True
```

Key attributes of this auto-generated model:
- `auto_created = True` — hides it from the admin and most introspection tools.
- `db_table` — follows the naming convention: `<app_label>_<model_name>_<field_name>`.
- No default ordering; no custom managers.

---

## 3. Migration Generation (`makemigrations`)

The migration autodetector inspects `ManyToManyField` and emits a `CreateModel` operation for the intermediary table, **not** a `AddField` on either side.

### 3.1 Generated migration file

```python
# migrations/0002_auto.py (conceptual)
from django.db import migrations, models

class Migration(migrations.Migration):
    dependencies = [("library", "0001_initial")]

    operations = [
        migrations.CreateModel(
            name="Book_authors",          # auto-generated class name
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True)),
                (
                    "book",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        to="library.book",
                    ),
                ),
                (
                    "author",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE,
                        to="library.author",
                    ),
                ),
            ],
            options={
                "db_table": "library_book_authors",
                "unique_together": {("book", "author")},
            },
        ),
    ]
```

### 3.2 SQL emitted by `sqlmigrate`

```sql
BEGIN;
--
-- Create model Book_authors
--
CREATE TABLE "library_book_authors" (
    "id" serial NOT NULL PRIMARY KEY,
    "book_id" integer NOT NULL
        REFERENCES "library_book" ("id")
        DEFERRABLE INITIALLY DEFERRED,
    "author_id" integer NOT NULL
        REFERENCES "library_author" ("id")
        DEFERRABLE INITIALLY DEFIALLY DEFERRED,
    CONSTRAINT "library_book_authors_book_id_author_id_uniq"
        UNIQUE ("book_id", "author_id")
);

CREATE INDEX "library_book_authors_book_id_idx"
    ON "library_book_authors" ("book_id");
CREATE INDEX "library_book_authors_author_id_idx"
    ON "library_book_authors" ("author_id");

COMMIT;
```

---

## 4. Explicit `through` Table (Custom Intermediary Model)

If you need extra fields on the relationship, you opt out of the auto-generated table:

```python
class Membership(models.Model):
    person = models.ForeignKey(Person, on_delete=models.CASCADE)
    group = models.ForeignKey(Group, on_delete=models.CASCADE)
    date_joined = models.DateField()
    invite_reason = models.CharField(max_length=64)

class Group(models.Model):
    members = models.ManyToManyField(Person, through="Membership")
```

**Consequences:**
- Django **skips** the automatic table creation.
- The migration autodetector treats `Membership` as a normal model with two `ForeignKey` fields.
- You lose the convenience methods `.add()`, `.remove()`, `.clear()`, `.set()` on the manager unless you implement them yourself.

---

## 5. ORM Query Translation

### 5.1 Forward query: `book.authors.all()`

Django resolves the M2M descriptor (`book.authors`) into a `ManyRelatedManager`. The manager builds a query that joins the hidden table:

```sql
SELECT "library_author"."id",
       "library_author"."name"
FROM   "library_author"
INNER JOIN "library_book_authors"
       ON ("library_author"."id" = "library_book_authors"."author_id")
WHERE  "library_book_authors"."book_id" = 7;
```

### 5.2 Reverse query: `author.books.all()`

Uses the `related_name="books"` to traverse in the opposite direction:

```sql
SELECT "library_book"."id",
       "library_book"."title"
FROM   "library_book"
INNER JOIN "library_book_authors"
       ON ("library_book"."id" = "library_book_authors"."book_id")
WHERE  "library_book_authors"."author_id" = 3;
```

### 5.3 Filter across the relationship

```python
Book.objects.filter(authors__name="Isaac Asimov")
```

SQL generated:

```sql
SELECT "library_book"."id",
       "library_book"."title"
FROM   "library_book"
INNER JOIN "library_book_authors"
       ON ("library_book"."id" = "library_book_authors"."book_id")
INNER JOIN "library_author"
       ON ("library_book_authors"."author_id" = "library_author"."id")
WHERE  "library_author"."name" = 'Isaac Asimov';
```

---

## 6. Write Operations on the Manager

### 6.1 `book.authors.add(author)`

```sql
INSERT INTO "library_book_authors" ("book_id", "author_id")
VALUES (7, 3)
ON CONFLICT DO NOTHING;   -- PostgreSQL; MySQL uses IGNORE, SQLite uses OR IGNORE
```

### 6.2 `book.authors.remove(author)`

```sql
DELETE FROM "library_book_authors"
WHERE "book_id" = 7 AND "author_id" = 3;
```

### 6.3 `book.authors.clear()`

```sql
DELETE FROM "library_book_authors"
WHERE "book_id" = 7;
```

### 6.4 `book.authors.set([a1, a2, a3])`

Django computes the diff:
1. `DELETE` authors not in the new list.
2. `INSERT` authors missing from the old list.
3. Wrapped in a transaction.

---

## 7. Implementation Checklist for PormG.jl

To replicate this behavior in Julia:

| # | Task | Details |
|---|------|---------|
| 1 | **Field type** | Define `ManyToManyField(to_model; through=nothing, related_name=nothing)` |
| 2 | **Meta-model hook** | Store the relationship in the model's metadata so migrations can discover it |
| 3 | **Migration autodetector** | When `through === nothing`, synthesize a `CreateTable` operation for the join table |
| 4 | **Join table schema** | Two `ForeignKeyField` columns + composite `UNIQUE` constraint + optional `id` PK |
| 5 | **Naming convention** | `<app>_<model>_<field>` or let the user override with `db_table` |
| 6 | **Query builder** | Resolve `__` lookups by injecting the join table between source and target |
| 7 | **Manager methods** | Implement `add!`, `remove!`, `clear!`, `set!`, `all` on the descriptor |
| 8 | **Reverse accessor** | Use `related_name` to attach a manager to the target model pointing back |
| 9 | **Explicit through** | Skip auto-generation when `through` is provided; treat it as a regular model |
| 10 | **Bulk helpers** | Optimize `set!` with diff logic and transaction wrapping |

---

## 8. Minimal Julia Pseudocode

```julia
# --- Field definition ---
struct ManyToManyField <: AbstractField
    to::Type{<:Model}
    through::Union{Nothing, Type{<:Model}}
    related_name::Union{Nothing, String}
end

# --- Migration synthesis ---
function make_migrations(model::Model)
    for field in meta(model).fields
        if field isa ManyToManyField && field.through === nothing
            through_name = "$(app)_$(model_name)_$(field_name)"
            create_table(through_name, [
                :id         => IDField(),
                :source_id  => ForeignKeyField(model, on_delete="CASCADE"),
                :target_id  => ForeignKeyField(field.to, on_delete="CASCADE"),
                :unique     => UniqueConstraint(:source_id, :target_id),
            ])
        end
    end
end

# --- Query resolution ---
function build_query(source::Model, filter::Pair{String, Any})
    # "authors__name" => "Asimov"
    parts = split(filter.first, "__")
    # parts = ["authors", "name"]
    # 1. Resolve "authors" → join table + target model
    # 2. Add INNER JOIN join_table ON source.id = join_table.source_id
    # 3. Add INNER JOIN target ON join_table.target_id = target.id
    # 4. Apply WHERE target.name = 'Asimov'
end
```