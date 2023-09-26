terraform {
  required_version = "~> 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.17.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
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
