# =============================================================================
# main.tf — VPC → EKS → namespaces → apply local YAML → set frontend URL
# =============================================================================
# All inputs have defaults in variables.tf. Harness can override any input by
# setting TF_VAR_<variable_name>, for example TF_VAR_cluster_name.
#
# Manifests are vendored at ../hpb-manifest/hpb-k8s (same git repo). They are
# applied as-is; Terraform patches live objects after apply.
#
# terraform init && terraform apply
# terraform output service_endpoints

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    # Used by terraform-aws-modules/eks (time_sleep). Keep pinned here so Harness
    # plan/apply uses the same lockfile as a local run.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# AWS credentials come from the environment / SSO — not from this file.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Talks to the cluster after it exists (same AWS identity as above).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region,
    ]
  }
}

locals {
  namespace_names = [
    for i in range(1, var.namespace_count + 1) : "${var.namespace_prefix}-${i}"
  ]
  deploy_namespaces = var.deploy_apps ? toset(local.namespace_names) : toset([])

  common_tags = {
    Project   = "hpb"
    ManagedBy = "terraform"
  }

  kubeconfig = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"

  manifests_abs = startswith(var.manifests_path, "/") ? var.manifests_path : abspath("${path.module}/${var.manifests_path}")
  manifest_files = sort(tolist(setunion(
    fileset(local.manifests_abs, "*.yaml"),
    fileset(local.manifests_abs, "*.yml"),
  )))
  manifests_hash = sha256(join("", [
    for file in local.manifest_files : "${file}:${filesha256("${local.manifests_abs}/${file}")}"
  ]))

  # Names below match the vendored hpb-k8s manifests. They are not pipeline inputs.
  frontend_deployment           = "frontend-service"
  gateway_service               = "gateway-service"
  frontend_gateway_env          = "VITE_API_URL"
  gateway_port                  = 8080
  prometheus_service            = "prometheus"
  prometheus_deployment         = "prometheus"
  prometheus_config_map         = "prometheus-config"
  prometheus_service_account    = "prometheus"
  prometheus_cluster_role       = "prometheus"
  prometheus_manifest_namespace = "banking"
  postgres_statefulset          = "postgresql"
  postgres_user                 = "postgres"
  app_databases                 = ["auth", "transaction", "account", "loan", "notification"]
  app_deployments = [
    "auth-service",
    "transaction-service",
    "account-service",
    "loan-service",
    "notification-service",
  ]
  transaction_deployment = "transaction-service"
  app_ready_timeout      = "15m"

  frontend_lb = {
    for ns, svc in data.kubernetes_service_v1.frontend :
    ns => try(svc.status[0].load_balancer[0].ingress[0].hostname, try(svc.status[0].load_balancer[0].ingress[0].ip, null))
  }
  gateway_lb = {
    for ns, svc in data.kubernetes_service_v1.gateway :
    ns => try(svc.status[0].load_balancer[0].ingress[0].hostname, try(svc.status[0].load_balancer[0].ingress[0].ip, null))
  }
  prometheus_lb = {
    for ns, svc in data.kubernetes_service_v1.prometheus :
    ns => try(svc.status[0].load_balancer[0].ingress[0].hostname, try(svc.status[0].load_balancer[0].ingress[0].ip, null))
  }

  service_endpoints = {
    for ns in local.namespace_names : ns => {
      namespace  = ns
      frontend   = try(local.frontend_lb[ns], null) != null ? "http://${local.frontend_lb[ns]}" : null
      gateway    = try(local.gateway_lb[ns], null) != null ? "http://${local.gateway_lb[ns]}:${local.gateway_port}" : null
      prometheus = try(local.prometheus_lb[ns], null) != null ? "http://${local.prometheus_lb[ns]}:9090" : null
    } if var.deploy_apps
  }
}

