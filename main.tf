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

# 1. Proyecto LXD aislado para la PoC de Alfresco
# features.networks = "false" permite compartir lxdbr0 del proyecto default
resource "lxd_project" "alfresco_poc" {
  name        = "alfresco-poc"
  description = "Proyecto aislado para PoC de Alfresco sin Solr"
}

# 3. Instancia VM para Alfresco (Kubernetes / Repository / ActiveMQ)
resource "lxd_instance" "alfresco_app" {
  name     = "alfresco-poc-app"
  project  = lxd_project.alfresco_poc.name
  image    = "ubuntu:24.04"
  profiles = ["default"]
  type     = "virtual-machine"

  # Asegura que la BD exista antes de levantar Alfresco

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
    name = "eth0"
    type = "nic"
    properties = {
      network        = "lxdbr0"
      "ipv4.address" = "10.146.220.55"
    }
  }

  # Proxy NAT para acceder a Alfresco (puerto por defecto 8080) desde tu LAN
  device {
    name = "alfresco-http-proxy"
    type = "proxy"
    properties = {
      listen  = "tcp:192.168.50.100:8090"
      connect = "tcp:10.146.220.55:8080"
      nat     = "true"
    }
  }
  
  lifecycle {
    create_before_destroy = false
  }

  # Proxy NAT opcional para consola web de ActiveMQ (puerto por defecto 8161)
  device {
    name = "activemq-web-proxy"
    type = "proxy"
    properties = {
      listen  = "tcp:192.168.50.100:8161"
      connect = "tcp:10.146.220.55:8161"
      nat     = "true"
    }
  }

  file {
    source_path        = "${path.module}/modules/alfresco-stack.yaml"
    target_path        = "/etc/alfresco-stack.yaml"
    create_directories = true
  }

  config = {
    "migration.stateful" = "false"
    "user.user-data"     = templatefile("${path.module}/cloud-init-alfresco.yaml", {
    })
  }
}
import {
  to = lxd_project.alfresco_poc
  id = "alfresco-poc"
}