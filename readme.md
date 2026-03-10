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

3.2 MSAL para Tokens Azure AD
Se usa msal.PublicClientApplication directamente (no azure-identity) para obtener tokens:
import msal

MSAL_CLIENT_ID = "a94f9c62-97fe-4d19-b06d-472bed8d2bcf"  # Well-known SSMS/ADS client
MSAL_AUTHORITY = "[https://login.microsoftonline.com/organizations](https://login.microsoftonline.com/organizations)"
MSAL_SCOPE = ["[https://database.windows.net/.default](https://database.windows.net/.default)"]

app = msal.PublicClientApplication(MSAL_CLIENT_ID, authority=MSAL_AUTHORITY)
result = app.acquire_token_by_username_password(username, password, scopes=MSAL_SCOPE)
token = result["access_token"]  # JWT token (~2650 chars)

¿Por qué MSAL directo y no azure-identity?
 * azure.identity.UsernamePasswordCredential construye mal la authority URL para tenants multi-org.
 * MSAL con authority='https://login.microsoftonline.com/organizations' funciona correctamente.
 * El client_id a94f9c62-97fe-4d19-b06d-472bed8d2bcf es el well-known de SQL Server Management Studio / Azure Data Studio.
3.3 Monkey-Patch de pytds (Skip Redirect)
El componente clave: parchear pytds._connect para que ignore la instrucción de redirect del servidor y mantenga la conexión existente:
import pytds

def patch_pytds_skip_redirect(real_hostname):
    """
    Monkey-patch pytds._connect para:
    1. Establecer login.server_name = hostname real de Azure SQL
       (así el TDS Login7 packet lleva el hostname correcto aunque
       el TCP vaya al proxy)
    2. Ignorar el redirect (route) que Azure SQL envía, manteniendo
       la conexión actual a través del proxy
    """
    _original_connect = pytds._connect

    def _patched_connect(login, *args, **kwargs):
        login.server_name = real_hostname
        conn = _original_connect(login, *args, **kwargs)
        
        if hasattr(conn, '_route') and conn._route is not None:
            conn._route = None
        return conn

    pytds._connect = _patched_connect

¿Por qué funciona?
| Sin patch | Con patch |
|---|---|
| TCP va al proxy (VM:11433) | TCP va al proxy (VM:11433) |
| TLS handshake con Azure SQL | TLS handshake con Azure SQL |
| Login7 envía hostname del proxy -> Azure SQL rechaza | Login7 envía hostname REAL -> Azure SQL acepta |
| Azure SQL responde "redirect a nodo X" | Azure SQL responde "redirect a nodo X" |
| pytds cierra conexión, intenta conectar a nodo X -> timeout | pytds ignora redirect, mantiene conexión actual |
| ❌ Falla | ✅ Funciona |
3.4 Conexión pytds con Token
def make_token_callable(msal_app, uid, pwd):
    """Retorna un callable que pytds invocará para obtener el token Azure AD."""
    def get_token():
        result = msal_app.acquire_token_by_username_password(uid, pwd, scopes=MSAL_SCOPE)
        return result["access_token"]
    return get_token

# Conexión
conn = pytds.connect(
    dsn="10.59.1.208",            # IP del proxy (VM)
    port=11433,                   # Puerto del proxy
    database="MX_DO_Spot_Control",
    auth=None,                    # No SQL auth
    access_token_callable=get_token,  # Azure AD token
    autocommit=True,
)

4. Implementación para KFP
4.1 Script de Test (test_db_kfp.py)
El script que corre en el pod KFP:
 * Lee credenciales de Secret Manager (marketplace_db)
 * Inicializa MSAL y obtiene token Azure AD
 * Verifica conectividad TCP a los 3 puertos del proxy
 * Aplica el monkey-patch a pytds
 * Conecta a los 3 servidores (PROD, QA, DEV) y ejecuta SELECT @@VERSION
4.2 Dependencias Agregadas (pyproject.toml)
"python-tds>=1.15.0",  # Cliente TDS puro Python
"msal>=1.28.0",        # Tokens Azure AD
"pyOpenSSL>=24.0.0",   # Requerido por pytds para TLS

