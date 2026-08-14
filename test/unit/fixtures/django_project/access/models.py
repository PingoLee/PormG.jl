# Fixture app `access` — the project's auth app.
#
# `User` is the single AbstractUser subclass, so `settings.AUTH_USER_MODEL` in `racing` resolves to
# it without an `auth_user_model` keyword. `Driver` collides with `racing.Driver` on purpose: both
# must come out app-qualified, not one of them silently suffixed.
from django.contrib.auth.models import AbstractUser
from django.db import models


class User(AbstractUser):
    matricula = models.CharField(max_length=20, unique=True)


class Driver(models.Model):
    # Same class name as racing.Driver. A licence record, not a competitor.
    badge = models.CharField(max_length=20)
    holder = models.ForeignKey(User, on_delete=models.CASCADE)
