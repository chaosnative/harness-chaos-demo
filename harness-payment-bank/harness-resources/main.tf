# =============================================================================
# main.tf — org workshop → templates → team projects → delegate → connectors
# =============================================================================
# Single Terraform root. Only this file and variables.tf are Terraform language.
#
# Order:
#   1. Read infrastructure remote state (cluster + banking-N) unless overridden
#   2. Organization workshop
#   3. Org experiment templates on existing custom-hub-workshop (gated; no new hub)
#   4. Projects team-N (one per namespace banking-N)
#   5. Org delegate token + Helm on EKS; wait for registration
#   6. Optional org AWS connector
#   7. Per project: K8s connector, Prometheus, environment, infra, discovery,
#      chaos v2, experiment import from a chaos hub template (if ids are set)
#
# Connector "templates" are not created here. Harness NG template types do not
# include Connector (only Step, Stage, Pipeline, …). Connectors are created
# with harness_platform_connector_* (InheritFromDelegate).
# Chaos experiment templates live on the existing org hub custom-hub-workshop
# (data.harness_chaos_hub_v2). Identities match PnC / the live hub so apply
# updates in place. Do not create a second hub.
#
# Failure / retry: do not terraform destroy this root on error. Re-run apply.
# Resources already in state are left alone; missing ones are created.
# Harness TerraformApply runs `terraform refresh` as its own command.
# TF_CLI_ARGS_apply does not skip that. On TerraformApply_2 enable
# "Skip Refresh Command" (skipRefreshCommand: true) until this apply succeeds.
# Helm is non-atomic so a timed-out delegate is upgraded in place on retry.
# upgrade_install adopts a cluster release that is not in Terraform state
# (previous apply installed Helm, then failed before state was saved).
# CD infra identifier is used as Helm release stem event-watcher-<infra_id>.
# Harness IDs forbid hyphens; Helm forbids underscores. Use lowercase
# alphanumeric only (e.g. hpbk8s).
#
# Docs:
#   https://registry.terraform.io/providers/harness/harness/latest/docs
#   https://developer.harness.io/docs/resilience-testing/platform-features/terraform-onboarding

terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "hpb-demo-tfstate-naren"
    key          = "hpb-harness/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    harness = {
      source  = "harness/harness"
      version = "~> 0.45"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
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

# PAT (HARNESS_PLATFORM_API_KEY) must be issued in this same account.
provider "harness" {
  endpoint   = var.harness_gateway_endpoint
  account_id = var.account_id
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_eks_cluster.this.name,
      "--region", var.aws_region,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", data.aws_eks_cluster.this.name,
        "--region", var.aws_region,
      ]
    }
  }
}

locals {
  infra_state_needed = var.cluster_name == "" || length(var.namespaces) == 0
}

