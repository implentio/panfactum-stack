terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.34.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.12.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.3"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.1.3"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  name      = "alloy"
  namespace = module.namespace.namespace
}

data "pf_kube_labels" "labels" {
  module = "kube_alloy"
}

module "util" {
  source = "${var.pf_module_source}kube_workload_utility${var.pf_module_ref}"

  workload_name            = "alloy"
  burstable_nodes_enabled  = true
  controller_nodes_enabled = true
  extra_labels             = data.pf_kube_labels.labels.labels
}

module "constants" {
  source = "${var.pf_module_source}kube_constants${var.pf_module_ref}"
}

/***************************************
* Namespace
***************************************/

module "namespace" {
  source = "${var.pf_module_source}kube_namespace${var.pf_module_ref}"

  namespace = local.name
}

/***************************************
* Alloy
***************************************/

resource "kubernetes_config_map" "alloy" {
  metadata {
    name      = "alloy-config"
    namespace = local.namespace
    labels    = module.util.labels
  }
  data = {
    "alloy.config" = templatefile("${path.module}/alloy.txt", {
      LOG_LEVEL = var.log_level
    })
  }
}

resource "helm_release" "alloy" {
  namespace       = local.namespace
  name            = "alloy"
  repository      = "https://grafana.github.io/helm-charts"
  chart           = "alloy"
  version         = var.alloy_chart_version
  recreate_pods   = false
  atomic          = var.wait
  cleanup_on_fail = var.wait
  wait            = var.wait
  force_update    = true
  wait_for_jobs   = true
  max_history     = 5

  values = [
    yamlencode({
      fullnameOverride = "alloy"
      crds = {
        create = false
      }
      alloy = {
        clustering = {
          enabled = false
        }
        configMap = {
          create = false
          name   = kubernetes_config_map.alloy.metadata[0].name
          key    = "alloy.config"
        }
        mounts = {
          varlog = true
        }
        resources = {
          requests = {
            cpu    = "100m"
            memory = "200Mi"
          }
          limits = {
            memory = "${floor(200 * 1.3)}Mi"
          }
        }
      }
      controller = {
        type              = "daemonset"
        tolerations       = module.util.tolerations
        priorityClassName = "system-node-critical"
        podLabels         = module.util.labels
        updateStrategy = {
          rollingUpdate = {
            maxUnavailable = "34%"
            maxSurge       = 0
          }
        }
      }
      configReloader = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "20Mi"
          }
          limits = {
            memory = "${floor(20 * 1.3)}Mi"
          }
        }
      }
      serviceMonitor = {
        enabled  = var.monitoring_enabled
        interval = "60s"
      }
    })
  ]

  timeout = 300
}

/***************************************
* Kubernetes Events
***************************************/

module "util_events" {
  source = "${var.pf_module_source}kube_workload_utility${var.pf_module_ref}"

  workload_name            = "alloy-events"
  burstable_nodes_enabled  = true
  controller_nodes_enabled = true
  extra_labels             = data.pf_kube_labels.labels.labels
}

resource "kubernetes_config_map" "alloy_events" {
  metadata {
    name      = "alloy-events-config"
    namespace = local.namespace
    labels    = module.util_events.labels
  }
  data = {
    "alloy.config" = templatefile("${path.module}/alloy-events.txt", {
      LOG_LEVEL = var.log_level
    })
  }
}

// loki.source.kubernetes_events does not support clustering, so a single replica
// avoids every DaemonSet pod shipping a duplicate of each event
resource "helm_release" "alloy_events" {
  namespace       = local.namespace
  name            = "alloy-events"
  repository      = "https://grafana.github.io/helm-charts"
  chart           = "alloy"
  version         = var.alloy_chart_version
  recreate_pods   = false
  atomic          = var.wait
  cleanup_on_fail = var.wait
  wait            = var.wait
  force_update    = true
  wait_for_jobs   = true
  max_history     = 5

  values = [
    yamlencode({
      fullnameOverride = "alloy-events"
      crds = {
        create = false
      }
      alloy = {
        clustering = {
          enabled = false
        }
        configMap = {
          create = false
          name   = kubernetes_config_map.alloy_events.metadata[0].name
          key    = "alloy.config"
        }
        // No VPA; the 30d peak (105Mi) was 81% of the old 130Mi limit and each start re-lists events
        resources = {
          requests = {
            cpu    = "50m"
            memory = "150Mi"
          }
          limits = {
            memory = "${floor(150 * 1.3)}Mi"
          }
        }
      }
      controller = {
        type        = "deployment"
        replicas    = 1
        tolerations = module.util_events.tolerations
        podLabels   = module.util_events.labels
      }
      configReloader = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "20Mi"
          }
          limits = {
            memory = "${floor(20 * 1.3)}Mi"
          }
        }
      }
      serviceMonitor = {
        enabled  = var.monitoring_enabled
        interval = "60s"
      }
    })
  ]

  timeout = 300
}

/***************************************
* Autoscaling
***************************************/

resource "kubectl_manifest" "vpa_alloy" {
  count = var.vpa_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "alloy"
      namespace = local.namespace
      labels    = module.util.labels
    }
    spec = {
      resourcePolicy = {
        containerPolicies = [{
          containerName = "alloy"
          // The 30d peak (174Mi) was 89% of the 195Mi limit; Alloy has no WAL, so an OOM drops buffered logs
          minAllowed = {
            memory = "200Mi"
          }
        }]
      }
      updatePolicy = {
        updateMode = "Auto"
        evictionRequirements = [{
          resources         = ["cpu", "memory"]
          changeRequirement = "TargetHigherThanRequests"
        }]
      }
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "DaemonSet"
        name       = "alloy"
      }
    }
  })
  force_conflicts   = true
  server_side_apply = true
  depends_on        = [helm_release.alloy]
}

/***************************************
* Image Cache
***************************************/

module "image_cache" {
  count  = var.node_image_cached_enabled ? 1 : 0
  source = "${var.pf_module_source}kube_node_image_cache${var.pf_module_ref}"

  images = [
    {
      registry    = "docker.io"
      repository  = "grafana/alloy"
      tag         = "v1.1.0"
      pin_enabled = false
    },
    {
      registry    = "ghcr.io"
      repository  = "jimmidyson/configmap-reload"
      tag         = "v0.12.0"
      pin_enabled = false
    }
  ]
}
