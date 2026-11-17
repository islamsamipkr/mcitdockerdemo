# Low-cost AWS ECS Fargate mini demo

A tiny Python website and `/api/hello` JSON API deployed as a **single** Amazon ECS task on Fargate. Uses ARM64 / Linux, 0.25 vCPU and 512 MiB RAM, one public IP, **no ALB**, **no NAT Gateway**. Inbound port 8080 is restricted to the public IP of your deploy machine. ECS is in your default VPC. **Demo only, not a production network/security architecture.**

## What you need

- AWS account, AWS CLI v2 authenticated (`aws sts get-caller-identity`), permissions for IAM, EC2/VPC, ECS, ECR, CloudWatch Logs
- Docker Desktop or Docker Engine with Buildx and ability to build `linux/arm64` images; `curl`
- Bash (macOS, Linux or WSL). Run from the folder containing this README.
- A **default VPC** with a public subnet and internet gateway in the selected AWS Region
- Optional: `MY_IP_CIDR=x.x.x.x/32` if automatic client IPv4 discovery is unavailable

## 1. Run locally

```bash
docker build -t fargate-mini-demo:local .
docker run --rm -p 8080:8080 fargate-mini-demo:local
# Browse http://localhost:8080
# curl http://localhost:8080/api/hello
```

## 2. Deploy using Fargate On-Demand

```bash
export AWS_REGION=us-east-1
./deploy.sh
```

The script builds a `linux/arm64` container, pushes to ECR, creates a dedicated ECS execution role, configures CloudWatch Logs with 1-day retention, creates a security group limited to your current IP, registers a task definition, creates a 1-task ECS service in a public default-VPC subnet, and prints the public-IP URL.

You can inspect:

- **ECS console** → Clusters → `fargate-mini-demo-cluster` → Services → `fargate-mini-demo-service` → Tasks
- **ECR** → Repositories → `fargate-mini-demo`
- **CloudWatch** → Log groups → `/ecs/fargate-mini-demo`

## Optional: Deploy using Fargate Spot

```bash
CAPACITY_PROVIDER=FARGATE_SPOT ./deploy.sh
```

Spot pricing changes and tasks may be interrupted or unavailable. Use On-Demand for a reliable lesson.

## Stop billing and delete the demo

```bash
./cleanup.sh
```

This stops/deletes the ECS service and cluster, unregisters active task definitions, removes the ECR repository, log group, security group and demo execution role. The script can report a security group still attached to a task ENI; check and delete it later after its ENI detaches. Double-check there are no other running ECS tasks or unexpected charges in your account.

## Cost estimate (us-east-1, US dollars)

At approx. Nov 2026 On-Demand Linux ARM rates: vCPU `$0.03238`/hour, memory `$0.00356`/GiB-hour, plus public IPv4 `$0.005`/hour:

- CPU: `0.25 × $0.03238 = $0.008095/hour`
- Memory: `0.5 × $0.00356 = $0.00178/hour`
- Public IPv4: `$0.005/hour`
- Total: **~$0.014875/hour**; **~$0.36 for 24 hours**; **~$10.86 for 730 hours**.

Excludes ECR storage, logging, outbound data transfer, taxes, and other AWS fees. No NAT, ALB or extra ephemeral storage. Spot pricing can change at any time.

For occasional requests, Lambda with a container image and a function URL is frequently cheaper; for a permanent tiny container, Lightsail's managed container nano plan starts at $7/month; a Lightsail VM with Docker starts at $5/month but requires OS administration.

Official price lists: https://aws.amazon.com/fargate/pricing/ | https://aws.amazon.com/vpc/pricing/ | https://aws.amazon.com/lightsail/pricing/

## Notes

- The public IP can change whenever ECS replaces the task. There's no load balancer, HTTPS termination, custom domain, WAF or HA.
- Web access is HTTP only and limited by a security group to your client IP. Do **not** put secrets, login forms, or user information here.
- A public subnet's route table must reach an Internet Gateway so the task can pull from ECR. This example doesn't create a NAT Gateway or VPC endpoints.
- Running continuously costs money even with no requests. Stop the demo using `./cleanup.sh`.
- If you have no default VPC, create/choose a public subnet and adapt the script to your VPC.
