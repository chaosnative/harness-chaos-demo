# =============================================================================
# main.tf — VPC → EKS → namespaces → apply local YAML → set frontend URL
# =============================================================================
# All inputs have defaults in variables.tf. Harness can override any input by
# setting TF_VAR_<variable_name>, for example TF_VAR_cluster_name.
#
# Manifests are vendored at ../hpb-manifest/hpb-k8s (same git repo). Apply uses
# a copy so the LoadBalancer Services can be annotated NLB first.
# Terraform still patches live Prometheus objects after apply.
#
# terraform init && terraform apply
# terraform output service_endpoints

terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "hpb-demo-tfstate-naren"
    key          = "hpb-eks/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
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
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
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
  deploy_namespaces = var.deploy_apps && var.manage_namespaces ? toset(local.namespace_names) : toset([])

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
        server                       = module.eks.cluster_endpoint
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

  # One file per shell. Parallel namespace steps must not share a path:
  # a neighbor's rewrite makes kubectl fall back to http://localhost:8080.
  kubeconfig = join("\n", [
    "export PATH=\"/usr/local/bin:/usr/bin:/opt/harness-delegate/client-tools/kubectl/v1.19.2:/opt/harness-delegate/client-tools/kubectl/v1.13.2:$PATH\"",
    "export KUBECONFIG=$(mktemp)",
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
  gateway_external_service      = "gateway-service-external"
  grafana_service               = "grafana"
  frontend_gateway_env          = "VITE_API_URL"
  gateway_port                  = 80
  prometheus_service            = "prometheus"
  prometheus_deployment         = "prometheus"
  prometheus_config_map         = "prometheus-config"
  prometheus_service_account    = "prometheus"
  prometheus_cluster_role       = "prometheus"
  prometheus_manifest_namespace = "banking"
  lb_services = [
    "frontend-service",
    "gateway-service-external",
    "prometheus",
    "grafana",
  ]
  lb_services_shell = join(" ", local.lb_services)
  nlb_per_namespace = length(local.lb_services)
  lb_manifest_files = [
    "frontend-service.yaml",
    "gateway-service-external.yaml",
    "prometheus.yaml",
    "grafana-all-in-one.yaml",
  ]
  lb_manifest_files_shell = join(" ", local.lb_manifest_files)
  postgres_statefulset    = "postgresql"
  postgres_user           = "postgres"
  app_databases           = ["auth", "transaction", "account", "loan", "notification"]
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

  # Client-side apply merges probe handlers. A manifest that switches
  # tcpSocket for exec is rejected until the live probe is replaced wholesale.
  kubectl_apply_helpers = <<-EOT
    to_json_pointer() {
      printf '%s' "$1" | sed -E 's/^spec/\/spec/; s/\.([A-Za-z0-9_]+)/\/\1/g; s/\[([0-9]+)\]/\/\1/g'
    }

    drop_cluster_scoped() {
      awk '
        function flush() {
          if (n && kind != "ClusterRole" && kind != "ClusterRoleBinding") {
            if (out) print "---"
            printf "%s", doc
            out = 1
          }
          doc = ""; n = 0; kind = ""
        }
        BEGIN { doc = ""; n = 0; kind = ""; out = 0 }
        /^---[[:space:]]*$/ { flush(); next }
        { if ($0 ~ /^kind:[[:space:]]/) kind = $2; doc = doc $0 ORS; n++ }
        END { flush() }
      ' "$1" > "$2"
    }

    keep_cluster_scoped() {
      awk '
        function flush() {
          if (n && (kind == "ClusterRole" || kind == "ClusterRoleBinding")) {
            if (out) print "---"
            printf "%s", doc
            out = 1
          }
          doc = ""; n = 0; kind = ""
        }
        BEGIN { doc = ""; n = 0; kind = ""; out = 0 }
        /^---[[:space:]]*$/ { flush(); next }
        { if ($0 ~ /^kind:[[:space:]]/) kind = $2; doc = doc $0 ORS; n++ }
        END { flush() }
      ' "$1" > "$2"
    }

    keep_kind() {
      awk -v want="$2" '
        function flush() {
          if (n && kind == want) {
            if (out) print "---"
            printf "%s", doc
            out = 1
          }
          doc = ""; n = 0; kind = ""
        }
        BEGIN { doc = ""; n = 0; kind = ""; out = 0 }
        /^---[[:space:]]*$/ { flush(); next }
        { if ($0 ~ /^kind:[[:space:]]/) kind = $2; doc = doc $0 ORS; n++ }
        END { flush() }
      ' "$1" > "$3"
    }

    # Client-side apply races across namespaces: the second create gets
    # AlreadyExists. That is success if the object is already there.
    apply_ignore_exists() {
      local blob
      if blob=$(kubectl apply --validate=false -f "$1" 2>&1); then
        printf '%s\n' "$blob"
        return 0
      fi
      if printf '%s\n' "$blob" | grep -q 'AlreadyExists'; then
        echo "already exists; continuing"
        return 0
      fi
      printf '%s\n' "$blob" >&2
      return 1
    }

    repair_probe_handlers() {
      local ns="$1" blob="$2" search="$3"
      local obj kind name res file path parent ptr probe paths
      obj=$(printf '%s\n' "$blob" | sed -nE \
        -e 's/.*(StatefulSet|Deployment|DaemonSet)\.apps "([^"]*)".*/\1 \2/p' \
        -e 's/.*The (StatefulSet|Deployment|DaemonSet) "([^"]*)".*/\1 \2/p' \
        | head -n 1)
      if [ -z "$obj" ]; then
        echo "[$ns] could not tell which object rejected the probe" >&2
        return 1
      fi
      kind=$(printf '%s' "$obj" | awk '{print $1}')
      name=$(printf '%s' "$obj" | awk '{print $2}')
      res=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
      file=$(printf '%s\n' "$blob" | sed -nE 's/.*for: "([^"]*)".*/\1/p' | head -n 1)
      if [ -z "$file" ] || [ ! -f "$file" ]; then
        file=""
        for candidate in "$search"/*.yaml "$search"/*.yml "$search"; do
          [ -f "$candidate" ] || continue
          if grep -q "kind: $kind" "$candidate" && grep -q "name: $name" "$candidate"; then
            file="$candidate"
            break
          fi
        done
      fi
      if [ -z "$file" ]; then
        echo "[$ns] could not find the manifest for $kind/$name" >&2
        return 1
      fi
      paths=$(mktemp)
      printf '%s\n' "$blob" | sed -nE 's/.*(spec\.template\.spec\.[^:[:space:]]+): Forbidden: may not specify more than 1 handler type.*/\1/p' | sort -u > "$paths" || true
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        parent=$(printf '%s' "$path" | sed 's/\.[^.]*$//')
        ptr=$(to_json_pointer "$parent")
        probe=$(kubectl create --dry-run=client --validate=false -f "$file" -n "$ns" -o jsonpath="{.$parent}" 2>/dev/null || true)
        if [ -z "$probe" ] || [ "$probe" = "null" ]; then
          echo "[$ns] manifest has no $parent for $name" >&2
          continue
        fi
        echo "[$ns] replacing $res/$name $parent from the manifest"
        kubectl patch "$res" "$name" -n "$ns" --type=json \
          -p="[{\"op\":\"replace\",\"path\":\"$ptr\",\"value\":$probe}]"
      done < "$paths"
      rm -f "$paths"
    }

    apply_with_repair() {
      local target="$1" ns="$2" search="$3"
      local attempt blob
      for attempt in 1 2 3 4 5; do
        if blob=$(kubectl apply --validate=false -f "$target" -n "$ns" 2>&1); then
          printf '%s\n' "$blob"
          return 0
        fi
        printf '%s\n' "$blob" >&2
        if printf '%s\n' "$blob" | grep -q "may not specify more than 1 handler type"; then
          echo "[$ns] manifest replaced a probe handler; updating the live object"
          repair_probe_handlers "$ns" "$blob" "$search" || true
          if blob=$(kubectl apply --validate=false -f "$target" -n "$ns" 2>&1); then
            printf '%s\n' "$blob"
            return 0
          fi
          printf '%s\n' "$blob" >&2
        fi
        if printf '%s\n' "$blob" | grep -q "is invalid:"; then
          echo "[$ns] Kubernetes rejected the manifest; not retrying"
          return 1
        fi
        echo "[$ns] apply attempt $attempt failed; retrying"
        sleep $((attempt * 5))
      done
      return 1
    }

    # An existing Service keeps the balancer it already has. Adding the NLB
    # annotation on a later apply makes AWS create a second one.
    keep_existing_balancer() {
      local file="$1" ns="$2" svc="$3" ann tmp
      [ -f "$file" ] || return 0
      if ! kubectl get svc "$svc" -n "$ns" >/dev/null 2>&1; then
        echo "[$ns] service/$svc is new and will be created once"
        return 0
      fi
      ann=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type}' 2>/dev/null || true)
      if [ "$ann" = "nlb" ]; then
        echo "[$ns] reusing service/$svc"
        return 0
      fi
      echo "[$ns] reusing service/$svc and its current load balancer"
      tmp=$(mktemp)
      awk '
        /^kind: Service$/ { in_svc=1 }
        in_svc && /^spec:/ { in_svc=0 }
        in_svc && /^  annotations:$/ { hold=1; next }
        in_svc && hold && /aws-load-balancer-type:/ { hold=0; next }
        in_svc && hold { print "  annotations:"; hold=0 }
        { print }
      ' "$file" > "$tmp"
      mv "$tmp" "$file"
    }

    # A failed apply can leave an extra balancer tagged for the same Service.
    # Keep the one the Service is using. If the Service has no hostname yet and
    # more than one balancer is tagged for it, keep the oldest and delete the rest.
    drop_orphan_balancers() {
      local ns="$1" region="$2"
      local svc host arns arn dns keep name ts keep_time n typ
      # gateway-service used to be a LoadBalancer; convert leftovers after it
      # becomes ClusterIP.
      for svc in ${local.lb_services_shell} gateway-service; do
        typ=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.type}' 2>/dev/null || true)
        host=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        host=$${host%.}
        arns=$(aws resourcegroupstaggingapi get-resources --region "$region" \
          --resource-type-filters elasticloadbalancing:loadbalancer \
          --tag-filters "Key=kubernetes.io/service-name,Values=$${ns}/$${svc}" \
          --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
        [ -n "$arns" ] && [ "$arns" != "None" ] || continue
        if [ "$typ" != "LoadBalancer" ]; then
          keep=""
        else
          keep=""
          keep_time=""
          n=0
          for arn in $arns; do
            n=$((n + 1))
            case "$arn" in
              *:loadbalancer/net/*|*:loadbalancer/app/*)
                dns=$(aws elbv2 describe-load-balancers --region "$region" --load-balancer-arns "$arn" --query 'LoadBalancers[0].[DNSName,CreatedTime]' --output text 2>/dev/null || true)
                ts=$(printf '%s' "$dns" | awk '{print $2}')
                dns=$(printf '%s' "$dns" | awk '{print $1}')
                ;;
              *)
                name=$(printf '%s' "$arn" | awk -F/ '{print $NF}')
                dns=$(aws elb describe-load-balancers --region "$region" --load-balancer-names "$name" --query 'LoadBalancerDescriptions[0].[DNSName,CreatedTime]' --output text 2>/dev/null || true)
                ts=$(printf '%s' "$dns" | awk '{print $2}')
                dns=$(printf '%s' "$dns" | awk '{print $1}')
                ;;
            esac
            dns=$${dns%.}
            if [ -n "$host" ] && [ "$dns" = "$host" ]; then
              keep="$arn"
            fi
            if [ -z "$host" ]; then
              if [ -z "$keep" ] || [[ "$ts" < "$keep_time" ]]; then
                keep="$arn"
                keep_time="$ts"
              fi
            fi
          done
          if [ -n "$host" ] && [ -z "$keep" ]; then
            continue
          fi
          if [ -z "$host" ] && [ "$n" -le 1 ]; then
            continue
          fi
        fi
        for arn in $arns; do
          [ "$arn" = "$keep" ] && continue
          echo "[$ns] deleting leftover balancer for service/$svc"
          case "$arn" in
            *:loadbalancer/net/*|*:loadbalancer/app/*)
              aws elbv2 delete-load-balancer --region "$region" --load-balancer-arn "$arn" || true
              ;;
            *)
              name=$(printf '%s' "$arn" | awk -F/ '{print $NF}')
              aws elb delete-load-balancer --region "$region" --load-balancer-name "$name" || true
              ;;
          esac
        done
      done
    }
  EOT

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
  grafana_lb = {
    for ns, svc in data.kubernetes_service_v1.grafana :
    ns => try(svc.status[0].load_balancer[0].ingress[0].hostname, try(svc.status[0].load_balancer[0].ingress[0].ip, null))
  }

  service_endpoints = {
    for ns in local.namespace_names : ns => {
      namespace  = ns
      frontend   = try(local.frontend_lb[ns], null) != null ? "http://${local.frontend_lb[ns]}" : null
      gateway    = try(local.gateway_lb[ns], null) != null ? "http://${local.gateway_lb[ns]}" : null
      prometheus = try(local.prometheus_lb[ns], null) != null ? "http://${local.prometheus_lb[ns]}" : null
      grafana    = try(local.grafana_lb[ns], null) != null ? "http://${local.grafana_lb[ns]}" : null
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
# Plan-time guard. Runs during terraform plan, before any node or load
# balancer update. Variable checks only compare the config with itself.
# EKS compares the new minimum and maximum with the size already running.
# -----------------------------------------------------------------------------
data "external" "preflight" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    cat >/dev/null
    REGION=${jsonencode(var.aws_region)}
    CLUSTER=${jsonencode(var.cluster_name)}
    PREFIX=${jsonencode(var.namespace_prefix)}
    COUNT=${var.namespace_count}
    NLB_NEED=$((COUNT * ${local.nlb_per_namespace}))
    cluster_exists=false
    nodegroup_exists=false
    live_min=0
    live_max=0
    live_desired=0
    nlb_quota_known=false
    nlb_quota=0
    nlb_used=0
    nodes_known=false
    ready_nodes=0
    placeable=true
    orphan_nlbs=0
    orphan_volumes=0
    residue=none

    if ! CLUSTER_ERR=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.status' --output text 2>&1); then
      case "$CLUSTER_ERR" in
        *ResourceNotFoundException*|*NotFound*) ;;
        *)
          echo "Could not read cluster $CLUSTER: $CLUSTER_ERR" >&2
          exit 1
          ;;
      esac
    else
      cluster_exists=true
      NGS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups' --output text)
      for NG in $NGS; do
        case "$NG" in
          main-*) ;;
          *) continue ;;
        esac
        nodegroup_exists=true
        SCALING=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --region "$REGION" --query 'nodegroup.scalingConfig.[minSize,maxSize,desiredSize]' --output text)
        live_min=$(echo "$SCALING" | awk '{print $1}')
        live_max=$(echo "$SCALING" | awk '{print $2}')
        live_desired=$(echo "$SCALING" | awk '{print $3}')
        break
      done
      if [ "$nodegroup_exists" = true ]; then
        for n in "$live_min" "$live_max" "$live_desired"; do
          case "$n" in
            ''|*[!0-9]*)
              echo "Could not read scaling for node group on $CLUSTER (got '$SCALING')" >&2
              exit 1
              ;;
          esac
        done
      fi
    fi

    QUOTA=$(aws service-quotas get-service-quota \
      --service-code elasticloadbalancing \
      --quota-code L-69A177A2 \
      --region "$REGION" \
      --query 'Quota.Value' --output text 2>/dev/null || true)
    if [ -n "$QUOTA" ] && [ "$QUOTA" != "None" ]; then
      nlb_quota_known=true
      nlb_quota=$(echo "$QUOTA" | awk -F. '{print $1}')
      nlb_used=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "length(LoadBalancers[?Type=='network'])" --output text)
      for n in "$nlb_quota" "$nlb_used"; do
        case "$n" in
          ''|*[!0-9]*)
            echo "Could not read the network load balancer quota (quota '$QUOTA', in use '$nlb_used')" >&2
            exit 1
            ;;
        esac
      done
    fi

    # A retry must not demand a balancer for a Service that already exists.
    # The first apply of banking-5..10 already created theirs.
    if [ "$cluster_exists" = true ]; then
      found=""
      listed=false
      KCFG=$(mktemp)
      if aws eks update-kubeconfig --kubeconfig "$KCFG" --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 \
        && command -v kubectl >/dev/null 2>&1; then
        KUBECONFIG="$KCFG"
        export KUBECONFIG
        listed=true
        for i in $(seq 1 "$COUNT"); do
          ns="$${PREFIX}-$${i}"
          for svc in ${local.lb_services_shell}; do
            typ=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.type}' 2>/dev/null || true)
            if [ "$typ" = "LoadBalancer" ]; then
              found="$${found}
$${ns}/$${svc}"
            fi
          done
        done
      else
        tagged=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
          --resource-type-filters elasticloadbalancing:loadbalancer \
          --tag-filters "Key=kubernetes.io/cluster/$${CLUSTER},Values=owned" \
          --query "ResourceTagMappingList[].Tags[?Key=='kubernetes.io/service-name'].Value[]" \
          --output text 2>/dev/null || true)
        if [ -n "$tagged" ]; then
          listed=true
          found=$(printf '%s' "$tagged" | tr '\t' '\n')
        fi
      fi
      if [ "$listed" = true ]; then
        missing=0
        for i in $(seq 1 "$COUNT"); do
          ns="$${PREFIX}-$${i}"
          for svc in ${local.lb_services_shell}; do
            key="$${ns}/$${svc}"
            if ! printf '%s\n' "$found" | grep -F -x -q "$key"; then
              missing=$((missing + 1))
            fi
          done
        done
        echo "Network load balancers still to create: $missing of $((COUNT * ${local.nlb_per_namespace}))" >&2
        NLB_NEED=$missing
      else
        echo "Could not list existing Services on $CLUSTER; not demanding a fresh set of balancers." >&2
        NLB_NEED=0
      fi

      # A node that is NotReady, or a subnet with no free address once the CNI
      # is already on a single warm IP, cannot run the pods this config names.
      # Only a live kubeconfig counts. The tag fallback above can list Services
      # without being able to see nodes.
      if [ -n "$${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ] && kubectl get ns kube-system >/dev/null 2>&1; then
        nodes_known=true
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
        warm_ip=$(kubectl get ds aws-node -n kube-system -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null | awk -F= '$1=="WARM_IP_TARGET"{print $2}')
        warm_ip=$${warm_ip:-unset}
        placeable=false
        if [ "$ready_nodes" -gt 0 ]; then
          if [ "$warm_ip" != "1" ]; then
            # This apply sets one warm IP and releases the full warm ENIs first.
            placeable=true
          else
            SUBNETS=$(aws ec2 describe-instances --region "$REGION" \
              --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" "Name=instance-state-name,Values=running" \
              --query 'Reservations[].Instances[].SubnetId' --output text | tr '\t' '\n' | sort -u)
            for sn in $SUBNETS; do
              [ -n "$sn" ] && [ "$sn" != "None" ] || continue
              avail=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$sn" --query 'Subnets[0].AvailableIpAddressCount' --output text 2>/dev/null || echo 0)
              case "$avail" in
                ''|*[!0-9]*) avail=0 ;;
              esac
              if [ "$avail" -ge 1 ]; then
                placeable=true
                break
              fi
            done
          fi
        fi

        HANDLES=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null || true)
        RESIDUE=$(mktemp)
        VOLS=$(aws ec2 describe-volumes --region "$REGION" \
          --filters "Name=tag:hpb-cluster,Values=$CLUSTER" "Name=status,Values=available" \
          --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
        for v in $VOLS; do
          [ -n "$v" ] && [ "$v" != "None" ] || continue
          if ! printf '%s\n' "$HANDLES" | grep -qx "$v"; then
            orphan_volumes=$((orphan_volumes + 1))
            echo "vol $v" >> "$RESIDUE"
          fi
        done

        TAGS=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
          --resource-type-filters elasticloadbalancing:loadbalancer \
          --tag-filters "Key=kubernetes.io/cluster/$${CLUSTER},Values=owned" \
          --query 'ResourceTagMappingList[].[ResourceARN, Tags[?Key==`kubernetes.io/service-name`].Value | [0]]' \
          --output text 2>/dev/null || true)
        SEEN=$(mktemp)
        if [ -n "$TAGS" ] && [ "$TAGS" != "None" ]; then
          printf '%s\n' "$TAGS" | while read -r arn svc; do
            case "$arn" in
              arn:aws:elasticloadbalancing:*) ;;
              *) continue ;;
            esac
            case "$svc" in
              */*) ;;
              *) continue ;;
            esac
            ns=$${svc%%/*}
            name=$${svc#*/}
            if ! kubectl get svc "$name" -n "$ns" >/dev/null 2>&1; then
              echo "lb $arn" >> "$RESIDUE"
              case "$arn" in
                *:loadbalancer/net/*) echo "$arn" >> "$KCFG.orphans" ;;
              esac
            elif grep -qx "$svc" "$SEEN"; then
              echo "lb $arn" >> "$RESIDUE"
            else
              echo "$svc" >> "$SEEN"
            fi
          done || true
          if [ -s "$KCFG.orphans" ]; then
            orphan_nlbs=$(wc -l < "$KCFG.orphans" | tr -d ' ')
          fi
        fi
        rm -f "$SEEN" "$KCFG.orphans"
        if [ "$orphan_nlbs" -gt "$nlb_used" ]; then
          orphan_nlbs=$nlb_used
        fi
        if command -v sha256sum >/dev/null 2>&1; then
          residue=$(sha256sum "$RESIDUE" | awk '{print $1}')
        else
          residue=$(shasum -a 256 "$RESIDUE" | awk '{print $1}')
        fi
        rm -f "$RESIDUE"
        echo "Ready nodes: $ready_nodes. Placeable: $placeable. Orphan NLBs: $orphan_nlbs. Unattached volumes: $orphan_volumes." >&2
      fi
      rm -f "$KCFG" "$KCFG.orphans"
    fi

    printf '{"cluster_exists":"%s","nodegroup_exists":"%s","live_min":"%s","live_max":"%s","live_desired":"%s","nlb_quota_known":"%s","nlb_quota":"%s","nlb_used":"%s","nlb_need":"%s","nodes_known":"%s","ready_nodes":"%s","placeable":"%s","orphan_nlbs":"%s","orphan_volumes":"%s","residue":"%s"}\n' \
      "$cluster_exists" "$nodegroup_exists" "$live_min" "$live_max" "$live_desired" \
      "$nlb_quota_known" "$nlb_quota" "$nlb_used" "$NLB_NEED" \
      "$nodes_known" "$ready_nodes" "$placeable" "$orphan_nlbs" "$orphan_volumes" "$residue"
  EOT
  ]
}

resource "terraform_data" "preflight" {
  lifecycle {
    precondition {
      condition = (
        data.external.preflight.result.nodegroup_exists == "false" ||
        var.node_min_size <= tonumber(data.external.preflight.result.live_desired)
      )
      error_message = "EKS rejects this before any node changes. The running desired size is ${data.external.preflight.result.live_desired}, and the node group update does not change desired size in that call. node_min_size is ${var.node_min_size}, which is above ${data.external.preflight.result.live_desired}. Set node_min_size to ${data.external.preflight.result.live_desired} or lower."
    }

    precondition {
      condition = (
        data.external.preflight.result.nodegroup_exists == "false" ||
        tonumber(data.external.preflight.result.live_desired) <= var.node_max_size
      )
      error_message = "EKS rejects this before any node changes. The running desired size is ${data.external.preflight.result.live_desired}, which is above node_max_size ${var.node_max_size}. Raise node_max_size to at least ${data.external.preflight.result.live_desired}."
    }

    precondition {
      condition = (
        data.external.preflight.result.nodes_known == "false" ||
        tonumber(data.external.preflight.result.ready_nodes) > 0
      )
      error_message = "Every node is NotReady, so a pod named by this config cannot start. Re-run terraform apply after a node is Ready. Do not destroy."
    }

    precondition {
      condition     = data.external.preflight.result.placeable == "true"
      error_message = "No Ready node can take another pod address. The node subnets have no free IP and the CNI is already keeping a single warm address, so the free count is the real capacity. Free an address and re-run terraform apply. Do not destroy."
    }

    precondition {
      condition = (
        data.external.preflight.result.nlb_quota_known == "false" ||
        (tonumber(data.external.preflight.result.nlb_quota) - (tonumber(data.external.preflight.result.nlb_used) - tonumber(data.external.preflight.result.orphan_nlbs))) >= tonumber(data.external.preflight.result.nlb_need)
      )
      error_message = "Not enough network load balancers for the Services that do not exist yet. This apply still needs ${data.external.preflight.result.nlb_need}. Quota is ${data.external.preflight.result.nlb_quota}, ${data.external.preflight.result.nlb_used} are in use, and ${data.external.preflight.result.orphan_nlbs} of those belong to a Service that is already gone (this apply deletes those before creating the missing ones)."
    }
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
  # preflight fails the plan when the live node group or the NLB quota would reject the update.
  depends_on = [null_resource.wait_after_eks, null_resource.nlb_quota, terraform_data.preflight]

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
      # The module builds a custom launch template by default, and disk_size
      # is ignored in that mode. AL2023 root volume is /dev/xvda.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
      timeouts = {
        delete = "30m"
        update = "120m"
      }
    }
  }

  tags = local.common_tags
}

# The org AWS connector authenticates as this node role (InheritFromDelegate).
# The EKS worker policies do not include ec2:DescribeRegions, so the connector
# test fails. DescribeRegions is not resource-scoped.
resource "aws_iam_role_policy" "node_describe_regions" {
  name = "hpb-delegate-describe-regions"
  role = module.eks.eks_managed_node_groups["main"].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeRegions", "ec2:DescribeAvailabilityZones"]
      Resource = "*"
    }]
  })
}

# Fail before the node-group update if this region cannot hold one network
# load balancer for frontend, gateway-service-external, Prometheus, and
# Grafana in every namespace. Classic ELB quota is 20; 10 namespaces need 40
# NLBs, so the Services are NLBs.
resource "null_resource" "nlb_quota" {
  triggers = {
    region          = var.aws_region
    namespace_count = tostring(var.namespace_count)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION=${jsonencode(var.aws_region)}
      CLUSTER=${jsonencode(var.cluster_name)}
      PREFIX=${jsonencode(var.namespace_prefix)}
      COUNT=${var.namespace_count}
      NEED=$((COUNT * ${local.nlb_per_namespace}))
      KCFG=$(mktemp)
      if aws eks update-kubeconfig --kubeconfig "$KCFG" --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 \
        && command -v kubectl >/dev/null 2>&1; then
        KUBECONFIG="$KCFG"
        export KUBECONFIG
        NEED=0
        for i in $(seq 1 "$COUNT"); do
          ns="$${PREFIX}-$${i}"
          for svc in ${local.lb_services_shell}; do
            typ=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.spec.type}' 2>/dev/null || true)
            if [ "$typ" != "LoadBalancer" ]; then
              NEED=$((NEED + 1))
            fi
          done
        done
      fi
      rm -f "$KCFG"
      QUOTA=$(aws service-quotas get-service-quota \
        --service-code elasticloadbalancing \
        --quota-code L-69A177A2 \
        --region "$REGION" \
        --query 'Quota.Value' --output text 2>/dev/null || true)
      if [ -z "$QUOTA" ] || [ "$QUOTA" = "None" ]; then
        echo "Could not read the NLB quota; continuing. This apply still needs $NEED network load balancers."
        exit 0
      fi
      QUOTA_INT="$${QUOTA%%.*}"
      USED=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "length(LoadBalancers[?Type=='network'])" --output text)
      FREE=$(( QUOTA_INT - USED ))
      echo "NLB quota $QUOTA_INT, in use $USED, free $FREE, still to create $NEED"
      if [ "$FREE" -lt "$NEED" ]; then
        echo "Not enough free network load balancers in $REGION for the Services that do not exist yet."
        exit 1
      fi
    EOT
  }
}

# The EKS module ignores scaling_config.desired_size on update, and EKS
# rejects a minimum above the live desired count. Terraform therefore only
# raises max_size here. This step then raises desired, after max is already
# high enough (desired 12 is illegal while max is still 8).
resource "null_resource" "scale_nodegroup" {
  triggers = {
    cluster  = module.eks.cluster_name
    region   = var.aws_region
    desired  = tostring(var.node_desired_size)
    max_size = tostring(var.node_max_size)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION=${jsonencode(var.aws_region)}
      CLUSTER=${jsonencode(module.eks.cluster_name)}
      TARGET=${var.node_desired_size}
      NGS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups' --output text)
      for NG in $NGS; do
        case "$NG" in
          main-*) ;;
          *) continue ;;
        esac
        echo "Waiting for node group $NG to be ACTIVE before changing its desired size"
        aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name "$NG" --region "$REGION"
        SCALING=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --region "$REGION" --query 'nodegroup.scalingConfig.[minSize,maxSize,desiredSize]' --output text)
        MIN=$(echo "$SCALING" | awk '{print $1}')
        MAX=$(echo "$SCALING" | awk '{print $2}')
        DESIRED=$(echo "$SCALING" | awk '{print $3}')
        echo "Node group $NG scaling min=$MIN max=$MAX desired=$DESIRED target=$TARGET"
        if [ "$DESIRED" -eq "$TARGET" ]; then
          echo "Desired size is already $TARGET"
          continue
        fi
        if [ "$TARGET" -gt "$MAX" ]; then
          echo "Refusing to set desired $TARGET above live max $MAX on $NG"
          exit 1
        fi
        if [ "$TARGET" -lt "$MIN" ]; then
          echo "Refusing to set desired $TARGET below live min $MIN on $NG"
          exit 1
        fi
        aws eks update-nodegroup-config \
          --cluster-name "$CLUSTER" \
          --nodegroup-name "$NG" \
          --region "$REGION" \
          --scaling-config "minSize=$MIN,maxSize=$MAX,desiredSize=$TARGET"
        aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name "$NG" --region "$REGION"
        echo "Node group $NG desired size is $TARGET"
      done
    EOT
  }

  depends_on = [module.eks]
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
      ${local.kubeconfig}
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
      ${local.kubeconfig}

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
    null_resource.scale_nodegroup,
    kubernetes_storage_class_v1.gp3,
    null_resource.unset_gp2_default,
  ]
}

# Default VPC CNI keeps a spare ENI (15 addresses) on every node. The private
# subnets are /24, so that spare pool fills the subnet while nodes still report
# free pod slots. One warm address lets the next pod take a real free IP.
resource "null_resource" "vpc_cni_warm_ip" {
  triggers = {
    cluster = module.eks.cluster_name
    warm    = "1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.kubeconfig}
      if ! kubectl get ds aws-node -n kube-system >/dev/null 2>&1; then
        echo "aws-node is not installed; pods cannot get addresses"
        exit 1
      fi
      current=$(kubectl get ds aws-node -n kube-system -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | awk -F= '$1=="WARM_IP_TARGET"{print $2}')
      if [ "$current" = "1" ]; then
        echo "aws-node WARM_IP_TARGET is already 1"
        exit 0
      fi
      echo "Setting aws-node WARM_IP_TARGET=1 before workloads are applied"
      kubectl set env daemonset/aws-node -n kube-system WARM_IP_TARGET=1
      kubectl rollout status daemonset/aws-node -n kube-system --timeout=180s
    EOT
  }

  depends_on = [null_resource.wait_ebs_csi]
}

# A failed apply can leave a balancer whose Service is gone, or an EBS volume
# no PV still points at. Both keep costing money and both count against the
# quota the next apply needs. Same names are never created twice; this only
# removes what the cluster no longer references.
resource "null_resource" "reclaim_residue" {
  triggers = {
    cluster = module.eks.cluster_name
    residue = data.external.preflight.result.residue
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.kubeconfig}
      REGION=${jsonencode(var.aws_region)}
      CLUSTER=${jsonencode(var.cluster_name)}
      if ! kubectl get ns kube-system >/dev/null 2>&1; then
        echo "Cannot list the cluster; leaving AWS resources alone"
        exit 0
      fi

      delete_lb() {
        local arn="$1" name
        case "$arn" in
          *:loadbalancer/net/*|*:loadbalancer/app/*)
            echo "Deleting leftover balancer $arn"
            aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" || true
            ;;
          *)
            name=$(printf '%s' "$arn" | awk -F/ '{print $NF}')
            echo "Deleting leftover classic balancer $name"
            aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name" || true
            ;;
        esac
      }

      TAGS=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
        --resource-type-filters elasticloadbalancing:loadbalancer \
        --tag-filters "Key=kubernetes.io/cluster/$${CLUSTER},Values=owned" \
        --query 'ResourceTagMappingList[].[ResourceARN, Tags[?Key==`kubernetes.io/service-name`].Value | [0]]' \
        --output text 2>/dev/null || true)
      if [ -n "$TAGS" ] && [ "$TAGS" != "None" ]; then
        pairs=$(mktemp)
        printf '%s\n' "$TAGS" > "$pairs"
        awk '{print $2}' "$pairs" | sort -u | while read -r svc; do
          case "$svc" in
            */*) ;;
            *) continue ;;
          esac
          ns=$${svc%%/*}
          name=$${svc#*/}
          arn_list=$(awk -v s="$svc" '$2==s {print $1}' "$pairs")
          if ! kubectl get svc "$name" -n "$ns" >/dev/null 2>&1; then
            for arn in $arn_list; do
              delete_lb "$arn"
            done
            continue
          fi
          n=0
          for arn in $arn_list; do
            n=$((n + 1))
          done
          [ "$n" -le 1 ] && continue
          host=$(kubectl get svc "$name" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
          host=$${host%.}
          keep=""
          keep_time=""
          for arn in $arn_list; do
            case "$arn" in
              *:loadbalancer/net/*|*:loadbalancer/app/*)
                meta=$(aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$arn" --query 'LoadBalancers[0].[DNSName,CreatedTime]' --output text 2>/dev/null || true)
                ;;
              *)
                lbname=$(printf '%s' "$arn" | awk -F/ '{print $NF}')
                meta=$(aws elb describe-load-balancers --region "$REGION" --load-balancer-names "$lbname" --query 'LoadBalancerDescriptions[0].[DNSName,CreatedTime]' --output text 2>/dev/null || true)
                ;;
            esac
            dns=$(printf '%s' "$meta" | awk '{print $1}')
            ts=$(printf '%s' "$meta" | awk '{print $2}')
            dns=$${dns%.}
            if [ -n "$host" ] && [ "$dns" = "$host" ]; then
              keep="$arn"
            fi
            if [ -z "$keep" ] || [[ "$ts" < "$keep_time" ]]; then
              if [ -z "$host" ] || [ -z "$keep" ]; then
                keep="$arn"
                keep_time="$ts"
              fi
            fi
          done
          for arn in $arn_list; do
            [ "$arn" = "$keep" ] && continue
            delete_lb "$arn"
          done
        done
        rm -f "$pairs"
      fi

      TGS=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
        --resource-type-filters elasticloadbalancing:targetgroup \
        --tag-filters "Key=kubernetes.io/cluster/$${CLUSTER},Values=owned" \
        --query 'ResourceTagMappingList[].[ResourceARN, Tags[?Key==`kubernetes.io/service-name`].Value | [0]]' \
        --output text 2>/dev/null || true)
      if [ -n "$TGS" ] && [ "$TGS" != "None" ]; then
        printf '%s\n' "$TGS" | while read -r arn svc; do
          [ -n "$arn" ] && [ "$arn" != "None" ] || continue
          case "$svc" in
            */*) ;;
            *) continue ;;
          esac
          ns=$${svc%%/*}
          name=$${svc#*/}
          if ! kubectl get svc "$name" -n "$ns" >/dev/null 2>&1; then
            echo "Deleting leftover target group $arn"
            aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" 2>/dev/null || true
          fi
        done
      fi

      HANDLES=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null || true)
      VOLS=$(aws ec2 describe-volumes --region "$REGION" \
        --filters "Name=tag:hpb-cluster,Values=$CLUSTER" "Name=status,Values=available" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
      for v in $VOLS; do
        [ -n "$v" ] && [ "$v" != "None" ] || continue
        if ! printf '%s\n' "$HANDLES" | grep -qx "$v"; then
          echo "Deleting unattached volume $v"
          aws ec2 delete-volume --region "$REGION" --volume-id "$v" || true
        fi
      done
    EOT
  }

  depends_on = [null_resource.wait_ebs_csi]
}

