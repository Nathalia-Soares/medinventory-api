# HTTPS público para a API via Ingress NGINX + cert-manager (Let's Encrypt).
# O hostname padrão usa nip.io (api.<octetos-com-hífens>.nip.io) quando api_https_host_override está vazio.

locals {
  ingress_https_enabled = var.enable_k8s_resources && var.enable_api_ingress_https && trimspace(var.letsencrypt_acme_email) != ""

  ingress_lb_ip = local.ingress_https_enabled ? try(
    data.kubernetes_service.ingress_nginx_controller[0].status[0].load_balancer[0].ingress[0].ip,
    ""
  ) : ""

  api_https_hostname = trimspace(var.api_https_host_override) != "" ? trimspace(var.api_https_host_override) : (
    local.ingress_lb_ip != "" ? "api.${replace(local.ingress_lb_ip, ".", "-")}.nip.io" : ""
  )

  cors_allowed_origins_effective = concat(
    var.cors_allowed_origins,
    local.api_https_hostname != "" ? ["https://${local.api_https_hostname}"] : []
  )
}

resource "helm_release" "ingress_nginx" {
  count = local.ingress_https_enabled ? 1 : 0

  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version

  values = [
    yamlencode({
      controller = {
        service = {
          annotations = {
            "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/healthz"
          }
        }
      }
    })
  ]

  depends_on = [
    azurerm_kubernetes_cluster.main,
  ]
}

resource "time_sleep" "wait_ingress_nginx_lb" {
  count = local.ingress_https_enabled ? 1 : 0

  depends_on      = [helm_release.ingress_nginx[0]]
  create_duration = "${max(30, var.ingress_wait_for_lb_seconds)}s"
}

data "kubernetes_service" "ingress_nginx_controller" {
  count = local.ingress_https_enabled ? 1 : 0

  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [time_sleep.wait_ingress_nginx_lb[0]]
}

resource "helm_release" "cert_manager" {
  count = local.ingress_https_enabled ? 1 : 0

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true

  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.cert_manager_chart_version

  # ClusterIssuer via extraObjects: evita kubernetes_manifest (plan falha antes dos CRDs existirem).
  values = [
    yamlencode({
      installCRDs = true
      extraObjects = [
        {
          apiVersion = "cert-manager.io/v1"
          kind       = "ClusterIssuer"
          metadata = {
            name = "letsencrypt-prod"
          }
          spec = {
            acme = {
              server = "https://acme-v02.api.letsencrypt.org/directory"
              email  = trimspace(var.letsencrypt_acme_email)
              privateKeySecretRef = {
                name = "letsencrypt-prod"
              }
              solvers = [
                {
                  http01 = {
                    ingress = {
                      class = "nginx"
                    }
                  }
                }
              ]
            }
          }
        }
      ]
    })
  ]

  depends_on = [
    azurerm_kubernetes_cluster.main,
    helm_release.ingress_nginx[0],
  ]
}

resource "kubernetes_ingress_v1" "api_https" {
  # count não pode depender de local.api_https_hostname (nip.io derivado do IP do LB): esse valor só existe após o data source ler o Service.
  count                  = local.ingress_https_enabled ? 1 : 0
  wait_for_load_balancer = true

  metadata {
    name      = "medinventory-api-https"
    namespace = kubernetes_namespace.medinventory[0].metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer"           = "letsencrypt-prod"
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = [local.api_https_hostname]
      secret_name = "medinventory-api-tls"
    }

    rule {
      host = local.api_https_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "medinventory-api"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.cert_manager[0],
    data.kubernetes_service.ingress_nginx_controller[0],
    kubernetes_deployment.api[0],
    kubernetes_service.api_lb[0],
  ]
}
