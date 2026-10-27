terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.34.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.1.3"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "5.80.0"
    }
    pf = {
      source  = "panfactum/pf"
      version = "0.0.7"
    }
  }
}

locals {
  entrypoint = "entry"
  args = {

  }

  implentio_util_image = "730335560480.dkr.ecr.us-west-2.amazonaws.com/implentio-util:${var.implentio_util_image_version}"

  # default_resources is sized for the build containers; the token minter only makes two HTTP calls.
  light_resources = {
    requests = {
      memory = "128Mi"
      cpu    = "50m"
    }
    limits = {
      memory = "128Mi"
      cpu    = "250m"
    }
  }

  oom_retry_tiers = var.oom_retry == null ? [] : [
    for attempt in range(var.oom_retry.max_retries + 1) :
    "${ceil(var.memory_mb * pow(var.oom_retry.growth_factor, attempt))}Mi"
  ]

  # Argo exposes `retries` as a string; without the sprig.int cast, pod patching fails.
  oom_retry_memory_expression = var.oom_retry == null ? null : format(
    "{{=%s'%s'}}",
    join("", [for attempt in range(length(local.oom_retry_tiers) - 1) : "sprig.int(retries) == ${attempt} ? '${local.oom_retry_tiers[attempt]}' : "]),
    local.oom_retry_tiers[length(local.oom_retry_tiers) - 1]
  )

  # Pod requests add up across containers, so only the buildctl containers get the larger memory.
  build_container_names = concat(
    var.amd_builder_enabled ? ["build-amd64"] : [],
    var.arm_builder_enabled ? ["build-arm64"] : []
  )

  # Template-level retry replaces the pod, which is the only way to change its memory.
  oom_retry_strategy = var.oom_retry == null ? null : {
    limit       = tostring(var.oom_retry.max_retries)
    retryPolicy = "Always"
    backoff = {
      duration = "10" # seconds
      factor   = 2
    }
    # containerSet nodes never get lastRetry.exitCode (Argo reads it only from a container named `main`),
    # so match the node message, which starts with the OOM reason. Deleted spot pods must still retry.
    expression = "lastRetry.message startsWith 'OOMKilled' || lastRetry.message matches 'pod deleted'"
  }

  oom_pod_spec_patch = var.oom_retry == null ? null : yamlencode({
    containers = [for name in local.build_container_names : {
      name = name
      resources = {
        requests = {
          cpu    = "${var.cpu_millicores}m"
          memory = local.oom_retry_memory_expression
        }
        limits = {
          memory = local.oom_retry_memory_expression
        }
      }
    }]
  })
}

