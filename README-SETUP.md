# Setup Raspberry Pi 5 + ArduCam IMX519 — rama `dev`

Guía paso a paso completa: desde flashear la microSD hasta dejar corriendo el `digitization-toolkit` en una Raspberry Pi 5 con dos cámaras ArduCam IMX519, sobre la rama `dev`.

## Requisitos previos

- Raspberry Pi 5 (8GB recomendado)
- 2x Arducam IMX519 (SKU: B0371)
- 2x cable ribbon CSI 22-a-22 pines (15-20 cm recomendado)
- Fuente oficial 5V/3A o superior (27W recomendado)
- microSD (16GB o más)

---

## 0. Flashear la microSD con Raspberry Pi Imager

⚠️ **Importante:** la opción "recomendada" por defecto de Raspberry Pi Imager (`Raspberry Pi OS (64-bit)`) actualmente instala **Debian 13 (Trixie)**, que este stack **no soporta** — Trixie trae Python 3.13, incompatible con los bindings de `libcamera`/`picamera2` que el proyecto necesita (Python 3.11 vía `pixi`).

**Selecciona en su lugar una de estas dos** (ambas son Debian 12 "Bookworm", 64-bit):

- **`Raspberry Pi OS (Legacy, 64-bit) Lite`** — sin entorno de escritorio, más liviana (422.6 MB). Recomendada si vas a operar principalmente por SSH/terminal.
- **`Raspberry Pi OS (Legacy, 64-bit) Full`** — con entorno de escritorio y aplicaciones. Más cómoda si prefieres interfaz gráfica mientras configuras.

Ambas funcionan igual de bien para este proyecto — la diferencia es solo de comodidad/recursos, no de compatibilidad.

**Pasos en Raspberry Pi Imager:**

1. Elige el dispositivo: **Raspberry Pi 5**.
2. Elige el sistema operativo: una de las dos opciones "Legacy, 64-bit" mencionadas arriba (busca en la lista completa, no en la entrada genérica de arriba).
3. En **opciones avanzadas** (ícono de engranaje ⚙️):
   - **Usuario:** `pi` (obligatorio — los scripts de servicio e instalación de kiosko tienen hardcodeado `User=pi` y `/home/pi/dtk`)
   - **Habilitar SSH** (si vas a hacer provisión headless)
4. Flashea la microSD.

---

## 1. Conexión física de las cámaras

Antes de encender la Pi:

- La Pi 5 tiene dos conectores CSI: **CAM0** y **CAM1**.
- Conecta una ArduCam en cada uno con el ribbon de 22 pines.
- **Orientación:** el refuerzo azul hacia afuera (hacia el puerto Ethernet), contactos metálicos hacia adentro (hacia la placa) — en ambos puertos.
- Verifica que el pestillo del conector quede completamente cerrado.
- Conecta heatsinks/cooling si aplica.
- Inserta la microSD, conecta la fuente oficial, enciende. Conecta periféricos o deja SSH habilitado para operación headless.

---

## 2. Software de cámaras (nivel sistema operativo)

> **Nota:** `rpicam-apps` oficiales de Raspberry Pi no detectan el IMX519 de forma confiable en nuestras pruebas. Usamos el paquete de Arducam.

```bash
wget -O install_pivariety_pkgs.sh https://github.com/ArduCAM/Arducam-Pivariety-V4L2-Driver/releases/download/install_script/install_pivariety_pkgs.sh
chmod +x install_pivariety_pkgs.sh

./install_pivariety_pkgs.sh -p libcamera_dev
./install_pivariety_pkgs.sh -p libcamera_apps
```

Edita el boot config:

```bash
sudo nano /boot/firmware/config.txt
```

Agrega al final del archivo:

```
# Disable auto-detect (doesn't catch third-party sensors reliably)
camera_auto_detect=0

[all]
dtoverlay=imx519,cam0
dtoverlay=imx519
```

> La primera línea (`imx519,cam0`) habilita explícitamente CAM0. La segunda (`imx519`) permite que el kernel detecte CAM1. Ambas son necesarias para dual-cámara.

Opcional — logging de debug:
```
dtdebug=1
```

Guarda y reinicia:

```bash
sudo reboot
```

---

## 3. Verificar detección de cámaras (nivel SO)

```bash
rpicam-hello --list-cameras
```

Salida esperada (dual IMX519):

```
Available cameras
-----------------
0 : imx519 [4656x3496 …] (/base/axi/pcie@…/i2c@88000/imx519@1a)
1 : imx519 [4656x3496 …] (/base/axi/pcie@…/i2c@80000/imx519@1a)
```

Confirmar el media graph (opcional):
```bash
v4l2-ctl --list-devices
media-ctl -p
```

### Prueba rápida

```bash
rpicam-hello --camera 0 -t 5000
rpicam-hello --camera 1 -t 5000

rpicam-jpeg --camera 0 -o cam0.jpg
rpicam-jpeg --camera 1 -o cam1.jpg
```

⚠️ **No continúes al paso 4 hasta confirmar que ambas cámaras aparecen en `--list-cameras`.**

### Troubleshooting

| Problema | Solución |
|---|---|
| `Error -5: failed to read chip id` | Sensor no responde por I²C — reasienta el ribbon, revisa orientación, prueba swap CAM0 ↔ CAM1 |
| Solo se detecta una cámara | Confirma que ambas líneas `dtoverlay` están en el config |
| No aparece `/dev/video0` | `dmesg \| grep imx` |
| Sospecha de undervoltage | `vcgencmd get_throttled` → `0x0` = saludable, distinto de cero = usar fuente oficial |
| Logs de debug (si `dtdebug=1`) | `dmesg \| grep -i imx` y `sudo vcdbg log msg` |
| `ModuleNotFoundError: No module named 'libcamera._libcamera'` al correr el backend | El sistema operativo no es Bookworm (probablemente instalaste Trixie por error). Verifica con `cat /etc/os-release` — si dice `trixie`, tienes que reflashear con una opción "Legacy" (ver paso 0) |

