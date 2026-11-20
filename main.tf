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

variable "agent_password_hash" {
  type        = string
  sensitive   = true
  default = "$6$HceeCl5SXXLWmiPr$eOFTeEjG68byefxoAF.uIvqS5owwY64Yv.XqeBmPMCRcSKNtvz4MnDUZV6ISX0C7ltunNNy7N0tzzsWol4hiP/"
  description = "Valor hash de la contraseña para el ambiente poc"
}

variable "ssh_proxy_port" {
    type        = string
    default     = "2222"
    description = "Puerto expuesto en 192.168.50.100 para redirigir SSH hacia la VM"
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
  # Proxy NAT para acceso SSH al agente desde la IP del servidor (192.168.50.100)
  device {
    name = "ssh-agent-proxy"
    type = "proxy"
    properties = {
      listen  = "tcp:192.168.50.100:${var.ssh_proxy_port}"
      connect = "tcp:${var.node_ip}:22"
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
      agent_password_hash = var.agent_password_hash
    })
  }
}