# -----------------------------------------------------------------------------
# 4. Namespaces — prefix-1 .. prefix-N
# -----------------------------------------------------------------------------

# Destroyed before the namespace. Deleting the namespace object while its
# LoadBalancer Services still exist leaves the NLBs and their security groups
# behind. This removes those Services first and waits until the hostnames are
# gone. It does not run on a full cluster destroy; destroy_lb_drain does that.
resource "null_resource" "namespace_loadbalancers" {
  for_each = var.manage_namespaces ? toset(local.namespace_names) : toset([])

  triggers = {
    namespace    = each.value
    aws_region   = var.aws_region
    cluster_name = var.cluster_name
  }

  depends_on = [
    kubernetes_namespace_v1.banking,
    null_resource.hpb_apply,
    null_resource.wait_for_lbs,
  ]

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION="${self.triggers.aws_region}"
      CLUSTER="${self.triggers.cluster_name}"
      NS="${self.triggers.namespace}"
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1 || exit 0
      kubectl get ns "$NS" >/dev/null 2>&1 || exit 0
      kubectl get svc -n "$NS" -o json | python3 -c '
import json,sys
data=json.load(sys.stdin)
for item in data.get("items") or []:
    if (item.get("spec") or {}).get("type")=="LoadBalancer":
        print(item["metadata"]["name"])
' | while read -r svc; do
        [ -n "$svc" ] || continue
        echo "Deleting LoadBalancer service $NS/$svc"
        kubectl delete svc "$svc" -n "$NS" --wait=true --timeout=180s || true
      done
    EOT
  }
}

