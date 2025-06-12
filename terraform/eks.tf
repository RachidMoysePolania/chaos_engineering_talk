#################################
#     EKS Cluster Module        #
#################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                             = "${local.name}-al2023"
  cluster_version                          = "1.33"
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = ["190.84.117.111/32"]
  enable_cluster_creator_admin_permissions = true
  kms_key_description                      = "key for eks secret encryption"

  # EKS Addons
  cluster_addons = {
    coredns = {
      name        = "coredns"
      most_recent = true
    }
    kube-proxy = {
      name        = "kube-proxy"
      most_recent = true
    }
    vpc-cni = {
      name        = "vpc-cni"
      most_recent = true
    }
  }

  node_security_group_additional_rules = {
    ingress_15017 = {
      description                   = "Cluster API - Istio Webhook namespace.sidecar-injector.istio.io"
      protocol                      = "TCP"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15012 = {
      description                   = "Cluster API to nodes ports/protocols"
      protocol                      = "TCP"
      from_port                     = 15012
      to_port                       = 15012
      type                          = "ingress"
      source_cluster_security_group = true
    }
    # Add rules for Istio data plane
    ingress_15000 = {
      description                   = "Cluster API - Istio proxy admin port"
      protocol                      = "TCP"
      from_port                     = 15000
      to_port                       = 15000
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15001 = {
      description                   = "Cluster API - Istio proxy inbound"
      protocol                      = "TCP"
      from_port                     = 15001
      to_port                       = 15001
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15006 = {
      description                   = "Cluster API - Istio proxy outbound"
      protocol                      = "TCP"
      from_port                     = 15006
      to_port                       = 15006
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15010 = {
      description                   = "Cluster API - Istio pilot grpc-xds"
      protocol                      = "TCP"
      from_port                     = 15010
      to_port                       = 15010
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15014 = {
      description                   = "Cluster API - Istio pilot http-monitoring"
      protocol                      = "TCP"
      from_port                     = 15014
      to_port                       = 15014
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15090 = {
      description                   = "Cluster API - Istio prometheus"
      protocol                      = "TCP"
      from_port                     = 15090
      to_port                       = 15090
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_9411 = {
      description                   = "Cluster API - Jaeger collector"
      protocol                      = "TCP"
      from_port                     = 9411
      to_port                       = 9411
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    node_group = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }

  tags = local.tags
}
