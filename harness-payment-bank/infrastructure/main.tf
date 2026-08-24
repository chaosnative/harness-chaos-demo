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

  backend "s3" {
    bucket         = "hpb-demo-tfstate-naren"
    key            = "hpb-eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "hpb-demo-tf-lock"
  }

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
# The identity needs EC2 (VPC/NAT/ELB/EBS), EKS, and IAM Role/Policy access.
# An ECR-only CI user will fail on CreateVpc / CreatePolicy.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Fresh token at apply time via aws CLI (installed on the delegate).
# data.aws_eks_cluster_auth is captured in the saved plan and expires (~15m),
# which causes Unauthorized after approval + EKS create.
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

  kubeconfig_yaml = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = "hpb-eks"
      cluster = {
        server                     = module.eks.cluster_endpoint
        "certificate-authority-data" = module.eks.cluster_certificate_authority_data
      }
    }]
    users = [{
      name = "hpb-eks"
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "aws"
          args = [
            "eks", "get-token",
            "--cluster-name", module.eks.cluster_name,
            "--region", var.aws_region,
          ]
        }
      }
    }]
    contexts = [{
      name = "hpb-eks"
      context = {
        cluster = "hpb-eks"
        user    = "hpb-eks"
      }
    }]
    "current-context" = "hpb-eks"
  })

  # kubectl uses aws eks get-token (aws + kubectl must be on PATH).
  kubeconfig = join("\n", [
    "export PATH=\"/usr/local/bin:/usr/bin:/opt/harness-delegate/client-tools/kubectl/v1.19.2:/opt/harness-delegate/client-tools/kubectl/v1.13.2:$PATH\"",
    "export KUBECONFIG=/tmp/hpb-eks.kubeconfig",
    "cat > \"$KUBECONFIG\" <<'KUBEEOF'",
    local.kubeconfig_yaml,
    "KUBEEOF",
  ])

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
  app_ready_timeout      = "20m"
  data_pvcs              = ["postgresql-pvc", "mongodb-pvc", "kafka-pvc"]
  data_statefulsets      = ["postgresql", "mongodb", "kafka"]

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

