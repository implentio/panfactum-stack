output "runtime_class_name" {
  description = "Set as runtimeClassName on a pod to run it in a Kata VM"
  value       = kubectl_manifest.runtime_class.name
}

output "node_pool_name" {
  description = "The Karpenter NodePool that provisions Kata nodes"
  value       = kubectl_manifest.node_pool.name
}
