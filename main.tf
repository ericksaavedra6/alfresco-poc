terraform {
  required_version = ">= 1.3.0"
  required_providers {
    lxd = {
      source  = "terraform-lxd/lxd"
      version = "~> 2.0"
    }
  }
}

provider "lxd" {}

variable "node_ip" {
  type        = string
  default     = "10.146.220.55"
  description = "IPv4 asignada a la VM en lxdbr0"
}

# 1. Proyecto LXD aislado para la PoC de Alfresco
# features.networks = "false" permite compartir lxdbr0 del proyecto default
resource "lxd_project" "alfresco_poc" {
  name        = "alfresco-poc"
  description = "Proyecto aislado para PoC de Alfresco sin Solr"

  config = {
    "features.networks" = "false"
  }
}

# 2. Instancia VM para Alfresco (Kubernetes / Repository / ActiveMQ)
resource "lxd_instance" "alfresco_app" {
  name     = "alfresco-poc-app"
  project  = lxd_project.alfresco_poc.name
  image    = "ubuntu:24.04"
  profiles = ["default"]
  type     = "virtual-machine"

  limits = {
    cpu    = "4"
    memory = "6GB"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      pool = "local"
      path = "/"
      size = "30GB"
    }
  }

  device {
    name = "microk8s-certs-dir"
    type = "disk"
    properties = {
      source = "/var/lib/alfresco-poc/microk8s-certs"
      path   = "/mnt/microk8s-certs"
    }
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = "lxdbr0"
      "ipv4.address" = var.node_ip
    }
  }

  # Proxy NAT para acceder a Alfresco (puerto por defecto 8080) desde tu LAN
  device {
    name = "alfresco-http-proxy"
    type = "proxy"
    properties = {
      listen  = "tcp:192.168.50.100:8090"
      connect = "tcp:${var.node_ip}:8080"
      nat     = "true"
    }
  }

  # Proxy NAT opcional para consola web de ActiveMQ (puerto por defecto 8161)
  device {
    name = "activemq-web-proxy"
    type = "proxy"
    properties = {
      listen  = "tcp:192.168.50.100:8161"
      connect = "tcp:${var.node_ip}:8161"
      nat     = "true"
    }
  }

  # Proxy NAT para exponer el API server de MicroK8s (puerto 16443) hacia tu LAN/Mac
  device {
    name = "k8s-api-proxy"
    type = "proxy"
    properties = {
      listen  = "tcp:192.168.50.100:16443"
      connect = "tcp:${var.node_ip}:16443"
      nat     = "true"
    }
  }

  lifecycle {
    create_before_destroy = false
  }

  file {
    source_path        = "${path.module}/modules/alfresco-stack.yaml"
    target_path        = "/etc/alfresco-stack.yaml"
    create_directories = true
  }

  config = {
    "migration.stateful" = "false"
    "user.user-data"     = templatefile("${path.module}/cloud-init-alfresco.yaml", {
      node_ip = var.node_ip
    })
  }
}