# Destroyed after EKS and before the VPC module (NAT, subnets, IGW, VPC).
# EKS/CNI/ELB ENIs are not Terraform resources; they must be gone or subnet
# delete fails and the NAT/VPC are left behind.
resource "null_resource" "wait_after_eks" {
  depends_on = [module.vpc]

  triggers = {
    vpc_id       = module.vpc.vpc_id
    aws_region   = var.aws_region
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION="${self.triggers.aws_region}"
      VPC="${self.triggers.vpc_id}"
      CLUSTER="${self.triggers.cluster_name}"
      export AWS_DEFAULT_REGION="$REGION"

      if ! aws ec2 describe-vpcs --vpc-ids "$VPC" >/dev/null 2>&1; then
        echo "VPC $VPC already gone"
        exit 0
      fi

      # If this resource is replaced while the cluster still exists, do not
      # delete node ENIs. Only run after EKS has already been destroyed.
      if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
        echo "Cluster $CLUSTER still exists; skipping post-EKS ENI cleanup"
        exit 0
      fi

      echo "EKS is gone; releasing leftover non-NAT ENIs, cluster EBS volumes, and leftover SGs in $VPC"

      leftover_enis() {
        aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
          --query "NetworkInterfaces[?InterfaceType!='nat_gateway'].NetworkInterfaceId" \
          --output text 2>/dev/null || true
      }

      leftover_volumes() {
        aws ec2 describe-volumes \
          --filters "Name=tag:hpb-cluster,Values=$CLUSTER" \
          --query "Volumes[].VolumeId" --output text 2>/dev/null || true
      }

      leftover_sgs() {
        aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
          --query "SecurityGroups[?GroupName!='default'].GroupId" \
          --output text 2>/dev/null || true
      }

      release_eni() {
        local eni="$1"
        [ -z "$eni" ] || [ "$eni" = "None" ] && return 0
        local meta st rm att
        meta=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
          --query 'NetworkInterfaces[0].[Status,RequesterManaged,Attachment.AttachmentId]' \
          --output text 2>/dev/null || true)
        [ -z "$meta" ] && return 0
        st=$(echo "$meta" | awk '{print $1}')
        rm=$(echo "$meta" | awk '{print $2}')
        att=$(echo "$meta" | awk '{print $3}')
        if [ "$rm" = "True" ] || [ "$rm" = "true" ]; then
          echo "Waiting for requester-managed ENI $eni ($st)"
          return 0
        fi
        if [ -n "$att" ] && [ "$att" != "None" ] && [ "$att" != "null" ]; then
          echo "Force-detaching ENI $eni ($att)"
          aws ec2 detach-network-interface --attachment-id "$att" --force || true
        fi
        if [ "$st" = "available" ]; then
          echo "Deleting detached ENI $eni"
          aws ec2 delete-network-interface --network-interface-id "$eni" || true
        fi
      }

      release_volume() {
        local vol="$1"
        [ -z "$vol" ] || [ "$vol" = "None" ] && return 0
        local st
        st=$(aws ec2 describe-volumes --volume-ids "$vol" \
          --query 'Volumes[0].State' --output text 2>/dev/null || true)
        [ -z "$st" ] || [ "$st" = "None" ] && return 0
        if [ "$st" = "in-use" ]; then
          echo "Force-detaching EBS volume $vol"
          aws ec2 detach-volume --volume-id "$vol" --force || true
        fi
        if [ "$st" = "available" ]; then
          echo "Deleting leftover EBS volume $vol"
          aws ec2 delete-volume --volume-id "$vol" || true
        fi
      }

      for i in $(seq 1 60); do
        ENIS=$(leftover_enis)
        VOLS=$(leftover_volumes)

        for eni in $ENIS; do
          release_eni "$eni"
        done
        for vol in $VOLS; do
          release_volume "$vol"
        done

        for sg in $(leftover_sgs); do
          if [ -n "$sg" ] && [ "$sg" != "None" ]; then
            echo "Deleting leftover SG $sg"
            aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
          fi
        done

        blocked=0
        ENIS=$(leftover_enis)
        VOLS=$(leftover_volumes)
        for eni in $ENIS; do
          if [ -n "$eni" ] && [ "$eni" != "None" ]; then
            blocked=1
          fi
        done
        for vol in $VOLS; do
          if [ -n "$vol" ] && [ "$vol" != "None" ]; then
            blocked=1
          fi
        done

        if [ "$blocked" -eq 0 ]; then
          echo "No leftover non-NAT ENIs or cluster EBS volumes in $VPC"
          echo "NAT ENI (if present) is Terraform-managed and is deleted with the NAT gateway next"
          exit 0
        fi

        echo "Waiting for leftover ENIs/volumes to release from $VPC (attempt $i/60)"
        sleep 15
      done

      echo "Timed out waiting for leftover ENIs/volumes after EKS delete"
      aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
        --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Type:InterfaceType,Desc:Description,Status:Status,RM:RequesterManaged}" \
        --output table || true
      aws ec2 describe-volumes --filters "Name=tag:hpb-cluster,Values=$CLUSTER" \
        --query "Volumes[].{Id:VolumeId,State:State}" --output table || true
      exit 1
    EOT
  }
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

  # Create after wait_after_eks so destroy order is: EKS → leftover ENI/EBS drain → NAT/VPC.
  depends_on = [null_resource.wait_after_eks]

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # This cluster is managed node groups, not EKS Auto Mode. Disabling the Auto
  # Mode tagging policy skips an extra iam:CreatePolicy that is not used.
  enable_auto_mode_custom_tags = false

  create_kms_key              = false
  cluster_encryption_config   = {}
  create_cloudwatch_log_group = false
  cluster_enabled_log_types   = []

  cluster_timeouts = {
    delete = "30m"
  }

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        controller = {
          extraVolumeTags = {
            Project       = "hpb"
            ManagedBy     = "terraform"
            "hpb-cluster" = var.cluster_name
          }
        }
      })
    }
  }

  eks_managed_node_groups = {
    main = {
      instance_types = var.node_instance_types
      desired_size   = var.node_desired_size
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      timeouts = {
        delete = "30m"
      }
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

  # EBS CSI rejects tag keys under kubernetes.io (reserved). Stamp allowed
  # tags so destroy can find leaked PVC volumes after the cluster is gone.
  parameters = {
    type               = "gp3"
    tagSpecification_1 = "Project=hpb"
    tagSpecification_2 = "ManagedBy=terraform"
    tagSpecification_3 = "hpb-cluster=${var.cluster_name}"
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

# CSI must be ACTIVE and nodes Ready before any PVC is created. A YAML apply
# that races the addon leaves postgres/mongo/kafka Pending until a later retry.
resource "null_resource" "wait_ebs_csi" {
  triggers = {
    cluster        = module.eks.cluster_name
    storage_class  = kubernetes_storage_class_v1.gp3.id
    gp2_annotation = null_resource.unset_gp2_default.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.kubeconfig} >/dev/null

      echo "Waiting for EKS addon aws-ebs-csi-driver to become ACTIVE"
      for i in $(seq 1 60); do
        ST=$(aws eks describe-addon --cluster-name "${module.eks.cluster_name}" --addon-name aws-ebs-csi-driver --region "${var.aws_region}" --query 'addon.status' --output text 2>/dev/null || true)
        if [ "$ST" = "ACTIVE" ]; then
          echo "aws-ebs-csi-driver is ACTIVE"
          break
        fi
        if [ "$i" -eq 60 ]; then
          echo "aws-ebs-csi-driver not ACTIVE (status=$${ST:-unknown})"
          exit 1
        fi
        sleep 10
      done

      echo "Waiting for worker nodes to be Ready"
      kubectl wait --for=condition=Ready nodes --all --timeout=15m

      echo "Waiting for EBS CSI controller and node plugin"
      kubectl wait --namespace kube-system --for=condition=available deployment/ebs-csi-controller --timeout=10m
      kubectl rollout status daemonset/ebs-csi-node --namespace kube-system --timeout=10m

      echo "Confirming gp3 StorageClass exists"
      kubectl get storageclass gp3 >/dev/null
    EOT
  }

  depends_on = [
    module.eks,
    kubernetes_storage_class_v1.gp3,
    null_resource.unset_gp2_default,
  ]
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
# prometheus.yaml includes a cluster-wide ClusterRole/Binding. Apply that file
# once first so the parallel namespace applies do not race on create.

resource "null_resource" "hpb_cluster_scoped" {
  count = var.deploy_apps ? 1 : 0

  triggers = {
    manifests_hash = local.manifests_hash
    cluster_name   = module.eks.cluster_name
    aws_region     = var.aws_region
    namespace      = local.namespace_names[0]
    cluster_role   = local.prometheus_cluster_role
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.kubeconfig} >/dev/null
      echo "Applying cluster-scoped Prometheus objects once (${local.namespace_names[0]})"
      kubectl apply -f "${local.manifests_abs}/prometheus.yaml" -n "${local.namespace_names[0]}"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --region "${self.triggers.aws_region}" --name "${self.triggers.cluster_name}" >/dev/null || true
      kubectl delete clusterrolebinding "${self.triggers.cluster_role}" --ignore-not-found=true || true
      kubectl delete clusterrole "${self.triggers.cluster_role}" --ignore-not-found=true || true
    EOT
  }

  depends_on = [
    kubernetes_namespace_v1.banking,
    null_resource.wait_ebs_csi,
  ]
}

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
      NS="${each.value}"
      DIR="${local.manifests_abs}"
      if [ ! -d "$DIR" ]; then
        echo "Manifest directory not found: $DIR"
        exit 1
      fi

      ${local.kubeconfig} >/dev/null

      # Secrets/config/PVCs first so StatefulSets always have a claim to bind.
      kubectl apply -f "$DIR/secrets.yaml" -n "$NS"
      kubectl apply -f "$DIR/configmap.yaml" -n "$NS"
      kubectl apply -f "$DIR/persistent-volumes.yaml" -n "$NS"

      apply_ok=0
      for attempt in $(seq 1 5); do
        if kubectl apply -f "$DIR" -n "$NS"; then
          apply_ok=1
          break
        fi
        echo "apply attempt $attempt for namespace $NS failed; retrying"
        sleep $((attempt * 5))
      done
      if [ "$apply_ok" -ne 1 ]; then
        echo "apply failed for namespace $NS after 5 attempts"
        kubectl get all,pvc,secret,cm -n "$NS" || true
        exit 1
      fi

      for kind in "secret/banking-secrets" "pvc/postgresql-pvc" "pvc/mongodb-pvc" "pvc/kafka-pvc" "statefulset/postgresql" "statefulset/mongodb" "statefulset/kafka"; do
        if ! kubectl get $kind -n "$NS" >/dev/null 2>&1; then
          echo "[$NS] expected $kind after apply, but it is missing"
          kubectl get all,pvc,secret -n "$NS" || true
          exit 1
        fi
      done
    EOT
  }

  depends_on = [
    kubernetes_namespace_v1.banking,
    kubernetes_storage_class_v1.gp3,
    null_resource.unset_gp2_default,
    null_resource.wait_ebs_csi,
    null_resource.hpb_cluster_scoped,
  ]
}

