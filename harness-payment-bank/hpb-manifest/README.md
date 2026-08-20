# Kubernetes Deployment for Harness Payments Bank Demo Application


## Architecture Overview

The application consists of:

### Infrastructure Components
- **PostgreSQL**: Relational database for core banking data
- **MongoDB**: NoSQL database for notifications
- **Kafka + Zookeeper**: Message broker for event-driven communication
- **Mail-dev**: Email testing server

### Microservices
- **Discovery Service (Eureka)**: Service registry and discovery (Port: 8761)
- **Config Server**: Centralized configuration management (Port: 8888)
- **Gateway Service**: API Gateway and routing (Port: 8080)
- **Account Service**: Account management (Port: 8070)
- **Auth Service**: Authentication service (Port: 8060)
- **Transaction Service**: Transaction processing (Port: 8090)
- **Loan Service**: Loan management (Port: 8050)
- **Notification Service**: Email/SMS notifications (Port: 10050)
- **Frontend Service**: Web UI (Port: 80)

## Prerequisites

Before deploying the application, ensure you have the following:

1. **Kubernetes Cluster**: A running Kubernetes cluster (GKE, EKS, AKS, Minikube, Kind, etc.)
   - Minimum 3 nodes recommended
   - At least 4GB RAM per node

2. **kubectl**: Configured to connect to your Kubernetes cluster
   ```bash
   kubectl cluster-info
   kubectl get nodes
   ```

3. **Storage Class**: Your cluster must have a default StorageClass configured
   ```bash
   # Check if default storage class exists
   kubectl get storageclass
   
   # Look for one marked as (default)
   # If no default exists, mark one as default:
   kubectl patch storageclass <storage-class-name> -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
   ```

4. **SMTP Configuration (Optional)**: For sending transaction notification emails
   - SendGrid API key or any SMTP server credentials
   - If not configured, the application will still work but won't send emails

## Installation Steps

### Step 1: Create the Banking Namespace

```bash
kubectl create namespace banking
```

### Step 2: Create SMTP Secret (Optional)

If you want to enable email notifications for transactions, create the SendGrid/SMTP secret:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: sendgrid-secret
  namespace: banking
type: Opaque
stringData:
  SENDGRID_HOST: "smtp.sendgrid.net"
  SENDGRID_USERNAME: "apikey"
  SENDGRID_API_KEY: "YOUR_SENDGRID_API_KEY"  # Replace with your actual SendGrid/SMTP API key
  SENDGRID_VERIFIED_EMAIL: "noreply@yourdomain.com"  # Replace with your verified email
EOF
```

**Note**: If you skip this step, the application will still work, but email notifications will not be sent.

### Step 3: Deploy All Kubernetes Resources

Apply all the manifests in the `hpb-k8s/` directory:

```bash
# Navigate to the hpb-k8s directory
cd hpb-k8s

# Apply all Kubernetes manifests
kubectl apply -f . -n banking
```

This will deploy:
- ConfigMaps and Secrets
- Persistent Volume Claims
- Databases (PostgreSQL, MongoDB)
- Kafka Infrastructure (Kafka)
- Microservices (Discovery, Config Server, Account, Auth, Loan, Transaction, Notification)
- API Gateway
- Frontend Service

### Step 4: Wait for Pods to be Ready

Monitor the deployment status:

```bash
# Watch all pods in the banking namespace
kubectl get pods -n banking -w

# Or check the status periodically
kubectl get pods -n banking
```

Wait until all pods show `Running` status and are ready (e.g., `1/1`, `2/2`). This may take 5-10 minutes depending on your cluster.

**Tip**: Some services have init containers that wait for dependencies, so they may take longer to start.

### Step 5: List Services and Get Gateway LoadBalancer IP

Once all pods are running, list the services:

```bash
kubectl get svc -n banking
```

Look for the `gateway-service` and note its `EXTERNAL-IP`. If you're using a cloud provider (GKE, EKS, AKS), it will be assigned a LoadBalancer IP. If using Minikube or Kind, you may need to use port-forwarding or NodePort.

```bash
# Wait for the LoadBalancer IP to be assigned
kubectl get svc gateway-service -n banking -w
```

Example output:
```
NAME              TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)          AGE
gateway-service   LoadBalancer   10.96.123.45    34.132.32.57     8080:30123/TCP   5m
```

### Step 6: Update Frontend Service with Gateway IP

Once you have the Gateway LoadBalancer IP, update the `VITE_API_URL` environment variable in the frontend deployment:

```bash
# Replace <GATEWAY_IP> with your actual Gateway LoadBalancer IP
kubectl set env deployment/frontend-service VITE_API_URL=http://<GATEWAY_IP>:8080 -n banking

# Example:
# kubectl set env deployment/frontend-service VITE_API_URL=http://34.132.32.57:8080 -n banking
```

Alternatively, you can edit the `frontend-service.yaml` file and update the `VITE_API_URL` value, then reapply:

```bash
# Edit the file
nano frontend-service.yaml

# Update this line:
# - name: VITE_API_URL
#   value: "http://<YOUR_GATEWAY_IP>:8080"

# Reapply the deployment
kubectl apply -f frontend-service.yaml -n banking
```

### Step 7: Access the Application

Get the frontend service external IP:

```bash
kubectl get svc frontend-service -n banking
```

Access the application in your browser:
- **Frontend UI**: `http://<FRONTEND_EXTERNAL_IP>`
- **API Gateway**: `http://<GATEWAY_EXTERNAL_IP>:8080`
- **Eureka Dashboard**: `http://<DISCOVERY_SERVICE_IP>:8080`

If using **Minikube**, use:
```bash
minikube service frontend-service -n banking
minikube service gateway-service -n banking
```

If using **Port Forwarding** (for local development):
```bash
# Frontend
kubectl port-forward svc/frontend-service 8081:80 -n banking

# Gateway
kubectl port-forward svc/gateway-service 8080:8080 -n banking

# Then access:
# Frontend: http://localhost:8081
# API Gateway: http://localhost:8080
```

## Accessing Services

### Via LoadBalancer (Gateway Service)

The Gateway Service is exposed via LoadBalancer. Get the external IP:

```bash
kubectl get svc gateway-service -n banking -w
```

Wait for the `EXTERNAL-IP` to be assigned (this may take a few minutes), then access the API Gateway at: `http://<EXTERNAL-IP>:8080`

```

## Monitoring and Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n banking
```

### View Logs

```bash
# View logs of a specific service
kubectl logs -f deployment/account-service -n banking

# View logs of all pods with a specific label
kubectl logs -l app=account-service -n banking --all-containers=true
```

### Describe Resources

```bash
# Describe a pod
kubectl describe pod <pod-name> -n banking

# Describe a service
kubectl describe svc gateway-service -n banking
```

### Check Events

```bash
kubectl get events -n banking --sort-by='.lastTimestamp'
```

