# Conectividad Azure SQL desde KFP (Vertex AI)

## Resumen

Se logró conectar pipelines de Kubeflow (KFP) ejecutándose en Vertex AI (GCP) a bases de datos Azure SQL que tienen acceso público denegado y política de conexión Redirect. La solución usa `pytds` + MSAL + monkey-patch + socat proxy a través de una VM intermedia.

---

## 1. El Problema

### Contexto
El proyecto Data Marketplace (DMP) necesita ejecutar pipelines programados en Vertex AI (KFP) que lean/escriban datos en Azure SQL Server. Los servidores Azure SQL están configurados con:
* **Deny Public Network Access = Yes** (solo accesibles vía Private Endpoints)
* **Connection Policy = Redirect** (no Proxy)

### Servidores Azure SQL involucrados

| Entorno | Hostname | IP Privada |
| :--- | :--- | :--- |
| **PROD** | `mx-dasc-analytics2-prod-614cecfb.database.windows.net` | `10.163.175.98` |
| **QA** | `mx-dasc-analytics2-nonprod-62b27780.database.windows.net` | `10.102.65.167` |
| **DEV** | `mx-dasc-analytics2-nonprod-614cecfa.database.windows.net` | `10.163.130.123` |

### ¿Por qué no funciona la conexión directa?
Los pods de KFP en Vertex AI corren en una VPC de GCP (`vpcnet-shared-prod-01`) con peering a la red de Azure. Sin embargo:

1. **DNS no resuelve a IPs privadas:** Desde los pods, los hostnames de Azure SQL resuelven a IPs públicas (las cuales están bloqueadas por la política de "Deny Public Network Access").
2. **Las IPs privadas de Azure no son alcanzables directamente:** Aunque se inyecten en `/etc/hosts`, las IPs privadas de los Private Endpoints de Azure (`10.163.x.x`, `10.102.x.x`) no son ruteables desde los pods de KFP. Los paquetes TCP se pierden (timeout).
3. **La VM sí es alcanzable:** Una VM en GCP (`10.59.1.208`, zona `us-south1-b`, subnet `prod-us-south1-01`) sí es accesible desde los pods, y esa VM sí puede alcanzar las IPs privadas de Azure SQL.

### ¿Por qué no funciona pyodbc a través de un proxy?
El primer intento fue usar `socat` en la VM como proxy TCP y conectar con `pyodbc` (ODBC Driver 18). Esto falló por la **política de conexión Redirect** de Azure SQL:

    Flujo de conexión con Redirect Policy:
    1. Cliente -> TCP -> Proxy (VM:11433) -> Azure SQL Gateway (:1433)
    2. Azure SQL Gateway responde: "Redirige a nodo interno X.X.X.X:PORT"
    3. El driver ODBC intenta conectar DIRECTAMENTE al nodo interno
    4. Ese nodo interno NO es alcanzable desde el pod -> TIMEOUT

Con la IP directa (sin hostname), Azure SQL rechaza con error 40532: "Cannot open server requested by the login" porque el TLS SNI/server name no coincide.

---

## 2. Soluciones Intentadas (Fallidas)

### 2.1 pymssql / FreeTDS
* **Descubrimiento:** FreeTDS (usado por pymssql) **NO sigue redirects** de Azure SQL. La conexión falla rápido (0.1s) en vez de hacer timeout (15s).
* **Problema:** FreeTDS no soporta autenticación Azure AD (`ActiveDirectoryPassword`). Solo puede hacer SQL Authentication, pero el servidor requiere tokens Azure AD.
* **Resultado:** ❌ Dead end.

### 2.2 pytds directo (sin monkey-patch)
* `pytds` (python-tds) es un cliente TDS puro en Python que soporta `access_token_callable` para Azure AD.
* **Problema:** pytds **SÍ** sigue redirects. Al conectar vía proxy, después del TLS handshake, pytds sigue el redirect al nodo interno -> timeout.
* **Resultado:** ❌ Mismo problema que pyodbc.

### 2.3 azure-identity para tokens
* Se intentó usar `azure.identity.UsernamePasswordCredential` para obtener tokens Azure AD.
* **Problema:** La librería construía mal la URL de authority, generando paths inválidos (`/organizations/organizations/oauth2/...`).
* **Resultado:** ❌ Tokens no obtenidos por este medio.

---

## 3. La Solución Final

### Arquitectura

    KFP Pod                 TCP         VM (socat)           TCP           Azure SQL
    (Vertex AI)    ----->   :11433/  -> 10.59.1.208      -----> :1433   -> (Private EP)
    pytds +                 :21433/     Forwarding:                        10.163.175.98
    MSAL token              :31433      11433->PROD                        10.102.65.167
    + patch                             21433->QA                          10.163.130.123
                                        31433->DEV

### Componentes

#### 3.1 Socat Proxies en la VM
Tres instancias de `socat` en la VM (`10.59.1.208`) que reenvían TCP:

```bash
# PROD
socat TCP-LISTEN:11433,fork,reuseaddr TCP:10.163.175.98:1433 &

# QA
socat TCP-LISTEN:21433,fork,reuseaddr TCP:10.102.65.167:1433 &

# DEV
socat TCP-LISTEN:31433,fork,reuseaddr TCP:10.163.130.123:1433 &