module "constants" {
  source = "../kube_constants"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

#############################################################
# Kubernetes Permissions
#
# Binding to the 'buildkit-user` role in the 'buildkit'
# namespace gives the Workflow's ServiceAccount permissions
# to scale BuildKit, select a BuildKit instance, and record
# builds
#############################################################

resource "kubernetes_role_binding" "image_builder" {
  metadata {
    generate_name = var.name
    namespace     = "buildkit"
    labels        = module.image_builder_workflow.labels
  }
  subject {
    kind      = "ServiceAccount"
    name      = module.image_builder_workflow.service_account_name
    namespace = var.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "buildkit-user"
  }
}

#############################################################
# AWS Permissions
#
# This policy gives the Workflow the ability to upload
# and download images from the repository
#############################################################

data "aws_iam_policy_document" "image_builder" {
  statement {
    sid    = "PrivateECR"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = [
      "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.image_repo}"
    ]
  }
  dynamic "statement" {
    for_each = length(var.extra_ecr_repo_arns_for_pull_access) > 0 ? toset(["enabled"]) : toset([])
    content {
      sid    = "ExtraPrivateECR"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:ListImages"
      ]
      resources = var.extra_ecr_repo_arns_for_pull_access
    }
  }
  statement {
    sid       = "PrivateECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

#############################################################
# Workflow
#############################################################

data "kubernetes_config_map" "buildkit_bucket" {
  metadata {
    name      = "buildkit-cache-bucket-config"
    namespace = "buildkit"
  }
}

# These define our workflow scripts
resource "kubernetes_config_map" "scripts" {
  metadata {
    name      = "${var.name}-scripts"
    labels    = module.image_builder_workflow.labels
    namespace = var.namespace
  }
  data = {
    "build.sh"           = file("${path.module}/scripts/build.sh")
    "clone.sh"           = file("${path.module}/scripts/clone.sh")
    "merge-manifests.sh" = file("${path.module}/scripts/merge-manifests.sh")
    "setup.sh"           = file("${path.module}/scripts/setup.sh")
    "scale-buildkit.sh"  = file("${path.module}/scripts/scale-buildkit.sh")
    # This mount shadows the implentio-util image's /scripts. Keep byte-identical to wf_tf_plan's copy.
    "refresh-github-token.sh" = file("${path.module}/scripts/refresh-github-token.sh")
  }
}

module "image_builder_workflow" {
  source = "../wf_spec"

  name                    = var.name
  namespace               = var.namespace
  burstable_nodes_enabled = true
  active_deadline_seconds = var.build_timeout
  workflow_parallelism    = 10
  retry_max_attempts      = 1

  entrypoint = local.entrypoint
  passthrough_parameters = [
    {
      name        = "git_ref"
      description = "Which commit to check out and build in the ${var.code_repo} repository"
      default     = var.git_ref
    }
  ]
  common_env = {
    GIT_REF                = "{{inputs.parameters.git_ref}}"
    CODE_REPO              = var.code_repo
    IMAGE_REPO             = var.image_repo
    IMAGE_REGISTRY         = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
    IMAGE_REGION           = data.aws_region.current.name
    PUSH_IMAGE             = tostring(var.push_image_enabled)
    BUILD_CONTEXT          = var.build_context
    DOCKERFILE_PATH        = var.dockerfile_path
    BUILDKIT_BUCKET_NAME   = data.kubernetes_config_map.buildkit_bucket.data.bucket
    BUILDKIT_BUCKET_REGION = data.aws_region.current.name
    SECRET_ARGS            = join(" ", [for id, val in var.secrets : "--secret id=${id},env=${id}"])
    BUILD_ARGS             = join(" ", [for arg, val in var.args : "--opt build-arg:${arg}=${val}"])
    IMAGE_TAG_PREFIX       = var.image_tag_prefix
  }
  common_secrets = merge(
    var.secrets,
    {
      GITHUB_APP_ID              = var.github_app_id
      GITHUB_APP_INSTALLATION_ID = var.github_app_installation_id
      GITHUB_APP_PRIVATE_KEY     = var.github_app_private_key
    }
  )
  extra_aws_permissions = data.aws_iam_policy_document.image_builder.json
  default_resources = {
    requests = {
      memory = "${var.memory_mb}Mi"
      cpu    = "${var.cpu_millicores}m"
    }
    limits = {
      memory = "${var.memory_mb}Mi"
    }
  }
  default_container_image = "${module.constants.images.devShell.registry}/${module.constants.images.devShell.repository}:${module.constants.images.devShell.tag}"
  templates = [
    {
      name = local.entrypoint
      dag = {
        tasks = [{ name = "build", template = "build" }]
      }
      # One build per image and commit: a second one waits, then setup.sh finds the image and skips.
      # It sits outside the build template so a waiting duplicate does not hold the build-slot queue.
      synchronization = {
        mutexes = [{ name = "${var.name}-{{inputs.parameters.git_ref}}" }]
      }
    },
    merge(
      {
        name    = "build"
        volumes = module.image_builder_workflow.volumes
        containerSet = {
          retry_strategy = {
            duration = "60s"
            retries  = var.retry_max_attempts
          }
          containers = concat(
            [
              {
                # The devShell image has no openssl, so a separate container mints the App token into /tmp.
                name      = "refresh-github-token"
                image     = local.implentio_util_image
                command   = ["/bin/bash", "/scripts/refresh-github-token.sh"]
                resources = local.light_resources
              },
              {
                name         = "setup"
                command      = ["/scripts/setup.sh"]
                dependencies = ["refresh-github-token"]
              },
              {
                name = "scale-buildkit"
                command = [for arg in [
                  "/scripts/scale-buildkit.sh",
                  var.amd_builder_enabled ? null : "--only=arm64",
                  var.arm_builder_enabled ? null : "--only=amd64",
                  "--wait"
                ] : arg if arg != null]
                dependencies = ["setup"]
              },
              {
                name         = "clone"
                command      = ["/scripts/clone.sh"]
                dependencies = ["setup"]
              }
            ],
            var.amd_builder_enabled ? [
              {
                name    = "build-amd64"
                command = ["/scripts/build.sh"]
                env = concat(
                  module.image_builder_workflow.env,
                  [
                    { name = "ARCH", value = "amd64" },
                    { name = "USE_ARCH_SUFFIX", value = var.arm_builder_enabled ? "1" : "0" },
                  ]
                )
                dependencies = ["scale-buildkit", "clone"]
            }] : [],
            var.arm_builder_enabled ? [
              {
                name    = "build-arm64"
                command = ["/scripts/build.sh"]
                env = concat(
                  module.image_builder_workflow.env,
                  [
                    { name = "ARCH", value = "arm64" },
                    { name = "USE_ARCH_SUFFIX", value = var.amd_builder_enabled ? "1" : "0" },
                  ]
                )
                dependencies = ["scale-buildkit", "clone"]
            }] : [],
            var.arm_builder_enabled && var.amd_builder_enabled ? [
              {
                name         = "merge-manifests"
                command      = ["/scripts/merge-manifests.sh"]
                dependencies = ["build-arm64", "build-amd64"]
              }
            ] : []
          )
        }
      },
      {
        retryStrategy = local.oom_retry_strategy
        podSpecPatch  = local.oom_pod_spec_patch
        # Template-level so the lock also applies through templateRef from the build-deploy workflows.
        synchronization = var.build_semaphore == null ? null : {
          semaphores = [{ configMapKeyRef = { name = var.build_semaphore.configmap_name, key = var.build_semaphore.key } }]
        }
      }
    )
  ]
  tmp_directories = {
    code = {
      mount_path = "/code"
      size_mb    = var.code_storage_gb * 1024
      node_local = true
    }
    creds = {
      mount_path = "/.docker"
      size_mb    = 10
      node_local = true
    }
    aws = {
      mount_path = "/.aws"
      size_mb    = 10
      node_local = true
    }
    tmp = {
      mount_path = "/tmp"
      size_mb    = 1
      node_local = true
    }
  }
  config_map_mounts = {
    "${kubernetes_config_map.scripts.metadata[0].name}" = {
      mount_path = "/scripts"
    }
  }
}

resource "kubectl_manifest" "workflow_template" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "WorkflowTemplate"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = module.image_builder_workflow.labels
    }
    spec = module.image_builder_workflow.workflow_spec
  })

  server_side_apply = true
  force_conflicts   = true

  lifecycle {
    precondition {
      condition     = var.arm_builder_enabled || var.amd_builder_enabled
      error_message = "At least one of arm_builder_enabled or amd_builder_enabled must be true."
    }
  }
}

