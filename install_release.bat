@echo off
REM install_release.bat - Builds release APK and installs it on first connected device.
REM Make sure this file is placed in your Flutter project root (same folder as pubspec.yaml).

setlocal

REM change to project root (assumes bat is in project root)
cd /d "%~dp0"

REM package name
set PACKAGE=com.example.speakeasy_app_fixed

echo.
echo === Checking flutter environment ===
flutter --version
if errorlevel 1 (
  echo Flutter not found. Make sure flutter is installed and on PATH.
  pause
  exit /b 1
)

echo.
echo === Building release APK ===
flutter clean
flutter pub get
flutter build apk --release
if errorlevel 1 (
  echo Build failed. Exiting.
  pause
  exit /b 1
)

REM path to adb (default Windows location)
set ADB="%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"

echo.
echo === Uninstalling old app (if installed): %PACKAGE% ===
%ADB% uninstall %PACKAGE%

echo.
echo === Installing release APK ===
%ADB% install -r "build\app\outputs\flutter-apk\app-release.apk"
if errorlevel 1 (
  echo Install failed. Check the output above.
  pause
  exit /b 1
)

echo.
echo === Launching app ===
%ADB% shell monkey -p %PACKAGE% -c android.intent.category.LAUNCHER 1

echo.
echo === Done! ===
pause
endlocal
