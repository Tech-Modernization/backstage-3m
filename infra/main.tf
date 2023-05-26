locals {
  name = "backstage-3m"
  port = 7007
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_vpc" "cloudboost" {
  tags = {
    "Name" = "cloudboost_vpc"
  }
}

data "aws_subnets" "public" {
  tags = {
    "Type"       = "Public",
    "managed-by" = "cloudboost"
  }
}

data "aws_subnets" "private" {
  tags = {
    "Type"       = "Private",
    "managed-by" = "cloudboost"
  }
}

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

# You cannot create a new backend by simply defining this and then
# immediately proceeding to "terraform apply". The S3 backend must
# be bootstrapped according to the simple yet essential procedure in
# https://github.com/cloudposse/terraform-aws-tfstate-backend#usage
module "terraform_state_backend" {
  source  = "cloudposse/tfstate-backend/aws"
  version = "0.38.1"
  #checkov:skip=CKV_AWS_119:na
  #checkov:skip=CKV_AWS_144:na
  #checkov:skip=CKV2_AWS_62:na
  #checkov:skip=CKV_AWS_145:na
  #checkov:skip=CKV2_AWS_61:na
  #checkov:skip=CKV2_AWS_6:na

  namespace   = "tm"
  stage       = "production"
  name        = local.name
  environment = data.aws_region.current.name

  attributes = ["state"]

  billing_mode               = "PAY_PER_REQUEST"
  terraform_version          = "1.3.9"
  enable_public_access_block = true

  terraform_backend_config_file_path = "."
  terraform_backend_config_file_name = "backend.tf"
  force_destroy                      = false

  tags = local.aws_default_tags
}


module "aurora_postgresql" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "7.7.0"
  #checkov:skip=CKV_AWS_118:Save money
  #checkov:skip=CKV_AWS_324:Save money
  #checkov:skip=CKV_AWS_325:Save money
  #checkov:skip=CKV2_AWS_8:Save money
  #checkov:skip=CKV2_AWS_27:Save money
  #checkov:skip=CKV_AWS_338:overkill
  #checkov:skip=CKV2_AWS_5:na

  name              = "${local.name}-postgresql"
  engine            = "aurora-postgresql"
  engine_mode       = "serverless"
  storage_encrypted = true

  vpc_id                = data.aws_vpc.cloudboost.id
  subnets               = data.aws_subnets.private.ids
  create_security_group = true
  allowed_cidr_blocks   = values(data.aws_subnet.private).*.cidr_block

  # monitoring_interval = 60

  apply_immediately    = true
  skip_final_snapshot  = true
  enable_http_endpoint = true

  db_parameter_group_name         = aws_db_parameter_group.example_postgresql11.id
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.example_postgresql11.id
  # enabled_cloudwatch_logs_exports = # NOT SUPPORTED

  scaling_configuration = {
    auto_pause               = true
    min_capacity             = 2
    max_capacity             = 2
    seconds_until_auto_pause = 300
    timeout_action           = "ForceApplyCapacityChange"
  }

  copy_tags_to_snapshot = true
  security_group_tags   = local.aws_default_tags
}
resource "aws_db_parameter_group" "example_postgresql11" {
  name        = "${local.name}-aurora-db-postgres11-parameter-group"
  family      = "aurora-postgresql11"
  description = "${local.name}-aurora-db-postgres11-parameter-group"
}

resource "aws_rds_cluster_parameter_group" "example_postgresql11" {
  name        = "${local.name}-aurora-postgres11-cluster-parameter-group"
  family      = "aurora-postgresql11"
  description = "${local.name}-aurora-postgres11-cluster-parameter-group"
  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1"
  }
}

resource "aws_secretsmanager_secret" "postgres_password" {
  #checkov:skip=CKV2_AWS_57:not supported
  #checkov:skip=CKV_AWS_149:overkill
  name = "rds/postgres/${local.name}"
}

resource "aws_secretsmanager_secret_version" "postgres_password" {
  secret_id     = aws_secretsmanager_secret.postgres_password.id
  secret_string = module.aurora_postgresql.cluster_master_password
}

module "elasticache-memcached" {
  #checkov:skip=CKV2_AWS_5:false positive