# -----------------------------------------------------------------------------
# 1. VPC — private subnets for nodes, public subnets for NAT + LoadBalancers
# -----------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = [for az in ["a", "b"] : "${var.aws_region}${az}"]
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 2. EKS — control plane, worker nodes, EBS CSI (for Postgres/Mongo/Kafka PVCs)
# -----------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  create_kms_key              = false
  cluster_encryption_config   = {}
  create_cloudwatch_log_group = false
  cluster_enabled_log_types   = []

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
    eks-node-monitoring-agent = {}
  }

  eks_managed_node_groups = {
    main = {
      instance_types     = var.node_instance_types
      node_repair_config = { enabled = true }
      desired_size       = var.node_desired_size
      min_size           = var.node_min_size
      max_size           = var.node_max_size
    }
  }

  tags = local.common_tags
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 3. Default StorageClass (gp3 via EBS CSI)
# -----------------------------------------------------------------------------

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
  }

  depends_on = [module.eks]
}

# EKS still ships gp2 as default. Two defaults make PVC provisioning undefined.
resource "null_resource" "unset_gp2_default" {
  triggers = {
    storage_class_id = kubernetes_storage_class_v1.gp3.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.kubeconfig} >/dev/null
      kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite || true
    EOT
  }

  depends_on = [kubernetes_storage_class_v1.gp3]
}

