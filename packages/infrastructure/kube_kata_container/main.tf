terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.80.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.34.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.12.1"
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
  namespace = "kube-system"

  // Pods opt in with runtimeClassName; the taint keeps everything else off these nodes.
  kata_taint = {
    key    = "implentio.com/kata"
    value  = "true"
    effect = "NoSchedule"
  }

  // kata-deploy removes this once the runtime is installed, so Kata pods never land on a half-ready node.
  kata_startup_taint = {
    key    = "katacontainers.io/kata-runtime"
    value  = "installing"
    effect = "NoSchedule"
  }

  // kata-deploy registers the containerd handler as kata-<shim>.
  runtime_handler = "kata-${var.kata_deploy.shim}"
}

data "pf_kube_labels" "labels" {
  module = "kube_kata_container"
}

module "constants" {
  source = "../kube_constants"
}

data "aws_subnet" "node_subnets" {
  for_each = var.node_subnets
  vpc_id   = var.node_vpc_id
  filter {
    name   = "tag:Name"
    values = [each.value]
  }
}

/***************************************
* Nodes
***************************************/

resource "kubectl_manifest" "node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name   = "kata"
      labels = data.pf_kube_labels.labels.labels
    }
    spec = {
      // Bottlerocket has a read-only root and no Kata variant, so kata-deploy cannot install there.
      amiSelectorTerms           = [{ alias = var.node_pool.ami_alias }]
      subnetSelectorTerms        = [for subnet in data.aws_subnet.node_subnets : { id = subnet.id }]
      securityGroupSelectorTerms = [{ id = var.node_security_group_id }]
      instanceProfile            = var.node_instance_profile
      // Exposes /dev/kvm on 8th-gen Intel instances; Karpenter filters to types that support it.
      cpuOptions = {
        nestedVirtualization = "enabled"
      }
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 1 // don't allow pods to access the node roles
        httpTokens              = "required"
      }
      userData = <<-EOT
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="//"

        --//
        Content-Type: text/x-shellscript; charset="us-ascii"

        #!/bin/bash
        modprobe kvm_intel
        --//--
      EOT
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "${var.node_pool.root_volume_size_gb}Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
    }
  })
  server_side_apply = true
  force_conflicts   = true
}

resource "kubectl_manifest" "node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name   = "kata"
      labels = data.pf_kube_labels.labels.labels
    }
    spec = {
      template = {
        metadata = {
          labels = { (local.kata_taint.key) = "true" }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = kubectl_manifest.node_class.name
          }
          taints = [local.kata_taint]
          startupTaints = [
            module.constants.cilium_taint,
            module.constants.linkerd_taint,
            local.kata_startup_taint,
          ]
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.k8s.aws/instance-family"
              operator = "In"
              values   = var.node_pool.instance_families
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.node_pool.capacity_types
            },
          ]
          expireAfter = "24h"
        }
      }
      limits = {
        cpu = var.node_pool.cpu_limit
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "10s"
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
}

/***************************************
* Runtime
***************************************/

resource "helm_release" "kata_deploy" {
  namespace       = local.namespace
  name            = "kata-deploy"
  repository      = "oci://ghcr.io/kata-containers/kata-deploy-charts"
  chart           = "kata-deploy"
  version         = var.kata_deploy.helm_version
  recreate_pods   = false
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  force_update    = true
  max_history     = 5

  values = [yamlencode({
    nodeSelector = { (local.kata_taint.key) = "true" }
    tolerations = [
      { key = local.kata_taint.key, operator = "Exists", effect = "NoSchedule" },
      { key = local.kata_startup_taint.key, operator = "Exists", effect = "NoSchedule" },
    ]
    startupTaints = ["${local.kata_startup_taint.key}:${local.kata_startup_taint.effect}"]
    podAnnotations = {
      "linkerd.io/inject" = "disabled"
    }
    shims = {
      disableAll = true
      (var.kata_deploy.shim) = {
        enabled = true
      }
    }
    defaultShim = {
      amd64 = var.kata_deploy.shim
    }
    // The chart's RuntimeClasses carry no tolerations, so they cannot reach the tainted pool.
    runtimeClasses = {
      enabled = false
    }
    snapshotter = {
      setup = []
    }
  })]

  depends_on = [kubectl_manifest.node_pool]
}

resource "kubectl_manifest" "runtime_class" {
  yaml_body = yamlencode({
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name   = var.runtime_class_name
      labels = data.pf_kube_labels.labels.labels
    }
    handler = local.runtime_handler
    // Matches the chart's built-in overhead for qemu-runtime-rs (guest kernel, agent, VMM).
    overhead = {
      podFixed = {
        memory = "320Mi"
        cpu    = "250m"
      }
    }
    scheduling = {
      nodeSelector = { (local.kata_startup_taint.key) = "true" }
      tolerations = [
        { key = local.kata_taint.key, operator = "Exists", effect = "NoSchedule" },
      ]
    }
  })
  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.kata_deploy]
}