---

## 4. Prerrequisitos de software general

Ninguno de estos viene con Raspberry Pi OS Lite recién flasheado:

```bash
sudo apt update && sudo apt install -y git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Instala la versión exacta de `pixi` que usa el proyecto — las versiones anteriores no pueden leer el formato actual del `pixi.lock` (ver `scripts/setup.sh`):

```bash
curl -fsSL https://pixi.sh/install.sh | PIXI_VERSION=v0.73.0 bash
```

Aplica ambos cambios (grupo `docker` + `PATH` de `pixi`) sin cerrar la terminal:

```bash
exec bash -l
```

O manualmente, si prefieres verificar cada uno por separado:
```bash
newgrp docker
source ~/.bashrc
```

---

## 5. Configurar acceso SSH a GitHub

Los submódulos del repo (`backend`, `frontend`, `wiki`) están registrados con URLs SSH — necesitas una llave SSH asociada a tu cuenta de GitHub antes de clonar.

**Generar la llave:**

```bash
ssh-keygen -t ed25519 -C "catalina-pi"
```

- Dale **Enter** para aceptar la ubicación por defecto (`~/.ssh/id_ed25519`).
- Dale **Enter** dos veces más para dejarla sin passphrase (Enter passphrase / Enter same passphrase again).

**Copiar la llave pública:**

```bash
cat ~/.ssh/id_ed25519.pub
```

Copia la línea completa que empieza con `ssh-ed25519 AAAA...`.

**Agregarla a GitHub:**

1. Ve a [github.com/settings/ssh/new](https://github.com/settings/ssh/new)
2. **Title:** algo descriptivo, ej. `Raspberry Pi Captua`
3. **Key type:** Authentication Key
4. **Key:** pega la llave copiada
5. Click en **Add SSH key**

**Verificar la conexión:**

```bash
ssh -T git@github.com
```

La primera vez te pedirá confirmar el host — escribe `yes`. Deberías ver:

```
Hi <tu-usuario>! You've successfully authenticated, but GitHub does not provide shell access.
```

---

## 6. Clonar el repositorio en `dev`

```bash
git clone --recurse-submodules -b dev https://github.com/UCSB-AMPLab/digitization-toolkit-software.git ~/dtk
cd ~/dtk
```

Si por algún motivo el clonado de submódulos falla con `Permission denied (publickey)`, confirma que el paso 5 se completó correctamente y corre:

```bash
git submodule update --init --recursive
```

---

## 7. Provisión inicial (requiere internet)

```bash
sudo ./scripts/setup.sh
```

Este script crea el `.env` si no existe, construye las imágenes Docker, instala el entorno de `pixi`, y aplica las migraciones de base de datos.

---

## 8. Link de cámaras (específico del proyecto)

```bash
cd backend
pixi install --locked
pixi run setup-camera-link
```

---

## 9. Arrancar el sistema

**Contenedores** (Postgres + Nginx, overlay de producción para Pi):

```bash
cd ~/dtk
docker compose -f docker-compose.yml -f docker-compose.pi.yml up -d --pull never
```

**Backend nativo** (obligatorio para acceso a cámaras — depende de `libcamera`/`picamera2`, específicas de Raspberry Pi), en otra terminal o sesión SSH:

```bash
cd ~/dtk/backend
pixi run start
```

> Si estás en modo desarrollo/pruebas y quieres hot-reload en vez de modo producción estricto, usa `pixi run dev` en lugar de `pixi run start`.

---

## 10. Verificar que todo levantó

```bash
curl http://localhost:8000/health   # → {"status":"ok"}
curl -I http://localhost            # → HTTP 200
```

**Acceso:**
- `http://localhost` → Nginx, sirve el frontend y proxea `/api/` al backend
- `http://localhost:8000/docs` → API directa

---

## 11. Verificar detección de cámaras a nivel de aplicación

El endpoint `/cameras/devices` requiere autenticación (JWT) — un `curl` sin sesión iniciada devolverá `{"detail":"Not authenticated"}`, lo cual **no** significa que las cámaras fallen. Para probarlo de verdad:

1. Abre `http://localhost` en el navegador (o la IP de la Pi desde otra máquina en la misma red).
2. Regístrate/inicia sesión.
3. Ve a la sección de cámaras/captura de la interfaz y confirma que detecta ambas ArduCam.

Si el backend no las detecta y el log muestra algo como:
```
Failed to list camera devices: picamera2 failed to import: ModuleNotFoundError("No module named 'libcamera._libcamera'")
```
revisa la tabla de troubleshooting del paso 3 — casi siempre es un problema de versión de sistema operativo (Trixie en vez de Bookworm).

---

## Notas finales

- **No ejecutes todavía** `./scripts/install-service.sh` ni `./scripts/install-kiosk-service.sh` — son para el arranque automático en modo kiosko de producción final, no para desarrollo/pruebas sobre `dev`.
- El overlay `docker-compose.pi.yml` es requerido en Pi: bind-mountea Postgres en `/var/lib/dtk/db/postgres` (en vez del volumen nombrado `postgres_data` de la compose base) y agrega el reverse proxy de Nginx.
- Si reflasheas la microSD en el futuro, la llave SSH se pierde junto con todo lo demás — deberás repetir el paso 5 (generar una nueva y agregarla a GitHub), o respaldar `~/.ssh` a otra máquina antes de reflashear si prefieres reutilizar la misma.
