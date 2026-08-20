# Harness Payment Bank — EKS Terraform

Deploys an EKS cluster, creates namespaces (`banking-1` … `banking-N`), applies the vendored `hpb-manifest/hpb-k8s` manifests, patches Prometheus for each namespace, ensures Postgres databases exist, and configures the frontend gateway URL.

Everything lives in this repository. Kubernetes YAML is applied as-is; do not edit it for this flow.

Terraform source:

- `main.tf`
- `variables.tf`

Optional overrides come from environment variables (`TF_VAR_*`) or Harness pipeline inputs. No `terraform.tfvars` is required.

## Layout

```text
harness-chaos-demo/
└── harness-payment-bank/
    ├── hpb-manifest/hpb-k8s/   # Kubernetes manifests (vendored; do not edit)
    └── terraform/              # this directory
        ├── main.tf
        ├── variables.tf
        └── README.md
```

## Prerequisites

- AWS credentials with permission to create VPC, EKS, IAM, ELB, EBS
- Terraform `>= 1.5`
- `kubectl` and AWS CLI (`aws`) on the machine or Harness delegate that runs Terraform
- This repo checked out so `../hpb-manifest/hpb-k8s` exists next to `terraform/`

## Inputs (optional)

If unset, defaults from `variables.tf` are used.

| Variable | Default | Example override |
|---|---|---|
| `aws_region` | `us-east-1` | `export TF_VAR_aws_region=us-east-1` |
| `cluster_name` | `hpb-eks` | `export TF_VAR_cluster_name=hpb-eks` |
| `namespace_prefix` | `banking` | `export TF_VAR_namespace_prefix=banking` |
| `namespace_count` | `4` | `export TF_VAR_namespace_count=4` |
| `deploy_apps` | `true` | `export TF_VAR_deploy_apps=true` |
| `manifests_path` | `../hpb-manifest/hpb-k8s` | absolute or relative path |

Only export a variable when you intentionally want to override the default. Empty exports can override defaults with blank values.

## Apply (create everything)

```bash
cd harness-payment-bank/terraform

# optional overrides
# export TF_VAR_cluster_name="hpb-eks"
# export TF_VAR_namespace_count=4

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Typical create time: **25–40 minutes**.

When apply finishes:

```bash
terraform output service_endpoints
terraform output kubeconfig_command
```

Open the `frontend` URL for a namespace (for example `banking-1`) to use the app. Open the `prometheus` URL and check **Status → Targets**.

## Destroy (tear everything down)

Normal path: one command. No extra AWS cleanup is required if destroy completes.

```bash
cd harness-payment-bank/terraform
terraform destroy -auto-approve
```

Terraform will:

1. Drain Kubernetes LoadBalancers (delete app namespaces, wait until classic ELBs and ELB ENIs are gone, delete leftover `k8s-elb-*` security groups)
2. Delete generated Prometheus ClusterRoleBindings
3. Destroy EKS, node groups, IAM, VPC, NAT, subnets, etc.

Typical destroy time: **20–30 minutes**. Most of that is EKS/NAT. Waiting for ELBs is expected and is what prevents the VPC hang.

Confirm:

```bash
terraform state list
# expect: empty

aws eks describe-cluster --name hpb-eks --region us-east-1
# expect: ResourceNotFoundException
```

### Why VPC delete used to fail (now automated)

You should **not** need extra AWS commands on a normal destroy.

Kubernetes `Service type: LoadBalancer` (frontend, gateway, prometheus) creates **classic ELBs and `k8s-elb-*` security groups**. Those are not Terraform resources. AWS will not delete a subnet/VPC while they exist.

`null_resource.destroy_lb_drain` runs first on destroy: it deletes the app namespaces, then polls AWS until those ELBs and ELB ENIs are gone (up to ~15 minutes). Only then does Terraform delete EKS and the VPC.

Use the commands below only if that drain times out or you interrupted an old destroy that already deleted EKS but left ELBs behind.

```bash
export AWS_DEFAULT_REGION=us-east-1
# set VPC to the ID from terraform output vpc_id, or from the Terraform error message
export VPC=vpc-xxxxxxxx

# delete classic ELBs in that VPC
aws elb describe-load-balancers \
  --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" \
  --output text \
| tr '\t' '\n' \
| while read -r name; do
    [ -n "$name" ] || continue
    aws elb delete-load-balancer --load-balancer-name "$name"
  done

# delete leftover non-default security groups
for i in 1 2 3 4 5; do
  aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text \
  | tr '\t' '\n' \
  | while read -r sg; do
      [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
    done
  sleep 5
done

# if VPC is already empty, delete it and drop it from state
aws ec2 delete-vpc --vpc-id "$VPC" || true
terraform state rm 'module.vpc.aws_vpc.this[0]' 2>/dev/null || true
terraform destroy -auto-approve
```

## Re-apply after destroy

```bash
cd harness-payment-bank/terraform
terraform init
terraform apply -auto-approve
```

No manual kubectl steps are required for the demo path. Terraform will:

- create cluster + namespaces
- apply manifests
- create Postgres databases (`auth`, `transaction`, `account`, `loan`, `notification`)
- restart DB-backed services
- patch Prometheus per namespace
- set frontend `VITE_API_URL`

Keycloak remains commented out in `hpb-manifest` (same as the upstream README path). Optional SendGrid email is also not required.

## Harness pipeline shape

Keep plan/apply in this same repo. Recommended stages:

1. **Plan** — checkout this repo, AWS auth, `terraform init`, `terraform plan -out=tfplan`
2. **Approve** — human approval
3. **Apply** — `terraform apply tfplan`

Prefer Harness native **Terraform Plan** / **Terraform Apply** steps over a raw shell `terraform apply`. Pass optional inputs as `TF_VAR_*` environment variables. Leave them unset to keep defaults.

Working directory for all Terraform commands:

```text
harness-payment-bank/terraform
```

The runner or delegate needs `terraform`, `aws`, and `kubectl`. Store state in Harness or a remote backend — do not commit `*.tfstate`.

## Useful commands after apply

```bash
# kubeconfig
aws eks update-kubeconfig --region us-east-1 --name hpb-eks

# pods in one namespace
kubectl get pods -n banking-1

# endpoints printed by Terraform
terraform output service_endpoints
```

## Notes

- Manifests live under `../hpb-manifest/hpb-k8s` in this repo and are applied as-is.
- Prometheus manifests hardcode namespace `banking`; Terraform rewrites the live ConfigMap and bindings to `banking-1` … `banking-N`.
- `transaction-service` probes are softened after apply so cold starts do not CrashLoop.
- Keep `main.tf` and `variables.tf` as the only Terraform source files for this demo.