  source  = "cloudposse/elasticache-memcached/aws"
  version = "0.16.0"

  namespace   = "tm"
  stage       = "production"
  name        = local.name
  environment = data.aws_region.current.name

  engine_version                     = "1.6.17"
  elasticache_parameter_group_family = "memcached1.6"

  availability_zone       = values(data.aws_subnet.private)[0].availability_zone
  vpc_id                  = data.aws_vpc.cloudboost.id
  allowed_security_groups = data.aws_security_groups.default.ids
  subnets                 = data.aws_subnets.private.ids
  zone_id                 = data.aws_route53_zone.tech_mod.zone_id
  dns_subdomain           = "${local.name}-memcached"

  tags = local.aws_default_tags
}

module "ecs" {
  #checkov:skip=CKV_AWS_158:overkill
  #checkov:skip=CKV_AWS_224:overkill
  source  = "terraform-aws-modules/ecs/aws"
  version = "4.1.3"

  cluster_name = local.name

  cluster_configuration = {
    execute_command_configuration = {
      logging = "OVERRIDE"
      log_configuration = {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.this.name
      }
    }
  }

  # Capacity provider
  fargate_capacity_providers = {
    FARGATE_SPOT = {
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:overkill
  #checkov:skip=CKV_AWS_338:overkill
  name              = "/aws/ecs/${local.name}"
  retention_in_days = 7
}

data "aws_route53_zone" "tech_mod" {
  name = "tech-modernization.com"
}

resource "aws_route53_record" "backstage" {
  #checkov:skip=CKV2_AWS_23:na
  zone_id = data.aws_route53_zone.tech_mod.zone_id
  name    = "backstage"
  type    = "A"
  alias {
    name                   = module.alb.lb_dns_name
    zone_id                = module.alb.lb_zone_id
    evaluate_target_health = true
  }
}

data "aws_acm_certificate" "tech_mod" {
  domain      = "tech-modernization.com"
  types       = ["AMAZON_ISSUED"]
  most_recent = true
}

data "aws_security_groups" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.cloudboost.id]
  }
  filter {
    name   = "group-name"
    values = ["default"]
  }
}

module "access_logs" {
  #checkov:skip=CKV_AWS_144:overkill
  #checkov:skip=CKV_AWS_18:overkill
  #checkov:skip=CKV_AWS_145:overkill
  #checkov:skip=CKV_AWS_21:overkill
  #checkov:skip=CKV2_AWS_62:overkill
  #checkov:skip=CKV_AWS_19:it is enabled
  #checkov:skip=CKV_AWS_300:we are covered
  #checkov:skip=CKV2_AWS_61:overkill
  #checkov:skip=CKV2_AWS_6:covered
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "3.8.2"

  bucket                         = "${local.name}-access-logs"
  acl                            = "private"
  block_public_acls              = true
  block_public_policy            = true
  ignore_public_acls             = true
  restrict_public_buckets        = true
  attach_elb_log_delivery_policy = true
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id     = "archive"
      status = "Enabled"
      filter = {}
      expiration = {
        days = 90
      }
      abort_incomplete_multipart_upload = {
        days_after_initiation = 1
      }
    }
  ]
}

module "alb" {
  #checkov:skip=CKV_AWS_103:no ssl on http
  #checkov:skip=CKV_AWS_2:confused
  #checkov:skip=CKV_AWS_97:dont care
  #checkov:skip=CKV_AWS_91:we are covered
  #checkov:skip=CKV_AWS_150:dont care
  #checkov:skip=CKV2_AWS_5:dont care
  source  = "terraform-aws-modules/alb/aws"
  version = "8.5.0"

  name = local.name

  load_balancer_type = "application"

  drop_invalid_header_fields = true
  access_logs = {
    bucket = module.access_logs.s3_bucket_id
    prefix = "alb"
  }

