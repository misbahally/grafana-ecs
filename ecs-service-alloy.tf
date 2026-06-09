# ==================== ALLOY SERVICE ====================
# Grafana Alloy — telemetry collector (metrics, logs, traces).
# config.alloy is read from the ECS Shares EFS at /monitoring/alloy/config.alloy.
# Alloy UI / API is available on port 12345 (internal only).

# ---------------------------------------------------------------------------
# Pre-requisite: place config.alloy on the EFS volume before starting the task.
# Mount the ECS Shares EFS on a bastion/admin host and copy the file:
#
#   sudo mount -t nfs4 <efs-id>.efs.eu-west-1.amazonaws.com:/ /mnt/ecs-shares
#   sudo mkdir -p /mnt/ecs-shares/monitoring/alloy
#   sudo cp config.alloy /mnt/ecs-shares/monitoring/alloy/config.alloy
#
# Minimal config.alloy example (scrape self + remote-write to Mimir):
#
#   prometheus.scrape "alloy" {
#     targets    = [{"__address__" = "localhost:12345"}]
#     forward_to = [prometheus.remote_write.mimir.receiver]
#   }
#
#   prometheus.remote_write "mimir" {
#     endpoint {
#       url = "http://mimir:8080/api/v1/push"
#     }
#   }
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ALB Target Group — Alloy UI/API (port 12345, private ALB)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "alloy" {
  name                 = "alloy-tg"
  port                 = 12345
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/-/ready"
    matcher             = "200"
    enabled             = true
  }

  tags = merge(var.tags, {
    Name        = "alloy-tg"
    Environment = var.environment
    Application = "alloy"
  })
}

# ---------------------------------------------------------------------------
# ALB Target Group — Alloy Loki push endpoint (port 3500, private ALB)
# Used by FluentBit/Fluentd to ship logs to Alloy via the Loki push API.
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "alloy_loki" {
  name                 = "alloy-loki-tg"
  port                 = 3500
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
    port                = 12345
    matcher             = "200"
    enabled             = true
  }

  tags = merge(var.tags, {
    Name        = "alloy-loki-tg"
    Environment = var.environment
    Application = "alloy"
  })
}

# ---------------------------------------------------------------------------
# Private ALB listener rule — port 80, host: fluentd-alloy.intangiblespring.internal
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "alloy_loki" {
  listener_arn = var.private_alb_listener_arn
  priority     = var.alloy_loki_alb_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alloy_loki.arn
  }

  condition {
    host_header {
      values = ["${var.alloy_loki_subdomain}.${var.private_domain}"]
    }
  }

  depends_on = [aws_lb_target_group.alloy_loki]
}

# ---------------------------------------------------------------------------
# Private ALB listener rule — port 80, host: alloy.intangiblespring.internal
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "alloy" {
  listener_arn = var.private_alb_listener_arn
  priority     = var.alloy_alb_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alloy.arn
  }

  condition {
    host_header {
      values = ["${var.alloy_subdomain}.${var.private_domain}"]
    }
  }

  depends_on = [aws_lb_target_group.alloy]
}

# ---------------------------------------------------------------------------
# Task Definition — Alloy service
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "alloy" {
  family                   = "alloy"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  volume {
    name = "efs-ecs-shares-monitoring-alloy"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/alloy"
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
      name              = "alloy"
      image             = var.alloy_image
      essential         = true
      stopTimeout       = 60
      memoryReservation = 512
      memory            = 1024

      command = [
        "run",
        "/etc/alloy/config.alloy",
        "--server.http.listen-addr=0.0.0.0:12345",
        "--storage.path=/tmp/alloy"
      ]

      portMappings = [
        {
          name          = "alloy-http"
          containerPort = 12345
          protocol      = "tcp"
        },
        {
          name          = "alloy-loki"
          containerPort = 3500
          protocol      = "tcp"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "efs-ecs-shares-monitoring-alloy"
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
    },
    {
      name              = "alloy-sidecar"
      image             = var.alloy_image
      essential         = false
      memoryReservation = 64
      memory            = 128

      command = [
        "run",
        "/etc/alloy/config.alloy",
        "--server.http.listen-addr=0.0.0.0:12346",
        "--storage.path=/tmp/alloy-sidecar",
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
    Name = "alloy"
  })
}

# ---------------------------------------------------------------------------
# ECS Service — Alloy
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "alloy" {
  name                               = "alloy"
  cluster                            = var.ecs_cluster_name
  task_definition                    = aws_ecs_task_definition.alloy.arn
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
      port_name = "alloy-http"

      client_alias {
        dns_name = "alloy"
        port     = 12345
      }
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.alloy.arn
    container_name   = "alloy"
    container_port   = 12345
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.alloy_loki.arn
    container_name   = "alloy"
    container_port   = 3500
  }

  depends_on = [
    aws_lb_target_group.alloy,
    aws_lb_listener_rule.alloy,
    aws_lb_target_group.alloy_loki,
    aws_lb_listener_rule.alloy_loki,
    aws_ecs_task_definition.alloy
  ]

  tags = merge(var.tags, {
    Name        = "alloy"
    Environment = var.environment
    Application = "alloy"
  })
}

# ---------------------------------------------------------------------------
# Route53 — alloy.intangiblespring.internal → private ALB
# ---------------------------------------------------------------------------
resource "aws_route53_record" "alloy_intangiblespring_internal" {
  count = var.create_dns_records ? 1 : 0

  zone_id = var.internal_zone_id
  name    = var.alloy_subdomain
  type    = "CNAME"
  ttl     = 86400

  records = [var.private_alb_dns_name]
}

# ---------------------------------------------------------------------------
# Route53 — fluentd-alloy.intangiblespring.internal → private ALB
# ---------------------------------------------------------------------------
resource "aws_route53_record" "fluentd_alloy_intangiblespring_internal" {
  count = var.create_dns_records ? 1 : 0

  zone_id = var.internal_zone_id
  name    = var.alloy_loki_subdomain
  type    = "CNAME"
  ttl     = 86400

  records = [var.private_alb_dns_name]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "alloy_service_name" {
  description = "Name of the Alloy ECS service"
  value       = aws_ecs_service.alloy.name
}
