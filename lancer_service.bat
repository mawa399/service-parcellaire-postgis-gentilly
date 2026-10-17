@echo off
REM Lance l API pg_featureserv (port 9010) et le serveur de la carte (port 8010), puis ouvre la carte.
REM Python : celui de QGIS par defaut, ou tout Python 3 present dans le PATH.
set PY=python
if exist "C:\Program Files\QGIS 4.0.3\bin\python.exe" set PY="C:\Program Files\QGIS 4.0.3\bin\python.exe"
cd /d "%~dp0pg_featureserv"
start "pg_featureserv" /min pg_featureserv.exe --config config\pg_featureserv.toml
cd /d "%~dp0web"
start "carte" /min %PY% serveur.py
timeout /t 3 >nul
start "" http://localhost:8010
