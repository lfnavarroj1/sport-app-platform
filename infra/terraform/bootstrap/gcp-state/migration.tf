# Retiro del diseño con Workload Identity Federation para GitHub
# (docs/migracion-retiro-wif-github.md).
#
# Al aplicar con un estado que todavía contiene el diseño anterior, el plan:
# - destruye el pool y el provider OIDC de GitHub y las cuentas ci-delivery-*;
# - olvida (sin llamar a la API) los bindings de cuenta anteriores: las
#   políticas autoritativas de main.tf reemplazan la política IAM completa de
#   tf-plan, tf-apply y las identidades de entrega, de modo que los bindings de
#   GitHub desaparecen sin una carrera con el binding de los operadores.
# Con un estado nuevo estos bloques no tienen efecto.

removed {
  from = google_service_account_iam_member.plan_github

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_service_account_iam_member.apply_github

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_service_account_iam_member.delivery_github

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_service_account_iam_member.operators_plan

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_service_account_iam_member.operators_apply

  lifecycle {
    destroy = false
  }
}
