locals {
  name = "techmod-3m"
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
  #checkov:skip=CKV_AWS_119:na
  #checkov:skip=CKV_AWS_144:na
  #checkov:skip=CKV2_AWS_62:na
  #checkov:skip=CKV_AWS_145:na
  #checkov:skip=CKV2_AWS_61:na
  #checkov:skip=CKV2_AWS_6:na
  #checkov:skip=CKV_TF_1:na
  #checkov:skip=CKV_AWS_21:na
  source = "git::https://github.com/cloudposse/terraform-aws-tfstate-backend.git?ref=99453ccfc0d01551458a29c35175b52fb0dfa906"

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

resource "random_password" "password" {
  length           = 32
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

module "aurora_postgresql" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds-aurora?ref=7eec8f4db8f94441e12f961c926820ea6fce1bb7"
  #checkov:skip=CKV_AWS_118:Save money
  #checkov:skip=CKV_AWS_324:Save money
  #checkov:skip=CKV_AWS_325:Save money
  #checkov:skip=CKV2_AWS_8:Save money
  #checkov:skip=CKV2_AWS_27:Save money
  #checkov:skip=CKV_AWS_338:overkill
  #checkov:skip=CKV2_AWS_5:na
  #checkov:skip=CKV_TF_1:na

  name              = "${local.name}-postgresql"
  engine            = "aurora-postgresql"
  engine_mode       = "serverless"
  storage_encrypted = true

  vpc_id                      = data.aws_vpc.cloudboost.id
  subnets                     = data.aws_subnets.private.ids
  create_db_subnet_group      = true
  create_security_group       = true
  manage_master_user_password = false
  master_username             = "backstage"
  master_password             = random_password.password.result

  security_group_rules = {
    vnet_ingress = {
      cidr_blocks = values(data.aws_subnet.private)[*].cidr_block
    }
  }

  # monitoring_interval = 60

  apply_immediately    = true
  skip_final_snapshot  = true
  enable_http_endpoint = true

  db_parameter_group_name         = aws_db_parameter_group.example_postgresql13.id
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.example_postgresql13.id
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
resource "aws_db_parameter_group" "example_postgresql13" {
  name        = "${local.name}-aurora-db-postgres13-parameter-group"
  family      = "aurora-postgresql13"
  description = "${local.name}-aurora-db-postgres13-parameter-group"
}

resource "aws_rds_cluster_parameter_group" "example_postgresql13" {
  name        = "${local.name}-aurora-postgres13-cluster-parameter-group"
  family      = "aurora-postgresql13"
  description = "${local.name}-aurora-postgres13-cluster-parameter-group"
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
  #checkov:skip=CKV_TF_1:na

  source = "git::https://github.com/cloudposse/terraform-aws-elasticache-memcached?ref=3af858db739aaf95779ce9a0c9c39a814db6d486"

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
  #checkov:skip=CKV_TF_1:na
  #checkov:skip=CKV_AWS_356:na
  #checkov:skip=CKV_AWS_111:na
  #checkov:skip=CKV_AWS_338:overkill
  #checkov:skip=CKV2_AWS_5:dont care
  #checkov:skip=CKV_AWS_97:na
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ecs?ref=2604124d05974c2ee47ff7194d62d55ac425a3cb"

  cluster_name                = local.name
  create_cloudwatch_log_group = false

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
  name = "example.com"
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
  #checkov:skip=CKV_TF_1:na
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-s3-bucket?ref=7263d096e3386493dc5113ad61ad0670e6c99028"

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
  #checkov:skip=CKV_TF_1:na
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-alb?ref=cb8e43d456a863e954f6b97a4a821f41d4280ab8"

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
  statement {
    effect = "Allow"
    actions = [
      "aoss:*",
    ]

    resources = [
      aws_opensearchserverless_collection.this.arn
    ]
  }

}

resource "aws_iam_policy" "ecs_task_policy" {
  name   = "${local.name}-task"
  policy = data.aws_iam_policy_document.ecs_task_policy.json
}

module "ecs_alb_service_task" {
  #checkov:skip=CKV_AWS_158:overkill
  #checkov:skip=CKV_AWS_249:covered
  #checkov:skip=CKV_AWS_111:na
  #checkov:skip=CKV_AWS_108:na
  #checkov:skip=CKV_AWS_356:na
  #checkov:skip=CKV_TF_1:na
  #checkov:skip=CKV_AWS_97:na
  source = "git::https://github.com/cloudposse/terraform-aws-ecs-alb-service-task?ref=474902c89a05d6ceda78b52f0c1f52618cda047c"

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

  depends_on = [
    module.tech_docs,
    module.elasticache-memcached,
    aws_opensearchserverless_collection.this,
    aws_route53_record.opensearch
  ]

}

resource "aws_cloudwatch_log_group" "logs" {
  #checkov:skip=CKV_AWS_158:overkill
  #checkov:skip=CKV_AWS_338:overkill
  #checkov:skip=CKV_AWS_158:na
  name              = local.name
  retention_in_days = 90
}
module "container_definition" {
  #checkov:skip=CKV_TF_1:na
  source = "git::https://github.com/cloudposse/terraform-aws-ecs-container-definition?ref=9e0307e261227d5717b4fa56896ec259c1b1947f"

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
  #checkov:skip=CKV2_AWS_61:overkill
  #checkov:skip=CKV2_AWS_6:covered
  #checkov:skip=CKV_TF_1:na
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-s3-bucket?ref=7263d096e3386493dc5113ad61ad0670e6c99028"

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

resource "aws_opensearchserverless_access_policy" "this" {
  name        = local.name
  type        = "data"
  description = "read and write permissions"
  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "index",
          Resource = [
            "index/${local.name}/*"
          ],
          Permission = [
            "aoss:*"
          ]
        },
        {
          ResourceType = "collection",
          Resource = [
            "collection/${local.name}"
          ],
          Permission = [
            "aoss:*"
          ]
        }
      ],
      Principal = [
        module.ecs_alb_service_task.task_role_arn
      ]
    }
  ])
}

resource "aws_opensearchserverless_security_policy" "security" {
  name = "${local.name}-security"
  type = "encryption"
  policy = jsonencode({
    "Rules" = [
      {
        "Resource" = [
          "collection/${local.name}"
        ],
        "ResourceType" = "collection"
      }
    ],
    "AWSOwnedKey" = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name        = "${local.name}-network"
  type        = "network"
  description = "Public access"
  policy = jsonencode([
    {
      Description = "Public access to collection",
      Rules = [
        {
          ResourceType = "collection",
          Resource = [
            "collection/${local.name}"
          ]
        },
      ],
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_collection" "this" {
  name = local.name
  type = "SEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.security,
    aws_opensearchserverless_security_policy.network
  ]
}

resource "aws_route53_record" "opensearch" {
  zone_id = data.aws_route53_zone.tech_mod.zone_id
  name    = "${local.name}-opensearch"
  type    = "CNAME"
  records = [aws_opensearchserverless_collection.this.collection_endpoint]
  ttl     = 300
}

