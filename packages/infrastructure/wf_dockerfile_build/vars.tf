variable "name" {
  description = "The name of the WorkflowTemplate"
  type        = string
}

variable "namespace" {
  description = "The namespace to deploy the WorkflowTemplate into"
  type        = string
}

variable "pull_through_cache_enabled" {
  description = "Whether to use the ECR pull through cache for the deployed images"
  type        = bool
  default     = true
}

variable "code_repo" {
  description = "The URL of the git repo containing the Dockerfile to build. Must NOT contain a protocol prefix."
  type        = string
  validation {
    condition     = !strcontains(var.code_repo, "//")
    error_message = "code_repo should NOT contain a protocol prefix such as https://"
  }
  validation {
    condition     = !strcontains(var.code_repo, "@")
    error_message = "code_repo should NOT contain a protocol git user prefix such as git@"
  }
}

variable "code_storage_gb" {
  description = "The size of the volume to mount the code into"
  type        = number
  default     = 1
}

variable "cpu_millicores" {
  description = "The amount of CPU to allocate to pods in the workflow (in millicores)"
  type        = number
  default     = 25
}

variable "memory_mb" {
  description = "The amount of memory to allocate to pods in the workflow (in MB)"
  type        = number
  default     = 100
}

variable "git_ref" {
  description = "The default git ref to checkout and build if none is provided to the WorkflowTemplate when executing the Workflow"
  type        = string
  default     = "main"
}

variable "build_context" {
  description = "Relative path from the root of the repository to the build context to submit to BuildKit"
  type        = string
  default     = "."
}

variable "dockerfile_path" {
  description = "Relative path from the root of the repository to the Dockerfile / Containerfile to submit to Buildkit"
  type        = string
  default     = "./Dockerfile"
}

variable "build_timeout" {
  description = "The number of seconds after which the build will be timed out"
  type        = number
  default     = 60 * 60
}

variable "image_repo" {
  description = "The name of the AWS ECR repository where generated images will be pushed"
  type        = string
}

variable "image_tag_prefix" {
  description = "The prefix to prepend to the image tag"
  type        = string
  default     = ""
}

variable "push_image_enabled" {
  description = "True iff images should be pushed to ECR in addition to being built"
  type        = bool
  default     = true
}

variable "secrets" {
  description = "A mapping of build-time secret ids to their respective values"
  type        = map(string)
  default     = {}
}

variable "args" {
  description = "A mapping of build-time arguments to their respective values"
  type        = map(string)
  default     = {}
}

variable "github_app_id" {
  description = "GitHub App id, used to mint the installation token that checks out the code"
  type        = string
  sensitive   = true
}

variable "github_app_installation_id" {
  description = "GitHub App installation id, used to mint the installation token that checks out the code"
  type        = string
  sensitive   = true
}

variable "github_app_private_key" {
  description = "GitHub App private key, used to mint the installation token that checks out the code"
  type        = string
  sensitive   = true
}

variable "implentio_util_image_version" {
  description = "Image tag of implentio-util, which runs the token minter (the devShell image has no openssl)"
  type        = string
}

variable "extra_ecr_repo_arns_for_pull_access" {
  description = "ARNs of private ECR repositories from which the Dockerfile pulls base images FROM"
  type        = list(string)
  default     = []
}

variable "arm_builder_enabled" {
  description = "Whether to build arm64 images."
  type        = bool
  default     = true
}

variable "amd_builder_enabled" {
  description = "Whether to build amd64 images."
  type        = bool
  default     = true
}

variable "retry_max_attempts" {
  description = "The maximum number of allowable retries"
  type        = number
  default     = 2
}

# Non-OOM failures stop immediately; spot evictions consume tiers and the build_timeout covers all attempts.
variable "oom_retry" {
  description = "Retry the whole build pod with more memory after an OOM kill. On by default. Null disables it and keeps the upstream single retry."
  type = object({
    max_retries   = optional(number, 3)
    growth_factor = optional(number, 1.3)
  })
  default = {}

  validation {
    condition = try(
      var.oom_retry.max_retries >= 0 && floor(var.oom_retry.max_retries) == var.oom_retry.max_retries,
      true
    )
    error_message = "oom_retry.max_retries must be a whole number, 0 or greater."
  }

  validation {
    condition     = try(var.oom_retry.growth_factor > 1, true)
    error_message = "oom_retry.growth_factor must be greater than 1. A value of 1 repeats one tier, and a value below 1 shrinks memory on every retry."
  }
}

variable "build_semaphore" {
  description = "A semaphore ConfigMap key shared across build templates, held by the build pod. Null matches upstream (no shared cap)."
  type = object({
    configmap_name = string
    key            = string
  })
  default = null
}
