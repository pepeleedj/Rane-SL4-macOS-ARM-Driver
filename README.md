<h1 align="center">Rane SL4 macOS ARM Driver (Apple Silicon M1 / M2 / M3 / M4)</h1>

<p align="center">
  <strong>Native User-Space CoreAudio Driver + Serato DJ Pro 2.5.5 Bridge (<code>SL4Api.framework</code>) for Rane SL 4 on Modern Macs</strong><br>
  <em>Original idea & project by <strong>pepelee (PPLEE)</strong> — <a href="https://www.instagram.com/pepeleedj/">@pepeleedj</a> &nbsp;|&nbsp; Ultra-low-latency audio engine & CoreAudio architecture with <strong>Ben XO</strong> (<a href="https://github.com/ben-xo">@ben-xo</a>)</em>
</p>

<p align="center">
  <a href="https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip"><strong>⬇️ DOWNLOAD INSTALLER (.ZIP)</strong></a>
  &nbsp;|&nbsp;
  <a href="https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Installer/RaneSL4-macOS-Universal.pkg"><strong>📦 DOWNLOAD .PKG DIRECTLY</strong></a>
  &nbsp;|&nbsp;
  <a href="#-español-instrucciones-en-español"><strong>🇪🇸 LEER EN ESPAÑOL</strong></a>
</p>

---

## 🇬🇧 English

### Why does this exist?
When Apple transitioned to **Apple Silicon (M1 / M2 / M3 / M4)** and modern macOS versions, Rane and Serato discontinued support for the flagship **Rane SL 4** dual-USB DVS audio interface because the official Rane driver relied on a legacy Intel Kernel Extension (`SL4.10.9.kext`).

**This project ports the proven Rane SL3 user-space architecture to the Rane SL 4 on Apple Silicon Macs (M1, M2, M3, M4 — Base, Pro, Max, Ultra) and modern macOS (Monterey, Ventura, Sonoma, Sequoia, and newer):**

* ✅ **Designed for Serato DJ Pro 2.5.5** (the last Serato version that supports Rane SL 4 hardware—unlocks 4-deck DVS `ABS` / `REL` / `INT` modes, Aux I/O, Dual USB A/B port status, and `THRU` control via `SL4Api.framework`).
* ✅ **NO SIP Disable Required & NO Reboot Required:** Runs 100% in user space via Apple's modern `AudioServerPlugIn` (CoreAudio HAL) and `IOUSBHost` frameworks, plus a custom Universal `SL4Api.framework` user-space bridge.
* ✅ **Works with the macOS System Settings "SL 4" Control Panel** and includes a terminal control utility (`sl4panel`) to switch between **Phono / Line** across all 4 inputs, toggle **Thru**, and change sample rates (**44.1 kHz / 48 kHz / 96 kHz**).
* ✅ **Works as a 10-In / 10-Out (24-bit) CoreAudio Soundcard** in **Mixxx, Traktor, Ableton Live, Rekordbox, Logic Pro**, and system-wide macOS audio.
* ✅ **Ultra-Low-Latency Audio Engine (~9–15 ms DVS Round-Trip):** Deep-scheduled isochronous USB playback with late writes directly from `WriteMix`, low-latency capture (`IN_SAFETY = 4 ms`, `OUT_SAFETY = 3 ms`), native macOS master + 10-channel volume/mute controls (`-64 dB` to `0 dB` with click-free ramping), and seamless USB hot-plug reconnect.

---

### 🚀 Quick Installation (1-Click)

