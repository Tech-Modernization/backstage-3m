terraform {
  required_version = ">= 1.3.9"

  backend "s3" {
    region         = "us-west-2"
    bucket         = "tm-us-west-2-production-backstage-3m-state"
    key            = "terraform.tfstate"
    dynamodb_table = "tm-us-west-2-production-backstage-3m-state-lock"
    profile        = ""
    role_arn       = ""
    encrypt        = "true"
  }
}
