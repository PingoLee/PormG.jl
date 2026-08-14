# Fixture app `racing` — the Formula 1 core of a three-app Django project.
#
# Exercises, in one file: a self-referential ForeignKey, a self-referential ManyToManyField, a
# cross-app target spelled Django's way (`access.User`), the `settings.AUTH_USER_MODEL` alias, a
# Meta.db_table that must stay absolute, and a class name (`Driver`) that also exists in `access`.
from django.conf import settings
from django.db import models


class Circuit(models.Model):
    name = models.CharField(max_length=120)
    country = models.CharField(max_length=60)


class Driver(models.Model):
    forename = models.CharField(max_length=60)
    surname = models.CharField(max_length=60)
    # Self-referential FK — Django's `"self"` literal. Emitted verbatim before #346, which made the
    # generated file throw at set_models. `related_name` because `teammates` below points at the same
    # model, and two relations to one target need distinct reverse accessors (Django: fields.E304).
    mentor = models.ForeignKey('self', on_delete=models.SET_NULL, null=True, blank=True,
                               related_name='mentees')
    # Self-referential M2M. Django names the two join columns from_driver_id / to_driver_id, because
    # one table cannot carry the same column twice.
    teammates = models.ManyToManyField('self')


class Race(models.Model):
    circuit = models.ForeignKey(Circuit, on_delete=models.CASCADE)
    # Cross-app, app-qualified — the spelling Django itself uses for a lazy reference.
    steward = models.ForeignKey('access.User', on_delete=models.PROTECT, related_name='races_stewarded')
    # The project's user model by its settings alias.
    reported_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True,
                                    blank=True, related_name='races_reported')
    season = models.IntegerField()

    class Meta:
        db_table = "f1_race_legacy"


class Lap(models.Model):
    # A bare name that BOTH `racing` and `access` define. Django resolves an unqualified reference in
    # the declaring app first, so this must be racing.Driver — never access.Driver.
    driver = models.ForeignKey('Driver', on_delete=models.CASCADE)
    race = models.ForeignKey(Race, on_delete=models.CASCADE)
    position = models.IntegerField()
