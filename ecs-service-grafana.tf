# ==================== GRAFANA SERVICE ====================
# Grafana — dashboards and visualisation frontend.
# Connects to Mimir (metrics), Loki (logs) via Service Connect.
# Served publicly at https://grafana.intangiblespring.com

# ---------------------------------------------------------------------------
# Task Definition
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "grafana" {
  family                   = "grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  volume {
    name = "efs-ecs-shares-monitoring-grafana-data"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/grafana/data"
      transit_encryption = "ENABLED"
    }
  }

  volume {
    name = "efs-ecs-shares-monitoring-grafana-provisioning"
    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      root_directory     = "/monitoring/grafana/provisioning"
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
      name              = "grafana"
      image             = var.grafana_image
      essential         = true
      memoryReservation = 384
      memory            = 768

      portMappings = [
        {
          name          = "grafana-http"
          containerPort = 3000
          protocol      = "tcp"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "efs-ecs-shares-monitoring-grafana-data"
          containerPath = "/var/lib/grafana"
          readOnly      = false
        },
        {
          sourceVolume  = "efs-ecs-shares-monitoring-grafana-provisioning"
          containerPath = "/etc/grafana/provisioning"
          readOnly      = true
        }
      ]

      environment = [
        {
          name  = "GF_LOG_LEVEL"
          value = "warn"
        },
        {
          name  = "GF_SERVER_ROOT_URL"
          value = var.grafana_root_url
        },
        {
          name  = "GF_SMTP_ENABLED"
          value = tostring(var.grafana_smtp_enabled)
        },
        {
          name  = "GF_SMTP_SKIP_VERIFY"
          value = tostring(var.grafana_smtp_skip_verify)
        },
        {
          name  = "GF_SMTP_FROM_ADDRESS"
          value = var.grafana_smtp_from_address
        },
        {
          name  = "GF_SMTP_FROM_NAME"
          value = var.grafana_smtp_from_name
        },
        {
          name  = "GF_SMTP_HOST"
          value = var.grafana_smtp_host
        }
      ]

      secrets = var.grafana_smtp_enabled ? [
        {
          name      = "GF_SMTP_USER"
          valueFrom = var.grafana_smtp_user_ssm_arn
        },
        {
          name      = "GF_SMTP_PASSWORD"
          valueFrom = var.grafana_smtp_password_ssm_arn
        }
      ] : []

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
    Name = "grafana"
  })
}

# ---------------------------------------------------------------------------
# ALB Target Group — Grafana (port 3000, public ALB)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "grafana" {
  name                 = "grafana-tg"
  port                 = 3000
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = 30

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/api/health"
    matcher             = "200"
    enabled             = true
  }

  tags = merge(var.tags, {
    Name        = "grafana-tg"
    Environment = var.environment
    Application = "grafana"
  })
}

# ---------------------------------------------------------------------------
# Public ALB listener rule — HTTPS, host: grafana.intangiblespring.com
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "grafana" {
  listener_arn = var.public_alb_https_listener_arn
  priority     = var.grafana_alb_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    host_header {
      values = ["${var.grafana_subdomain}.${var.public_domain}"]
    }
  }

  depends_on = [aws_lb_target_group.grafana]
}

# ---------------------------------------------------------------------------
# ECS Service — Grafana
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "grafana" {
  name                               = "grafana"
  cluster                            = var.ecs_cluster_name
  task_definition                    = aws_ecs_task_definition.grafana.arn
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

  # Client-only — discovers mimir, loki, alloy via Service Connect
  service_connect_configuration {
    enabled   = true
    namespace = var.service_connect_namespace_arn
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }

  depends_on = [
    aws_lb_target_group.grafana,
    aws_lb_listener_rule.grafana,
    aws_ecs_task_definition.grafana
  ]

  tags = merge(var.tags, {
    Name        = "grafana"
    Environment = var.environment
    Application = "grafana"
  })
}

# ---------------------------------------------------------------------------
# Route53 — grafana.intangiblespring.com → public ALB
# ---------------------------------------------------------------------------
resource "aws_route53_record" "grafana_intangiblespring_com" {
  count = var.create_dns_records ? 1 : 0

  zone_id = var.grafana_public_zone_id
  name    = var.grafana_subdomain
  type    = "CNAME"
  ttl     = 86400

  records = [var.public_alb_dns_name]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "grafana_service_name" {
  description = "Name of the Grafana ECS service"
  value       = aws_ecs_service.grafana.name
}
