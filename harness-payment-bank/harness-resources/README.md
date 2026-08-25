# Harness Payment Bank — workshop Harness resources

One Terraform root. After EKS/HPB (`../infrastructure`) is up, a single apply creates the Harness org, connector templates, projects, delegate, org connectors, discovery agents, and chaos infra.

```text
harness-payment-bank/
├── infrastructure/     # EKS + HPB
└── harness-resources/  # this directory
    ├── main.tf
    └── variables.tf
```

## What apply creates

| Layer | Resource | Default name |
| --- | --- | --- |
| Org | organization | `workshop` |
| Templates | Connector templates | `hpb_k8s_inherit_delegate`, `hpb_aws_inherit_delegate`, `hpb_prometheus` @ `v1` |
| Projects | one per namespace | identifier `banking_1`, name `banking-1` |
| Delegate | token + helm on `hpb-eks` | `hpb-workshop-delegate` in `harness-delegate-ng` |
| Connectors | org-level | `org.hpb_eks`, `org.hpb_aws`, `org.hpb_prometheus_banking_N` |
| Per project | environment, K8s infra, discovery, chaos v2 | env `hpb`, infra `hpb_k8s`, `hpb-discovery-<ns>`, `hpb-chaos-<ns>` |

Namespaces and cluster name are read from `hpb-eks/terraform.tfstate`. Override with `TF_VAR_namespaces` / `TF_VAR_cluster_name`.

Rename anything via `variables.tf` (or `TF_VAR_*`). `resource_prefix` (default `hpb`) is used when a specific name is left empty.

## Apply

```bash
export HARNESS_ACCOUNT_ID="..."
export HARNESS_PLATFORM_API_KEY="..."
export TF_VAR_account_id="$HARNESS_ACCOUNT_ID"

cd harness-payment-bank/harness-resources
terraform init
terraform apply
```

Needs `terraform`, `aws`, `helm`, and `kubectl`. Optional: `TF_VAR_manager_endpoint` if Account Overview is not `https://app.harness.io`.

```bash
terraform destroy   # Harness resources only — does not destroy EKS
```

If org `workshop` already exists: `terraform import harness_platform_organization.this workshop`.

Connector templates are created in the same apply. If they already exist in the org, either import them or set `TF_VAR_create_connector_templates=false`.

Kubernetes / AWS / Prometheus Terraform resources do not accept `templateRef`; instances use the native resources and fill the template inputs (delegate selector, region, Prometheus URL).

## Name overrides (examples)

```bash
export TF_VAR_org_id=workshop
export TF_VAR_org_name="Chaos Workshop"
export TF_VAR_resource_prefix=hpb
export TF_VAR_delegate_name=hpb-workshop-delegate
export TF_VAR_k8s_connector_id=hpb_eks
export TF_VAR_k8s_connector_name="HPB EKS"
export TF_VAR_environment_id=hpb
export TF_VAR_infra_id=hpb_k8s
export TF_VAR_project_identifier_prefix=ws   # project ids become ws_banking_1
export TF_VAR_discovery_agent_name_prefix=hpb-discovery
export TF_VAR_chaos_infra_name_prefix=hpb-chaos
```

Per-namespace project names:

```hcl
# terraform.tfvars (not committed)
project_overrides = {
  "banking-1" = { identifier = "team_alpha", name = "Team Alpha" }
}
```

Experiments stay in the UI after discovery maps services.
