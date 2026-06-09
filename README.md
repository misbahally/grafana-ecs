# terraform-ecs-grafana-stack

A Terraform module that deploys a complete, production-ready observability stack on **AWS ECS (EC2 launch type)**:

| Service | Role | Port |
|---------|------|------|
| [Grafana](https://grafana.com/grafana/) | Visualisation frontend | 3000 |
| [Grafana Loki](https://grafana.com/loki/) | Log aggregation | 3100 |
| [Grafana Mimir](https://grafana.com/mimir/) | Long-term metrics storage | 8080 |
| [Grafana Alloy](https://grafana.com/alloy/) | Telemetry collector (standalone) | 12345, 3500 |

Each service runs as an ECS task with:
- An **EFS volume** for configuration files and persistent data
- An **Alloy sidecar** for local telemetry scraping
- **ECS Service Connect** for zero-config internal service discovery (`loki`, `mimir`, `alloy`)
- **ALB listener rules** for external (Grafana) or internal (Loki, Mimir, Alloy) access
- Optional **Route53 CNAME records**

---

## Architecture

```
Internet ──► Public ALB ──► Grafana (port 3000)
                                 │
                    Service Connect namespace
                         ┌───────┼───────┐
                         ▼       ▼       ▼
                        Loki   Mimir   Alloy
                       (3100) (8080) (12345)

Private ALB ──► Loki / Mimir / Alloy (internal only)

S3 ◄──── Loki (chunk/index storage)
S3 ◄──── Mimir (block storage)
EFS ◄─── All services (config + data)
```

---

## Prerequisites

The following resources must exist **before** using this module:

- An ECS cluster (EC2 launch type)
- ECS task execution and task IAM roles
- An EFS file system with the directory structure below
- A public (internet-facing) ALB with an HTTPS listener
- A private (internal) ALB with an HTTP listener
- A VPC with private subnets
- A security group for ECS tasks
- An AWS Cloud Map HTTP namespace for Service Connect
- *(Optional)* Route53 hosted zones for public and private domains

### EFS directory structure

Mount the EFS file system and create the following directories before starting any service:

```bash
sudo mount -t nfs4 <efs-id>.efs.<region>.amazonaws.com:/ /mnt/efs

sudo mkdir -p /mnt/efs/monitoring/grafana/data
sudo mkdir -p /mnt/efs/monitoring/grafana/provisioning
sudo mkdir -p /mnt/efs/monitoring/loki/data
sudo mkdir -p /mnt/efs/monitoring/mimir/data
sudo mkdir -p /mnt/efs/monitoring/alloy
sudo mkdir -p /mnt/efs/monitoring/sidecar/alloy

# Loki and Mimir data directories need to be owned by UID 10001
sudo chown -R 10001:10001 /mnt/efs/monitoring/loki/data
sudo chown -R 10001:10001 /mnt/efs/monitoring/mimir/data
```

Place service configuration files on the EFS:
- `/monitoring/loki/loki.yaml` — Loki configuration
- `/monitoring/mimir/mimir.yaml` — Mimir configuration
- `/monitoring/alloy/config.alloy` — Alloy (standalone) configuration
- `/monitoring/sidecar/alloy/config.alloy` — Alloy sidecar configuration (shared by Grafana, Loki, Mimir)
- `/monitoring/grafana/provisioning/` — Grafana provisioning files (datasources, dashboards, etc.)

---

## Usage

```hcl
module "grafana_stack" {
  source = "github.com/misbahally/terraform-ecs-grafana-stack"

  # Networking
  vpc_id            = "vpc-0123456789abcdef0"
  private_subnets   = ["subnet-aaa", "subnet-bbb"]
  security_group_id = aws_security_group.ecs_tasks.id

  # ECS cluster
  ecs_cluster_name            = aws_ecs_cluster.main.name
  ecs_task_execution_role_arn = aws_iam_role.ecs_execution.arn
  ecs_task_role_arn           = aws_iam_role.ecs_task.arn
  ecs_task_role_name          = aws_iam_role.ecs_task.name

  # Storage
  efs_file_system_id = aws_efs_file_system.main.id

  # Observability
  cloudwatch_log_group_name     = aws_cloudwatch_log_group.ecs.name
  service_connect_namespace_arn = aws_service_discovery_http_namespace.monitoring.arn

  # Load balancers
  public_alb_https_listener_arn = aws_lb_listener.https.arn
  private_alb_listener_arn      = aws_lb_listener.private_http.arn
  public_alb_dns_name           = aws_lb.public.dns_name
  private_alb_dns_name          = aws_lb.private.dns_name

  # DNS
  public_domain          = "example.com"
  private_domain         = "corp.internal"
  grafana_public_zone_id = "Z1234567890ABCDEF"
  internal_zone_id       = "Z0987654321FEDCBA"

  # S3 buckets (must be globally unique)
  loki_s3_bucket_name  = "my-company-loki"
  mimir_s3_bucket_name = "my-company-mimir"

  # Grafana
  grafana_root_url = "https://grafana.example.com"

  # Optional: SMTP alerts
  grafana_smtp_enabled          = true
  grafana_smtp_host             = "smtp.example.com:587"
  grafana_smtp_from_address     = "grafana@example.com"
  grafana_smtp_user_ssm_arn     = aws_ssm_parameter.smtp_user.arn
  grafana_smtp_password_ssm_arn = aws_ssm_parameter.smtp_password.arn
}
```

---

## Inputs

### Required

| Name | Description | Type |
|------|-------------|------|
| `vpc_id` | VPC ID | `string` |
| `private_subnets` | List of private subnet IDs for ECS tasks | `list(string)` |
| `security_group_id` | Security group ID for ECS tasks | `string` |
| `ecs_cluster_name` | ECS cluster name | `string` |
| `ecs_task_execution_role_arn` | ARN of the ECS task execution role | `string` |
| `ecs_task_role_arn` | ARN of the ECS task role | `string` |
| `ecs_task_role_name` | Name of the ECS task role (used for inline S3 policies) | `string` |
| `efs_file_system_id` | EFS file system ID | `string` |
| `cloudwatch_log_group_name` | CloudWatch log group name | `string` |
| `service_connect_namespace_arn` | Cloud Map namespace ARN for Service Connect | `string` |
| `public_alb_https_listener_arn` | ARN of the public ALB HTTPS listener | `string` |
| `private_alb_listener_arn` | ARN of the private ALB HTTP listener | `string` |
| `public_domain` | Public domain (e.g. `example.com`) | `string` |
| `private_domain` | Private domain (e.g. `corp.internal`) | `string` |
| `loki_s3_bucket_name` | S3 bucket name for Loki storage | `string` |
| `mimir_s3_bucket_name` | S3 bucket name for Mimir storage | `string` |
| `grafana_root_url` | Full public URL for Grafana (e.g. `https://grafana.example.com`) | `string` |

### Optional

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `public_alb_dns_name` | Public ALB DNS name (required if `create_dns_records = true`) | `string` | `null` |
| `private_alb_dns_name` | Private ALB DNS name (required if `create_dns_records = true`) | `string` | `null` |
| `grafana_public_zone_id` | Route53 zone ID for public domain | `string` | `null` |
| `internal_zone_id` | Route53 zone ID for private domain | `string` | `null` |
| `create_dns_records` | Create Route53 CNAME records | `bool` | `true` |
| `grafana_subdomain` | Grafana subdomain prefix | `string` | `"grafana"` |
| `loki_subdomain` | Loki subdomain prefix | `string` | `"loki"` |
| `mimir_subdomain` | Mimir subdomain prefix | `string` | `"mimir"` |
| `alloy_subdomain` | Alloy subdomain prefix | `string` | `"alloy"` |
| `alloy_loki_subdomain` | Alloy Loki push endpoint subdomain prefix | `string` | `"fluentd-alloy"` |
| `grafana_image` | Grafana container image | `string` | `"grafana/grafana:12.4.3-security-02"` |
| `loki_image` | Loki container image | `string` | `"grafana/loki:3.6.10"` |
| `mimir_image` | Mimir container image | `string` | `"grafana/mimir:3.0.6"` |
| `alloy_image` | Alloy container image | `string` | `"grafana/alloy:v1.16.1"` |
| `grafana_alb_rule_priority` | ALB listener rule priority for Grafana | `number` | `89` |
| `loki_alb_rule_priority` | ALB listener rule priority for Loki | `number` | `12` |
| `mimir_alb_rule_priority` | ALB listener rule priority for Mimir | `number` | `10` |
| `alloy_alb_rule_priority` | ALB listener rule priority for Alloy UI | `number` | `11` |
| `alloy_loki_alb_rule_priority` | ALB listener rule priority for Alloy Loki push | `number` | `13` |
| `grafana_smtp_enabled` | Enable SMTP email in Grafana | `bool` | `false` |
| `grafana_smtp_host` | SMTP host:port | `string` | `""` |
| `grafana_smtp_skip_verify` | Skip SMTP TLS verification | `bool` | `false` |
| `grafana_smtp_from_address` | Grafana sender email | `string` | `""` |
| `grafana_smtp_from_name` | Grafana sender display name | `string` | `"Grafana"` |
| `grafana_smtp_user_ssm_arn` | SSM ARN for SMTP username | `string` | `null` |
| `grafana_smtp_password_ssm_arn` | SSM ARN for SMTP password | `string` | `null` |
| `environment` | Environment tag value | `string` | `"production"` |
| `tags` | Additional tags for all resources | `map(string)` | `{}` |

---

## Outputs

| Name | Description |
|------|-------------|
| `grafana_service_name` | ECS service name for Grafana |
| `loki_service_name` | ECS service name for Loki |
| `loki_s3_bucket` | S3 bucket name used by Loki |
| `mimir_service_name` | ECS service name for Mimir |
| `mimir_s3_bucket` | S3 bucket name used by Mimir |
| `mimir_target_group_arn` | ARN of the Mimir ALB target group |
| `alloy_service_name` | ECS service name for Alloy |

---

## Configuration file examples

### `loki.yaml` (minimal, filesystem storage)

```yaml
auth_enabled: false
server:
  http_listen_port: 3100
common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
```

### `mimir.yaml` (minimal, S3 backend)

```yaml
target: all,no-compactor
multitenancy_enabled: false
common:
  storage:
    backend: s3
    s3:
      bucket_name: <your-mimir-bucket>
      region: <aws-region>
blocks_storage:
  tsdb:
    dir: /data/tsdb
compactor:
  data_dir: /data/compactor
ingester:
  ring:
    replication_factor: 1
store_gateway:
  sharding_ring:
    replication_factor: 1
```

### `config.alloy` (minimal, scrape self + remote-write to Mimir)

```alloy
prometheus.scrape "alloy" {
  targets    = [{"__address__" = "localhost:12345"}]
  forward_to = [prometheus.remote_write.mimir.receiver]
}

prometheus.remote_write "mimir" {
  endpoint {
    url = "http://mimir:8080/api/v1/push"
  }
}
```

---

## License

MIT
