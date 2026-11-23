# Infraestructura para la POC de Alfresco 6.2

Prepara la VM `alfresco-poc-app` en el proyecto LXD `alfresco-poc`, sobre MicroCloud.
La capacidad existente se conserva: **4 CPU, 10GB de RAM y disco raíz de 150GB**.
El sistema operativo muestra esas capacidades en GiB, por eso los números internos difieren.

## Qué instala y configura

- Docker de Ubuntu, Compose v2 y Buildx; acceso del usuario `agent` al grupo `docker`.
- MicroK8s en el canal `1.35/stable`, grupo `microk8s` y contexto `alfresco-poc` para `agent`.
- Red del nodo, SAN del API para `10.146.220.55` y `192.168.50.100`, DNS y almacenamiento hostpath.
- Registro local `localhost:32000` para publicar imágenes y descargarlas desde containerd.
- Namespace `alfresco-poc` y directorio `/home/agent/alfresco-poc` para el proyecto de construcción.
- Verificación de permisos reales, componentes de infraestructura y heartbeats recientes.

La secuencia anterior copiaba certificados de una VM anterior sobre una instalación nueva,
dejando los kubeconfigs de los componentes con otra CA. Ahora cada instalación conserva su
propia identidad; el directorio montado de certificados **no se usa como origen de restauración**.
Si se detecta el problema en la VM existente, se reimporta su CA actual con el comando soportado
de MicroK8s, que reconstruye las credenciales internas. No se crea una CA nueva ni se reinicia el clúster desde cero.

## GitHub Actions y ejecución en la VM existente

Todas las ramas y PR ejecutan validaciones en un runner hospedado por GitHub. Los PR no se
ejecutan en el runner self-hosted. Solamente `main` y la ejecución manual desde `main` pueden
aprovisionar en el servidor MicroCloud.

El runner self-hosted necesita Terraform, Python 3, LXD CLI y permisos para administrar el
proyecto `alfresco-poc`. El workflow guarda el estado local en
`$HOME/.local/state/alfresco-poc/terraform.tfstate`, fuera del checkout descartable.
Los bloques `import` mantienen la adopción de los recursos existentes.

Antes de aplicar, `scripts/check-plan.py` rechaza eliminaciones, reemplazos y cambios de CPU,
memoria o dispositivos de disco. Aplica exactamente el plan que pasó esa comprobación.

LXD aplica nuevos datos de cloud-init en el siguiente arranque. Si la revisión instalada no
coincide, el workflow **reinicia la VM existente**, sin recrearla ni ampliar sus recursos.
Después espera a que cloud-init termine y verifica la revisión completada. Una comprobación
final construye una imagen BusyBox pequeña, ejecuta un contenedor, publica en el registro y
ejecuta un pod temporal que prueba la descarga y el DNS del clúster. El pod se elimina al finalizar.

El bootstrap crea PVC para los complementos dentro del disco ya asignado; no aprovisiona
otro disco ni amplía el disco de LXD. Hostpath es almacenamiento local de esta POC de un nodo.

## Validación y diagnóstico

Como `agent`, en una sesión SSH nueva:

```bash
docker info
docker compose version
docker buildx version
kubectl config use-context alfresco-poc
/usr/local/bin/alfresco-poc-verify --smoke
```

Desde el host LXD, con permisos de administración:

```bash
lxc --project alfresco-poc exec alfresco-poc-app -- cloud-init status --long
lxc --project alfresco-poc exec alfresco-poc-app -- tail -n 100 /var/log/alfresco-poc-bootstrap.log
```

Los tiempos de espera son finitos: un fallo de red, TLS o descarga hace fallar el workflow
en lugar de declarar el aprovisionamiento exitoso con pods pendientes.

El acceso externo se exporta con modo `0600` a
`/var/lib/alfresco-poc/microk8s-certs/alfresco-poc.kubeconfig` en el host LXD.
Después de recrear una VM hay que actualizar el contexto local con ese archivo y verificar
su nueva huella SSH. El kubeconfig contiene credenciales: no se sube al repositorio ni a artefactos.

Para futuras instancias se puede sustituir el hash de contraseña por `TF_VAR_agent_password_hash`
en el entorno del runner. El acceso por contraseña se mantiene para la POC autorizada.

## Despliegue de Alfresco pendiente

Esta fase prepara la infraestructura; todavía no construye ni despliega las imágenes propias.
El proyecto fuente es `C:\producto\toolbox-customs-ecm\alfresco-docker`.
Falta trasladarlo, adaptar sus endpoints, confirmar SQL Server y las integraciones OCR/índice
electrónico y preparar los manifiestos de la pila 6.2 con límites adecuados para la RAM disponible.

`modules/alfresco-stack.yaml` es un borrador anterior de Alfresco 26.2 con otra base de datos.
Terraform conserva su copia en `/etc/alfresco-stack.yaml`, pero el bootstrap **no lo aplica**;
no corresponde al despliegue 6.2 solicitado.
