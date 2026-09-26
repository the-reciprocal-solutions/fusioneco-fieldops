export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$ANDROID_HOME/platform-tools:$PATH"

ADB="$ANDROID_HOME/platform-tools/adb"

echo "=== ADB ==="
$ADB version

echo "=== USB DEVICES ==="
$ADB devices

echo "=== PHONE IP ==="
IP=$($ADB shell ip route | grep -oE 'src ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' | head -1 | awk '{print $2}')

echo "Detected IP: $IP"

echo "=== ENABLE TCP/IP ==="
$ADB tcpip 5555

sleep 2

echo "=== CONNECT ==="
$ADB connect "$IP:5555"

sleep 2

echo "=== DEVICES ==="
$ADB devices -l