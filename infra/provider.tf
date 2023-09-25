terraform {
  required_version = "~> 1.5.0"
  required_providers {
    aws = {
      version = "~> 4.59.0"
    }
  }
}

locals {
  aws_default_tags = {
    managed-by  = "cop-platform-engineering",
    DoNotDelete = true
  }
  region = "us-west-2"
}

provider "aws" {
  default_tags {
    tags = local.aws_default_tags
  }
  region = local.region
}
