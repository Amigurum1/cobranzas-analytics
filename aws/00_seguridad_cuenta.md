# 00 — Seguridad de la cuenta AWS (hazlo ANTES de crear cualquier recurso)

> Este es el paso 0 real del proyecto. No es trámite: **root puede cerrar la cuenta, borrar todo
> y no tiene ningún límite**. Un error ahí no se deshace y no se puede recuperar. Todo lo demás
> del proyecto se puede rehacer en una hora; esto no.

Marcas usadas en este documento:

- **[TÚ]** — solo puedes hacerlo tú, en la consola de AWS. Yo no tengo acceso a tu cuenta.
- **[LISTO]** — artefacto ya preparado en el repo, no hay que crearlo.

---

## FASE A — Proteger root (hazlo ahora, ya estás dentro)

### A1. Verificar que root NO tenga access keys [TÚ]

En la consola: menú de tu nombre de cuenta (arriba a la derecha) → **Security credentials**
→ sección **Access keys**.

- Si la lista está **vacía** → correcto, sigue al A2.
- Si hay **alguna key** → `Actions` → `Delete`. Sin excepciones: una access key de root da
  control total y permanente de la cuenta a quien la tenga, y no expira.

AWS lo dice explícitamente: *"We strongly recommend that you do not create access keys for your
root user"* ([root user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)).

**Por qué importa más que nada:** una contraseña se filtra y se cambia. Una access key filtrada es
acceso programático silencioso a toda la cuenta, incluyendo facturación.

### A2. Activar MFA en root [TÚ]

Misma página **Security credentials** → sección **Multi-factor authentication (MFA)**
→ `Assign MFA device`.

Datos verificados en la doc de AWS:

- AWS **exige** MFA en el root de todos los tipos de cuenta, con **35 días de gracia** desde el
  primer intento de acceso a la consola. No es opcional.
- Puedes registrar **hasta 8 dispositivos MFA** de cualquier combinación de tipos soportados.

**Recomendación concreta:** registra **dos** dispositivos, no uno. AWS recomienda explícitamente
múltiples MFA para resiliencia. Si pierdes el único dispositivo y no tienes otro, la recuperación
depende de que el **email y el teléfono** registrados en la cuenta sigan activos y accesibles.

- Opción simple: app de autenticación (virtual MFA / TOTP) en tu celular **y** un segundo
  dispositivo (otro celular, tablet o una app en tu PC).
- Opción más fuerte: una llave física FIDO (hardware security key).

**Antes de cerrar la página:** confirma que tienes acceso al **email** con el que creaste la
cuenta y a su **teléfono** registrado. Son los canales de recuperación.

### A3. Dar acceso de facturación a IAM [TÚ]

Sin esto, tu usuario de trabajo **no verá** Billing ni Budgets en la consola y no servirán de nada.

Consola: menú de tu nombre de cuenta → **Account settings** → sección
**IAM user and role access to billing information** → `Edit` → marcar **Activate IAM Access**.

### A4. Salir de root y no volver

Desde aquí, root solo se usa para las **pocas tareas que lo requieren** (`root-user-tasks`). Todo
el trabajo del proyecto se hace con el usuario de trabajo de la Fase B.

**Tareas de ESTE proyecto que sí requieren root** (por diseño de la política del usuario, que
deliberadamente no concede IAM más allá de los roles del proyecto):

| Tarea | Por qué root |
|---|---|
| **Editar la política `AnaliticaCobranzasPermisosProyecto`** | `bruno-admin` no tiene `iam:CreatePolicyVersion` y `PowerUserAccess` niega `iam:*` |
| Crear un rol fuera de los 3 del proyecto, o borrar uno | `iam:CreateRole` está acotado a 3 ARNs y `iam:DeleteRole` no se concede a propósito |

**Lo que NO requiere root**: crear el bucket, subir datos, ejecutar Glue, consultar Athena,
crear el namespace/workgroup de Redshift, ejecutar los SQL y desplegar el Lambda. **Si algo de eso
te pide root, es señal de que un permiso quedó mal configurado.**

> **No se concede `iam:CreatePolicyVersion` al usuario de trabajo**: permitir que alguien edite su
> propia política es autoelevación de privilegios. Por eso este cambio puntual se hace con root y
> **se cierra la sesión de root inmediatamente después**.

---

## FASE B — Tu usuario de trabajo

### B0. Decisión: ¿usuario IAM o IAM Identity Center?

| | Usuario IAM con MFA | IAM Identity Center |
|---|---|---|
| Pasos de configuración | Pocos | Varios (instancia, permission set, asignación) |
| Tipo de credencial | **De largo plazo** (access key) | **Temporales** (SSO) |
| Recomendado por AWS | Para casos simples | Sí, para varios usuarios/cuentas o IdP externo |
| CLI | `aws configure` | `aws configure sso` |

