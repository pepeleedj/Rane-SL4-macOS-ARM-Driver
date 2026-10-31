#!/bin/bash
set -e

clear
echo "=========================================================="
echo "   DESINSTALADOR DRIVER RANE SL4                          "
echo "=========================================================="
echo ""
echo "Se eliminaran el driver SL4Device.driver, SL4Api.framework y el panel de control."
echo "(Te pedira la contrasena de inicio de sesion de tu Mac)"
echo ""

sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SL4Device.driver"
sudo rm -rf "/Library/Frameworks/SL4Api.framework"
sudo rm -rf "/Library/PreferencePanes/SL 4 Audio Control Panel.prefPane"
sudo rm -rf "/Library/Extensions/SL4.10.9.kext"
sudo rm -f "/usr/local/bin/sl4panel"
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod >/dev/null 2>&1 || sudo killall coreaudiod >/dev/null 2>&1 || true

echo ""
echo "Driver Rane SL4 desinstalado correctamente."
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