  vpc_id          = data.aws_vpc.cloudboost.id
  subnets         = data.aws_subnets.public.ids
  security_groups = data.aws_security_groups.default.ids
  security_group_rules = {
    ingress_all_http = {
      type        = "ingress"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP web traffic"
      cidr_blocks = ["0.0.0.0/0"]
    }
    ingress_all_https = {
      type        = "ingress"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS web traffic"
      cidr_blocks = ["0.0.0.0/0"]
    }
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  enable_http2 = true
  internal     = true

  target_groups = [
    {
      name_prefix      = "tmbs-"
      backend_protocol = "HTTP"
      backend_port     = 7007
      target_type      = "ip"
      health_check = {
        path = "/healthcheck"
      }
    }
  ]
  listener_ssl_policy_default = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  https_listeners = [
    {
      port               = 443
      protocol           = "HTTPS"
      certificate_arn    = data.aws_acm_certificate.tech_mod.arn
      target_group_index = 0
    }
  ]

  http_tcp_listeners = [
    {
      port        = 80
      protocol    = "HTTP"
      action_type = "redirect"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  ]

  security_group_tags          = local.aws_default_tags
  target_group_tags            = local.aws_default_tags
  https_listener_rules_tags    = local.aws_default_tags
  http_tcp_listener_rules_tags = local.aws_default_tags
}


data "aws_secretsmanager_secret" "ghcr" {
  name = "github/tech-mod/ghcr.io"
}

data "aws_secretsmanager_secret" "backstage_app" {
  name = "github/tech-mod/backstage-oauth-app"
}

data "aws_iam_policy_document" "ecs_task_execution_policy" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]

    resources = [
      data.aws_secretsmanager_secret.ghcr.arn,
      data.aws_secretsmanager_secret.backstage_app.arn,
      aws_secretsmanager_secret_version.postgres_password.arn
    ]
  }
}

resource "aws_iam_policy" "ecs_task_execution_policy" {
  name   = "${local.name}-task-execution"
  policy = data.aws_iam_policy_document.ecs_task_execution_policy.json
}

data "aws_iam_policy_document" "ecs_task_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
      "s3:HeadBucket"
    ]

    resources = [
      module.tech_docs.s3_bucket_arn,
      "${module.tech_docs.s3_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_policy" "ecs_task_policy" {
  name   = "${local.name}-task"
  policy = data.aws_iam_policy_document.ecs_task_policy.json
}

module "ecs_alb_service_task" {
  #checkov:skip=CKV_AWS_158:overkill
  #checkov:skip=CKV_AWS_97:doesnt apply
  #checkov:skip=CKV_AWS_249:covered
  #checkov:skip=CKV_AWS_111:na
  #checkov:skip=CKV_AWS_108:na
  source  = "cloudposse/ecs-alb-service-task/aws"
  version = "0.67.1"

  namespace   = "tm"
  stage       = "production"
  name        = local.name
  environment = data.aws_region.current.name
  ecs_load_balancers = [
    {
      container_name   = local.name
      container_port   = local.port
      elb_name         = ""
      target_group_arn = module.alb.target_group_arns[0]
    }
  ]

  ignore_changes_task_definition = false
  alb_security_group             = module.alb.security_group_id
  use_alb_security_group         = true
  container_port                 = local.port
  container_definition_json      = module.container_definition.json_map_encoded_list
  ecs_cluster_arn                = module.ecs.cluster_arn
  vpc_id                         = data.aws_vpc.cloudboost.id
  security_group_ids             = data.aws_security_groups.default.ids
  subnet_ids                     = data.aws_subnets.private.ids
  wait_for_steady_state          = true
  task_exec_policy_arns = [
    aws_iam_policy.ecs_task_execution_policy.arn
  ]
  task_policy_arns = [
    aws_iam_policy.ecs_task_policy.arn
  ]
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/cloudboost_account_operator_boundary_policy"

  tags = local.aws_default_tags
}

resource "aws_cloudwatch_log_group" "logs" {
  #checkov:skip=CKV_AWS_158:overkill
  #checkov:skip=CKV_AWS_338:overkill
  name              = local.name
  retention_in_days = 90
}
module "container_definition" {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "0.58.2"

  container_name  = local.name
  container_image = "${var.image}:${var.image_tag}"
  repository_credentials = {
    credentialsParameter = data.aws_secretsmanager_secret.ghcr.arn
  }

  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-region        = data.aws_region.current.name
      awslogs-group         = resource.aws_cloudwatch_log_group.logs.name
      awslogs-stream-prefix = local.name
    }
    secretOptions = null
  }

  port_mappings = [
    {
      containerPort = 7007
      hostPort      = 7007
      protocol      = "tcp"
    }
  ]

  environment = [
    {
      name  = "POSTGRES_HOST"
      value = module.aurora_postgresql.cluster_endpoint
    },
    {
      name  = "POSTGRES_PORT"
      value = module.aurora_postgresql.cluster_port
    },
    {
      name  = "POSTGRES_USER"
      value = module.aurora_postgresql.cluster_master_username
    },
  ]
  secrets = [
    {
      name      = "GITHUB_CLIENT_ID"
      valueFrom = "${data.aws_secretsmanager_secret.backstage_app.arn}:GITHUB_CLIENT_ID::"
    },
    {
      name      = "GITHUB_CLIENT_SECRET"
      valueFrom = "${data.aws_secretsmanager_secret.backstage_app.arn}:GITHUB_CLIENT_SECRET::"
    },
    {
      name      = "GITHUB_WEBHOOK_SECRET"
      valueFrom = "${data.aws_secretsmanager_secret.backstage_app.arn}:GITHUB_WEBHOOK_SECRET::"
    },
    {
      name      = "GITHUB_PRIVATE_KEY"
      valueFrom = "${data.aws_secretsmanager_secret.backstage_app.arn}:GITHUB_PRIVATE_KEY::"
    },
    {
      name      = "POSTGRES_PASSWORD"
      valueFrom = aws_secretsmanager_secret_version.postgres_password.arn
    },
  ]
}