Los scripts del proyecto soportan **ambos** (así lo dice `01_setup_s3.ps1`, línea 54-55).

**Recomendación para este proyecto: usuario IAM con MFA.** Una persona, una cuenta, un proyecto.
Identity Center es la respuesta correcta cuando hay equipo o varias cuentas, y añade ceremonia que
aquí no aporta. Si más adelante quieres hacerlo "como en una empresa", migrar es un ejercicio en
sí mismo y lo puedes montar encima.

**El costo de esta decisión, dicho claro:** la access key del usuario IAM es de largo plazo. Si se
filtra, hay que rotarla. Por eso: MFA obligatorio en el usuario, y la key **solo** en tu máquina
(nunca en un repo, nunca en un chat).

### B1. Crear la política del proyecto [LISTO]

Ya está en `aws\politica_iam_usuario_trabajo.json`. **Ábrelo y léelo antes de usarlo** — la sección
de abajo explica qué permite y por qué.

> **OJO — si ya creaste esta política con otro nombre.** El proyecto se renombró el **2026-09-28**
> para desligarlo de cualquier empresa concreta: la política y los roles pasaron al prefijo
> `analitica-cobranzas-`. **Los nombres anteriores ya no aparecen en ningún script**, así que
> aquella política ya no autoriza nada útil. Y una política de IAM **no se puede renombrar**: hay
> que crear la nueva con el JSON actual, adjuntarla al grupo y **borrar la vieja**.

### B2. Crear el grupo y el usuario [TÚ]

En la consola de IAM:

1. **Policies → Create policy → pestaña JSON** → pega el contenido de
   `politica_iam_usuario_trabajo.json` → nombre: `AnaliticaCobranzasPermisosProyecto`.
2. **Policies → Create policy → pestaña JSON** → pega el contenido de
   `politica_autogestion_credenciales.json` → nombre: `AutogestionCredenciales`.
   **Sin esta política te vas a bloquear**: `PowerUserAccess` niega `iam:*`, así que tu usuario no
   podría configurar su propio MFA ni crear su access key. Ver la explicación al final.
3. **User groups → Create group** → nombre: `data-portfolio-admins`.
4. Al grupo, adjunta **tres** políticas:
   - `PowerUserAccess` (administrada por AWS)
   - `AnaliticaCobranzasPermisosProyecto`
   - `AutogestionCredenciales`
5. **Users → Create user** → nombre: `bruno-admin` → marca **Provide user access to the AWS
   Management Console** y asigna una contraseña fuerte.
6. Añade el usuario al grupo `data-portfolio-admins`. **Si lo olvidas, el usuario no tendrá
   ningún permiso.**

### B3. MFA en el usuario de trabajo [TÚ]

**No necesitas comprar ni tener un dispositivo adicional.** Una app de autenticación (Google
Authenticator, Authy, Microsoft Authenticator) es gratis y puede vivir en el **mismo teléfono** que
ya usas para el MFA de root. "Dispositivo distinto" significa **no reutilizar el mismo registro
MFA**, no comprar hardware.

**El trade-off, sin dramatizar:**

| Opción | Qué ganas | Qué arriesgas |
|---|---|---|
| MFA en el **mismo** teléfono | El login a la consola queda protegido | Si pierdes el teléfono pierdes ambos MFA — pero root se recupera con email + teléfono de la cuenta, y desde root puedes resetear el MFA del usuario |
| **Sin** MFA en el usuario | Nada | Quien consiga tu contraseña de consola entra directo |

Tenerlo en el mismo teléfono es **mejor que no tenerlo**.

**Lo que el MFA del usuario NO protege:** las llamadas del **CLI con access key** siguen
funcionando sin MFA. El MFA protege la consola. El eslabón débil real es la **access key**: no se
comparte, no se sube al repo y se rota si se sospecha. Para cerrar ese hueco haría falta migrar a
credenciales temporales (IAM Identity Center) o usar `aws sts get-session-token` con MFA.

> **Riesgo aceptado (2026-09-28):** el usuario de trabajo se creó **sin MFA** por falta de un
> segundo dispositivo. Mitigación: la access key no sale de la máquina local, y los **Budgets de la
> Fase C** pasan a ser la defensa principal contra un uso indebido de la key.

### B4. Access key solo para el CLI [TÚ]

**Security credentials** (del usuario, no de root) → **Access keys** → `Create access key`
→ caso de uso: **Command Line Interface (CLI)**.

**Deja VACÍO el campo de descripción/etiqueta.** Si escribes algo ahí, la consola intenta etiquetar
al usuario y exige `iam:TagUser`, que no está en ninguna de tus políticas; verás el error
*"is not authorized to perform: iam:TagUser"*. Según la
[doc de AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-keys_required-permissions.html),
esa etiqueta es **opcional** y no aporta nada aquí. No concedemos `iam:TagUser`: las etiquetas se
usan en condiciones de control de acceso, así que poder auto-etiquetarse es un vector de escalada.