resource "kubernetes_namespace_v1" "banking" {
  for_each = var.manage_namespaces ? toset(local.namespace_names) : toset([])

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
    lb_type        = "nlb"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.kubeconfig} >/dev/null
      ${local.kubectl_apply_helpers}
      WORK=$(mktemp -d)
      trap 'rm -rf "$WORK"' EXIT
      # One apply of the shared ClusterRole. Per-namespace applies omit it so
      # ten parallel applies do not race on AlreadyExists. Skip the manifest
      # ClusterRoleBinding (it targets namespace "banking").
      keep_cluster_scoped "${local.manifests_abs}/prometheus.yaml" "$WORK/cluster-all.yaml"
      keep_kind "$WORK/cluster-all.yaml" ClusterRole "$WORK/cluster.yaml"
      if [ -s "$WORK/cluster.yaml" ]; then
        echo "Applying cluster-scoped Prometheus ClusterRole once"
        apply_ignore_exists "$WORK/cluster.yaml"
      fi
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
    manifests_hash = local.manifests_hash
    lb_type        = "nlb"
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

      ${local.kubeconfig}
      ${local.kubectl_apply_helpers}

      # Vendored YAML stays untouched. Copy it and annotate the
      # LoadBalancer Services as NLBs before they are created. Classic ELB
      # quota (20) cannot hold 10 namespaces x 4 balancers.
      WORK=$(mktemp -d)
      trap 'rm -rf "$WORK"' EXIT
      cp -R "$DIR/." "$WORK/"
      patch_nlb() {
        awk '
          /^---$/ { in_svc=0; in_meta=0; injected=0 }
          /^kind: Service$/ { in_svc=1 }
          in_svc && /^metadata:$/ { in_meta=1 }
          in_svc && in_meta && /^spec:$/ && !injected {
            print "  annotations:"
            print "    service.beta.kubernetes.io/aws-load-balancer-type: nlb"
            injected=1
          }
          { print }
        ' "$1" > "$2"
      }
      for f in ${local.lb_manifest_files_shell}; do
        patch_nlb "$DIR/$f" "$WORK/$f"
      done
      for f in "$WORK"/*.yaml "$WORK"/*.yml; do
        [ -f "$f" ] || continue
        tmp=$(mktemp)
        drop_cluster_scoped "$f" "$tmp"
        if [ -s "$tmp" ]; then
          mv "$tmp" "$f"
        else
          rm -f "$tmp" "$f"
        fi
      done
      # Same names are updated in place. An existing Service keeps its balancer
      # so a retry cannot create a second one beside it.
      keep_existing_balancer "$WORK/frontend-service.yaml" "$NS" frontend-service
      keep_existing_balancer "$WORK/gateway-service-external.yaml" "$NS" gateway-service-external
      keep_existing_balancer "$WORK/prometheus.yaml" "$NS" prometheus
      keep_existing_balancer "$WORK/grafana-all-in-one.yaml" "$NS" grafana

      # Secrets/config/PVCs first so StatefulSets always have a claim to bind.
      apply_with_repair "$WORK/secrets.yaml" "$NS" "$WORK"
      apply_with_repair "$WORK/configmap.yaml" "$NS" "$WORK"
      apply_with_repair "$WORK/persistent-volumes.yaml" "$NS" "$WORK"

      if ! apply_with_repair "$WORK" "$NS" "$WORK"; then
        echo "apply failed for namespace $NS"
        exit 1
      fi
      drop_orphan_balancers "$NS" ${jsonencode(var.aws_region)}

      for kind in "secret/banking-secrets" "pvc/postgresql-pvc" "pvc/mongodb-pvc" "pvc/kafka-pvc" "statefulset/postgresql" "statefulset/mongodb" "statefulset/kafka" "deployment/grafana" "deployment/load-generator" "svc/gateway-service-external" "svc/grafana" "svc/prometheus"; do
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
    null_resource.vpc_cni_warm_ip,
    null_resource.reclaim_residue,
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

      ${local.kubeconfig}
      ${local.kubectl_apply_helpers}

      fail_ns() {
        echo "[$NS] $*"
        kubectl get pods,pvc,sts,deploy -n "$NS" || true
        kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -n 40 || true
        exit 1
      }

      ensure_data_manifests() {
        apply_with_repair "$DIR/secrets.yaml" "$NS" "$DIR" >/dev/null
        apply_with_repair "$DIR/persistent-volumes.yaml" "$NS" "$DIR" >/dev/null
        apply_with_repair "$DIR/postgresql.yaml" "$NS" "$DIR" >/dev/null
        apply_with_repair "$DIR/mongodb.yaml" "$NS" "$DIR" >/dev/null
        apply_with_repair "$DIR/kafka.yaml" "$NS" "$DIR" >/dev/null
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
# ClusterRole is applied once. Manifests hardcode namespace "banking" in
# service discovery and the ClusterRoleBinding. Add one uniquely named
# binding per namespace and rewrite only the live ConfigMap.

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
    rbac_version         = "v3-crb-replace"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      TMP=$(mktemp -d)
      trap 'rm -rf "$TMP"' EXIT

      ${local.kubeconfig}
      ${local.kubectl_apply_helpers}

      keep_cluster_scoped "${local.manifests_abs}/prometheus.yaml" "$TMP/cluster-all.yaml"
      keep_kind "$TMP/cluster-all.yaml" ClusterRole "$TMP/clusterrole.yaml"
      if [ -s "$TMP/clusterrole.yaml" ]; then
        apply_ignore_exists "$TMP/clusterrole.yaml"
      fi

      # Manifest CRB is named "prometheus" and targets namespace "banking".
      # Replace it with one binding per real namespace.
      kubectl delete clusterrolebinding "${local.prometheus_cluster_role}" --ignore-not-found=true
      kubectl delete clusterrolebinding "${local.prometheus_cluster_role}-${each.value}" --ignore-not-found=true
      kubectl create clusterrolebinding "${local.prometheus_cluster_role}-${each.value}" \
        --clusterrole="${local.prometheus_cluster_role}" \
        --serviceaccount="${each.value}:${local.prometheus_service_account}" \
        --dry-run=client -o yaml > "$TMP/crb.yaml"
      apply_ignore_exists "$TMP/crb.yaml"

      kubectl get configmap "${local.prometheus_config_map}" \
        --namespace "${each.value}" \
        --output go-template='{{index .data "prometheus.yml"}}' \
        > "$TMP/prometheus.yml"

      sed "s/^\\([[:space:]]*- \\)${local.prometheus_manifest_namespace}$/\\1${each.value}/" \
        "$TMP/prometheus.yml" > "$TMP/prometheus-updated.yml"

      kubectl create configmap "${local.prometheus_config_map}" \
        --namespace "${each.value}" \
        --from-file=prometheus.yml="$TMP/prometheus-updated.yml" \
        --dry-run=client -o yaml | kubectl apply --validate=false -f -

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
      ${local.kubeconfig}
      NS="${each.value}"
      for svc in ${local.lb_services_shell}; do
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
    name      = local.gateway_external_service
    namespace = each.value
  }
}

data "kubernetes_service_v1" "grafana" {
  for_each   = local.deploy_namespaces
  depends_on = [null_resource.wait_for_lbs]

  metadata {
    name      = local.grafana_service
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
      ${local.kubeconfig}
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
# Frontend / gateway-service-external / prometheus / grafana Services create NLBs and k8s-elb
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
    kubernetes_storage_class_v1.gp3,
    null_resource.scale_nodegroup,
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

        # Order: Service (releases the AWS balancer) -> RoleBinding -> Role ->
        # namespace -> Released PV. A namespace delete blocks on a Service
        # finalizer, and a ClusterRole cannot go while a binding still points
        # at it.
        for ns in $NS_LIST; do
          echo "Deleting LoadBalancer Services in $ns"
          kubectl delete svc -n "$ns" --field-selector spec.type=LoadBalancer --wait=false --ignore-not-found=true || true
        done
        for i in $(seq 1 36); do
          left=""
          for ns in $NS_LIST; do
            got=$(kubectl get svc -n "$ns" --field-selector spec.type=LoadBalancer -o name 2>/dev/null || true)
            [ -n "$got" ] && left="$left $ns"
          done
          [ -z "$left" ] && break
          echo "Waiting for LoadBalancer Services to go away:$left"
          sleep 10
        done

        for ns in $NS_LIST; do
          kubectl delete clusterrolebinding "prometheus-$ns" --ignore-not-found=true || true
        done
        kubectl delete clusterrolebinding prometheus --ignore-not-found=true || true
        kubectl delete clusterrole prometheus --ignore-not-found=true || true

        for ns in $NS_LIST; do
          echo "Deleting namespace $ns"
          kubectl delete namespace "$ns" --ignore-not-found=true --wait=true --timeout=25m || true
        done

        kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.phase}{","}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null \
          | while IFS=, read -r pv phase claim_ns; do
              [ "$phase" = "Released" ] || [ "$phase" = "Failed" ] || continue
              for ns in $NS_LIST; do
                if [ "$claim_ns" = "$ns" ]; then
                  echo "Deleting $phase persistent volume $pv from $ns"
                  kubectl delete pv "$pv" --wait=false --ignore-not-found=true || true
                fi
              done
            done || true
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

        TGS=$(aws elbv2 describe-target-groups \
          --query "TargetGroups[?VpcId=='$VPC'].TargetGroupArn" \
          --output text 2>/dev/null || true)
        for tg in $TGS; do
          if [ -n "$tg" ] && [ "$tg" != "None" ]; then
            echo "Deleting target group $tg"
            aws elbv2 delete-target-group --target-group-arn "$tg" 2>/dev/null || true
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
        TAGGED_SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=tag-key,Values=kubernetes.io/service-name" \
          --query "SecurityGroups[].GroupId" --output text 2>/dev/null || true)
        SGS="$SGS $TAGGED_SGS"
        if [ -z "$SGS" ] || [ "$SGS" = "None" ]; then
          break
        fi
        for sg in $SGS; do
          [ -z "$sg" ] || [ "$sg" = "None" ] && continue
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
  # range() order, not sort(). sort() places banking-10 before banking-2.
  value = [
    for ns in local.namespace_names : ns
    if contains(keys(kubernetes_namespace_v1.banking), ns)
  ]
}

output "service_endpoints" {
  description = "Frontend / gateway / prometheus / grafana URLs per namespace"
  value       = local.service_endpoints
}

output "kubeconfig_command" {
  value     = local.kubeconfig
  sensitive = true
}
