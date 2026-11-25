# =============================================================================
# variables.tf — defaults for local use and Harness pipeline overrides
# =============================================================================
# Override any value in Harness with TF_VAR_<name>, for example:
# TF_VAR_cluster_name, TF_VAR_namespace_prefix, TF_VAR_namespace_count.
#
# AWS credentials must allow VPC, EKS, IAM roles/policies, ELB, and EBS.
# An ECR-only CI user (for example harness-aws-ecr-prod-ci-rw) will fail on
# ec2:CreateVpc and iam:CreatePolicy.

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
  description = "Number of namespaces to create. The POC default is 10. The cap is 15."
  type        = number
  default     = 10

  validation {
    condition     = var.namespace_count >= 1 && var.namespace_count <= 15
    error_message = "namespace_count must be between 1 and 15."
  }
}

# --- Application manifests ---

variable "manage_namespaces" {
  description = "true = create banking-1..N and, when deploy_apps is true, install the bank into each. false = terraform apply deletes those namespaces and the workloads in them, including their load balancers. The EKS cluster and its node group stay, so this does not by itself stop node cost, and it does not touch org workshop or the chaos templates. Set manage_team_projects=false in harness-resources first, while the cluster still exists, so Harness can remove discovery agents and experiments before the namespaces disappear. Do not set this false if another org still runs pods in these namespaces."
  type        = bool
  default     = true
}

variable "deploy_apps" {
  description = "Whether to apply the local Kubernetes manifests in every namespace. Ignored when manage_namespaces is false."
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
  description = "Desired worker node count. 12 x m5.xlarge is sized for the 10-namespace POC, including one 2-core CPU hog."
  type        = number
  default     = 20
}

variable "node_min_size" {
  description = "Minimum worker node count. Must stay at or below the live desired count. EKS rejects a minimum above the current desired size."
  type        = number
  default     = 6
}

variable "node_max_size" {
  description = "Maximum worker node count. 16 leaves room above the desired 12. Keep this >= node_desired_size >= node_min_size."
  type        = number
  default     = 32
}

variable "node_disk_size" {
  description = "Worker root volume size in GiB. The module default of 20 fills up once every node has the bank images."
  type        = number
  default     = 50

  validation {
    condition     = var.node_disk_size >= 50 && var.node_disk_size <= 200
    error_message = "node_disk_size must be between 50 and 200 GiB."
  }
}