1. [**Download `Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip) and unzip it on your Mac.
2. Open Terminal and clear macOS Gatekeeper quarantine on the downloaded folder:
   ```bash
   xattr -cr ~/Downloads/Rane-SL4-Installer-Mac-M1-M2-M3-M4
   ```
3. Double-click **`Instalar-Rane-SL4.command`** (or right-click -> **Open** on **`RaneSL4-macOS-Universal.pkg`**).
4. Enter your Mac password when prompted.
5. **Done!** `coreaudiod` reloads automatically (no reboot needed). Plug in your Rane SL 4 via USB A or USB B!

---
---

## 🇪🇸 Español (Instrucciones en Español)

### ¿Qué es este proyecto?
Con la llegada de los procesadores **Apple Silicon (M1 / M2 / M3 / M4)** y los nuevos sistemas macOS, las míticas tarjetas **Rane SL 4** quedaron sin soporte oficial porque el driver original de Rane dependía de una extensión de kernel antigua (`SL4.10.9.kext`) para procesadores Intel.

**Este driver traslada la arquitectura probada en la Rane SL 3 a la Rane SL 4 para cualquier Mac moderno (M1, M2, M3, M4 y variantes Pro, Max, Ultra):**

* ✅ **Compatible con Serato DJ Pro 2.5.5** (la última versión de Serato compatible con Rane SL 4; activa los 4 platos en modo DVS `ABS` / `REL` / `INT`, canal Aux, estado de doble puerto USB A/B y `THRU`).
* ✅ **SIN desactivar la seguridad del Mac (SIP) y SIN reiniciar:** Todo funciona en espacio de usuario mediante un plugin HAL de CoreAudio (`SL4Device.driver` sobre `IOUSBHost`) junto con un puente nativo Universal (`SL4Api.framework`).
* ✅ **Funciona con el panel "SL 4" en Ajustes del Sistema de macOS** e incluye utilidad de control (`Panel-Control-SL4.command` / `sl4panel`) para cambiar entre **Phono / Line** en los 4 canales, activar/desactivar **Thru** y elegir entre **44.1 kHz, 48 kHz y 96 kHz**.
* ✅ **Funciona como tarjeta de sonido de 10 Entradas y 10 Salidas (24-bit)** en **Ableton Live, Traktor, Mixxx, Rekordbox, Logic Pro** y el audio general de macOS.
* ✅ **Motor de Audio de Ultra-Baja Latencia (~9–15 ms DVS Round-Trip):** Escritura tardía (`late-write`) directa sobre transferencias USB isócronas desde `WriteMix`, captura de baja latencia, control nativo de volumen/mute en macOS (Master + 10 canales con rampa sin clics) y reconexión USB en caliente (`hot-plug`).

---

### 🚀 Instalación Paso a Paso

1. [**Descarga `Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip`**](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver/raw/main/Rane-SL4-Installer-Mac-M1-M2-M3-M4.zip) y descomprímelo.
2. Si macOS bloquea los archivos descargados de Internet, abre **Terminal**, escribe `xattr -cr ` (con un espacio al final), arrastra la carpeta descomprimida dentro de la Terminal y pulsa **ENTER**.
3. Haz doble clic en **`Instalar-Rane-SL4.command`** (o abre **`RaneSL4-macOS-Universal.pkg`**), introduce la contraseña de tu Mac y pulsa ENTER.

#### Canales de Audio (10 Entradas / 10 Salidas a 24-bit, 44.1 / 48 / 96 kHz)
* **Canales 1–2:** Deck 1 (Plato / CDJ 1)
* **Canales 3–4:** Deck 2 (Plato / CDJ 2)
* **Canales 5–6:** Deck 3 (Plato / CDJ 3)
* **Canales 7–8:** Deck 4 (Plato / CDJ 4)
* **Canales 9–10:** Aux (Entrada / Salida Auxiliar)

---

### 🙌 Créditos y Licencia / Credits & License
* **Idea original, puente Serato (`SL4Api.framework`), utilidad `sl4panel` e instalador macOS Universal:** **pepelee (PPLEE)** — Instagram: [@pepeleedj](https://www.instagram.com/pepeleedj/)
* **Arquitectura de baja latencia (`WriteMix` late-write, controles de volumen/mute CoreAudio, hot-plug):** **Ben XO** — GitHub: [@ben-xo](https://github.com/ben-xo)
* **Licencia:** [GPL-3.0-or-later](LICENSE).
* *Disclaimer:* Proyecto independiente no afiliado con Rane ni Serato.

---

### 🔗 Other Rane Series Drivers for Apple Silicon (M1 / M2 / M3 / M4)
* 🎛️ **Rane SL 2:** [pepeleedj/Rane-SL2-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL2-Macos-ARM-Driver)
* 🎛️ **Rane SL 3:** [pepeleedj/Rane-SL3-Macos-ARM-Driver](https://github.com/pepeleedj/Rane-SL3-Macos-ARM-Driver)
* 🎛️ **Rane SL 4:** [pepeleedj/Rane-SL4-macOS-ARM-Driver](https://github.com/pepeleedj/Rane-SL4-macOS-ARM-Driver)
