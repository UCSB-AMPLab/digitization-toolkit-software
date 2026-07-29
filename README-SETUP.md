# Setup Raspberry Pi 5 + ArduCam IMX519 — rama `dev`

Guía paso a paso para dejar corriendo el `digitization-toolkit` en una Raspberry Pi 5 recién inicializada, con dos cámaras ArduCam IMX519, sobre la rama `dev`.

## Requisitos previos

- Raspberry Pi 5 (8GB recomendado)
- 2x Arducam IMX519 (SKU: B0371)
- 2x cable ribbon CSI 22-a-22 pines (15-20 cm recomendado)
- Fuente oficial 5V/3A o superior (27W recomendado)
- microSD con Raspberry Pi OS Lite (64-bit) — **no** la versión Trixie/Debian 13, este stack está validado sobre Bookworm/Debian 12

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

---

## 4. Prerrequisitos de software general

Ninguno de estos viene con Raspberry Pi OS Lite recién flasheado:

```bash
sudo apt update && sudo apt install -y git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER          # re-login para que tome efecto
```

Cierra sesión y vuelve a entrar (o `newgrp docker`).

```bash
curl -fsSL https://pixi.sh/install.sh | bash
```

Cierra y abre la terminal de nuevo (o `source ~/.bashrc`) para que `pixi` quede en el `PATH`.

---

## 5. Clonar el repositorio en `dev`

```bash
git clone --recurse-submodules -b dev https://github.com/UCSB-AMPLab/digitization-toolkit-software.git ~/dtk
cd ~/dtk
```

---

## 6. Provisión inicial (requiere internet)

```bash
sudo ./scripts/setup.sh
```

Este script crea el `.env` si no existe, construye las imágenes Docker, instala el entorno de `pixi`, y aplica las migraciones de base de datos.

---

## 7. Link de cámaras (específico del proyecto)

```bash
cd backend
pixi install --locked
pixi run setup-camera-link
```

---

## 8. Arrancar el sistema

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

## 9. Verificar que todo levantó

```bash
curl http://localhost:8000/health   # → {"status":"ok"}
curl -I http://localhost            # → HTTP 200
```

**Acceso:**
- `http://localhost` → Nginx, sirve el frontend y proxea `/api/` al backend
- `http://localhost:8000/docs` → API directa

---

## 10. Verificar detección de cámaras a nivel de aplicación

```bash
curl http://localhost:8000/cameras/devices
```

Debería devolver ambas ArduCam — si devuelve `[]`, revisa el paso 3 (detección a nivel de sistema operativo) antes de asumir que es un problema del backend.

---

## Notas finales

- **No ejecutes todavía** `./scripts/install-service.sh` ni `./scripts/install-kiosk-service.sh` — son para el arranque automático en modo kiosko de producción final, no para desarrollo/pruebas sobre `dev`.
- El overlay `docker-compose.pi.yml` es requerido en Pi: bind-mountea Postgres en `/var/lib/dtk/db/postgres` (en vez del volumen nombrado `postgres_data` de la compose base) y agrega el reverse proxy de Nginx.
