@ECHO OFF
CD /D "%~dp0"
START "" /B /WAIT CMD /C BackupRestoreTool.cmd
echo.
echo [i] Press any key to close window (debug mode was used).
PAUSE
