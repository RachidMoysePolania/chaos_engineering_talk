terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.95"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
