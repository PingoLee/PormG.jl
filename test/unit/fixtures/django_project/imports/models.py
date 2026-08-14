# Fixture app `imports` — the ETL side of the project.
#
# Exercises a cross-app FK and M2M, a bare class name that is unique across the whole project, and a
# target in an app that was NOT imported (`django.contrib.contenttypes`), which must degrade to a
# plain column rather than take the file down.
from django.db import models


class ImportBatch(models.Model):
    circuit = models.ForeignKey('racing.Circuit', on_delete=models.CASCADE)
    # `django.contrib` is not part of this import: the column is real, the relation is not expressible.
    created_by = models.ForeignKey('contenttypes.ContentType', on_delete=models.SET_NULL, null=True,
                                   blank=True)
    # Bare name, unique across the project — resolves to access.User.
    steward = models.ForeignKey('User', on_delete=models.PROTECT)
    started_at = models.DateTimeField(auto_now_add=True)
    circuits = models.ManyToManyField('racing.Circuit', related_name='import_batches')
    # Targets the model that the cross-app collision renamed, so Django's join column
    # (`driver_id`, from the CLASS name) stops agreeing with PormG's derivation.
    drivers = models.ManyToManyField('racing.Driver')


class ImportRow(models.Model):
    batch = models.ForeignKey(ImportBatch, on_delete=models.CASCADE)
    payload = models.TextField()