Copia el **Access key ID** y el **Secret access key** en ese momento: el secret **no se vuelve a
mostrar**.

> **Es normal ver un aviso rojo de "Acceso denegado a `iam:ListSigningCertificates`"** en esa
> página. La consola intenta cargar también las secciones de certificados de firma, claves SSH y
> credenciales Git de CodeCommit, y la política de autogestión las excluye a propósito. **Es ruido
> visual: no afecta a tus access keys, ni a tu MFA, ni al CLI.** Ignóralo.

### B5. Configurar el CLI [TÚ]

```powershell
aws configure
```

- Access key ID / Secret access key: los de B4
- Default region name: `us-east-1`
- Default output format: `json`

### B6. Verificar que NO eres root [TÚ]

```powershell
aws sts get-caller-identity
```

Mira el campo `Arn`:

- **Correcto:** termina en `:user/bruno-admin`
- **Mal:** termina en `:root` → no terminaste la Fase A/B

Los scripts ya se protegen solos: `01_setup_s3.ps1` aborta si detecta que eres root.

---

## FASE C — El dinero

### C1. Un presupuesto, tres alertas

Consola: **Billing and Cost Management** → **Budgets** → `Create budget`.
Pasos exactos, verificados en la
[doc oficial](https://docs.aws.amazon.com/cost-management/latest/userguide/create-cost-budget.html):

1. **Budget setup** → **Customize (advanced)**.
2. **Budget types** → **Cost budget** → `Next`.
3. **Budget name** → `cobranzas-mensual`.
4. **Period** → `Monthly` · **Budget renewal type** → `Recurring budget` ·
   **Budgeting method** → `Fixed` · **Budgeted amount** → **10** (USD).
5. `Next` → pulsa **`Add an alert threshold`** y repítelo para cada una de las tres:

| Threshold | Tipo | Qué te dice |
|---|---|---|
| **1** | `Absolute value` · `Actual` | Ya hay gasto real: algo se creó |
| **5** | `Absolute value` · `Actual` | Zona de alarma: Redshift son **$1.50/hora**; si no lo encendiste tú, algo quedó prendido |
| **10** | `Absolute value` · `Actual` | Techo del presupuesto mensual |

6. En **cada** alerta, rellena **Email recipients** con tu correo. AWS no te deja avanzar si una
   alerta no tiene email, SNS o acción asociada.
7. `Next` → `Next` → `Create budget`.

**Añade una cuarta alerta de tipo `Forecasted`** con umbral $5. Motivo: AWS advierte que hay
retraso entre usar un recurso y que el gasto se registre, así que el pronóstico avisa **antes** de
que el gasto real aparezca.

Verificado: un presupuesto admite **múltiples notificaciones** (por eso **no necesitas tres
presupuestos** — con uno basta para el $1 / $5 / $10 del checklist) y el umbral puede ser valor
**absoluto**, no solo porcentaje.

**Advertencia honesta sobre el costo de Budgets:** no he podido verificar en la documentación
oficial cuál es el cargo por presupuesto adicional. **No te lo voy a inventar.** Verifícalo tú en
la página de precios de AWS Budgets antes de crear un cuarto, y por eso la recomendación es usar
**uno solo**.

### C2. Alertas de capa gratuita

En **Billing and Cost Management → Billing preferences**, activa las alertas de uso de la capa
gratuita. Son independientes de Budgets y avisan cuando te acercas a salir del free tier.

### C3. Región fija: us-east-1

`us-east-1` (Norte de Virginia), para todo. Es la que asume el proyecto y es la más barata.
Trabajar en dos regiones sin darte cuenta duplica recursos y costos.

---

## Checklist final

- [ ] A1 — root sin access keys
- [ ] A2 — MFA en root, con **dos** dispositivos y recuperación verificada
- [ ] A3 — IAM con acceso a la información de facturación
- [ ] A4 — salir de root
- [ ] B1 — política `AnaliticaCobranzasPermisosProyecto` creada
- [ ] B1b — política `AutogestionCredenciales` creada
- [ ] B2 — grupo `data-portfolio-admins` con las **tres** políticas
- [ ] B3 — usuario `bruno-admin` con MFA propio
- [ ] B4 — access key creada **para el usuario**, no para root
- [ ] B5 — `aws configure` con región `us-east-1`
- [ ] B6 — `aws sts get-caller-identity` NO devuelve `:root`
- [ ] C1 — un presupuesto con alertas en $1 / $5 / $10
- [ ] C2 — alertas de capa gratuita activadas
- [ ] C3 — región fija us-east-1

---

## Por qué la política del proyecto es así

`PowerUserAccess` da acceso amplio, **pero no a IAM** — su `NotAction` excluye `iam:*`,
`organizations:*` y `account:*` ([referencia oficial](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/PowerUserAccess.html)).
Y tus scripts **sí necesitan IAM**: `03_crear_glue_job.ps1` y `05_configurar_lambda.ps1` crean
roles con `iam:CreateRole`, `iam:AttachRolePolicy` y `iam:PutRolePolicy`.

Eso deja un hueco, y este es el punto delicado:

- **`iam:PassRole` es el permiso con el que se escala privilegios.** Quien puede pasar un rol
  arbitrario a un servicio puede, en la práctica, obtener los permisos de ese rol.
- Por eso la política del proyecto **no** da `iam:PassRole` sobre `*`. Lo limita a los **dos roles
  exactos** del proyecto (`AWSGlueServiceRole-analitica-cobranzas` y `analitica-cobranzas-lambda-role`, los
  nombres reales que usan tus scripts) y además exige la condición
  `iam:PassedToService` para `glue.amazonaws.com` y `lambda.amazonaws.com`.
- `iam:CreateRole` y las de configuración también están acotadas a esos dos ARNs.

**Concesión honesta que sí estoy haciendo:** `PowerUserAccess` no se puede acotar por recurso, así
que el usuario de trabajo tiene acceso amplio al resto de servicios (S3, Glue, Lambda, Redshift,
etc.). Eso significa que **puede crear recursos que cuestan dinero en cualquier región**. La
defensa contra eso no es IAM, son los Budgets de la Fase C. Decirlo así es más útil que fingir
que es least-privilege perfecto.

**Lo que NO incluye a propósito:** `iam:DeleteRole`, `iam:DetachRolePolicy`, `iam:CreateUser`.
Los scripts no los necesitan. Si algún día necesitas borrar un rol, lo haces desde root (es una
tarea puntual) y lo documentas.

### Por qué además hace falta la política de autogestión

La política del proyecto **no** incluye `iam:CreateAccessKey`, y hace bien: un permiso para crear
credenciales es escalada de privilegios. Pero entonces, ¿cómo crea tu propio usuario su access key?

`PowerUserAccess` tampoco lo resuelve, porque niega `iam:*`. Y la doc de AWS es explícita: para que
un usuario gestione sus credenciales y su MFA desde **Security credentials** hace falta una política
aparte ([tutorial oficial](https://docs.aws.amazon.com/IAM/latest/UserGuide/tutorial_users-self-manage-mfa-and-creds.html)).

`AutogestionCredenciales` es exactamente eso: los `Allow` de la política estándar de AWS
([AWS: Allows MFA-authenticated IAM users to manage their own credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_examples_aws_my-sec-creds-self-manage.html)),
con **dos recortes deliberados**:

- **Fuera los permisos de CodeCommit** (certificados de firma, claves SSH y credenciales Git).
  Este proyecto no usa CodeCommit; no hay razón para concederlos.
- **Fuera el statement `DenyAllExceptListedIfNoMFA`.** Ese `Deny` exige MFA presente en *cada*
  llamada y, en palabras de la propia doc, *"a user accessing an API with long-term credentials,
  such as an access key, is denied access to the non-IAM API operations"*. O sea: **dejarlo dentro
  rompería tu AWS CLI**, porque la access key no lleva MFA. Todo el `Resource` está acotado a
  `arn:aws:iam::*:user/${aws:username}`: el usuario **solo puede tocar sus propias** credenciales.

### Endurecimiento opcional para después

Se puede exigir MFA en cada llamada con una condición `aws:MultiFactorAuthPresent`. **Ojo:** eso
**rompe el CLI con access keys de largo plazo**, porque esa clave solo se cumple con credenciales
temporales (por ejemplo `aws sts get-session-token --serial-number <arn-mfa> --token-code <codigo>`).
Queda como ejercicio posterior, no lo activamos ahora.

---

## Lo que NO debes hacer

| Antipatrón | Por qué |
|---|---|
| Crear access keys para root | Control total y permanente; no expira |
| Trabajar el día a día como root | Un error es irreversible y no hay auditoría útil |
| Reutilizar el mismo teléfono para MFA de root y del usuario | Pierdes los dos factores a la vez |
| Dar `AdministratorAccess` al usuario de trabajo | Evita aprender IAM y oculta errores de permisos |
| Dar `iam:PassRole` sobre `*` | Es escalada de privilegios, no un permiso más |
| Subir access keys al repo o pegarlas en un chat | Se filtran de inmediato y hay que rotarlas |
| Saltarse Budgets "porque es poquito" | Redshift Serverless cuesta $1.50/hora si se queda encendido |
| Crear recursos en varias regiones | Duplica costos y desordena el inventario |
