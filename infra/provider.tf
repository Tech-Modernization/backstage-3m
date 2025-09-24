terraform {
  required_version = "~> 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
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

provider "random" {

}