data "terraform_remote_state" "infra" {
  count = local.infra_state_needed ? 1 : 0

  backend = "s3"
  config = {
    bucket = "hpb-demo-tfstate-naren"
    key    = "hpb-eks/terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

locals {
  prefix_id = replace(var.resource_prefix, "-", "_")
  org_id    = var.org_id
  org_name  = var.org_name != "" ? var.org_name : var.org_id
  tags      = var.tags

  generated_namespaces = [for i in range(1, var.namespace_count + 1) : "${var.namespace_prefix}-${i}"]
  namespaces = length(var.namespaces) > 0 ? var.namespaces : coalesce(
    try(data.terraform_remote_state.infra[0].outputs.namespaces, null),
    local.generated_namespaces,
  )
  cluster_name = var.cluster_name != "" ? var.cluster_name : data.terraform_remote_state.infra[0].outputs.cluster_name

  delegate_name       = var.delegate_name != "" ? var.delegate_name : "${var.resource_prefix}-workshop-delegate"
  delegate_token_name = var.delegate_token_name != "" ? var.delegate_token_name : "${var.resource_prefix}-workshop-delegate-token"
  delegate_token      = var.decode_delegate_token ? base64decode(harness_platform_delegatetoken.this.value) : harness_platform_delegatetoken.this.value

  k8s_connector_id       = var.k8s_connector_id != "" ? var.k8s_connector_id : "${local.prefix_id}_eks"
  k8s_connector_name     = var.k8s_connector_name != "" ? var.k8s_connector_name : local.k8s_connector_id
  aws_connector_id       = var.aws_connector_id != "" ? var.aws_connector_id : "${local.prefix_id}_aws"
  aws_connector_name     = var.aws_connector_name != "" ? var.aws_connector_name : local.aws_connector_id
  prometheus_id_prefix   = var.prometheus_connector_id_prefix != "" ? var.prometheus_connector_id_prefix : "${local.prefix_id}_prometheus"
  prometheus_name_prefix = var.prometheus_connector_name_prefix != "" ? var.prometheus_connector_name_prefix : "${var.resource_prefix}-prometheus"

  environment_id   = var.environment_id != "" ? var.environment_id : local.prefix_id
  environment_name = var.environment_name != "" ? var.environment_name : local.environment_id
  # A STEM, not a full identifier. The per-project suffix is added in
  # local.projects. Four projects sharing one infra identifier also share one
  # discovery agent identity, and the agent identity is what names the
  # collector objects the delegate installs — so four agents were installing
  # and uninstalling the same objects in the same namespace, cancelling each
  # other out. Must stay lowercase alphanumeric: it becomes a Helm release
  # stem (event-watcher-<infra_id>), and Harness IDs forbid hyphens while Helm
  # forbids underscores.
  infra_id_stem         = var.infra_id != "" ? var.infra_id : "${replace(var.resource_prefix, "-", "")}k8s"
  infra_name            = var.infra_name != "" ? var.infra_name : "${var.resource_prefix}-k8s"
  discovery_name_prefix = var.discovery_agent_name_prefix != "" ? var.discovery_agent_name_prefix : "${var.resource_prefix}-discovery"
  chaos_name_prefix     = var.chaos_infra_name_prefix != "" ? var.chaos_infra_name_prefix : "${var.resource_prefix}-chaos"

  team_prefix_id   = var.project_identifier_prefix != "" ? var.project_identifier_prefix : "team"
  team_prefix_name = var.project_name_prefix != "" ? var.project_name_prefix : "team"

  org_identifier = var.create_organization ? harness_platform_organization.this[0].identifier : data.harness_platform_organization.this[0].identifier

  discovery_install_ns = (
    var.discovery_install_namespace != ""
    ? var.discovery_install_namespace
    : var.delegate_namespace
  )

  ns_index = {
    for ns in local.namespaces : ns => (
      can(regex("[0-9]+$", ns)) ? regex("[0-9]+$", ns) : replace(ns, "-", "_")
    )
  }

  projects = {
    for ns in local.namespaces : ns => {
      namespace  = ns
      index      = local.ns_index[ns]
      identifier = coalesce(try(var.project_overrides[ns].identifier, null), "${local.team_prefix_id}_${local.ns_index[ns]}")
      name       = coalesce(try(var.project_overrides[ns].name, null), "${local.team_prefix_name}-${local.ns_index[ns]}")
      # ns_index falls back to the namespace with hyphens turned into
      # underscores when it does not end in digits, and an underscore here
      # would produce an invalid Helm release stem. Strip to alphanumerics.
      infra_id = "${local.infra_id_stem}${lower(replace(local.ns_index[ns], "/[^0-9A-Za-z]/", ""))}"
    }
  }
}

# The namespace list from infrastructure state wins over namespace_count.
# Fail here when that list is still the old shorter set, and when banking-10
# would not become team_10 / hpbk8s10. regex [0-9]+$ is what keeps the 10.
resource "terraform_data" "namespace_layout" {
  lifecycle {
    precondition {
      condition     = !var.manage_team_projects || length(var.namespaces) > 0 || length(local.namespaces) == var.namespace_count
      error_message = "This root is set for ${var.namespace_count} namespaces, but it will use ${length(local.namespaces)} (${join(", ", local.namespaces)}). Apply infrastructure first so its state lists ${var.namespace_prefix}-1 through ${var.namespace_prefix}-${var.namespace_count}, or pass namespaces explicitly."
    }

    precondition {
      condition = !var.manage_team_projects || (!contains(keys(local.projects), "${var.namespace_prefix}-10") ? var.namespace_count < 10 : (
        local.projects["${var.namespace_prefix}-10"].identifier == "${local.team_prefix_id}_10" &&
        local.projects["${var.namespace_prefix}-10"].name == "${local.team_prefix_name}-10" &&
        local.projects["${var.namespace_prefix}-10"].infra_id == "${local.infra_id_stem}10"
      ))
      error_message = "${var.namespace_prefix}-10 must be project ${local.team_prefix_id}_10 / ${local.team_prefix_name}-10 with infrastructure ${local.infra_id_stem}10."
    }
  }
}

# -----------------------------------------------------------------------------
# Organization
# -----------------------------------------------------------------------------

resource "harness_platform_organization" "this" {
  count = var.create_organization ? 1 : 0

  identifier  = local.org_id
  name        = local.org_name
  description = var.org_description
  tags        = local.tags
}

data "harness_platform_organization" "this" {
  count = var.create_organization ? 0 : 1

  identifier = local.org_id
}

# -----------------------------------------------------------------------------
# Org ChaosHub copy
# The hub already exists (custom-hub-workshop). Apply copies faults, probes,
# actions, and experiment templates from the PnC hub through the chaos API.
# Tokens stay in memory. It does not delete them. Deleting the organization
# deletes the hub, so manage_team_projects=false is how projects go away
# while the org and these templates stay.
# -----------------------------------------------------------------------------

locals {
  chaos_hub_name = var.chaos_hub_name != "" ? var.chaos_hub_name : var.chaos_hub_identity
  chaos_hub_ref  = "org.${var.chaos_hub_identity}"
  # Per-project connector id is hpb_prometheus_team_1 (name hpb-prometheus-team-1).
  # Org hub templates cannot bake one of those IDs. PnC kafka probes use <+input>;
  # workshop avg-cpu does the same because Prometheus is project-scoped.
  chaos_prom_connector = "<+input>"

  # Team projects are destroyed by apply when this is false. The org and the
  # chaos templates stay. See manage_team_projects.
  active_projects = var.manage_team_projects ? local.projects : {}

}

# Harness creates custom-hub-workshop itself when the organization is created.
# A lookup before that organization exists returns 500 "failed to get chaos hub".
# This waits until that lookup succeeds, then the data source below reads it.
resource "null_resource" "chaos_hub_ready" {
  count = var.create_org_chaos_templates ? 1 : 0

  triggers = {
    org = local.org_identifier
    hub = var.chaos_hub_identity
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KEY="$${HARNESS_PLATFORM_API_KEY:-$${HARNESS_API_KEY:-}}"
      if [ -z "$KEY" ]; then
        echo "Set HARNESS_PLATFORM_API_KEY or HARNESS_API_KEY before reading the chaos hub."
        exit 1
      fi
      ENDPOINT=${jsonencode(var.harness_gateway_endpoint)}
      ENDPOINT="$${ENDPOINT%/}"
      ACCT=${jsonencode(var.account_id)}
      ORG=${jsonencode(local.org_identifier)}
      HUB=${jsonencode(var.chaos_hub_identity)}
      URL="$ENDPOINT/chaos/manager/api/rest/hubs/$HUB?accountIdentifier=$ACCT&organizationIdentifier=$ORG"
      for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w "%%{http_code}" "$URL" -H "x-api-key: $KEY" || echo 000)
        if [ "$code" = "200" ]; then
          echo "Chaos hub $HUB is ready in $ORG"
          exit 0
        fi
        echo "Waiting for chaos hub $HUB (HTTP $code)"
        sleep 2
      done
      echo "Chaos hub $HUB was not readable in $ORG"
      exit 1
    EOT
  }

  depends_on = [harness_platform_organization.this]
}

data "harness_chaos_hub_v2" "org" {
  count = var.create_org_chaos_templates ? 1 : 0

  org_id   = local.org_identifier
  identity = var.chaos_hub_identity

  depends_on = [null_resource.chaos_hub_ready]
}

# Copy the live PnC ChaosHub onto custom-hub-workshop. Destroy does not
# delete the copied objects. Deleting the organization would, because the
# hub is removed with the org. Use manage_team_projects = false instead.
resource "terraform_data" "chaos_templates" {
  count = var.create_org_chaos_templates ? 1 : 0

  triggers_replace = {
    script      = filesha256("${path.module}/sync_chaos_templates.py")
    hub         = var.chaos_hub_identity
    org         = local.org_identifier
    source_org  = var.source_chaos_org_id
    source_hub  = var.source_chaos_hub_identity
  }

  provisioner "local-exec" {
    command = "python3 ${path.module}/sync_chaos_templates.py"
    environment = {
      HARNESS_ACCOUNT_ID   = var.account_id
      HARNESS_ORG_ID       = local.org_identifier
      HARNESS_HUB_IDENTITY = var.chaos_hub_identity
      HARNESS_ENDPOINT     = var.harness_gateway_endpoint
      SOURCE_ORG_ID        = var.source_chaos_org_id
      SOURCE_HUB           = var.source_chaos_hub_identity
    }
  }

  depends_on = [data.harness_chaos_hub_v2.org]
}

# Drop the provider-managed copies without deleting the hub objects. The
# sync above owns them. A destroy of these resources would wipe the templates
# the workshop keeps when projects are removed.
removed {
  from = harness_chaos_experiment_template.this
  lifecycle {
    destroy = false
  }
}

removed {
  from = harness_chaos_probe_template.http
  lifecycle {
    destroy = false
  }
}

removed {
  from = harness_chaos_probe_template.prom
  lifecycle {
    destroy = false
  }
}

removed {
  from = harness_chaos_action_template.delay
  lifecycle {
    destroy = false
  }
}

# Destroyed before templates, environments, and connectors. Harness rejects
# those deletes while a project experiment, chaos infrastructure, or discovery
# agent still points at them. The list payloads do not use "identity" for the
# id that DELETE accepts: experiments use experimentID, chaos infrastructures
# use environmentID + identity. CD infrastructures stay for the provider so a
# second delete does not 404; the environment provisioner removes any orphan
# the provider no longer has in state.
resource "null_resource" "chaos_experiments_in_projects" {
  triggers = {
    endpoint = var.harness_gateway_endpoint
    account  = var.account_id
    org      = local.org_identifier
    projects = join(" ", [for p in local.active_projects : p.identifier])
  }

  # Destroyed first, including after an aborted destroy. Same names are deleted
  # again; a 404 means that object is already gone.
  depends_on = [
    harness_platform_project.this,
    terraform_data.chaos_templates,
    harness_service_discovery_agent.agent,
    harness_platform_infrastructure.this,
    harness_platform_environment.this,
    harness_platform_connector_kubernetes.eks,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KEY="$${HARNESS_PLATFORM_API_KEY:-$${HARNESS_API_KEY:-}}"
      if [ -z "$KEY" ]; then
        echo "Set HARNESS_PLATFORM_API_KEY or HARNESS_API_KEY so project resources can be deleted in order."
        exit 1
      fi
      ENDPOINT="${self.triggers.endpoint}"
      ENDPOINT="$${ENDPOINT%/}"
      ACCT="${self.triggers.account}"
      ORG="${self.triggers.org}"
      CHAOS="$ENDPOINT/chaos/manager/api"
      SD="$ENDPOINT/servicediscovery"
      NG="$ENDPOINT/ng/api"
      SCOPE="$${TMPDIR:-/tmp}/hpb-$${ORG}-destroy-scope"
      umask 077
      printf 'endpoint=%s\naccount=%s\norg=%s\n' "$ENDPOINT" "$ACCT" "$ORG" > "$SCOPE"

      http() {
        local method="$1" url="$2" body="$${3:-}" tmp code
        tmp=$(mktemp)
        if [ -n "$body" ]; then
          code=$(curl -sS -o "$tmp" -w "%%{http_code}" -X "$method" "$url" \
            -H "x-api-key: $KEY" -H "Content-Type: application/json" -d "$body" || echo 000)
        else
          code=$(curl -sS -o "$tmp" -w "%%{http_code}" -X "$method" "$url" \
            -H "x-api-key: $KEY" -H "Content-Type: application/json" || echo 000)
        fi
        HTTP_CODE="$code"
        HTTP_BODY=$(cat "$tmp")
        rm -f "$tmp"
      }

      gone() {
        case "$HTTP_CODE" in
          200|201|204|404) return 0 ;;
        esac
        printf '%s' "$HTTP_BODY" | grep -qiE 'not found|does not exist|already deleted|no matching' && return 0
        return 1
      }

      parse() {
        printf '%s' "$1" | python3 -c "$2"
      }

      for PROJ in ${self.triggers.projects}; do
        echo "Removing experiments, chaos infrastructures, and discovery agents in $ORG/$PROJ"
        Q="accountIdentifier=$ACCT&organizationIdentifier=$ORG&projectIdentifier=$PROJ"
        ok=0
        for round in 1 2 3 4 5 6 7 8; do
          found=0

          http GET "$CHAOS/rest/v2/experiment?$Q&page=0&limit=100"
          if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
            echo "Could not list experiments in $ORG/$PROJ (HTTP $HTTP_CODE)"
            printf '%s\n' "$HTTP_BODY" | head -c 400; echo
            exit 1
          fi
          if [ "$HTTP_CODE" = "404" ]; then HTTP_BODY='{}'; fi
          IDS=$(parse "$HTTP_BODY" '
import json,sys
raw=sys.stdin.read().strip()
data=json.loads(raw) if raw else {}
for exp in data.get("data") or []:
    eid=exp.get("experimentID") or exp.get("experimentId") or exp.get("workflowID") or ""
    if eid:
        print(eid)
')
          for ID in $IDS; do
            found=1
            echo "Stopping experiment $ID"
            http POST "$CHAOS/rest/v2/experiment/$ID/stop?$Q" "{}"
            echo "Deleting experiment $ID"
            http DELETE "$CHAOS/rest/v2/experiment/$ID?$Q"
            if ! gone; then
              echo "Could not delete experiment $ID (HTTP $HTTP_CODE)"
              printf '%s\n' "$HTTP_BODY" | head -c 400; echo
            fi
          done

          http GET "$NG/environmentsV2?accountIdentifier=$ACCT&orgIdentifier=$ORG&projectIdentifier=$PROJ&size=100"
          if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
            echo "Could not list environments in $ORG/$PROJ (HTTP $HTTP_CODE)"
            printf '%s\n' "$HTTP_BODY" | head -c 400; echo
            exit 1
          fi
          if [ "$HTTP_CODE" = "404" ]; then HTTP_BODY='{}'; fi
          ENVS=$(parse "$HTTP_BODY" '
import json,sys
raw=sys.stdin.read().strip()
data=json.loads(raw) if raw else {}
content=((data.get("data") or {}).get("content")) or []
for item in content:
    env=item.get("environment") or item
    ident=env.get("identifier") or ""
    if ident:
        print(ident)
')
          # Listing chaos infrastructures without an environment id returns 500
          # "missing envID". Ask once per environment that still exists.
          for ENV in $ENVS; do
            http POST "$CHAOS/rest/v2/infrastructures?$Q&environmentIdentifier=$ENV&envID=$ENV&page=0&limit=100" \
              "{\"filter\":{\"environmentIDs\":[\"$ENV\"]}}"
            if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
              echo "Could not list chaos infrastructures in $ORG/$PROJ/$ENV (HTTP $HTTP_CODE)"
              printf '%s\n' "$HTTP_BODY" | head -c 400; echo
              exit 1
            fi
            if [ "$HTTP_CODE" = "404" ]; then HTTP_BODY='{}'; fi
            ROWS=$(parse "$HTTP_BODY" '
import json,sys
raw=sys.stdin.read().strip()
data=json.loads(raw) if raw else {}
for inf in data.get("infras") or []:
    ident=inf.get("identity") or inf.get("infraID") or ""
    env=inf.get("environmentID") or inf.get("environmentIdentifier") or ""
    if ident and env:
        print(env + "\t" + ident)
')
            while IFS= read -r row; do
              [ -n "$row" ] || continue
              CENV="$${row%%$'\t'*}"
              ID="$${row#*$'\t'}"
              echo "Deleting chaos infrastructure $ID in environment $CENV"
              http DELETE "$CHAOS/rest/v2/infrastructure/$CENV/$ID?$Q"
              if gone; then
                continue
              fi
              # DDCR records are the CD infrastructure. Chaos DELETE answers 500
              # "could not verify whether this infrastructure is managed by
              # Harness" for them. hpbk8sN is deleted by Terraform. Any other
              # infrastructure in the project is removed here so the project can go.
              if printf '%s' "$HTTP_BODY" | grep -qiE 'managed by Harness|could not verify|not a k8s infra|no matching infra'; then
                MANAGED="hpbk8s$${PROJ#team_}"
                if [ "$ID" = "$MANAGED" ]; then
                  echo "Leaving $ID for the infrastructure delete"
                  continue
                fi
                echo "Deleting CD infrastructure $ID in $CENV"
                http DELETE "$NG/infrastructures/$ID?accountIdentifier=$ACCT&orgIdentifier=$ORG&projectIdentifier=$PROJ&environmentIdentifier=$CENV"
                if ! gone; then
                  echo "Could not delete CD infrastructure $ID (HTTP $HTTP_CODE)"
                  printf '%s\n' "$HTTP_BODY" | head -c 400; echo
                  found=1
                fi
                continue
              fi
              echo "Could not delete chaos infrastructure $ID (HTTP $HTTP_CODE)"
              printf '%s\n' "$HTTP_BODY" | head -c 400; echo
              found=1
            done < <(printf '%s\n' "$ROWS")

            http GET "$SD/api/v1/agents?$Q&environmentIdentifier=$ENV&page=0&limit=100&all=true"
            if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
              echo "Could not list discovery agents in $ORG/$PROJ/$ENV (HTTP $HTTP_CODE)"
              printf '%s\n' "$HTTP_BODY" | head -c 400; echo
              exit 1
            fi
            if [ "$HTTP_CODE" != "200" ]; then HTTP_BODY='{}'; fi
            AGENTS=$(parse "$HTTP_BODY" '
import json,sys
raw=sys.stdin.read().strip()
data=json.loads(raw) if raw else {}
items=data.get("items") or data.get("data") or []
if isinstance(items, dict):
    items=items.get("content") or items.get("items") or []
for agent in items:
    if not isinstance(agent, dict) or agent.get("removed"):
        continue
    ident=agent.get("identity") or ""
    if ident:
        print(ident)
')
            for ID in $AGENTS; do
              found=1
              echo "Deleting discovery agent $ID in environment $ENV"
              http DELETE "$SD/api/v1/agents/$ID?$Q&environmentIdentifier=$ENV"
              if ! gone; then
                echo "Could not delete discovery agent $ID (HTTP $HTTP_CODE)"
                printf '%s\n' "$HTTP_BODY" | head -c 400; echo
              fi
            done
          done

          for ENV in $ENVS; do
            if [ "$ENV" = "hpb" ]; then
              continue
            fi
            echo "Deleting environment $ENV in $ORG/$PROJ"
            http DELETE "$NG/environmentsV2/$ENV?accountIdentifier=$ACCT&orgIdentifier=$ORG&projectIdentifier=$PROJ"
            if ! gone; then
              echo "Could not delete environment $ENV (HTTP $HTTP_CODE)"
              printf '%s\n' "$HTTP_BODY" | head -c 400; echo
              found=1
            fi
          done

          if [ "$found" -eq 0 ]; then
            ok=1
            break
          fi
          echo "References remain in $ORG/$PROJ; retry $round"
          sleep 3
        done
        if [ "$ok" -ne 1 ]; then
          echo "Experiments, chaos infrastructures, or discovery agents are still in $ORG/$PROJ"
          exit 1
        fi
        echo "Project $ORG/$PROJ no longer has experiments, chaos infrastructures, or discovery agents"
      done
    EOT
  }
}

# -----------------------------------------------------------------------------
# Projects (one per Kubernetes namespace)
# -----------------------------------------------------------------------------

resource "harness_platform_project" "this" {
  for_each = local.active_projects

  identifier  = each.value.identifier
  name        = each.value.name
  org_id      = local.org_identifier
  description = "HPB chaos workshop project targeting Kubernetes namespace ${each.value.namespace}"
  color       = var.project_color
  tags        = concat(local.tags, ["namespace:${each.value.namespace}"])
}

# -----------------------------------------------------------------------------
# Delegate (account-scoped token + Helm on the EKS cluster)
# -----------------------------------------------------------------------------

# Fail the plan when the cluster cannot run the delegate. Creating Harness
# objects and then waiting on a Pending pod leaves the account half-built and
# does not make the delegate exist. Re-run apply after a node is Ready and a
# subnet has a free address. Do not destroy.
data "external" "cluster_schedulable" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    cat >/dev/null
    REGION=${jsonencode(var.aws_region)}
    CLUSTER=${jsonencode(local.cluster_name)}
    cluster_exists=false
    nodes_known=false
    ready_nodes=0
    placeable=true
    if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
      cluster_exists=true
      KCFG=$(mktemp)
      if aws eks update-kubeconfig --kubeconfig "$KCFG" --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 \
        && command -v kubectl >/dev/null 2>&1; then
        KUBECONFIG="$KCFG"
        export KUBECONFIG
        if kubectl get ns kube-system >/dev/null 2>&1; then
          nodes_known=true
          ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
          warm_ip=$(kubectl get ds aws-node -n kube-system -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null | awk -F= '$1=="WARM_IP_TARGET"{print $2}')
          warm_ip=$${warm_ip:-unset}
          placeable=false
          if [ "$ready_nodes" -gt 0 ]; then
            if [ "$warm_ip" != "1" ]; then
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
        fi
      fi
      rm -f "$KCFG"
    fi
    printf '{"cluster_exists":"%s","nodes_known":"%s","ready_nodes":"%s","placeable":"%s"}\n' \
      "$cluster_exists" "$nodes_known" "$ready_nodes" "$placeable"
  EOT
  ]
}

resource "terraform_data" "cluster_schedulable" {
  lifecycle {
    precondition {
      condition = (
        data.external.cluster_schedulable.result.nodes_known == "false" ||
        tonumber(data.external.cluster_schedulable.result.ready_nodes) > 0
      )
      error_message = "Every node on ${local.cluster_name} is NotReady, so the delegate cannot be scheduled. Re-run terraform apply after a node is Ready. Do not destroy."
    }

    precondition {
      condition     = data.external.cluster_schedulable.result.placeable == "true"
      error_message = "No Ready node on ${local.cluster_name} can take the delegate's address. The node subnets have no free IP. Free an address and re-run terraform apply. Do not destroy."
    }
  }
}

# ACCOUNT-scoped deliberately: no org_id. The delegate that actually registers
# was installed from account-level settings
# (/account/<acct>/module/chaos/settings/delegates/list — note there is no
# /orgs/<org>/ segment), so its token is account-scoped. An org_id here made
# this token org-scoped while the Helm chart still registered at account level
# with accountId only, and every call came back 401 ACCOUNT_DOES_NOT_EXIST.
# Removing org_id replaces the token, which is intended: the new value flows
# into helm_release.delegate and the delegate re-registers.
# Revoking a token keeps the name for 30 days. Destroy only revokes it, so the
# next apply deletes that revoked token before creating the same name again.
resource "null_resource" "delegate_token_name" {
  triggers = {
    name    = local.delegate_token_name
    account = var.account_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KEY="$${HARNESS_PLATFORM_API_KEY:-$${HARNESS_API_KEY:-}}"
      if [ -z "$KEY" ]; then
        echo "Set HARNESS_PLATFORM_API_KEY or HARNESS_API_KEY before creating the delegate token."
        exit 1
      fi
      ENDPOINT=${jsonencode(var.harness_gateway_endpoint)}
      ENDPOINT="$${ENDPOINT%/}"
      ACCT=${jsonencode(var.account_id)}
      NAME=${jsonencode(local.delegate_token_name)}
      tmp=$(mktemp)
      code=$(curl -sS -o "$tmp" -w "%%{http_code}" -X DELETE \
        "$ENDPOINT/ng/api/delegate-token-ng?accountIdentifier=$ACCT&tokenName=$NAME" \
        -H "x-api-key: $KEY" || echo 000)
      if [ "$code" = "200" ] || [ "$code" = "204" ] || [ "$code" = "404" ]; then
        echo "Delegate token name $NAME is free"
      elif grep -qi "does not exist" "$tmp"; then
        echo "Delegate token name $NAME is already free"
      else
        echo "Could not remove revoked delegate token $NAME (HTTP $code)"
        head -c 300 "$tmp"; echo
        rm -f "$tmp"
        exit 1
      fi
      rm -f "$tmp"
    EOT
  }

  # Destroy revokes the token and keeps the name for 30 days. This runs after
  # that revoke and removes the name, so the next apply is not blocked by it.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KEY="$${HARNESS_PLATFORM_API_KEY:-$${HARNESS_API_KEY:-}}"
      if [ -z "$KEY" ]; then
        echo "Set HARNESS_PLATFORM_API_KEY or HARNESS_API_KEY before deleting the delegate token."
        exit 1
      fi
      ENDPOINT="https://app.harness.io/gateway"
      ACCT="${self.triggers.account}"
      NAME="${self.triggers.name}"
      tmp=$(mktemp)
      code=$(curl -sS -o "$tmp" -w "%%{http_code}" -X DELETE \
        "$ENDPOINT/ng/api/delegate-token-ng?accountIdentifier=$ACCT&tokenName=$NAME" \
        -H "x-api-key: $KEY" || echo 000)
      if [ "$code" = "200" ] || [ "$code" = "204" ] || [ "$code" = "404" ]; then
        echo "Delegate token name $NAME is removed"
      elif grep -qi "does not exist" "$tmp"; then
        echo "Delegate token name $NAME is already removed"
      else
        echo "Could not remove delegate token $NAME (HTTP $code)"
        head -c 300 "$tmp"; echo
        rm -f "$tmp"
        exit 1
      fi
      rm -f "$tmp"
    EOT
  }
}

resource "harness_platform_delegatetoken" "this" {
  name       = local.delegate_token_name
  account_id = var.account_id

  depends_on = [null_resource.delegate_token_name]
}

resource "kubernetes_namespace_v1" "delegate" {
  metadata {
    name = var.delegate_namespace
    labels = {
      "app.kubernetes.io/name"       = "harness-delegate"
      "app.kubernetes.io/part-of"    = "hpb-workshop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Node subnets are /24. The default VPC CNI warm ENI takes 15 addresses, so a
# node that still has pod slots can have no free secondary IP, and the delegate
# stays in ContainerCreating until apply gives up. One warm address is enough
# for this cluster and lets a new pod take a single IP from the subnet.
resource "null_resource" "vpc_cni_warm_ip" {
  triggers = {
    cluster        = local.cluster_name
    warm_ip_target = "1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      CLUSTER=${jsonencode(local.cluster_name)}
      REGION=${jsonencode(var.aws_region)}
      KUBECONFIG_FILE=$(mktemp)
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
      export KUBECONFIG="$KUBECONFIG_FILE"
      if ! kubectl get ds aws-node -n kube-system >/dev/null 2>&1; then
        echo "aws-node daemonset is not installed; delegate pods cannot get addresses"
        rm -f "$KUBECONFIG_FILE"
        exit 1
      fi
      current=$(kubectl get ds aws-node -n kube-system -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | awk -F= '$1=="WARM_IP_TARGET"{print $2}')
      if [ "$current" = "1" ]; then
        echo "aws-node WARM_IP_TARGET is already 1"
        rm -f "$KUBECONFIG_FILE"
        exit 0
      fi
      echo "Setting aws-node WARM_IP_TARGET=1"
      kubectl set env daemonset/aws-node -n kube-system WARM_IP_TARGET=1
      kubectl rollout status daemonset/aws-node -n kube-system --timeout=180s
      rm -f "$KUBECONFIG_FILE"
    EOT
  }
}

# Set manage_delegate = false when the delegate was installed by hand from the
# Harness UI. Terraform would otherwise re-assert its own managerEndpoint,
# accountId and token on every apply and push a working delegate straight back
# into ACCOUNT_DOES_NOT_EXIST. delegate_ready still verifies it is Ready either
# way, so the rest of the graph keeps its ordering guarantee.
resource "helm_release" "delegate" {
  count = var.manage_delegate ? 1 : 0

  name       = local.delegate_name
  namespace  = kubernetes_namespace_v1.delegate.metadata[0].name
  repository = "https://app.harness.io/storage/harness-download/delegate-helm-chart/"
  chart      = "harness-delegate-ng"

  create_namespace = false
  # Ready is polled by null_resource.delegate_ready so Helm is not killed by wait timeout.
  wait            = false
  wait_for_jobs   = false
  atomic          = false
  timeout         = var.delegate_helm_timeout
  cleanup_on_fail = false
  max_history     = 5
  # Cluster already has this release from a prior apply that never wrote state.
  upgrade_install = true
  take_ownership  = true

  # Mirrors the UI install command that registers successfully. tags and
  # k8sPermissionsType are additions: tags backs delegate_selectors on the
  # connectors, CLUSTER_ADMIN is needed for chaos and discovery.
  set = concat(
    [
      {
        name  = "delegateName"
        value = local.delegate_name
      },
      {
        name  = "accountId"
        value = var.account_id
      },
      {
        name  = "managerEndpoint"
        value = var.manager_endpoint
      },
      {
        name  = "replicas"
        value = tostring(var.delegate_replicas)
      },
      {
        name  = "nextGen"
        value = "true"
      },
      {
        name  = "k8sPermissionsType"
        value = "CLUSTER_ADMIN"
      },
      {
        name  = "upgrader.enabled"
        value = "false"
      },
      {
        name  = "tags"
        value = local.delegate_name
      },
    ],
    var.delegate_docker_image != "" ? [
      {
        name  = "delegateDockerImage"
        value = var.delegate_docker_image
      },
    ] : [],
  )

  set_sensitive = [
    {
      name  = "delegateToken"
      value = local.delegate_token
    },
  ]

  depends_on = [
    harness_platform_delegatetoken.this,
    kubernetes_namespace_v1.delegate,
    null_resource.vpc_cni_warm_ip,
    terraform_data.cluster_schedulable,
  ]
}

resource "null_resource" "delegate_ready" {
  triggers = {
    release = var.manage_delegate ? helm_release.delegate[0].id : "externally-installed"
    retries = tostring(var.apply_retries)
    delay   = tostring(var.apply_retry_interval)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS=${jsonencode(var.delegate_namespace)}
      NAME=${jsonencode(local.delegate_name)}
      CLUSTER=${jsonencode(local.cluster_name)}
      REGION=${jsonencode(var.aws_region)}
      RETRIES=${var.apply_retries}
      DELAY=${var.apply_retry_interval}
      KUBECONFIG_FILE="/tmp/hpb-delegate.kubeconfig"
      aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
      export KUBECONFIG="$KUBECONFIG_FILE"
      echo "Waiting for delegate $NAME in $NS on cluster $CLUSTER (up to $RETRIES attempts, $${DELAY}s apart)"
      i=1
      while [ "$i" -le "$RETRIES" ]; do
        echo "delegate ready attempt $i/$RETRIES"
        if kubectl get ns "$NS" >/dev/null 2>&1; then
          # Only condition=Ready is trusted. A previous fallback grepped for
          # 'Running|1/1', which matches the literal "0/1   Running" of a
          # crash-looping delegate — so this gate went green over a delegate
          # with 200+ restarts, and every downstream delegate task (including
          # the discovery collector install) silently never ran.
          if kubectl wait --for=condition=Ready pod -n "$NS" -l app.kubernetes.io/instance="$NAME" --timeout=45s 2>/dev/null; then
            echo "Delegate pods Ready"
            exit 0
          fi
        fi
        if [ "$i" -eq "$RETRIES" ]; then
          echo "Delegate not Ready after $RETRIES attempts on $CLUSTER; re-run terraform apply (do not destroy)"
          kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$NAME" -o wide || true
          echo "--- nodes ---"
          kubectl get nodes || true
          echo "--- scheduling / sandbox ---"
          kubectl describe pod -n "$NS" -l app.kubernetes.io/instance="$NAME" 2>/dev/null | grep -iE 'FailedScheduling|FailedCreatePodSandBox|untolerated|assign an IP|Successfully assigned' || true
          echo "--- restart count / last termination ---"
          kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$NAME" \
            -o 'jsonpath={range .items[*]}{.metadata.name}{"  restarts="}{.status.containerStatuses[0].restartCount}{"  lastState="}{.status.containerStatuses[0].lastState}{"\n"}{end}' || true
          echo "--- probe failures ---"
          kubectl describe pod -n "$NS" -l app.kubernetes.io/instance="$NAME" 2>/dev/null | grep -iE 'probe|unhealthy|oomkill|killing|backoff' || true
          echo "--- delegate logs (previous container) ---"
          kubectl logs -n "$NS" -l app.kubernetes.io/instance="$NAME" --tail=80 --previous 2>/dev/null || true
          echo "--- delegate logs (current container) ---"
          kubectl logs -n "$NS" -l app.kubernetes.io/instance="$NAME" --tail=80 2>/dev/null || true
          exit 1
        fi
        sleep "$DELAY"
        i=$((i + 1))
      done
    EOT
  }

  depends_on = [helm_release.delegate]
}

resource "time_sleep" "delegate_register" {
  create_duration = var.delegate_register_wait
  depends_on      = [null_resource.delegate_ready]
}

# -----------------------------------------------------------------------------
# Connectors. K8s + Prometheus are per project. Optional AWS stays org-level.
# InheritFromDelegate — same spec as a Connector recipe; NG has no Connector template type.
# -----------------------------------------------------------------------------

resource "harness_platform_connector_kubernetes" "eks" {
  for_each = local.active_projects

  identifier  = local.k8s_connector_id
  name        = local.k8s_connector_name
  org_id      = local.org_identifier
  project_id  = harness_platform_project.this[each.key].identifier
  description = "Project Kubernetes connector for namespace ${each.value.namespace} (InheritFromDelegate)."
  tags        = concat(local.tags, ["namespace:${each.value.namespace}"])
  # This account rejects forceDelete. Children are removed first, then a normal delete.
  force_delete = false

  inherit_from_delegate {
    delegate_selectors = [local.delegate_name]
  }

  # A chaos infrastructure that survived an aborted destroy still names this
  # connector. Delete those records first. CD infrastructures are removed by
  # the provider before this connector, because they reference it.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KEY="$${HARNESS_PLATFORM_API_KEY:-$${HARNESS_API_KEY:-}}"
      if [ -z "$KEY" ]; then
        echo "Set HARNESS_PLATFORM_API_KEY or HARNESS_API_KEY so connector ${self.identifier} can be deleted."
        exit 1
      fi
      ORG="${self.org_id}"
      PROJ="${self.project_id}"
      SCOPE="$${TMPDIR:-/tmp}/hpb-$${ORG}-destroy-scope"
      ENDPOINT=""
      ACCT=""
      if [ -f "$SCOPE" ]; then
        ENDPOINT=$(sed -n 's/^endpoint=//p' "$SCOPE")
        ACCT=$(sed -n 's/^account=//p' "$SCOPE")
      fi
      if [ -z "$ACCT" ]; then ACCT="$${HARNESS_ACCOUNT_ID:-}"; fi
      if [ -z "$ACCT" ]; then ACCT="$${TF_VAR_account_id:-}"; fi
      # Destroy provisioners cannot read var.account_id. This is that variable's default.
      if [ -z "$ACCT" ]; then ACCT="cTU1lRSWS2SSRV9phKvuOA"; fi
      if [ -z "$ENDPOINT" ]; then ENDPOINT="$${HARNESS_ENDPOINT:-https://app.harness.io/gateway}"; fi
      ENDPOINT="$${ENDPOINT%/}"
      Q="accountIdentifier=$ACCT&organizationIdentifier=$ORG&projectIdentifier=$PROJ"
      tmp=$(mktemp)
      code=$(curl -sS -o "$tmp" -w "%%{http_code}" \
        "$ENDPOINT/ng/api/environmentsV2?accountIdentifier=$ACCT&orgIdentifier=$ORG&projectIdentifier=$PROJ&size=100" \
        -H "x-api-key: $KEY" || echo 000)
      if [ "$code" != "200" ] && [ "$code" != "404" ]; then
        echo "Could not list environments before deleting connector ${self.identifier} (HTTP $code)"
        head -c 400 "$tmp"; echo
        rm -f "$tmp"
        exit 1
      fi
      ENVS=$(python3 -c '
import json,sys
raw=sys.stdin.read().strip()
data=json.loads(raw) if raw.startswith("{") else {}
content=((data.get("data") or {}).get("content")) or []
for item in content:
    env=item.get("environment") or item
    ident=env.get("identifier") or ""
    if ident:
        print(ident)
' < "$tmp")
      rm -f "$tmp"
      ROWS=""
      for ENV in $ENVS; do
        tmp=$(mktemp)
        code=$(curl -sS -o "$tmp" -w "%%{http_code}" -X POST \
          "$ENDPOINT/chaos/manager/api/rest/v2/infrastructures?$Q&environmentIdentifier=$ENV&envID=$ENV&page=0&limit=100" \
          -H "x-api-key: $KEY" -H "Content-Type: application/json" \
          -d "{\"filter\":{\"environmentIDs\":[\"$ENV\"]}}" || echo 000)
        if [ "$code" != "200" ] && [ "$code" != "404" ]; then
          echo "Could not list chaos infrastructures before deleting connector ${self.identifier} (HTTP $code)"
          head -c 400 "$tmp"; echo
          rm -f "$tmp"
          exit 1
        fi
        if [ "$code" = "200" ]; then
          ROWS="$ROWS
$(python3 -c '
import json,sys
data=json.loads(sys.stdin.read() or "{}")
for inf in data.get("infras") or []:
    ident=inf.get("identity") or inf.get("infraID") or ""
    env=inf.get("environmentID") or inf.get("environmentIdentifier") or ""
    if ident and env:
        print(env + "\t" + ident)
' < "$tmp")"
        fi
        rm -f "$tmp"
      done
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        ENV="$${row%%$'\t'*}"
        ID="$${row#*$'\t'}"
        echo "Deleting leftover chaos infrastructure $ID before connector ${self.identifier}"
        tmp=$(mktemp)
        del=$(curl -sS -o "$tmp" -w "%%{http_code}" -X DELETE \
          "$ENDPOINT/chaos/manager/api/rest/v2/infrastructure/$ENV/$ID?$Q" \
          -H "x-api-key: $KEY" || echo 000)
        if [ "$del" != "200" ] && [ "$del" != "201" ] && [ "$del" != "204" ] && [ "$del" != "404" ]; then
          if ! grep -qiE 'managed by Harness|could not verify|not a k8s infra|no matching infra' "$tmp"; then
            echo "Could not delete chaos infrastructure $ID (HTTP $del)"
            head -c 400 "$tmp"; echo
            rm -f "$tmp"
            exit 1
          fi
          echo "Chaos API will not delete $ID; the infrastructure delete removes it"
        fi
        rm -f "$tmp"
      done < <(printf '%s\n' "$ROWS")
    EOT
  }

  depends_on = [
    time_sleep.delegate_register,
    harness_platform_project.this,
  ]
}

resource "harness_platform_connector_aws" "eks" {
  count = var.create_aws_connector ? 1 : 0

  identifier          = local.aws_connector_id
  name                = local.aws_connector_name
  org_id              = local.org_identifier
  description         = "Org AWS connector (InheritFromDelegate)."
  tags                = local.tags
  execute_on_delegate = true
  force_delete        = false

  inherit_from_delegate {
    delegate_selectors = [local.delegate_name]
    region             = var.aws_region
  }

  depends_on = [time_sleep.delegate_register]
}

resource "harness_platform_connector_prometheus" "namespace" {
  for_each = var.create_prometheus_connectors ? local.active_projects : {}

  identifier  = "${local.prometheus_id_prefix}_${each.value.identifier}"
  name        = "${local.prometheus_name_prefix}-${each.value.name}"
  org_id      = local.org_identifier
  project_id  = harness_platform_project.this[each.key].identifier
  description = "Prometheus in namespace ${each.value.namespace}."
  tags        = concat(local.tags, ["namespace:${each.value.namespace}"])
  # Trailing slash is not cosmetic: the API stores the URL normalised with one,
  # so writing it without produces an update-in-place on every single plan.
  url                = "http://prometheus.${each.value.namespace}.svc.cluster.local:${var.prometheus_port}/"
  delegate_selectors = [local.delegate_name]

  depends_on = [
    time_sleep.delegate_register,
    harness_platform_project.this,
  ]
}

# -----------------------------------------------------------------------------
# Per project: environment, Kubernetes infra, discovery, chaos v2
# -----------------------------------------------------------------------------

resource "harness_platform_environment" "this" {
  for_each = local.active_projects

  identifier   = local.environment_id
  name         = local.environment_name
  org_id       = local.org_identifier
  project_id   = harness_platform_project.this[each.key].identifier
  type         = var.environment_type
  description  = "HPB workshop environment for namespace ${each.value.namespace}"
  tags         = concat(local.tags, ["namespace:${each.value.namespace}"])
  force_delete = false

  # Runs after the CD infrastructure resource is gone. Deletes a chaos
  # infrastructure, discovery agent, or CD infrastructure that an aborted
  # destroy dropped from state while Harness still had it. In-state CD
  # infrastructures are deleted by the provider before this runs, so a 404
  # here is the normal case. forceDelete is not sent; this account rejects it.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KEY="$${HARNESS_PLATFORM_API_KEY:-$${HARNESS_API_KEY:-}}"
      if [ -z "$KEY" ]; then
        echo "Set HARNESS_PLATFORM_API_KEY or HARNESS_API_KEY so environment ${self.identifier} can be deleted."
        exit 1
      fi
      ORG="${self.org_id}"
      PROJ="${self.project_id}"
      ENV_ID="${self.identifier}"
      SCOPE="$${TMPDIR:-/tmp}/hpb-$${ORG}-destroy-scope"
      ENDPOINT=""
      ACCT=""
      if [ -f "$SCOPE" ]; then
        ENDPOINT=$(sed -n 's/^endpoint=//p' "$SCOPE")
        ACCT=$(sed -n 's/^account=//p' "$SCOPE")
      fi
      if [ -z "$ACCT" ]; then ACCT="$${HARNESS_ACCOUNT_ID:-}"; fi
      if [ -z "$ACCT" ]; then ACCT="$${TF_VAR_account_id:-}"; fi
      # Destroy provisioners cannot read var.account_id. This is that variable's default.
      if [ -z "$ACCT" ]; then ACCT="cTU1lRSWS2SSRV9phKvuOA"; fi
      if [ -z "$ENDPOINT" ]; then ENDPOINT="$${HARNESS_ENDPOINT:-https://app.harness.io/gateway}"; fi
      ENDPOINT="$${ENDPOINT%/}"
      CHAOS="$ENDPOINT/chaos/manager/api"
      SD="$ENDPOINT/servicediscovery"
      NG="$ENDPOINT/ng/api"
      Q="accountIdentifier=$ACCT&organizationIdentifier=$ORG&projectIdentifier=$PROJ"

      http() {
        local method="$1" url="$2" body="$${3:-}" tmp code
        tmp=$(mktemp)
        if [ -n "$body" ]; then
          code=$(curl -sS -o "$tmp" -w "%%{http_code}" -X "$method" "$url" \
            -H "x-api-key: $KEY" -H "Content-Type: application/json" -d "$body" || echo 000)
        else
          code=$(curl -sS -o "$tmp" -w "%%{http_code}" -X "$method" "$url" \
            -H "x-api-key: $KEY" -H "Content-Type: application/json" || echo 000)
        fi
        HTTP_CODE="$code"
        HTTP_BODY=$(cat "$tmp")
        rm -f "$tmp"
      }
      gone() {
        case "$HTTP_CODE" in
          200|201|204|404) return 0 ;;
        esac
        printf '%s' "$HTTP_BODY" | grep -qiE 'not found|does not exist|already deleted|no matching' && return 0
        return 1
      }

      http POST "$CHAOS/rest/v2/infrastructures?$Q&environmentIdentifier=$ENV_ID&envID=$ENV_ID&page=0&limit=100" \
        "{\"filter\":{\"environmentIDs\":[\"$ENV_ID\"]}}"
      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
        echo "Could not list chaos infrastructures in $ORG/$PROJ (HTTP $HTTP_CODE)"
        printf '%s\n' "$HTTP_BODY" | head -c 400; echo
        exit 1
      fi
      if [ "$HTTP_CODE" = "200" ]; then
        ROWS=$(printf '%s' "$HTTP_BODY" | python3 -c '
import json,sys
data=json.loads(sys.stdin.read() or "{}")
for inf in data.get("infras") or []:
    ident=inf.get("identity") or inf.get("infraID") or ""
    env=inf.get("environmentID") or inf.get("environmentIdentifier") or ""
    if ident and env:
        print(env + "\t" + ident)
')
        while IFS= read -r row; do
          [ -n "$row" ] || continue
          ENV="$${row%%$'\t'*}"
          ID="$${row#*$'\t'}"
          echo "Deleting leftover chaos infrastructure $ID in $ENV"
          http DELETE "$CHAOS/rest/v2/infrastructure/$ENV/$ID?$Q"
          if ! gone; then
            if printf '%s' "$HTTP_BODY" | grep -qiE 'managed by Harness|could not verify|not a k8s infra|no matching infra'; then
              echo "Chaos API will not delete $ID; removing it as a CD infrastructure"
              http DELETE "$NG/infrastructures/$ID?$Q&environmentIdentifier=$ENV"
              gone || { echo "Could not delete CD infrastructure $ID (HTTP $HTTP_CODE)"; exit 1; }
            else
              echo "Could not delete chaos infrastructure $ID (HTTP $HTTP_CODE)"
              printf '%s\n' "$HTTP_BODY" | head -c 400; echo
              exit 1
            fi
          fi
        done < <(printf '%s\n' "$ROWS")
      fi

      http GET "$SD/api/v1/agents?$Q&environmentIdentifier=$ENV_ID&page=0&limit=100&all=true"
      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
        echo "Could not list discovery agents in $ORG/$PROJ/$ENV_ID (HTTP $HTTP_CODE)"
        printf '%s\n' "$HTTP_BODY" | head -c 400; echo
        exit 1
      fi
      if [ "$HTTP_CODE" = "200" ]; then
        AGENTS=$(printf '%s' "$HTTP_BODY" | python3 -c '
import json,sys
data=json.loads(sys.stdin.read() or "{}")
items=data.get("items") or []
for agent in items:
    ident=agent.get("identity") or ""
    if ident and not agent.get("removed"):
        print(ident)
')
        for ID in $AGENTS; do
          echo "Deleting leftover discovery agent $ID"
          http DELETE "$SD/api/v1/agents/$ID?$Q&environmentIdentifier=$ENV_ID"
          gone || { echo "Could not delete discovery agent $ID (HTTP $HTTP_CODE)"; exit 1; }
        done
      fi

      http GET "$NG/infrastructures?$Q&environmentIdentifier=$ENV_ID&size=100"
      if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "404" ]; then
        echo "Could not list CD infrastructures in $ORG/$PROJ/$ENV_ID (HTTP $HTTP_CODE)"
        printf '%s\n' "$HTTP_BODY" | head -c 400; echo
        exit 1
      fi
      if [ "$HTTP_CODE" = "200" ]; then
        INFRA=$(printf '%s' "$HTTP_BODY" | python3 -c '
import json,sys
data=json.loads(sys.stdin.read() or "{}")
for item in ((data.get("data") or {}).get("content")) or []:
    infra=item.get("infrastructure") or item
    ident=infra.get("identifier") or ""
    if ident:
        print(ident)
')
        for ID in $INFRA; do
          echo "Deleting leftover CD infrastructure $ID in $ENV_ID"
          http DELETE "$NG/infrastructures/$ID?$Q&environmentIdentifier=$ENV_ID"
          gone || { echo "Could not delete CD infrastructure $ID (HTTP $HTTP_CODE)"; exit 1; }
        done
      fi
    EOT
  }
}

# The API stores the tags declared in the YAML body and ignores anything extra
# in the tags attribute, so the two must be generated from one list. Hardcoding
# only workshop + namespace in the YAML while the attribute also carried
# project + managedby meant those two never persisted and every plan re-issued
# the same in-place tag update forever.
locals {
  infra_tags = {
    for k, p in local.active_projects : k => concat(local.tags, ["namespace:${p.namespace}"])
  }

  # Split on the first colon only, so a value containing one (a URL, say)
  # survives instead of being silently truncated.
  infra_tags_yaml = {
    for k, tags in local.infra_tags : k => join("\n", [
      for t in tags : format("    %s: %q",
        split(":", t)[0],
        join(":", slice(split(":", t), 1, length(split(":", t))))
      )
    ])
  }
}

resource "harness_platform_infrastructure" "this" {
  for_each = local.active_projects

  identifier      = each.value.infra_id
  name            = local.infra_name
  org_id          = local.org_identifier
  project_id      = harness_platform_project.this[each.key].identifier
  env_id          = harness_platform_environment.this[each.key].identifier
  type            = "KubernetesDirect"
  deployment_type = "Kubernetes"
  force_delete    = false
  tags            = local.infra_tags[each.key]

  lifecycle {
    create_before_destroy = true
  }

  yaml = <<-EOT
infrastructureDefinition:
  name: ${local.infra_name}
  identifier: ${each.value.infra_id}
  orgIdentifier: ${local.org_identifier}
  projectIdentifier: ${each.value.identifier}
  environmentRef: ${local.environment_id}
  description: HPB workshop Kubernetes infrastructure for ${each.value.namespace}
  tags:
${local.infra_tags_yaml[each.key]}
  deploymentType: Kubernetes
  type: KubernetesDirect
  spec:
    connectorRef: ${local.k8s_connector_id}
    namespace: ${each.value.namespace}
    releaseName: release-<+INFRA_KEY>
  allowSimultaneousDeployments: true
  EOT

  depends_on = [
    harness_platform_environment.this,
    harness_platform_connector_kubernetes.eks,
  ]
}

# Stale state: agents were deleted in Harness (or imported under the wrong id
# hpb_k8s) so refresh returns 404. Drop them from state without a destroy API
# call, then create a new resource address bound to hpbk8s.
# Pipeline: enable Skip Refresh Command on TerraformApply_2 (not TF_CLI_ARGS_apply).
removed {
  from = harness_service_discovery_agent.this
  lifecycle { destroy = false }
}

# PnC DA-banking-1: install ns harness-delegate-ng, SA chaos-delegate,
# cron 0/15, Inclusion banking-1, network trace OFF, static configmap name OFF.
# Docs (single namespace + Inclusion): "Disable the Detect network trace
# connectivity." Leaving it on makes the form demand a node selector and the
# collector never runs (Last Discovery: N/A).
resource "kubernetes_service_account_v1" "discovery" {
  count = var.create_discovery_service_account ? 1 : 0

  metadata {
    name      = var.discovery_service_account
    namespace = kubernetes_namespace_v1.delegate.metadata[0].name
    labels = {
      "app.kubernetes.io/name"       = "harness-service-discovery"
      "app.kubernetes.io/part-of"    = "hpb-workshop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Cluster-wide read so the collector can list Namespace objects, which is what
# populates the Namespace dropdown when scoping with Inclusion.
resource "kubernetes_cluster_role_binding_v1" "discovery" {
  count = var.create_discovery_service_account ? 1 : 0

  metadata {
    name = "${var.discovery_service_account}-cluster-admin"
    labels = {
      "app.kubernetes.io/part-of"    = "hpb-workshop"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.discovery[0].metadata[0].name
    namespace = kubernetes_namespace_v1.delegate.metadata[0].name
  }
}

# Bump discovery_scope_version to force a reinstall after changing install
# namespace, service account or cron.
#
# Do NOT reintroduce a kubectl-based "is the collector running" probe here. The
# collector is a short-lived Job (reported by the API as sd-cluster-<suffix>,
# status Succeeded) that is garbage-collected once it finishes, so its absence
# from the cluster says nothing at all — an earlier version of this file polled
# for a CronJob that never exists in any state and failed a perfectly healthy
# apply. Read installation_details and service_count in the
# discovery_installation output instead: that is the API's own answer.
resource "terraform_data" "discovery_cluster_scope" {
  input = var.discovery_scope_version
}

# org_identifier, project_identifier, environment_identifier and
# infra_identifier are immutable server-side; the API answers an update with
# "cannot update immutable fields". The provider does not mark them ForceNew,
# so Terraform cheerfully plans an in-place update that can only fail. Bind the
# agent's replacement to them so a change recreates the agent instead.
resource "terraform_data" "discovery_agent_binding" {
  for_each = local.active_projects

  input = join("|", [
    local.org_identifier,
    each.value.identifier,
    local.environment_id,
    each.value.infra_id,
  ])
}

# Destroying harness_chaos_infrastructure_v2 also deleted the agent records
# behind it — they share the infra_id keyspace in the chaos service — and the
# provider answers a refresh of a deleted agent with a bare "Not Found" instead
# of dropping it from state, which makes even a plan impossible. The stale
# instances are forgotten by the removed block below; this new address builds
# the agents fresh.
resource "harness_service_discovery_agent" "agent" {
  for_each = local.active_projects

  name                   = "${local.discovery_name_prefix}-${each.value.name}"
  org_identifier         = local.org_identifier
  project_identifier     = harness_platform_project.this[each.key].identifier
  environment_identifier = harness_platform_environment.this[each.key].identifier
  infra_identifier       = harness_platform_infrastructure.this[each.key].identifier

  # installation_type is deliberately not set. The provider never sends it on
  # create/update (resource_agent.go only does d.Set from the API response), so
  # setting it does nothing except invite permanent drift when the API reports a
  # different value than the one in config. Ours said "CONNECTOR"; the provider
  # vocabulary is Connector / Helm / Manifest / Yaml, so it never matched.

  config {
    kubernetes {
      namespace                  = local.discovery_install_ns
      namespaced                 = false
      disable_namespace_creation = true
      service_account            = var.discovery_service_account
    }
    data {
      # Inclusion only. This list is the UI Namespace dropdown: team-1 → banking-1.
      observed_namespaces = [each.value.namespace]

      # Network trace needs a node agent + node selector + duration. PnC leaves
      # it off, so these stay null unless discovery_enable_network_trace is set.
      enable_node_agent        = var.discovery_enable_network_trace
      node_agent_selector      = var.discovery_enable_network_trace ? var.discovery_node_agent_selector : null
      collection_window_in_min = var.discovery_enable_network_trace ? var.discovery_collection_window_in_min : null

      cron {
        expression = var.discovery_cron_expression
      }
    }
  }

  lifecycle {
    replace_triggered_by = [
      terraform_data.discovery_cluster_scope,
      terraform_data.discovery_agent_binding[each.key],
    ]

    # The API reports CONNECTOR while the provider never sends the field, so
    # leaving it unset still shows "CONNECTOR" -> null and re-PATCHes all four
    # agents on every apply.
    ignore_changes = [installation_type]
  }

  depends_on = [
    harness_platform_infrastructure.this,
    harness_platform_connector_kubernetes.eks,
    kubernetes_cluster_role_binding_v1.discovery,
    time_sleep.delegate_register,
  ]
}

# installation_details is computed by the provider from the API, so a green
# apply already knows why the collector never ran — it just never printed it.
# delegate_task_status is the answer: if there is no install task, or it failed,
# Discovery History stays completely empty and Last Discovery stays N/A no
# matter how correct the agent config is. Read these in the stage-2 apply log.
output "discovery_installation" {
  description = "Per-project discovery install status. delegate_task_status is the field that explains an empty Discovery History."
  value = {
    for k, a in harness_service_discovery_agent.agent : k => {
      name          = a.name
      identity      = a.identity
      service_count = a.service_count
      removed       = a.removed
      install = [
        for d in a.installation_details : {
          delegate_id          = d.delegate_id
          delegate_task_id     = d.delegate_task_id
          delegate_task_status = d.delegate_task_status
          is_cron_triggered    = d.is_cron_triggered
          stopped              = d.stopped
          removed              = d.removed
          log_stream_id        = d.log_stream_id
          agent_details        = d.agent_details
        }
      ]
    }
  }
}

# DDCR chaos infrastructure is the CD infrastructure (hpbk8sN). The chaos
# provider's delete returns 500 "could not verify whether this infrastructure
# is managed by Harness", which blocks destroy. Forget these state entries
# without calling that API. harness_platform_infrastructure deletes the record.
removed {
  from = harness_chaos_infrastructure_v2.this
  lifecycle { destroy = false }
}

resource "null_resource" "install_chaos" {
  for_each = var.apply_chaos_install_command ? local.active_projects : {}

  triggers = {
    infra_id = harness_platform_infrastructure.this[each.key].id
    cluster  = local.cluster_name
    region   = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "No chaos install command for ${each.value.namespace}; DDCR uses connector ${local.k8s_connector_id}"
    EOT
  }

  depends_on = [harness_platform_infrastructure.this]
}


# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "org_id" {
  value = local.org_identifier
}

output "namespaces" {
  value = local.namespaces
}

output "projects" {
  value = {
    for ns, project in harness_platform_project.this : ns => {
      namespace  = local.projects[ns].namespace
      identifier = project.identifier
      name       = project.name
    }
  }
}

output "delegate_name" {
  value = local.delegate_name
}

output "k8s_connector_refs" {
  value = {
    for ns, connector in harness_platform_connector_kubernetes.eks :
    ns => connector.identifier
  }
}

resource "harness_chaos_experiment" "from_template" {
  for_each = var.experiment_template_identity != "" && var.experiment_hub_identity != "" ? local.active_projects : {}

  org_id     = local.org_identifier
  project_id = harness_platform_project.this[each.key].identifier

  hub_identity      = var.experiment_hub_identity
  hub_org_id        = var.experiment_hub_org_id != "" ? var.experiment_hub_org_id : null
  hub_project_id    = var.experiment_hub_project_id != "" ? var.experiment_hub_project_id : null
  template_identity = var.experiment_template_identity
  revision          = var.experiment_template_revision
  import_type       = var.experiment_import_type
  infra_ref         = "${local.environment_id}/${each.value.infra_id}"
  name              = var.experiment_name != "" ? var.experiment_name : var.experiment_template_identity
  identity          = replace(var.experiment_template_identity, "-", "_")
  description       = "Imported from template ${var.experiment_template_identity} for namespace ${each.value.namespace}"
  tags              = concat(local.tags, ["namespace:${each.value.namespace}"])

  lifecycle {
    ignore_changes = [tags]
  }

  # Provider delete runs before null_resource.chaos_experiments_in_projects,
  # while this experiment still exists. The null resource then deletes any
  # experiment that was created in the project and is not in state.
  depends_on = [
    harness_platform_infrastructure.this,
    terraform_data.chaos_templates,
    null_resource.chaos_experiments_in_projects,
  ]
}

output "chaos_hub" {
  value = var.create_org_chaos_templates ? {
    identity    = data.harness_chaos_hub_v2.org[0].identity
    name        = data.harness_chaos_hub_v2.org[0].name
    hub_ref     = local.chaos_hub_ref
    import_hint = "Set experiment_hub_identity=${local.chaos_hub_ref}, experiment_hub_org_id=${local.org_identifier}, and experiment_template_identity to a live identity such as txnservicedependencyfailure."
  } : null
}

output "chaos_experiment_templates" {
  value = sort([
    for f in fileset("${path.module}/chaos-templates/experiments", "*.yaml") :
    trimsuffix(f, ".yaml")
  ])
}

output "experiments" {
  value = {
    for ns, experiment in harness_chaos_experiment.from_template : ns => {
      name     = experiment.name
      identity = experiment.identity
      id       = experiment.id
    }
  }
}

output "aws_connector_ref" {
  value = var.create_aws_connector ? "org.${local.aws_connector_id}" : null
}

output "prometheus_connector_refs" {
  value = {
    for ns, connector in harness_platform_connector_prometheus.namespace :
    ns => connector.identifier
  }
}

output "discovery_agents" {
  value = {
    for ns, agent in harness_service_discovery_agent.agent : ns => {
      name     = agent.name
      id       = agent.id
      identity = agent.identity
      ui_url   = "https://app.harness.io/ng/account/${var.account_id}/module/chaos/orgs/${local.org_identifier}/projects/${harness_platform_project.this[ns].identifier}/settings/discovery/${coalesce(agent.identity, agent.id)}?environmentIdentifier=${local.environment_id}"
    }
  }
}

output "chaos_infrastructures" {
  value = {
    for ns, infra in harness_platform_infrastructure.this : ns => {
      name = infra.name
      id   = infra.id
    }
  }
}
