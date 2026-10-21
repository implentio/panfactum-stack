/***************************************
* Snapshot Leak Metrics
*
* The shared kube-state-metrics does not export VolumeSnapshots, VolumeSnapshotContents,
* or Velero Backups, so a failing snapshot GC left no signal for four months. This
* dedicated KSM instance exports those objects so leaks are visible from object state.
***************************************/

locals {
  snapshot_metrics_name = "velero-snapshot-metrics"
  snapshot_metrics_port = 8080

  snapshot_metrics_config = {
    kind = "CustomResourceStateMetrics"
    spec = {
      resources = [
        {
          groupVersionKind = { group = "snapshot.storage.k8s.io", version = "v1", kind = "VolumeSnapshot" }
          metrics = [{
            name = "velero_volumesnapshot_info"
            help = "VolumeSnapshot and the Velero Backup that created it."
            each = {
              type = "Info"
              info = {
                labelsFromPath = {
                  namespace    = ["metadata", "namespace"]
                  name         = ["metadata", "name"]
                  backup_name  = ["metadata", "labels", "velero.io/backup-name"]
                  content_name = ["status", "boundVolumeSnapshotContentName"]
                }
              }
            }
          }]
        },
        {
          groupVersionKind = { group = "snapshot.storage.k8s.io", version = "v1", kind = "VolumeSnapshotContent" }
          metrics = [
            {
              name = "velero_volumesnapshotcontent_info"
              help = "VolumeSnapshotContent and the VolumeSnapshot it is bound to."
              each = {
                type = "Info"
                info = {
                  labelsFromPath = {
                    name            = ["metadata", "name"]
                    backup_name     = ["metadata", "labels", "velero.io/backup-name"]
                    deletion_policy = ["spec", "deletionPolicy"]
                    snapshot_class  = ["spec", "volumeSnapshotClassName"]
                    vs_namespace    = ["spec", "volumeSnapshotRef", "namespace"]
                    vs_name         = ["spec", "volumeSnapshotRef", "name"]
                    snapshot_handle = ["status", "snapshotHandle"]
                  }
                }
              }
            }
          ]
        },
        {
          groupVersionKind = { group = "velero.io", version = "v1", kind = "Backup" }
          metrics = [{
            name = "velero_backup_info"
            help = "Velero Backup and its phase."
            each = {
              type = "Info"
              info = {
                labelsFromPath = {
                  backup_name = ["metadata", "name"]
                  phase       = ["status", "phase"]
                }
              }
            }
          }]
        }
      ]
    }
  }
}

resource "kubernetes_config_map" "snapshot_metrics" {
  count = var.monitoring_enabled ? 1 : 0
  metadata {
    name      = local.snapshot_metrics_name
    namespace = local.namespace
    labels    = module.util.labels
  }
  data = {
    "config.yaml" = yamlencode(local.snapshot_metrics_config)
  }
}

resource "kubernetes_cluster_role" "snapshot_metrics" {
  count = var.monitoring_enabled ? 1 : 0
  metadata {
    name   = local.snapshot_metrics_name
    labels = module.snapshot_metrics[0].labels
  }
  rule {
    api_groups = ["snapshot.storage.k8s.io"]
    resources  = ["volumesnapshots", "volumesnapshotcontents"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["velero.io"]
    resources  = ["backups"]
    verbs      = ["list", "watch"]
  }
  # KSM discovers custom resource kinds through their CRDs before it watches them.
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "snapshot_metrics" {
  count = var.monitoring_enabled ? 1 : 0
  metadata {
    name   = local.snapshot_metrics_name
    labels = module.snapshot_metrics[0].labels
  }
  subject {
    kind      = "ServiceAccount"
    name      = module.snapshot_metrics[0].service_account_name
    namespace = local.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.snapshot_metrics[0].metadata[0].name
  }
}

module "snapshot_metrics" {
  count  = var.monitoring_enabled ? 1 : 0
  source = "../kube_deployment"

  namespace = local.namespace
  name      = local.snapshot_metrics_name
  replicas  = 1

  panfactum_scheduler_enabled          = var.panfactum_scheduler_enabled
  pull_through_cache_enabled           = var.pull_through_cache_enabled
  vpa_enabled                          = var.vpa_enabled
  spot_nodes_enabled                   = true
  burstable_nodes_enabled              = true
  arm_nodes_enabled                    = true
  instance_type_anti_affinity_required = false
  az_anti_affinity_required            = false
  extra_labels                         = data.pf_kube_labels.labels.labels
  # Rolls the pod on config changes; KSM reads the config file only at startup.
  extra_pod_labels = { configHash = md5(yamlencode(local.snapshot_metrics_config)) }

  config_map_mounts = {
    (local.snapshot_metrics_name) = { mount_path = "/etc/ksm" }
  }

  containers = [{
    name             = "kube-state-metrics"
    image_registry   = "registry.k8s.io"
    image_repository = "kube-state-metrics/kube-state-metrics"
    image_tag        = "v2.12.0"
    command = [
      "/kube-state-metrics",
      "--port=${local.snapshot_metrics_port}",
      "--custom-resource-state-only",
      "--custom-resource-state-config-file=/etc/ksm/config.yaml",
    ]
    minimum_memory = 100

    liveness_probe_type  = "HTTP"
    liveness_probe_port  = local.snapshot_metrics_port
    liveness_probe_route = "/healthz"

    ports = {
      http = { port = local.snapshot_metrics_port }
    }
  }]

  depends_on = [kubernetes_config_map.snapshot_metrics]
}

resource "kubectl_manifest" "snapshot_metrics_service_monitor" {
  count = var.monitoring_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = local.snapshot_metrics_name
      namespace = local.namespace
      labels    = module.snapshot_metrics[0].labels
    }
    spec = {
      selector = { matchLabels = module.snapshot_metrics[0].match_labels }
      endpoints = [{
        port     = "http"
        interval = "60s"
        # Keeps the VolumeSnapshot's own `namespace` label instead of the scrape target's.
        honorLabels = true
      }]
    }
  })
  depends_on = [module.snapshot_metrics]
}
