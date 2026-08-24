# Harness Payment Bank — EKS Terraform

Deploys an EKS cluster, creates namespaces (`banking-1` … `banking-N`), applies the vendored `hpb-manifest/hpb-k8s` manifests, patches Prometheus for each namespace, ensures Postgres databases exist, and configures the frontend gateway URL.

Everything lives in this repository. Kubernetes YAML is applied as-is; do not edit it for this flow.

Terraform source:

- `main.tf`
- `variables.tf`
- `apply.sh` — create with rollback: if apply fails, destroy everything in this state

Optional overrides come from environment variables (`TF_VAR_*`) or Harness pipeline inputs. No `terraform.tfvars` is required.

## Layout

```text
harness-chaos-demo/
└── harness-payment-bank/
    ├── hpb-manifest/hpb-k8s/   # Kubernetes manifests (vendored; do not edit)
    └── terraform/              # this directory
        ├── main.tf
        ├── variables.tf
        ├── apply.sh
        └── README.md
```



## Prerequisites

- AWS credentials with permission to create VPC, EKS, IAM, ELB, EBS
- Terraform `>= 1.5`
- `kubectl` and AWS CLI (`aws`) on the machine or Harness delegate that runs Terraform
- This repo checked out so `../hpb-manifest/hpb-k8s` exists next to `terraform/`



## Inputs (optional)

If unset, defaults from `variables.tf` are used.


| Variable           | Default                   | Example override                         |
| ------------------ | ------------------------- | ---------------------------------------- |
| `aws_region`       | `us-east-1`               | `export TF_VAR_aws_region=us-east-1`     |
| `cluster_name`     | `hpb-eks`                 | `export TF_VAR_cluster_name=hpb-eks`     |
| `namespace_prefix` | `banking`                 | `export TF_VAR_namespace_prefix=banking` |
| `namespace_count`  | `4`                       | `export TF_VAR_namespace_count=4`        |
| `deploy_apps`      | `true`                    | `export TF_VAR_deploy_apps=true`         |
| `manifests_path`   | `../hpb-manifest/hpb-k8s` | absolute or relative path                |


Only export a variable when you intentionally want to override the default. Empty exports can override defaults with blank values.

## Apply (create everything)

Terraform does **not** undo a failed apply. Use `apply.sh` so a failure destroys whatever this state created (VPC, IAM, partial EKS, etc.) instead of leaving a second stack behind.

```bash
cd harness-payment-bank/terraform

# optional overrides
# export TF_VAR_cluster_name="hpb-eks"
# export TF_VAR_namespace_count=4

./apply.sh
```

That is `terraform init` + `terraform apply -auto-approve`. On non-zero apply, it runs `terraform destroy -auto-approve` against the same state.

Do **not** use `./apply.sh` for a day-2 change on a stack you want to keep. A failed update would destroy the whole cluster. For that, use `terraform apply` with no rollback.

Typical create time: **25–40 minutes**. Rollback destroy adds **20–30 minutes**.

