# ==================== MIMIR SERVICE ====================
# Grafana Mimir — monolithic-mode metrics backend.
# Exposes the Prometheus remote-write / query API on port 9009.
# S3 is used as the long-term block storage backend; IAM role-based access.
# mimir.yaml is read from the ECS Shares EFS at /monitoring/mimir/mimir.yaml.

# ---------------------------------------------------------------------------
# Pre-requisite: place mimir.yaml on the EFS volume before starting the task.
# Mount the ECS Shares EFS on a bastion/admin host and copy the file:
#
#   sudo mount -t nfs4 <efs-id>.efs.eu-west-1.amazonaws.com:/ /mnt/ecs-shares
#   sudo mkdir -p /mnt/ecs-shares/monitoring/mimir
#   sudo mkdir -p /mnt/ecs-shares/monitoring/mimir/data
#   sudo chown -R 10001:10001 /mnt/ecs-shares/monitoring/mimir/data
#   sudo cp mimir.yaml /mnt/ecs-shares/monitoring/mimir/mimir.yaml
#
# Minimal mimir.yaml (monolithic, single-replica, S3 backend):
#
#   target: all,no-compactor
#   multitenancy_enabled: false
#   common:
#     storage:
#       backend: s3
#       s3:
#         bucket_name: intangiblespring-mimir
#         region: eu-west-1
#   blocks_storage:
#     tsdb:
#       dir: /data/tsdb
#   compactor:
#     data_dir: /data/compactor
#   ingester:
#     ring:
#       replication_factor: 1
#   store_gateway:
#     sharding_ring:
#       replication_factor: 1
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# IAM — task role: read/write to the Mimir S3 bucket at runtime
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "ecs_task_s3_mimir" {
  name = "s3-mimir"
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
          aws_s3_bucket.mimir.arn,
          "${aws_s3_bucket.mimir.arn}/*"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# S3 bucket — Mimir block storage
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "mimir" {
  bucket = var.mimir_s3_bucket_name

  tags = merge(var.tags, {
    Name        = var.mimir_s3_bucket_name
    Environment = var.environment
    Application = "mimir"
    ManagedBy   = "Terraform"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mimir" {
  bucket = aws_s3_bucket.mimir.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "mimir" {
  bucket = aws_s3_bucket.mimir.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# ALB Target Group — Mimir (port 8080, private ALB)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "mimir" {
  name                 = "mimir-tg"
  port                 = 8080
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
    Name        = "mimir-tg"
    Environment = var.environment
    Application = "mimir"
  })
}

# ---------------------------------------------------------------------------
# Private ALB listener rule — port 80, host: mimir.intangiblespring.internal
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "mimir" {
  listener_arn = var.private_alb_listener_arn
  priority     = var.mimir_alb_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mimir.arn
  }

  condition {
    host_header {
      values = ["${var.mimir_subdomain}.${var.private_domain}"]
    }
  }

  depends_on = [aws_lb_target_group.mimir]
}

# ---------------------------------------------------------------------------
# Task Definition — Mimir service
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "mimir" {
  family                   = "mimir"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  volume {
    name = "efs-ecs-shares-monitoring-mimir"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/mimir"
      transit_encryption = "ENABLED"
    }
  }

  volume {
    name = "efs-ecs-shares-monitoring-mimir-data"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/mimir/data"
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
      name              = "mimir"
      image             = var.mimir_image
      essential         = true
      stopTimeout       = 180
      memoryReservation = 768
      memory            = 1280

      command = ["-config.file=/etc/mimir/mimir.yaml", "-target=all"]

      portMappings = [
        {
          name          = "mimir-http"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "efs-ecs-shares-monitoring-mimir"
          containerPath = "/etc/mimir"
          readOnly      = true
        },
        {
          sourceVolume  = "efs-ecs-shares-monitoring-mimir-data"
          containerPath = "/data"
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
    Name = "mimir"
  })
}

# ---------------------------------------------------------------------------
# ECS Service — Mimir
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "mimir" {
  name                               = "mimir"
  cluster                            = var.ecs_cluster_name
  task_definition                    = aws_ecs_task_definition.mimir.arn
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
      port_name = "mimir-http"

      client_alias {
        dns_name = "mimir"
        port     = 8080
      }
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mimir.arn
    container_name   = "mimir"
    container_port   = 8080
  }

  depends_on = [
    aws_lb_target_group.mimir,
    aws_lb_listener_rule.mimir,
    aws_ecs_task_definition.mimir
  ]

  tags = merge(var.tags, {
    Name        = "mimir"
    Environment = var.environment
    Application = "mimir"
  })
}

# ---------------------------------------------------------------------------
# Route53 — mimir.intangiblespring.internal → private ALB
# ---------------------------------------------------------------------------
resource "aws_route53_record" "mimir_intangiblespring_internal" {
  count = var.create_dns_records ? 1 : 0

  zone_id = var.internal_zone_id
  name    = var.mimir_subdomain
  type    = "CNAME"
  ttl     = 86400

  records = [var.private_alb_dns_name]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "mimir_service_name" {
  description = "Name of the Mimir ECS service"
  value       = aws_ecs_service.mimir.name
}

output "mimir_target_group_arn" {
  description = "ARN of the Mimir ALB target group"
  value       = aws_lb_target_group.mimir.arn
}

output "mimir_s3_bucket" {
  description = "Name of the S3 bucket used for Mimir block storage"
  value       = aws_s3_bucket.mimir.bucket
}
