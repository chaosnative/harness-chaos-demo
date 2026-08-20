# =============================================================================
# variables.tf — defaults for local use and Harness pipeline overrides
# =============================================================================
# Override any value in Harness with TF_VAR_<name>, for example:
# TF_VAR_cluster_name, TF_VAR_namespace_prefix, TF_VAR_namespace_count.

# --- Cluster ---

variable "aws_region" {
  description = "AWS region for VPC and EKS"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name (unique in the account and region)"
  type        = string
  default     = "hpb-eks"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.36"
}

# --- Network ---

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs for worker nodes"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs for NAT and LoadBalancers"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# --- Namespaces ---

variable "namespace_prefix" {
  description = "Prefix for generated namespaces"
  type        = string
  default     = "banking"
}

variable "namespace_count" {
  description = "Number of namespaces to create"
  type        = number
  default     = 4

  validation {
    condition     = var.namespace_count >= 1 && var.namespace_count <= 8
    error_message = "namespace_count must be between 1 and 8."
  }
}

# --- Application manifests ---

variable "deploy_apps" {
  description = "Whether to apply the local Kubernetes manifests in every namespace"
  type        = bool
  default     = true
}

variable "manifests_path" {
  description = "Manifest directory, absolute or relative to the Terraform directory"
  type        = string
  default     = "../hpb-manifest/hpb-k8s"
}

# --- Worker nodes ---

variable "node_instance_types" {
  description = "EKS managed node group instance types"
  type        = list(string)
  default     = ["m5.xlarge"]
}

variable "node_desired_size" {
  description = "Desired worker node count"
  type        = number
  default     = 6
}

variable "node_min_size" {
  description = "Minimum worker node count"
  type        = number
  default     = 6
}

variable "node_max_size" {
  description = "Maximum worker node count"
  type        = number
  default     = 8
}