4.3 Pipeline KFP (src/pipelines/db_test_pipeline.py)
Pipeline con un solo step que invoca test_db_kfp.main(). Compilado con mlops_tools:
python -m mlops_tools kfp compile src/pipelines/db_test_pipeline.py \
  --pipeline-name db-connectivity-test \
  --region us-south1 \
  --vpc-network "projects/12856960411/global/networks/vpcnet-shared-prod-01" \
  --single-run

4.4 Docker
La imagen gcr.io/wmt-mx-dl-iaml-dev/wmt-mx-data-marketplace:latest fue reconstruida con las nuevas dependencias (pytds, msal, pyOpenSSL).
4.5 Resultado del Test KFP
El pipeline se ejecutó exitosamente en Vertex AI el 10 de marzo de 2026:
>>> STARTING DB CONNECTIVITY TEST (pytds + MSAL + socat VM proxy)
>>> Loading credentials from Secret Manager...
>>> DB: MX_DO_Spot_Control, UID: SVC_IA_AZSQL_RW@svc.wmtcloud.com
>>> MSAL app initialized
>>> Azure AD token acquired (length: 2647)
>>> TCP 10.59.1.208:11433 (PROD) -> OPEN
>>> TCP 10.59.1.208:21433 (QA) -> OPEN
>>> TCP 10.59.1.208:31433 (DEV) -> OPEN
>>> PROD OK: Microsoft SQL Azure (RTM) - 12.0.2000.8
>>> QA   OK: Microsoft SQL Azure (RTM) - 12.0.2000.8
>>> DEV  OK: Microsoft SQL Azure (RTM) - 12.0.2000.8
>>> TEST COMPLETE
5. Pendientes para Producción
5.1 Persistencia de socat
Los proxies socat corren como procesos background en la VM. Para producción necesitan ser daemonizados:
 * Opción A: Servicio systemd (/etc/systemd/system/socat-azuresql.service)
 * Opción B: supervisor o screen persistente
5.2 Integrar en conector.py
Reemplazar la conexión pyodbc/sqlalchemy en src/utils/conector.py con la solución pytds para que el pipeline de context_similarity (y futuros pipelines) puedan conectar a Azure SQL desde KFP.
5.3 Mapeo de puertos por entorno
| Entorno | Puerto VM | Servidor Azure SQL |
|---|---|---|
| PROD | 11433 | mx-dasc-analytics2-prod-614cecfb.database.windows.net |
| QA | 21433 | mx-dasc-analytics2-nonprod-62b27780.database.windows.net |
| DEV | 31433 | mx-dasc-analytics2-nonprod-614cecfa.database.windows.net |
6. Diagrama de Secuencia
Pod KFP                   VM (socat)                 Azure SQL
|                          |                          |
|--- TCP connect :11433 -->|                          |
|                          |--- TCP connect :1433 --->|
|                          |<-------- TCP ACK --------|
|<------- TCP ACK ---------|                          |
|                          |                          |
|--- TLS ClientHello ----->|------- forward --------->|
|<--- TLS ServerHello -----|<------ forward ----------|
| (cert: *.database.windows.net)                      |
|                          |                          |
|--- TDS Login7 ---------->|------- forward --------->|
| (server_name=real host)  |                          |
| (access_token=JWT)       |                          |
|<--- TDS LoginAck --------|<------ forward ----------|
|     + Route(redirect)    |                          |
|                          |                          |
| [PATCH: ignore redirect] |                          |
|                          |                          |
|--- TDS SQL Query ------->|------- forward --------->|
|<--- TDS Results ---------|<------ forward ----------|
|                          |                          |
7. Archivos Clave
| Archivo | Descripción |
|---|---|
| test_db_kfp.py | Script de test con la solución completa (pytds + MSAL + patch) |
| src/pipelines/db_test_pipeline.py | Definición del pipeline KFP para el test |
| kfp_compiled_pipelines/db_connectivity_test.py | Pipeline compilado por mlops_tools |
| src/utils/conector.py | Conector actual (pyodbc) - pendiente de migrar a pytds |
| pyproject.toml | Dependencias del proyecto (python-tds, msal, pyOpenSSL agregados) |
| Dockerfile | Imagen Docker con ODBC drivers y dependencias Python |
