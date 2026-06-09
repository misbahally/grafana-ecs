# ==============================================================================
# Core Networking
# ==============================================================================

variable "vpc_id" {
  description = "ID of the VPC where all resources will be deployed."
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs for ECS task network interfaces."
  type        = list(string)
}

variable "security_group_id" {
  description = "ID of the security group attached to all ECS tasks."
  type        = string
}

# ==============================================================================
# ECS Cluster
# ==============================================================================

variable "ecs_cluster_name" {
  description = "Name of the existing ECS cluster to deploy services into."
  type        = string
}

variable "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution IAM role (used to pull images and write logs)."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "ARN of the ECS task IAM role (used at runtime by the containers)."
  type        = string
}

variable "ecs_task_role_name" {
  description = "Name of the ECS task IAM role. Used to attach inline S3 policies for Loki and Mimir."
  type        = string
}

# ==============================================================================
# EFS
# ==============================================================================

variable "efs_file_system_id" {
  description = "ID of the EFS file system that holds config files and persistent data for all services."
  type        = string
}

# ==============================================================================
# CloudWatch
# ==============================================================================

variable "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch Logs group where ECS container logs are sent."
  type        = string
}

# ==============================================================================
# ECS Service Connect
# ==============================================================================

variable "service_connect_namespace_arn" {
  description = "ARN of the AWS Cloud Map HTTP namespace used by ECS Service Connect for service discovery."
  type        = string
}

# ==============================================================================
# Load Balancers
# ==============================================================================

variable "public_alb_https_listener_arn" {
  description = "ARN of the public (internet-facing) ALB HTTPS listener. Used for the Grafana listener rule."
  type        = string
}

variable "private_alb_listener_arn" {
  description = "ARN of the private (internal) ALB HTTP listener. Used for Loki, Mimir, and Alloy listener rules."
  type        = string
}

variable "public_alb_dns_name" {
  description = "DNS name of the public ALB. Used as the CNAME target for the Grafana Route53 record. Required when create_dns_records = true."
  type        = string
  default     = null
}

variable "private_alb_dns_name" {
  description = "DNS name of the private ALB. Used as the CNAME target for internal Route53 records. Required when create_dns_records = true."
  type        = string
  default     = null
}

# ==============================================================================
# DNS
# ==============================================================================

variable "public_domain" {
  description = "Public domain name (e.g. example.com). Used to construct the Grafana public hostname."
  type        = string
}

variable "private_domain" {
  description = "Private/internal domain name (e.g. corp.internal). Used to construct internal hostnames for Loki, Mimir, and Alloy."
  type        = string
}

variable "grafana_public_zone_id" {
  description = "Route53 hosted zone ID for the public domain. Required when create_dns_records = true."
  type        = string
  default     = null
}

variable "internal_zone_id" {
  description = "Route53 hosted zone ID for the private/internal domain. Required when create_dns_records = true."
  type        = string
  default     = null
}

variable "create_dns_records" {
  description = "Set to true to create Route53 CNAME records for all services."
  type        = bool
  default     = true
}

# ==============================================================================
# Subdomains (used to build hostnames and Route53 record names)
# ==============================================================================

variable "grafana_subdomain" {
  description = "Subdomain for Grafana. Final hostname: <grafana_subdomain>.<public_domain>."
  type        = string
  default     = "grafana"
}

variable "loki_subdomain" {
  description = "Subdomain for Loki. Final hostname: <loki_subdomain>.<private_domain>."
  type        = string
  default     = "loki"
}

variable "mimir_subdomain" {
  description = "Subdomain for Mimir. Final hostname: <mimir_subdomain>.<private_domain>."
  type        = string
  default     = "mimir"
}

variable "alloy_subdomain" {
  description = "Subdomain for Alloy UI/API. Final hostname: <alloy_subdomain>.<private_domain>."
  type        = string
  default     = "alloy"
}