# -----------------------------------------------------------------------------
# 6. Bootstrap apps after apply (README Step 4, automated)
# -----------------------------------------------------------------------------
# Manifests race secrets/Postgres on first boot, so app databases can be missing
# and transaction-service can crash-loop on aggressive probes. Without editing
# hpb-manifest, wait for data stores, ensure DBs exist, relax probes, and only
# restart DB-backed services that are not already Ready.

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
    data_pvcs              = join(",", local.data_pvcs)
    data_statefulsets      = join(",", local.data_statefulsets)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS="${each.value}"
      DIR="${local.manifests_abs}"
      STS="${local.postgres_statefulset}"
      PGUSER="${local.postgres_user}"
      DBS="${join(" ", local.app_databases)}"
      DEPLOYS="${join(" ", local.app_deployments)}"
      DATA_PVCS="${join(" ", local.data_pvcs)}"
      DATA_STS="${join(" ", local.data_statefulsets)}"
      TX="${local.transaction_deployment}"
      TIMEOUT="${local.app_ready_timeout}"

      ${local.kubeconfig} >/dev/null

      fail_ns() {
        echo "[$NS] $*"
        kubectl get pods,pvc,sts,deploy -n "$NS" || true
        kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -n 40 || true
        exit 1
      }

      ensure_data_manifests() {
        kubectl apply -f "$DIR/secrets.yaml" -n "$NS" >/dev/null
        kubectl apply -f "$DIR/persistent-volumes.yaml" -n "$NS" >/dev/null
        kubectl apply -f "$DIR/postgresql.yaml" -n "$NS" >/dev/null
        kubectl apply -f "$DIR/mongodb.yaml" -n "$NS" >/dev/null
        kubectl apply -f "$DIR/kafka.yaml" -n "$NS" >/dev/null
      }

      echo "[$NS] ensuring secrets and data-plane manifests"
      ensure_data_manifests

      # Manifest mongo probes call mongosh without auth; TCP is enough to mean "up".
      kubectl patch statefulset mongodb -n "$NS" --type='json' -p='[
        {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe","value":{"tcpSocket":{"port":27017},"initialDelaySeconds":30,"periodSeconds":10}},
        {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe","value":{"tcpSocket":{"port":27017},"initialDelaySeconds":10,"periodSeconds":5}}
      ]' >/dev/null || true

      echo "[$NS] relaxing $TX probes for reliable startup"
      kubectl patch deployment "$TX" -n "$NS" --type='json' -p='[
        {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":300},
        {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":180},
        {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/failureThreshold","value":30},
        {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/failureThreshold","value":30}
      ]' >/dev/null || true

      echo "[$NS] waiting for data PVCs to bind"
      for i in $(seq 1 120); do
        missing=0
        for pvc in $DATA_PVCS; do
          if ! kubectl get pvc "$pvc" -n "$NS" >/dev/null 2>&1; then
            echo "[$NS] $pvc missing; re-applying volume manifests"
            ensure_data_manifests
            missing=1
            continue
          fi
          phase=$(kubectl get pvc "$pvc" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
          if [ "$phase" = "Bound" ]; then
            continue
          fi
          missing=1
          desc=$(kubectl describe pvc "$pvc" -n "$NS" 2>/dev/null || true)
          if echo "$desc" | grep -qiE 'ProvisioningFailed|Invalid tag|is reserved'; then
            echo "[$NS] $pvc provision failed; deleting and recreating"
            echo "$desc" | tail -n 20
            app="$${pvc%-pvc}"
            kubectl delete pvc "$pvc" -n "$NS" --wait=true --timeout=2m || true
            kubectl apply -f "$DIR/persistent-volumes.yaml" -n "$NS"
            kubectl delete pod -n "$NS" -l "app=$app" --wait=false --ignore-not-found=true || true
          fi
        done
        if [ "$missing" -eq 0 ]; then
          echo "[$NS] all data PVCs are Bound"
          break
        fi
        if [ "$i" -eq 120 ]; then
          fail_ns "data PVCs did not all bind"
        fi
        sleep 10
      done

      echo "[$NS] waiting for data StatefulSets"
      pids=""
      for name in $DATA_STS; do
        kubectl rollout status "statefulset/$name" -n "$NS" --timeout=20m &
        pids="$pids $!"
      done
      for p in $pids; do
        wait "$p" || fail_ns "a data StatefulSet is not Ready"
      done

      echo "[$NS] waiting for Postgres to accept connections"
      for i in $(seq 1 36); do
        if kubectl exec -n "$NS" "statefulset/$STS" -- pg_isready -U "$PGUSER" >/dev/null 2>&1; then
          break
        fi
        sleep 5
        if [ "$i" -eq 36 ]; then
          fail_ns "Postgres is not accepting connections"
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
        fail_ns "failed to create database $db"
      done

      need_restart=""
      for d in $DEPLOYS; do
        want=$(kubectl get deployment "$d" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
        ready=$(kubectl get deployment "$d" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
        if [ "$${ready:-0}" != "$${want:-0}" ] || [ "$${want:-0}" = "0" ]; then
          need_restart="$need_restart $d"
        fi
      done

      if [ -n "$need_restart" ]; then
        echo "[$NS] restarting unready deployments:$need_restart"
        for d in $need_restart; do
          kubectl rollout restart "deployment/$d" -n "$NS" || true
        done
      else
        echo "[$NS] DB-backed deployments already available; skipping restart"
      fi

      wait_pids=""
      for d in $DEPLOYS; do
        echo "[$NS] waiting for deployment/$d"
        kubectl rollout status "deployment/$d" -n "$NS" --timeout="$TIMEOUT" &
        wait_pids="$wait_pids $!"
      done
      for p in $wait_pids; do
        wait "$p" || fail_ns "a DB-backed deployment is not Ready"
      done

      echo "[$NS] app bootstrap complete"
    EOT
  }

  depends_on = [
    null_resource.hpb_apply,
    null_resource.wait_ebs_csi,
  ]
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
      kubectl delete clusterrolebinding "${self.triggers.cluster_role_binding}" --ignore-not-found=true || true
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
        for i in $(seq 1 90); do
          HOST=$(kubectl get svc "$svc" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
          IP=$(kubectl get svc "$svc" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
          if [ -n "$HOST" ] || [ -n "$IP" ]; then
            echo "$svc ready: $${HOST:-$IP}"
            break
          fi
          if [ "$i" -eq 90 ]; then
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
    null_resource.wait_after_eks,
    null_resource.unset_gp2_default,
    null_resource.wait_ebs_csi,
    null_resource.hpb_cluster_scoped,
    null_resource.hpb_apply,
    null_resource.app_bootstrap,
    null_resource.prometheus_namespace_config,
    null_resource.wait_for_lbs,
    null_resource.frontend_gateway_url,
  ]

  # Namespaces are deliberately NOT a trigger: scaling namespace_count would
  # replace this resource and run the destroy provisioner mid-apply, tearing
  # down the live stack. They are discovered by label at destroy time instead.
  triggers = {
    vpc_id       = module.vpc.vpc_id
    aws_region   = var.aws_region
    cluster_name = module.eks.cluster_name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION="${self.triggers.aws_region}"
      VPC="${self.triggers.vpc_id}"
      CLUSTER="${self.triggers.cluster_name}"
      export AWS_DEFAULT_REGION="$REGION"

      echo "Draining Kubernetes LoadBalancers from VPC $VPC before destroy"

      VOL_IDS=""
      if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
        aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null || true

        NS_LIST=$(kubectl get namespace -l "managed-by=terraform,cluster=$CLUSTER" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        echo "Namespaces to drain: $${NS_LIST:-<none>}"

        # Map PVC -> PV -> EBS volume id NOW. Once EKS is gone there is nothing
        # left that can associate a volume with this cluster, so a namespace
        # delete that times out would orphan the volumes silently.
        for ns in $NS_LIST; do
          for pv in $(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true); do
            VH=$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)
            case "$VH" in
              vol-*) VOL_IDS="$VOL_IDS $VH" ;;
            esac
          done
        done
        echo "Tracking PV-backed EBS volumes:$${VOL_IDS:- <none>}"

        # Delete LoadBalancer Services first so AWS starts ELB teardown while
        # namespace termination continues in parallel.
        for ns in $NS_LIST; do
          echo "Deleting LoadBalancer Services in $ns"
          kubectl delete svc -n "$ns" --field-selector spec.type=LoadBalancer --wait=false --ignore-not-found=true || true
        done

        kubectl delete clusterrolebinding prometheus --ignore-not-found=true || true
        kubectl delete clusterrole prometheus --ignore-not-found=true || true
        for ns in $NS_LIST; do
          kubectl delete clusterrolebinding "prometheus-$ns" --ignore-not-found=true || true
        done

        for ns in $NS_LIST; do
          echo "Deleting namespace $ns"
          kubectl delete namespace "$ns" --ignore-not-found=true --wait=true --timeout=25m || true
        done
      else
        echo "Cluster $CLUSTER already gone; draining leftover AWS LoadBalancers"
      fi

      TAGGED=$(aws ec2 describe-volumes --filters "Name=tag:hpb-cluster,Values=$CLUSTER" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
      for v in $TAGGED; do
        if [ -n "$v" ] && [ "$v" != "None" ]; then
          VOL_IDS="$VOL_IDS $v"
        fi
      done
      echo "Tracking cluster-tagged EBS volumes:$${VOL_IDS:- <none>}"

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

        ELB_ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
          --query "NetworkInterfaces[?starts_with(Description, 'ELB')].[NetworkInterfaceId,Attachment.AttachmentId,Status]" \
          --output text 2>/dev/null || true)
        if [ -n "$ELB_ENIS" ] && [ "$ELB_ENIS" != "None" ]; then
          echo "$ELB_ENIS" | while read -r eni att st; do
            [ -z "$eni" ] || [ "$eni" = "None" ] && continue
            if [ -n "$att" ] && [ "$att" != "None" ] && [ "$att" != "null" ]; then
              aws ec2 detach-network-interface --attachment-id "$att" --force 2>/dev/null || true
            fi
            if [ "$st" = "available" ]; then
              aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
            fi
          done
        fi

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

      # Wait for the CSI driver to delete the volumes behind the PVs captured
      # above, then force-delete any that detached but were never reclaimed.
      # Keyed on explicit ids, so this holds regardless of volume tagging.
      if [ -n "$(echo $VOL_IDS | tr -d ' ')" ]; then
        for i in $(seq 1 40); do
          LEFT=""
          for v in $VOL_IDS; do
            ST=$(aws ec2 describe-volumes --volume-ids "$v" \
              --query 'Volumes[0].State' --output text 2>/dev/null || true)
            if [ -z "$ST" ] || [ "$ST" = "None" ]; then
              continue
            fi
            if [ "$ST" = "in-use" ]; then
              aws ec2 detach-volume --volume-id "$v" --force || true
            fi
            if [ "$ST" = "available" ]; then
              echo "Force-deleting unreclaimed EBS volume $v"
              aws ec2 delete-volume --volume-id "$v" || true
            fi
            LEFT="$LEFT $v"
          done

          if [ -z "$(echo $LEFT | tr -d ' ')" ]; then
            echo "All PV-backed EBS volumes released"
            break
          fi
          echo "Waiting for PV-backed EBS volumes to delete (attempt $i/40):$LEFT"
          sleep 15
          if [ "$i" -eq 40 ]; then
            echo "WARNING: EBS volumes still present after namespace delete:$LEFT"
            echo "The post-EKS sweep will retry them once nodes are gone."
          fi
        done
      fi

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
  value     = local.kubeconfig
  sensitive = true
}