# -----------------------------------------------------------------------------
# 4. Namespaces — prefix-1 .. prefix-N
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "banking" {
  for_each = toset(local.namespace_names)

  wait_for_default_service_account = true

  metadata {
    name = each.value
    labels = {
      managed-by = "terraform"
      cluster    = var.cluster_name
    }
  }

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# 5. Apply YAML into each namespace (skipped if deploy_apps = false)
# -----------------------------------------------------------------------------

resource "null_resource" "hpb_apply" {
  for_each = local.deploy_namespaces

  triggers = {
    namespace      = each.value
    aws_region     = var.aws_region
    cluster_name   = module.eks.cluster_name
    manifests_path = local.manifests_abs
    manifests_hash = local.manifests_hash
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [ ! -d "${local.manifests_abs}" ]; then
        echo "Manifest directory not found: ${local.manifests_abs}"
        exit 1
      fi

      ${local.kubeconfig} >/dev/null

      # Cluster-scoped Prometheus objects are shared. Parallel namespace applies
      # can race on create; retries converge on AlreadyExists.
      for attempt in 1 2 3; do
        if kubectl apply -f "${local.manifests_abs}" -n "${each.value}"; then
          exit 0
        fi
        echo "apply attempt $attempt for namespace ${each.value} failed; retrying"
        sleep $((attempt * 10))
      done

      echo "apply failed for namespace ${each.value} after 3 attempts"
      exit 1
    EOT
  }

  depends_on = [
    kubernetes_namespace_v1.banking,
    kubernetes_storage_class_v1.gp3,
    null_resource.unset_gp2_default,
  ]
}

# -----------------------------------------------------------------------------
# 6. Bootstrap apps after apply (README Step 4, automated)
# -----------------------------------------------------------------------------
# Manifests race secrets/Postgres on first boot, so app databases can be missing
# and transaction-service can crash-loop on aggressive probes. Without editing
# hpb-manifest, wait for Postgres, ensure DBs exist, relax probes, and restart
# the DB-backed services until they are Ready.

resource "null_resource" "app_bootstrap" {
  for_each = local.deploy_namespaces

  triggers = {
    namespace              = each.value
    aws_region             = var.aws_region
    cluster_name           = module.eks.cluster_name
    apply_id               = null_resource.hpb_apply[each.key].id
    postgres_statefulset   = local.postgres_statefulset
    postgres_user          = local.postgres_user
    app_databases          = join(",", local.app_databases)
    app_deployments        = join(",", local.app_deployments)
    transaction_deployment = local.transaction_deployment
    app_ready_timeout      = local.app_ready_timeout
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS="${each.value}"
      STS="${local.postgres_statefulset}"
      PGUSER="${local.postgres_user}"
      DBS="${join(" ", local.app_databases)}"
      DEPLOYS="${join(" ", local.app_deployments)}"
      TX="${local.transaction_deployment}"
      TIMEOUT="${local.app_ready_timeout}"

      ${local.kubeconfig} >/dev/null

      echo "[$NS] waiting for secret banking-secrets"
      for i in $(seq 1 60); do
        if kubectl get secret banking-secrets -n "$NS" >/dev/null 2>&1; then
          break
        fi
        sleep 5
        if [ "$i" -eq 60 ]; then
          echo "[$NS] banking-secrets not found"
          exit 1
        fi
      done

      echo "[$NS] waiting for Postgres StatefulSet/$STS"
      kubectl rollout status "statefulset/$STS" -n "$NS" --timeout=15m
      for i in $(seq 1 60); do
        if kubectl exec -n "$NS" "statefulset/$STS" -- pg_isready -U "$PGUSER" >/dev/null 2>&1; then
          break
        fi
        sleep 5
        if [ "$i" -eq 60 ]; then
          echo "[$NS] Postgres is not accepting connections"
          exit 1
        fi
      done

      echo "[$NS] ensuring application databases exist"
      for db in $DBS; do
        exists=$(kubectl exec -n "$NS" "statefulset/$STS" -- \
          psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" || true)
        if [ "$exists" = "1" ]; then
          echo "[$NS] database $db already exists"
          continue
        fi
        echo "[$NS] creating database $db"
        if kubectl exec -n "$NS" "statefulset/$STS" -- \
          psql -U "$PGUSER" -d postgres -c "CREATE DATABASE $db"; then
          continue
        fi
        exists=$(kubectl exec -n "$NS" "statefulset/$STS" -- \
          psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" || true)
        if [ "$exists" = "1" ]; then
          echo "[$NS] database $db already exists"
          continue
        fi
        echo "[$NS] failed to create database $db"
        exit 1
      done

      echo "[$NS] relaxing $TX probes for reliable startup"
      kubectl patch deployment "$TX" -n "$NS" --type='json' -p='[
        {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":300},
        {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":180},
        {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":30},
        {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/failureThreshold","value":30}
      ]' || true

      echo "[$NS] restarting DB-backed deployments"
      for d in $DEPLOYS; do
        kubectl rollout restart "deployment/$d" -n "$NS" || true
      done

      for d in $DEPLOYS; do
        echo "[$NS] waiting for deployment/$d"
        kubectl rollout status "deployment/$d" -n "$NS" --timeout="$TIMEOUT"
      done

      echo "[$NS] app bootstrap complete"
    EOT
  }

  depends_on = [null_resource.hpb_apply]
}

# -----------------------------------------------------------------------------
# 7. Make the manifest's Prometheus configuration namespace-aware
# -----------------------------------------------------------------------------
# Source manifests are left unchanged. They share a ClusterRole but hardcode
# namespace "banking" in service discovery and the ClusterRoleBinding. Add one
# uniquely named binding per namespace and rewrite only the live ConfigMap.

resource "null_resource" "prometheus_namespace_config" {
  for_each = local.deploy_namespaces

  triggers = {
    namespace            = each.value
    aws_region           = var.aws_region
    cluster_name         = module.eks.cluster_name
    apply_id             = null_resource.app_bootstrap[each.key].id
    config_map           = local.prometheus_config_map
    deployment           = local.prometheus_deployment
    service_account      = local.prometheus_service_account
    cluster_role         = local.prometheus_cluster_role
    manifest_namespace   = local.prometheus_manifest_namespace
    cluster_role_binding = "${local.prometheus_cluster_role}-${each.value}"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      TMP=$(mktemp -d)
      trap 'rm -rf "$TMP"' EXIT

      ${local.kubeconfig} >/dev/null

      kubectl create clusterrolebinding "${local.prometheus_cluster_role}-${each.value}" \
        --clusterrole="${local.prometheus_cluster_role}" \
        --serviceaccount="${each.value}:${local.prometheus_service_account}" \
        --dry-run=client -o yaml | kubectl apply -f -

      # Manifest CRB points at namespace "banking", which this stack does not create.
      kubectl delete clusterrolebinding "${local.prometheus_cluster_role}" --ignore-not-found=true

      kubectl get configmap "${local.prometheus_config_map}" \
        --namespace "${each.value}" \
        --output go-template='{{index .data "prometheus.yml"}}' \
        > "$TMP/prometheus.yml"

      sed "s/^\\([[:space:]]*- \\)${local.prometheus_manifest_namespace}$/\\1${each.value}/" \
        "$TMP/prometheus.yml" > "$TMP/prometheus-updated.yml"

      kubectl create configmap "${local.prometheus_config_map}" \
        --namespace "${each.value}" \
        --from-file=prometheus.yml="$TMP/prometheus-updated.yml" \
        --dry-run=client -o yaml | kubectl apply -f -

      kubectl rollout restart deployment/"${local.prometheus_deployment}" --namespace "${each.value}"
      kubectl rollout status deployment/"${local.prometheus_deployment}" \
        --namespace "${each.value}" --timeout=10m
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --region "${self.triggers.aws_region}" --name "${self.triggers.cluster_name}" >/dev/null
      kubectl delete clusterrolebinding "${self.triggers.cluster_role_binding}" --ignore-not-found=true
    EOT
  }

  depends_on = [null_resource.app_bootstrap]
}

# -----------------------------------------------------------------------------
# 8. Wait for LoadBalancer hostnames, then read Services
# -----------------------------------------------------------------------------

resource "null_resource" "wait_for_lbs" {
  for_each = local.deploy_namespaces

  triggers = {
    apply_id             = null_resource.hpb_apply[each.key].id
    bootstrap_id         = null_resource.app_bootstrap[each.key].id
    prometheus_config_id = null_resource.prometheus_namespace_config[each.key].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.kubeconfig} >/dev/null
      NS="${each.value}"
      for svc in ${local.frontend_deployment} ${local.gateway_service} ${local.prometheus_service}; do
        echo "Waiting for LoadBalancer on $svc in $NS"
        for i in $(seq 1 36); do
          HOST=$(kubectl get svc "$svc" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
          IP=$(kubectl get svc "$svc" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
          if [ -n "$HOST" ] || [ -n "$IP" ]; then
            echo "$svc ready: $${HOST:-$IP}"
            break
          fi
          if [ "$i" -eq 36 ]; then
            echo "timed out waiting for $svc in $NS"
            kubectl get svc "$svc" -n "$NS" || true
            exit 1
          fi
          sleep 10
        done
      done
    EOT
  }

  depends_on = [null_resource.prometheus_namespace_config]
}

data "kubernetes_service_v1" "frontend" {
  for_each   = local.deploy_namespaces
  depends_on = [null_resource.wait_for_lbs]

  metadata {
    name      = local.frontend_deployment
    namespace = each.value
  }
}

data "kubernetes_service_v1" "gateway" {
  for_each   = local.deploy_namespaces
  depends_on = [null_resource.wait_for_lbs]

  metadata {
    name      = local.gateway_service
    namespace = each.value
  }
}

data "kubernetes_service_v1" "prometheus" {
  for_each   = local.deploy_namespaces
  depends_on = [null_resource.wait_for_lbs]

  metadata {
    name      = local.prometheus_service
    namespace = each.value
  }
}

# -----------------------------------------------------------------------------
# 9. Set frontend env to this namespace's public gateway URL
# -----------------------------------------------------------------------------

resource "null_resource" "frontend_gateway_url" {
  for_each = local.deploy_namespaces

  triggers = {
    namespace   = each.value
    gateway_url = local.service_endpoints[each.value].gateway
    apply_id    = null_resource.hpb_apply[each.key].id
    env_name    = local.frontend_gateway_env
    deployment  = local.frontend_deployment
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [ -z "${self.triggers.gateway_url}" ] || [ "${self.triggers.gateway_url}" = "null" ]; then
        echo "Gateway LoadBalancer not ready for ${self.triggers.namespace}"
        exit 1
      fi
      ${local.kubeconfig} >/dev/null
      kubectl set env deployment/${self.triggers.deployment} -n "${self.triggers.namespace}" "${self.triggers.env_name}=${self.triggers.gateway_url}"
      kubectl rollout status deployment/${self.triggers.deployment} -n "${self.triggers.namespace}" --timeout=10m
    EOT
  }

  depends_on = [
    data.kubernetes_service_v1.gateway,
    data.kubernetes_service_v1.frontend,
  ]
}

# -----------------------------------------------------------------------------
# 10. Drain Kubernetes LoadBalancers before VPC destroy
# -----------------------------------------------------------------------------
# Frontend / gateway / prometheus Services create classic ELBs and k8s-elb
# security groups that are NOT in Terraform state. This resource is created
# last, so it is destroyed first while the cluster still exists. It deletes
# app namespaces, then waits until AWS ELBs and ELB ENIs are gone.

resource "null_resource" "destroy_lb_drain" {
  depends_on = [
    module.vpc,
    module.eks,
    kubernetes_namespace_v1.banking,
    null_resource.unset_gp2_default,
    null_resource.hpb_apply,
    null_resource.app_bootstrap,
    null_resource.prometheus_namespace_config,
    null_resource.wait_for_lbs,
    null_resource.frontend_gateway_url,
  ]

  triggers = {
    vpc_id       = module.vpc.vpc_id
    aws_region   = var.aws_region
    cluster_name = module.eks.cluster_name
    namespaces   = join(" ", local.namespace_names)
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION="${self.triggers.aws_region}"
      VPC="${self.triggers.vpc_id}"
      CLUSTER="${self.triggers.cluster_name}"
      NS_LIST="${self.triggers.namespaces}"
      export AWS_DEFAULT_REGION="$REGION"

      echo "Draining Kubernetes LoadBalancers from VPC $VPC before destroy"

      if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
        aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null || true
        for ns in $NS_LIST; do
          echo "Deleting namespace $ns"
          kubectl delete namespace "$ns" --ignore-not-found=true --wait=true --timeout=25m || true
        done
      else
        echo "Cluster $CLUSTER already gone; draining leftover AWS LoadBalancers"
      fi

      delete_lbs() {
        NAMES=$(aws elb describe-load-balancers \
          --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" \
          --output text 2>/dev/null || true)
        for name in $NAMES; do
          if [ -n "$name" ] && [ "$name" != "None" ]; then
            echo "Deleting classic ELB $name"
            aws elb delete-load-balancer --load-balancer-name "$name" || true
          fi
        done

        ARNS=$(aws elbv2 describe-load-balancers \
          --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" \
          --output text 2>/dev/null || true)
        for arn in $ARNS; do
          if [ -n "$arn" ] && [ "$arn" != "None" ]; then
            echo "Deleting ELBv2 $arn"
            aws elbv2 delete-load-balancer --load-balancer-arn "$arn" || true
          fi
        done
      }

      still_blocked() {
        CLASSIC=$(aws elb describe-load-balancers \
          --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" \
          --output text 2>/dev/null || true)
        V2=$(aws elbv2 describe-load-balancers \
          --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" \
          --output text 2>/dev/null || true)
        ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
          --query "NetworkInterfaces[?starts_with(Description, 'ELB')].NetworkInterfaceId" \
          --output text 2>/dev/null || true)

        [ -n "$CLASSIC" ] && [ "$CLASSIC" != "None" ] && return 0
        [ -n "$V2" ] && [ "$V2" != "None" ] && return 0
        [ -n "$ENIS" ] && [ "$ENIS" != "None" ] && return 0
        return 1
      }

      for i in $(seq 1 60); do
        delete_lbs
        if ! still_blocked; then
          echo "No LoadBalancers or ELB ENIs remain in $VPC"
          break
        fi
        echo "Waiting for ELBs/ENIs to release from $VPC (attempt $i/60)"
        sleep 15
        if [ "$i" -eq 60 ]; then
          echo "Timed out waiting for LoadBalancers to drain from $VPC"
          aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output table || true
          aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
            --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description}" --output table || true
          exit 1
        fi
      done

      for i in $(seq 1 8); do
        SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
          --query "SecurityGroups[?starts_with(GroupName, 'k8s-elb-')].GroupId" \
          --output text 2>/dev/null || true)
        if [ -z "$SGS" ] || [ "$SGS" = "None" ]; then
          break
        fi
        for sg in $SGS; do
          echo "Deleting leftover SG $sg"
          aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
        done
        sleep 5
      done

      echo "LoadBalancer drain complete for $VPC"
    EOT
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "namespaces" {
  value = sort(keys(kubernetes_namespace_v1.banking))
}

output "service_endpoints" {
  description = "Frontend / gateway / prometheus URLs per namespace"
  value       = local.service_endpoints
}

output "kubeconfig_command" {
  value = local.kubeconfig
}