If apply or destroy still left objects in AWS (common: IAM role `hpb-eks-ebs-csi`), use [Leftover cleanup](#leftover-cleanup-failed-apply) before the next apply.

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

## Leftover cleanup (failed apply)

`apply.sh` only destroys what is in **this Terraform state**. A failed apply, an interrupted destroy, or an earlier Harness run can leave AWS objects that are not in state. The next apply then fails with `ResourceInUseException` (cluster name) or `EntityAlreadyExists` (IAM role `hpb-eks-ebs-csi`).

Run this **after** `terraform destroy` has finished (or when `terraform state list` is empty) and you still see leftovers in the AWS console.

Do **not** delete the VPC first. EKS control-plane ENIs (`Description: Amazon EKS hpb-eks`, `Instance: None`) stay `in-use` until the cluster is deleted. You cannot delete those ENIs by hand while the cluster exists.

```bash
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER=hpb-eks
export ROLE="${CLUSTER}-ebs-csi"

# --- 1. What is still there ---
aws eks describe-cluster --name "$CLUSTER" --query 'cluster.{name:name,status:status,vpc:resourcesVpcConfig.vpcId}' --output table
aws iam get-role --role-name "$ROLE" --query 'Role.RoleName' --output text
aws ec2 describe-vpcs --filters Name=tag:Project,Values=hpb \
  --query 'Vpcs[].{Id:VpcId,Name:Tags[?Key==`Name`]|[0].Value}' --output table

# --- 2. Node groups, then cluster (releases EKS ENIs) ---
if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[]' --output text \
  | tr '\t' '\n' \
  | while read -r ng; do
      [ -n "$ng" ] || continue
      aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng"
      aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$ng"
    done
  aws eks delete-cluster --name "$CLUSTER"
  aws eks wait cluster-deleted --name "$CLUSTER"
fi

# --- 3. Load balancers in leftover HPB VPCs ---
VPCS=$(aws ec2 describe-vpcs --filters Name=tag:Project,Values=hpb --query 'Vpcs[].VpcId' --output text)
for VPC in $VPCS; do
  aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC'].LoadBalancerName" --output text \
  | tr '\t' '\n' \
  | while read -r name; do
      [ -n "$name" ] || continue
      aws elb delete-load-balancer --load-balancer-name "$name"
    done
  aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text \
  | tr '\t' '\n' \
  | while read -r arn; do
      [ -n "$arn" ] || continue
      aws elbv2 delete-load-balancer --load-balancer-arn "$arn"
    done
done

# --- 4. IAM role that causes EntityAlreadyExists on the next apply ---
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text \
  | tr '\t' '\n' \
  | while read -r arn; do
      [ -n "$arn" ] || continue
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$arn"
    done
  aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text \
  | tr '\t' '\n' \
  | while read -r name; do
      [ -n "$name" ] || continue
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$name"
    done
  aws iam delete-role --role-name "$ROLE"
fi

aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, '$CLUSTER')].Arn" --output text \
| tr '\t' '\n' \
| while read -r arn; do
    [ -n "$arn" ] || continue
    aws iam delete-policy --policy-arn "$arn" || true
  done

# --- 5. OIDC provider (optional; a leftover does not block the next apply) ---
# List only. Delete an ARN by hand if it is for this deleted cluster and you
# have no other EKS clusters in the account:
#   aws iam list-open-id-connect-providers --output table
#   aws iam delete-open-id-connect-provider --open-id-connect-provider-arn <arn>

# --- 6. Empty leftover VPCs (after ENIs are gone) ---
for VPC in $VPCS; do
  aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" \
    --query "NatGateways[?State!='deleted'].NatGatewayId" --output text \
  | tr '\t' '\n' \
  | while read -r nat; do
      [ -n "$nat" ] || continue
      aws ec2 delete-nat-gateway --nat-gateway-id "$nat"
    done
  sleep 30
  aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC" \
    --query 'InternetGateways[].InternetGatewayId' --output text \
  | tr '\t' '\n' \
  | while read -r igw; do
      [ -n "$igw" ] || continue
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC"
      aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
    done
  aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text \
  | tr '\t' '\n' \
  | while read -r sn; do
      [ -n "$sn" ] || continue
      aws ec2 delete-subnet --subnet-id "$sn"
    done
  aws ec2 delete-vpc --vpc-id "$VPC" || true
done
```

Confirm before the next apply. Empty / `ResourceNotFound` / `NoSuchEntity` is clean:

```bash
aws eks describe-cluster --name "$CLUSTER"
aws iam get-role --role-name "$ROLE"
aws ec2 describe-vpcs --filters Name=tag:Project,Values=hpb --query 'Vpcs[].VpcId' --output text
terraform state list   # expect: empty
```

Then create again with `./apply.sh` from this directory.

If an ENI is still `in-use` with description `Amazon EKS hpb-eks` and `Instance: None`, the cluster is not fully deleted yet. Wait for `aws eks wait cluster-deleted`, then retry VPC delete. Do not `detach-network-interface` on those ENIs.

### Why VPC delete used to fail (now automated)

You should **not** need extra AWS commands on a normal destroy.

Kubernetes `Service type: LoadBalancer` (frontend, gateway, prometheus) creates **classic ELBs and** `k8s-elb-`* **security groups**. Those are not Terraform resources. AWS will not delete a subnet/VPC while they exist.

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
3. **Apply** — `./apply.sh` (or a Shell step that runs it)

A native Terraform Apply step will **not** roll back on failure. To meet all-or-nothing, the Apply stage must run `apply.sh`, or a failure strategy must run `terraform destroy -auto-approve` in this directory.

Pass optional inputs as `TF_VAR_*` environment variables. Leave them unset to keep defaults.

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
- Keep `main.tf` and `variables.tf` as the only Terraform language files. `apply.sh` is the create entrypoint because HCL cannot roll back a failed apply.
