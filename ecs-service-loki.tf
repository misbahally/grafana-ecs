# ==================== LOKI SERVICE ====================
# Grafana Loki — log aggregation backend.
# loki.yaml is read from the ECS Shares EFS at /monitoring/loki/loki.yaml.
# HTTP API / query frontend is available on port 3100.

# ---------------------------------------------------------------------------
# Pre-requisite: place loki.yaml on the EFS volume before starting the task.
# Mount the ECS Shares EFS on a bastion/admin host and copy the file:
#
#   sudo mount -t nfs4 <efs-id>.efs.eu-west-1.amazonaws.com:/ /mnt/ecs-shares
#   sudo mkdir -p /mnt/ecs-shares/monitoring/loki/data
#   sudo chown -R 10001:10001 /mnt/ecs-shares/monitoring/loki/data
#   sudo cp loki.yaml /mnt/ecs-shares/monitoring/loki/loki.yaml
#
# Minimal loki.yaml (filesystem storage, single binary):
#
#   auth_enabled: false
#   server:
#     http_listen_port: 3100
#   common:
#     path_prefix: /loki
#     storage:
#       filesystem:
#         chunks_directory: /loki/chunks
#         rules_directory: /loki/rules
#     replication_factor: 1
#     ring:
#       instance_addr: 127.0.0.1
#       kvstore:
#         store: inmemory
#   schema_config:
#     configs:
#       - from: 2024-01-01
#         store: tsdb
#         object_store: filesystem
#         schema: v13
#         index:
#           prefix: index_
#           period: 24h
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# IAM — task role: read/write to the Loki S3 bucket at runtime
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "ecs_task_s3_loki" {
  name = "s3-loki"
  role = var.ecs_task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.loki.arn,
          "${aws_s3_bucket.loki.arn}/*"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# S3 bucket — Loki chunk/index storage
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "loki" {
  bucket = var.loki_s3_bucket_name

  tags = merge(var.tags, {
    Name        = var.loki_s3_bucket_name
    Environment = var.environment
    Application = "loki"
    ManagedBy   = "Terraform"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket = aws_s3_bucket.loki.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# ALB Target Group — Loki (port 3100, private ALB)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "loki" {
  name                 = "loki-tg"
  port                 = 3100
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/ready"
    matcher             = "200"
    enabled             = true
  }

  tags = merge(var.tags, {
    Name        = "loki-tg"
    Environment = var.environment
    Application = "loki"
  })
}

# ---------------------------------------------------------------------------
# Private ALB listener rule — port 80, host: loki.intangiblespring.internal
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "loki" {
  listener_arn = var.private_alb_listener_arn
  priority     = var.loki_alb_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loki.arn
  }

  condition {
    host_header {
      values = ["${var.loki_subdomain}.${var.private_domain}"]
    }
  }

  depends_on = [aws_lb_target_group.loki]
}

# ---------------------------------------------------------------------------
# Task Definition — Loki service
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "loki" {
  family                   = "loki"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  volume {
    name = "efs-ecs-shares-monitoring-loki"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/loki"
      transit_encryption = "ENABLED"
    }
  }

  volume {
    name = "efs-ecs-shares-monitoring-loki-data"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/loki/data"
      transit_encryption = "ENABLED"
    }
  }

  volume {
    name = "efs-ecs-shares-monitoring-alloy-sidecar"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/sidecar/alloy"
      transit_encryption = "ENABLED"
    }
  }

  container_definitions = jsonencode([
    {
      name              = "loki"
      image             = var.loki_image
      essential         = true
      stopTimeout       = 120
      memoryReservation = 512
      memory            = 1024

      command = ["-config.file=/etc/loki/loki.yaml", "-server.grpc-listen-port=9096"]

      portMappings = [
        {
          name          = "loki-http"
          containerPort = 3100
          protocol      = "tcp"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "efs-ecs-shares-monitoring-loki"
          containerPath = "/etc/loki"
          readOnly      = true
        },
        {
          sourceVolume  = "efs-ecs-shares-monitoring-loki-data"
          containerPath = "/loki"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.cloudwatch_log_group_name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name              = "alloy"
      image             = var.alloy_image
      essential         = false
      memoryReservation = 64
      memory            = 128

      command = [
        "run",
        "/etc/alloy/config.alloy",
        "--storage.path=/tmp/alloy",
        "--stability.level=experimental"
      ]

      mountPoints = [
        {
          sourceVolume  = "efs-ecs-shares-monitoring-alloy-sidecar"
          containerPath = "/etc/alloy"
          readOnly      = true
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.cloudwatch_log_group_name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = merge(var.tags, {
    Name = "loki"
  })
}

# ---------------------------------------------------------------------------
# ECS Service — Loki
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "loki" {
  name                               = "loki"
  cluster                            = var.ecs_cluster_name
  task_definition                    = aws_ecs_task_definition.loki.arn
  desired_count                      = 1
  launch_type                        = "EC2"
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  service_connect_configuration {
    enabled   = true
    namespace = var.service_connect_namespace_arn

    service {
      port_name = "loki-http"

      client_alias {
        dns_name = "loki"
        port     = 3100
      }
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.loki.arn
    container_name   = "loki"
    container_port   = 3100
  }

  depends_on = [
    aws_lb_target_group.loki,
    aws_lb_listener_rule.loki,
    aws_ecs_task_definition.loki
  ]

  tags = merge(var.tags, {
    Name        = "loki"
    Environment = var.environment
    Application = "loki"
  })
}

# ---------------------------------------------------------------------------
# Route53 — loki.intangiblespring.internal → private ALB
# ---------------------------------------------------------------------------
resource "aws_route53_record" "loki_intangiblespring_internal" {
  count = var.create_dns_records ? 1 : 0

  zone_id = var.internal_zone_id
  name    = var.loki_subdomain
  type    = "CNAME"
  ttl     = 86400

  records = [var.private_alb_dns_name]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "loki_service_name" {
  description = "Name of the Loki ECS service"
  value       = aws_ecs_service.loki.name
}

output "loki_s3_bucket" {
  description = "Name of the S3 bucket used for Loki storage"
  value       = aws_s3_bucket.loki.bucket
}
