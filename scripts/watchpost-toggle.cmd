@echo off
rem One-click toggle: starts the rig if the camera service is stopped, stops it if running.
rem Runs via the elevated on-demand tasks so no UAC prompt appears (registered by setup.ps1).
rem PENDING catches START_PENDING and STOP_PENDING: a rig mid-start or mid-drain counts as on,
rem so a second click during the slow Off never re-arms everything mid-teardown
sc query Agent | findstr "RUNNING PENDING" >nul
if %errorlevel%==0 (
  schtasks /Run /TN CamRigOff
) else (
  schtasks /Run /TN CamRigOn
)