module "tech_docs" {
  #checkov:skip=CKV_AWS_144:overkill
  #checkov:skip=CKV_AWS_18:overkill
  #checkov:skip=CKV_AWS_145:overkill
  #checkov:skip=CKV_AWS_21:overkill
  #checkov:skip=CKV2_AWS_62:overkill
  #checkov:skip=CKV_AWS_19:it is enabled
  #checkov:skip=CKV_AWS_300:we are covered
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "3.8.2"

  bucket                  = "${local.name}-storage"
  acl                     = "private"
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id     = "archive"
      status = "Enabled"
      filter = {}
      expiration = {
        days = 90
      }
      abort_incomplete_multipart_upload = {
        days_after_initiation = 1
      }
    }
  ]
}

data "aws_iam_policy_document" "example" {
  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["es:*"]
    resources = ["${aws_opensearch_domain.this.arn}/*"]
  }
}

resource "aws_opensearch_domain" "this" {
  #checkov:skip=CKV_AWS_84:overkill
  #checkov:skip=CKV_AWS_318:overkill
  #checkov:skip=CKV_AWS_317:overkill
  #checkov:skip=CKV_AWS_247:overkill
  #checkov:skip=CKV2_AWS_59:overkill
  #checkov:skip=CKV2_AWS_52:overkill

  domain_name    = local.name
  engine_version = "OpenSearch_2.5"

  vpc_options {
    subnet_ids         = [data.aws_subnets.private.ids[0]]
    security_group_ids = [module.alb.security_group_id]
  }

  cluster_config {
    instance_type  = "t3.small.search"
    instance_count = 1
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 10
  }

  domain_endpoint_options {
    enforce_https                   = true
    custom_endpoint_enabled         = false
    tls_security_policy             = "Policy-Min-TLS-1-2-2019-07"
    custom_endpoint                 = "${local.name}-opensearch.${data.aws_route53_zone.tech_mod.name}"
    custom_endpoint_certificate_arn = data.aws_acm_certificate.tech_mod.arn
  }

  encrypt_at_rest {
    enabled = true
  }

}

resource "aws_opensearch_domain_policy" "this" {
  domain_name     = aws_opensearch_domain.this.domain_name
  access_policies = data.aws_iam_policy_document.example.json
}

resource "aws_route53_record" "opensearch" {
  zone_id = data.aws_route53_zone.tech_mod.zone_id
  name    = "${local.name}-opensearch"
  type    = "CNAME"
  records = [aws_opensearch_domain.this.endpoint]
  ttl     = 300
}