variable "alloy_loki_subdomain" {
  description = "Subdomain for the Alloy Loki push endpoint (used by log shippers such as FluentBit/Fluentd). Final hostname: <alloy_loki_subdomain>.<private_domain>."
  type        = string
  default     = "fluentd-alloy"
}

# ==============================================================================
# Container Images
# ==============================================================================

variable "grafana_image" {
  description = "Docker image for Grafana, including tag."
  type        = string
  default     = "grafana/grafana:12.4.3-security-02"
}

variable "loki_image" {
  description = "Docker image for Grafana Loki, including tag."
  type        = string
  default     = "grafana/loki:3.6.10"
}

variable "mimir_image" {
  description = "Docker image for Grafana Mimir, including tag."
  type        = string
  default     = "grafana/mimir:3.0.6"
}

variable "alloy_image" {
  description = "Docker image for Grafana Alloy, including tag. Used for the standalone Alloy service and the sidecar containers attached to Grafana, Loki, and Mimir."
  type        = string
  default     = "grafana/alloy:v1.16.1"
}

# ==============================================================================
# ALB Listener Rule Priorities
# ==============================================================================

variable "mimir_alb_rule_priority" {
  description = "Listener rule priority for Mimir on the private ALB."
  type        = number
  default     = 10
}

variable "alloy_alb_rule_priority" {
  description = "Listener rule priority for the Alloy UI/API endpoint on the private ALB."
  type        = number
  default     = 11
}

variable "loki_alb_rule_priority" {
  description = "Listener rule priority for Loki on the private ALB."
  type        = number
  default     = 12
}

variable "alloy_loki_alb_rule_priority" {
  description = "Listener rule priority for the Alloy Loki push endpoint on the private ALB."
  type        = number
  default     = 13
}

variable "grafana_alb_rule_priority" {
  description = "Listener rule priority for Grafana on the public ALB HTTPS listener."
  type        = number
  default     = 89
}

# ==============================================================================
# S3 Buckets
# ==============================================================================

variable "loki_s3_bucket_name" {
  description = "Name of the S3 bucket for Loki chunk and index storage. Must be globally unique."
  type        = string
}

variable "mimir_s3_bucket_name" {
  description = "Name of the S3 bucket for Mimir block storage. Must be globally unique."
  type        = string
}

# ==============================================================================
# Grafana Configuration
# ==============================================================================

variable "grafana_root_url" {
  description = "Full public URL of the Grafana instance (GF_SERVER_ROOT_URL). Example: https://grafana.example.com"
  type        = string
}

variable "grafana_smtp_enabled" {
  description = "Set to true to enable SMTP email alerts in Grafana."
  type        = bool
  default     = false
}

variable "grafana_smtp_host" {
  description = "SMTP server address and port in host:port format. Required when grafana_smtp_enabled = true."
  type        = string
  default     = ""
}

variable "grafana_smtp_skip_verify" {
  description = "Set to true to skip TLS certificate verification for the SMTP connection."
  type        = bool
  default     = false
}

variable "grafana_smtp_from_address" {
  description = "Sender email address for Grafana notifications. Required when grafana_smtp_enabled = true."
  type        = string
  default     = ""
}

variable "grafana_smtp_from_name" {
  description = "Sender display name for Grafana notifications."
  type        = string
  default     = "Grafana"
}

variable "grafana_smtp_user_ssm_arn" {
  description = "ARN of the SSM Parameter Store parameter containing the SMTP username. Required when grafana_smtp_enabled = true."
  type        = string
  default     = null
}

variable "grafana_smtp_password_ssm_arn" {
  description = "ARN of the SSM Parameter Store parameter containing the SMTP password. Required when grafana_smtp_enabled = true."
  type        = string
  default     = null
}

# ==============================================================================
# General / Tagging
# ==============================================================================

variable "environment" {
  description = "Environment name applied to resource tags (e.g. production, staging)."
  type        = string
  default     = "production"
}

variable "tags" {
  description = "Additional tags merged into every resource created by this module."
  type        = map(string)
  default     = {}
}
