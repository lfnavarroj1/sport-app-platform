# Traspaso de Deployments y Jobs de migración a Cloud Deploy.
#
# Versiones anteriores de esta raíz los aplicaban (kustomization_resource
# "workloads", kubernetes_manifest "migration"). Con un estado que todavía los
# contiene, estos bloques solo los quitan del estado: los objetos siguen
# corriendo en el clúster y el primer rollout de Cloud Deploy los adopta.
# Con un estado nuevo no tienen efecto. No se usa `terraform state rm`.

removed {
  from = kustomization_resource.workloads

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_manifest.migration

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.migration_revision

  lifecycle {
    destroy = false
  }
}

# La configuración y los Services se aplicaban juntos en kustomization_resource
# "config". Los Services conservan su estado en "services"; el ConfigMap con
# sufijo de hash queda fuera del for_each y el plan propone borrarlo: revíselo
# (docs/migracion-retiro-wif-github.md, sección de cargas) y aplique después del
# primer rollout de Cloud Deploy, que usa sportapp-runtime con nombre fijo.
moved {
  from = kustomization_resource.config
  to   = kustomization_resource.services
}
